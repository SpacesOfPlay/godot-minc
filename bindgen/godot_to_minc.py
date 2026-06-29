#!/usr/bin/env python3
"""Generate minc GDExtension bindings from Godot's extension_api.json.

Driven by a used-set spec (an explicit allow-list - the API has ~14k
methods). For each requested global enum it emits a minc `enum`; for each
requested class method it emits a wrapper - a cached MethodBind
(classdb_get_method_bind, resolved on first call) plus an
object_method_bind_ptrcall with the arguments marshalled per type.

The generated files are importable modules (lib/godot_{enums,classes,utility}.mc);
the method wrappers call the core runtime in lib/godot_core.mc (gd_method,
gd_ptrcall).

To add a binding, edit + regen: add the method name to bindgen/bindings.json
under its class (or a new "Class": [...] entry), then regenerate. Inherited
methods are defined on the base class that declares them - list them there (the
wrapper takes any GdObject*, so it works on subclasses).

Spec (JSON), e.g. bindgen/bindings.json:
  { "enums": ["Variant.Type", "MethodFlags"],
    "classes": { "Node": ["set_name", "add_child"] },
    "utility": ["deg_to_rad", "lerpf", "randf"] }   // global free functions

Usage:
  # Discover what a class exposes (names, signatures, void* fallbacks):
  godot_to_minc.py <extension_api.json> --list Node3D
  # Validate a spec without writing (friendly errors: typos, inherited-from,
  # virtual/vararg). Good to run after editing bindings.json:
  godot_to_minc.py <extension_api.json> --spec bindgen/bindings.json --check
  # Generate:
  godot_to_minc.py <extension_api.json> \
      --spec bindgen/bindings.json --outdir lib

Instance methods bind directly. Static methods bind too (same MethodBind,
ptrcalled with a null instance, no `self`). Singleton classes (Input, Engine,
Time, OS, …, detected from the API's singleton list) get a cached
<class>_singleton() accessor instead of <class>_new(), and their method wrappers
take no `self`. Virtual methods are implemented (not bound) via gd_bind_virtual,
and vararg methods go through the Variant call path.

Default arguments: for each trailing arg Godot defaults to a simple literal
(bool/int/float/null), the generator emits a shorter same-name overload that
fills it; minc resolves the call by arity. A non-literal default (String "",
Vector3(0,1,0), Variant) stops parsing.

Transitive closure: an engine class referenced by a bound method's arg/return
but not listed gets an auto-pulled <class>_new() (if instantiable) or singleton
accessor. --check reports them; listing a class explicitly removes it from the
auto set.
"""

import argparse
import json
import re
import sys

# ptrcall argument/return categories and the minc parameter type each maps to.
# - builtin : opaque value (String, Vector2, ...) passed as a pointer to its
#             buffer; the minc param IS that pointer, so it marshals directly.
# - object  : Object-derived; ptrcall wants &Object*, so marshal &param.
# - bool/int/float : scalar; marshal &param.
# `object` is the opaque GdObject* handle; a builtin with a value type in the
# core maps to a typed pointer, any other falls back to void*.
PARAM_TYPE = {"bool": "u8", "int": "i64", "float": "f64",
              "builtin": "void*", "object": "GdObject*"}
# Builtin types that have a matching value struct in lib/godot_core.mc.
# A method arg/return of one of these maps to its typed pointer; any other
# builtin (Array, Dictionary, RID, …) falls back to void*. To add one: define
# the struct in lib/godot_core.mc (sized to the float_64 build) and add it here.
BUILTIN_TYPE = {
    "String": "GdString", "StringName": "GdStringName", "NodePath": "GdNodePath",
    "Variant": "GdVariant", "Callable": "GdCallable",
    "Vector2": "GdVector2", "Vector2i": "GdVector2i",
    "Vector3": "GdVector3", "Vector3i": "GdVector3i", "Vector4": "GdVector4",
    "Color": "GdColor", "Rect2": "GdRect2", "Plane": "GdPlane",
    "Quaternion": "GdQuaternion", "AABB": "GdAABB", "Basis": "GdBasis",
    "Transform2D": "GdTransform2D", "Transform3D": "GdTransform3D",
}


def param_type(t, cat):
    if cat == "builtin":
        bt = BUILTIN_TYPE.get(t)
        return (bt + "*") if bt else "void*"
    return PARAM_TYPE[cat]


def categorize(t, builtins, classes):
    if t == "bool":
        return "bool"
    if t == "float":
        return "float"
    if t == "int" or t.startswith("enum::") or t.startswith("bitfield::"):
        return "int"
    if t.startswith("typedarray::"):
        return "builtin"  # Array
    if t in builtins:
        return "builtin"
    if t in classes:
        return "object"
    # Unknown / Object: treat as an object handle (single pointer).
    return "object"


def marshal(cat, t, pname):
    # Builtins are already a pointer-to-buffer (typed Gd<T>* needs a void* cast
    # for the args array; bare void* passes directly); everything else needs &.
    if cat != "builtin":
        return "cast(void*, &" + pname + ")"
    return ("cast(void*, " + pname + ")") if BUILTIN_TYPE.get(t) else pname


# Flat POD math types whose Godot flat constructor args map 1:1 onto the Gd<T>
# struct fields (verified: Transform2D(1,0,0,1,0,0) / Transform3D(1,0,…) are the
# identities in field order). field_count, and whether fields are int.
FLAT_POD = {
    "Vector2": (2, False), "Vector2i": (2, True),
    "Vector3": (3, False), "Vector3i": (3, True), "Vector4": (4, False),
    "Color": (4, False), "Rect2": (4, False), "Plane": (4, False),
    "Quaternion": (4, False), "AABB": (6, False), "Basis": (9, False),
    "Transform2D": (6, False), "Transform3D": (12, False),
}
SN_KIND = {"String": "string", "StringName": "stringname", "NodePath": "nodepath"}


def _f32lit(s):
    s = s if any(c in s for c in ".eE") else s + ".0"
    return s + "f"


def default_arg(cat, t, dv, idx):
    # Describe how an overload fills a defaulted argument. Returns a dict
    # {setup: [lines], expr: str, teardown: [lines]} or None (can't represent →
    # the peel stops). Simple literals have empty setup/teardown; non-literal
    # defaults (a String, a Vector3, a nil Variant) build a local `_d<idx>`.
    if cat == "bool":
        v = "1" if dv == "true" else "0" if dv == "false" else None
        return {"setup": [], "expr": v, "teardown": []} if v else None
    if cat == "int":
        try:
            int(dv, 0)
        except ValueError:
            return None
        return {"setup": [], "expr": dv, "teardown": []}
    if cat == "float":
        try:
            float(dv)
        except ValueError:
            return None
        return {"setup": [], "expr": dv if any(c in dv for c in ".eE") else dv + ".0",
                "teardown": []}
    if cat == "object":
        return {"setup": [], "expr": "null", "teardown": []} if dv in ("null", "") else None

    # --- builtin value types: build a local ---
    if not BUILTIN_TYPE.get(t):
        return None
    gt = BUILTIN_TYPE[t]
    loc = "_d%d" % idx

    if t in SN_KIND:                                  # String / StringName / NodePath
        s = dv[1:] if dv.startswith("&") else dv      # StringName defaults are &"…"
        if not (len(s) >= 2 and s[0] == '"' and s[-1] == '"'):
            return None
        if t == "NodePath" and dv.startswith("NodePath("):
            inner = dv[len("NodePath("):-1].strip()
            if not (len(inner) >= 2 and inner[0] == '"' and inner[-1] == '"'):
                return None
            s = inner
        kind = SN_KIND[t]
        return {"setup": ["%s %s;" % (gt, loc), 'gd_%s_new(&%s, %s);' % (kind, loc, s)],
                "expr": "&" + loc, "teardown": ["gd_%s_destroy(&%s);" % (kind, loc)]}

    if t == "NodePath" and dv.startswith("NodePath("):
        inner = dv[len("NodePath("):-1].strip()
        if not (len(inner) >= 2 and inner[0] == '"' and inner[-1] == '"'):
            return None
        return {"setup": ["%s %s;" % (gt, loc), 'gd_nodepath_new(&%s, %s);' % (loc, inner)],
                "expr": "&" + loc, "teardown": ["gd_nodepath_destroy(&%s);" % loc]}

    if t == "Variant":
        if dv == "null":                              # nil Variant: a zeroed local
            return {"setup": ["GdVariant %s;" % loc], "expr": "&" + loc, "teardown": []}
        try:
            int(dv, 0)
        except ValueError:
            return None
        return {"setup": ["GdVariant %s;" % loc, "gd_variant_int(&%s, %s);" % (loc, dv)],
                "expr": "&" + loc, "teardown": ["gd_variant_destroy(&%s);" % loc]}

    pod = FLAT_POD.get(t)
    if pod:
        m = re.match(r'^([A-Za-z0-9_]+)\((.*)\)$', dv)
        if m and m.group(1) == t:
            inner = m.group(2).strip()
            comps = [a.strip() for a in inner.split(",")] if inner else []
            if len(comps) == pod[0] and all("(" not in a for a in comps):
                comps = [c if pod[1] else _f32lit(c) for c in comps]
                return {"setup": ["%s %s = %s{ %s };" % (gt, loc, gt, ", ".join(comps))],
                        "expr": "&" + loc, "teardown": []}
    return None


def gen_method(cls, m, builtins, classes, is_singleton=False):
    name = m["name"]
    fp = cls.lower() + "_" + name
    args = m.get("arguments", [])
    ret = m.get("return_value", {}).get("type", None)

    # Instance: a normal method takes the object as `self`; a static method has
    # no instance (ptrcalled with null); a singleton method has no `self` either
    # (it's always the one global instance, fetched internally).
    is_static = m.get("is_static", False)
    if is_static:
        lead_params, lead_call, instance = [], [], "null"
    elif is_singleton:
        lead_params, lead_call = [], []
        instance = "cast(void*, %s_singleton())" % cls.lower()
    else:
        lead_params, lead_call, instance = ["GdObject* self"], ["self"], "cast(void*, self)"

    # Per method-arg: declaration, name, and a default descriptor (or None).
    margs = []
    for i, a in enumerate(args):
        cat = categorize(a["type"], builtins, classes)
        pn = "p_" + a["name"]
        dv = a.get("default_value")
        # idx i keeps the local name (_d<i>) unique within any overload.
        d = default_arg(cat, a["type"], dv, i) if dv is not None else None
        margs.append({"cat": cat, "t": a["type"], "pn": pn, "dv": dv, "default": d,
                      "decl": param_type(a["type"], cat) + " " + pn})

    # Return handling. A builtin return adds a trailing r_ret out-param (always
    # required, never defaulted); scalar/object returns come back by value.
    rcat = categorize(ret, builtins, classes) if ret else None
    rettype, retptr, retdecl, retstmt = "void", "null", None, None
    rret_param, rret_call = None, None
    if rcat is None:
        pass
    elif rcat == "builtin":
        rt = BUILTIN_TYPE.get(ret)
        rret_param = (rt + "* r_ret") if rt else "void* r_ret"
        rret_call, retptr = "r_ret", ("cast(void*, r_ret)" if rt else "r_ret")
    else:
        rt = PARAM_TYPE[rcat]
        rettype = rt
        zero = "null" if rt.endswith("*") else ("0.0" if rt == "f64" else "0")
        retdecl, retptr, retstmt = rt + " r = " + zero + ";", "cast(void*, &r)", "return r;"

    # --- full wrapper: every arg explicit, the actual ptrcall ---
    params = lead_params + [a["decl"] for a in margs] + ([rret_param] if rret_param else [])
    L = []
    sig = ", ".join("%s: %s" % (a["name"], a["type"]) for a in args)
    L.append("// %s.%s(%s) -> %s%s"
             % (cls, name, sig, ret if ret else "void", "  [static]" if is_static else ""))
    L.append("void* %s__bind;" % fp)
    L.append("bool %s__ready;" % fp)
    L.append("%s %s(%s) {" % (rettype, fp, ", ".join(params)))
    L.append("    if !%s__ready {" % fp)
    L.append('        %s__bind = gd_method("%s", "%s", %d);' % (fp, cls, name, m["hash"]))
    L.append("        %s__ready = true;" % fp)
    L.append("    }")
    if margs:
        L.append("    void*[%d] a;" % len(margs))
        for i, a in enumerate(margs):
            L.append("    a[%d] = %s;" % (i, marshal(a["cat"], a["t"], a["pn"])))
        argsptr = "cast(void*, &a[0])"
    else:
        argsptr = "null"
    if retdecl:
        L.append("    " + retdecl)
    L.append("    gd_ptrcall(%s__bind, %s, %s, %s);" % (fp, instance, argsptr, retptr))
    L.append("    " + (retstmt if retstmt else "return;"))
    L.append("}")
    blocks = ["\n".join(L)]

    # --- default overloads: omit a contiguous run of trailing args whose
    # defaults we can fill (literal, or a constructed local); minc picks the
    # overload by arity. A filled arg may need a setup local + teardown. ---
    peel = 0
    for a in reversed(margs):
        if a["default"] is None:
            break
        peel += 1
    for k in range(1, peel + 1):
        keep = margs[:len(margs) - k]
        filled = margs[len(margs) - k:]
        oparams = lead_params + [a["decl"] for a in keep] + ([rret_param] if rret_param else [])
        setup, teardown, fillexprs = [], [], []
        for a in filled:
            d = a["default"]
            setup += d["setup"]
            teardown += d["teardown"]
            fillexprs.append(d["expr"])
        callvals = lead_call + [a["pn"] for a in keep] + fillexprs \
            + ([rret_call] if rret_call else [])
        call = "%s(%s)" % (fp, ", ".join(callvals))
        note = ", ".join("%s=%s" % (a["pn"][2:], a["dv"]) for a in filled)
        O = ["// %s - default %s" % (fp, note),
             "%s %s(%s) {" % (rettype, fp, ", ".join(oparams))]
        for line in setup:
            O.append("    " + line)
        if teardown:
            # Capture the result, run teardown, then return - so temporaries
            # (a constructed String, …) outlive the call but are still freed.
            if rettype != "void":
                O.append("    %s _ret = %s;" % (rettype, call))
                O += ["    " + t for t in teardown]
                O.append("    return _ret;")
            else:
                O.append("    " + call + ";")
                O += ["    " + t for t in teardown]
                O.append("    return;")
        else:
            O.append("    " + ("return %s;" % call if rettype != "void" else call + ";"))
            if rettype == "void":
                O.append("    return;")
        O.append("}")
        blocks.append("\n".join(O))
    return "\n\n".join(blocks)


def gen_construct(cls):
    # <class>_new() -> Object*, via classdb_construct_object on the class name.
    fp = cls.lower() + "_new"
    return "\n".join([
        "// %s_new() -> GdObject*" % cls,
        "GdObject* %s() {" % fp,
        "    GdStringName sn;",
        '    gd_stringname_new(&sn, "%s");' % cls,
        "    GdObject* obj = cast(GdObject*, gd_construct_object(cast(void*, &sn)));",
        "    gd_stringname_destroy(&sn);",
        "    return obj;",
        "}",
    ])


def gen_singleton(cls):
    # <class>_singleton() -> Object*, via global_get_singleton on the class name.
    # The result is the one global instance, so cache it after the first fetch.
    fp = cls.lower() + "_singleton"
    return "\n".join([
        "// %s_singleton() -> GdObject*  (cached global singleton)" % cls,
        "void* %s__cached;" % fp,
        "GdObject* %s() {" % fp,
        "    if %s__cached == null {" % fp,
        "        GdStringName sn;",
        '        gd_stringname_new(&sn, "%s");' % cls,
        "        %s__cached = gd_global_get_singleton(cast(void*, &sn));" % fp,
        "        gd_stringname_destroy(&sn);",
        "    }",
        "    return cast(GdObject*, %s__cached);" % fp,
        "}",
    ])


def gen_utility(f, builtins, classes):
    # A Godot utility function (UtilityFunctions.<name>) - a free function called
    # through the Variant utility table (same ABI as gd_print). Args are raw
    # typed pointers, like a ptrcall. Wrappers are prefixed gd_ so they never
    # clash with engine methods or minc math builtins (sin, pow, floor, …).
    name = f["name"]
    fp = "gd_" + name
    args = f.get("arguments", [])
    ret = f.get("return_type")
    if ret == "void":
        ret = None

    params, margs = [], []
    for a in args:
        cat = categorize(a["type"], builtins, classes)
        pn = "p_" + a["name"]
        params.append(param_type(a["type"], cat) + " " + pn)
        margs.append((cat, a["type"], pn))

    rcat = categorize(ret, builtins, classes) if ret else None
    rettype, retptr, retdecl, retstmt = "void", "null", None, None
    if rcat is None:
        pass
    elif rcat == "builtin":
        rt = BUILTIN_TYPE.get(ret)
        if rt:
            params.append(rt + "* r_ret"); retptr = "cast(void*, r_ret)"
        else:
            params.append("void* r_ret"); retptr = "r_ret"
    else:
        rt = PARAM_TYPE[rcat]
        rettype = rt
        zero = "null" if rt.endswith("*") else ("0.0" if rt == "f64" else "0")
        retdecl, retptr, retstmt = rt + " r = " + zero + ";", "cast(void*, &r)", "return r;"

    L = []
    sig = ", ".join("%s: %s" % (a["name"], a["type"]) for a in args)
    L.append("// %s(%s) -> %s  [utility]" % (name, sig, ret if ret else "void"))
    L.append("void* %s__fn;" % fp)
    L.append("bool %s__ready;" % fp)
    L.append("%s %s(%s) {" % (rettype, fp, ", ".join(params)))
    L.append("    if !%s__ready {" % fp)
    L.append('        %s__fn = gd_utility("%s", %d);' % (fp, name, f["hash"]))
    L.append("        %s__ready = true;" % fp)
    L.append("    }")
    if margs:
        L.append("    void*[%d] a;" % len(margs))
        for i, (cat, t, pn) in enumerate(margs):
            L.append("    a[%d] = %s;" % (i, marshal(cat, t, pn)))
        argsptr = "cast(void*, &a[0])"
    else:
        argsptr = "null"
    if retdecl:
        L.append("    " + retdecl)
    L.append("    cast(fn(void*, void*, i32): void, %s__fn)(%s, %s, %d);"
             % (fp, retptr, argsptr, len(margs)))
    L.append("    " + (retstmt if retstmt else "return;"))
    L.append("}")
    return "\n".join(L)


def gen_enum(api, name):
    e = next((x for x in api["global_enums"] if x["name"] == name), None)
    if e is None:
        sys.exit("global enum %s not found" % name)
    safe = name.replace(".", "_")  # minc identifiers have no dots
    note = " (bitfield)" if e.get("is_bitfield") else ""
    L = ["// %s%s - Godot global enum" % (name, note), "enum %s {" % safe]
    for v in e["values"]:
        L.append("    %s = %d," % (v["name"], v["value"]))
    L.append("}")
    return "\n".join(L)


def header(api, desc, regen):
    return (
        "// GENERATED by bindgen/godot_to_minc.py - do not edit.\n"
        "// source: Godot extension_api.json (%s)\n"
        "// %s\n"
        "// regenerate: %s\n"
        % (api["header"]["version_full_name"], desc, regen)
    )


def _api_sets(api):
    classes = {c["name"]: c for c in api["classes"]}
    builtins = {c["name"] for c in api["builtin_classes"]} | {
        "Variant", "String", "StringName", "NodePath", "Array", "Dictionary",
        "Callable", "Signal", "RID"}
    singletons = {s["name"] for s in api["singletons"]}
    return classes, set(classes), builtins, singletons


def transitive_closure(api, spec):
    """Engine classes referenced by a bound method's arg/return but not listed
    in the spec. Returns {name: 'singleton'|'construct'} (only types we can
    produce an accessor for - instantiable classes or singletons; abstract
    dependencies stay reachable as a bare GdObject* and are skipped)."""
    classes, classes_set, builtins, singletons = _api_sets(api)
    explicit = set(spec.get("classes", {}))

    def refs(m):
        ts = [a["type"] for a in m.get("arguments", [])]
        rt = m.get("return_value", {}).get("type")
        if rt:
            ts.append(rt)
        return [t for t in ts
                if t in classes_set and categorize(t, builtins, classes_set) == "object"]

    queue = []
    for cn, mns in spec.get("classes", {}).items():
        by = {m["name"]: m for m in classes[cn].get("methods", [])}
        for mn in mns:
            if mn in by:
                queue += refs(by[mn])

    pulled = {}
    while queue:
        t = queue.pop()
        if t in explicit or t in pulled:
            continue
        if t in singletons:
            pulled[t] = "singleton"
        elif classes[t].get("is_instantiable", False):
            pulled[t] = "construct"
        # else: abstract - reachable as a GdObject* handle, nothing to emit.
        # Pulled classes contribute only an accessor (no methods), so they add
        # no further references; no need to re-queue.
    return pulled


# --- spec validation + discovery (end-user friendliness) -------------------

def inherit_chain(api_classes, cls_name):
    chain, cur = [], cls_name
    while cur:
        chain.append(cur)
        cur = api_classes.get(cur, {}).get("inherits")
    return chain


def bindable_reason(m):
    # Why a method can't be bound, or None if it's fine. (Static methods bind:
    # same MethodBind, ptrcalled with a null instance.)
    if m.get("is_virtual"):
        return "virtual (you implement it via gd_bind_virtual, not a binding)"
    if m.get("is_vararg"):
        return "vararg (call it through the Variant path, e.g. gd_emit_signal)"
    return None


def find_method_homes(api, name):
    # Every class declaring a bindable method `name`, by class name.
    return [c["name"] for c in api["classes"]
            if any(mm["name"] == name and not bindable_reason(mm)
                   for mm in c.get("methods", []))]


def validate_spec(api, spec):
    """Return a list of human-readable problem strings (empty = OK)."""
    import difflib
    api_classes = {c["name"]: c for c in api["classes"]}
    global_enums = {e["name"] for e in api["global_enums"]}
    problems = []

    for n in spec.get("enums", []):
        if n not in global_enums:
            near = difflib.get_close_matches(n, global_enums, n=3)
            hint = ("  did you mean: %s" % ", ".join(near)) if near else ""
            problems.append("enum '%s' not a global enum.%s" % (n, hint))

    for cls_name, methods in spec.get("classes", {}).items():
        cls = api_classes.get(cls_name)
        if cls is None:
            near = difflib.get_close_matches(cls_name, api_classes.keys(), n=3)
            hint = ("  did you mean: %s" % ", ".join(near)) if near else ""
            problems.append("class '%s' not found.%s" % (cls_name, hint))
            continue
        by_name = {m["name"]: m for m in cls.get("methods", [])}
        chain = set(inherit_chain(api_classes, cls_name))
        for mn in methods:
            m = by_name.get(mn)
            if m is None:
                homes = find_method_homes(api, mn)
                base = [h for h in homes if h in chain and h != cls_name]
                if base:
                    # The common case: it's inherited. Tell them where to list it.
                    problems.append(
                        "method '%s.%s' is inherited from %s - list it under "
                        "\"%s\" (the wrapper works on any %s)."
                        % (cls_name, mn, base[0], base[0], cls_name))
                elif homes:
                    problems.append("method '%s.%s' not on %s; found on: %s"
                                    % (cls_name, mn, cls_name, ", ".join(homes[:6])))
                else:
                    near = difflib.get_close_matches(mn, by_name.keys(), n=3)
                    hint = ("  did you mean: %s" % ", ".join(near)) if near else \
                           "  (run --list %s to see bindable methods)" % cls_name
                    problems.append("method '%s.%s' not found.%s" % (cls_name, mn, hint))
                continue
            why = bindable_reason(m)
            if why:
                problems.append("method '%s.%s' is %s" % (cls_name, mn, why))

    uf = {f["name"]: f for f in api.get("utility_functions", [])}
    for n in spec.get("utility", []):
        f = uf.get(n)
        if f is None:
            near = difflib.get_close_matches(n, uf.keys(), n=3)
            hint = ("  did you mean: %s" % ", ".join(near)) if near else ""
            problems.append("utility '%s' not a Godot utility function.%s" % (n, hint))
        elif f.get("is_vararg"):
            problems.append("utility '%s' is vararg (e.g. print/max/min/str) - "
                            "not bindable; use the Variant path" % n)
    return problems


def list_class(api, cls_name):
    api_classes = {c["name"]: c for c in api["classes"]}
    cls = api_classes.get(cls_name)
    if cls is None:
        import difflib
        near = difflib.get_close_matches(cls_name, api_classes.keys(), n=5)
        sys.exit("class '%s' not found.%s"
                 % (cls_name, ("  did you mean: " + ", ".join(near)) if near else ""))
    builtins = {c["name"] for c in api["builtin_classes"]} | {
        "Variant", "String", "StringName", "NodePath", "Array", "Dictionary",
        "Callable", "Signal", "RID"}
    classes = set(api_classes.keys())
    singletons = {s["name"] for s in api.get("singletons", [])}
    tag = "  [singleton - no _new(), use %s_singleton(); methods take no self]" \
          % cls_name.lower() if cls_name in singletons else ""
    print("// %s  (inherits: %s)%s"
          % (cls_name, " -> ".join(inherit_chain(api_classes, cls_name)[1:]) or "-", tag))
    bindable, skipped = [], []
    for m in cls.get("methods", []):
        why = bindable_reason(m)
        sig = ", ".join("%s: %s" % (a["name"], a["type"]) for a in m.get("arguments", []))
        ret = m.get("return_value", {}).get("type", "void")
        line = "  %-34s (%s) -> %s" % (m["name"], sig, ret)
        if why:
            skipped.append("  %-34s SKIP: %s" % (m["name"], why))
            continue
        # Flag args/returns that would land as void* (untyped builtins).
        untyped = [t for t in [a["type"] for a in m.get("arguments", [])] + [ret]
                   if categorize(t, builtins, classes) == "builtin"
                   and not BUILTIN_TYPE.get(t)]
        if m.get("is_static"):
            line += "   [static - no self]"
        if untyped:
            line += "   [void*: %s]" % ", ".join(sorted(set(untyped)))
        bindable.append(line)
    print("// bindable (%d):" % len(bindable))
    print("\n".join(bindable))
    if skipped:
        print("// not bindable (%d):" % len(skipped))
        print("\n".join(skipped))


def main():
    ap = argparse.ArgumentParser(
        description="Generate minc GDExtension bindings from a used-set spec.",
        epilog="Discover methods:   godot_to_minc.py <api> --list Node3D\n"
               "Validate a spec:    godot_to_minc.py <api> --spec b.json --check\n"
               "Generate bindings:  godot_to_minc.py <api> --spec b.json --outdir gen",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("api", help="path to Godot extension_api.json")
    ap.add_argument("--spec", help="used-set JSON (enums + classes)")
    ap.add_argument("--outdir", help="where to write godot_enums.mc / godot_classes.mc")
    ap.add_argument("--list", metavar="CLASS",
                    help="print the bindable methods of CLASS and exit (discovery aid)")
    ap.add_argument("--check", action="store_true",
                    help="validate the spec and report problems without writing output")
    args = ap.parse_args()

    with open(args.api) as f:
        api = json.load(f)

    # Discovery mode: list a class's bindable methods (no spec needed).
    if args.list:
        list_class(api, args.list)
        return

    if not args.spec:
        ap.error("need --spec (or --list CLASS to explore the API)")
    with open(args.spec) as f:
        spec = json.load(f)

    # Validate the whole spec up front and report every problem at once, with a
    # hint per problem (inherited-method home, close-name match, why-unbindable).
    problems = validate_spec(api, spec)
    if problems:
        sys.stderr.write("spec has %d problem(s):\n" % len(problems))
        for p in problems:
            sys.stderr.write("  - %s\n" % p)
        sys.exit(1)
    if args.check:
        nc = len(spec.get("classes", {}))
        nm = sum(len(v) for v in spec.get("classes", {}).values())
        print("spec OK: %d enum(s), %d class(es), %d method(s), %d utility fn(s)"
              % (len(spec.get("enums", [])), nc, nm, len(spec.get("utility", []))))
        pulled = transitive_closure(api, spec)
        if pulled:
            print("auto-pulls %d dependency accessor(s) (referenced by a bound "
                  "method, not in the spec):" % len(pulled))
            for name in sorted(pulled):
                print("  %s_%s()" % (name.lower(),
                                     "singleton" if pulled[name] == "singleton" else "new"))
        return

    if not args.outdir:
        ap.error("need --outdir to generate (or --check to validate only)")

    builtins = {c["name"] for c in api["builtin_classes"]} | {
        "Variant", "String", "StringName", "NodePath", "Array", "Dictionary",
        "Callable", "Signal", "RID"}
    classes = {c["name"] for c in api["classes"]}

    # Canonical regen command for the header - fixed, so committed output is
    # byte-stable regardless of the actual --outdir.
    regen = ("python3 bindgen/godot_to_minc.py bindgen/extension_api.json "
             "--spec bindgen/bindings.json --outdir lib")

    # Global enums -> one shared file.
    enums = spec.get("enums", [])
    if enums:
        blocks = [gen_enum(api, n) for n in enums]
        h = header(api, "global enums: " + ", ".join(enums), regen)
        with open(args.outdir + "/godot_enums.mc", "w") as f:
            f.write(h + "\n" + "\n\n".join(blocks) + "\n")

    # Classes -> one combined file. Per class: a <class>_new() constructor,
    # then one wrapper per requested method. (Spec already validated above.)
    spec_classes = spec.get("classes", {})
    if spec_classes:
        api_classes = {c["name"]: c for c in api["classes"]}
        singletons = {s["name"] for s in api.get("singletons", [])}
        blocks = []
        for cls_name, methods in spec_classes.items():
            by_name = {m["name"]: m for m in api_classes[cls_name].get("methods", [])}
            is_sing = cls_name in singletons
            blocks.append("// === %s%s ===" % (cls_name, " (singleton)" if is_sing else ""))
            # Singletons aren't constructed - fetch the one global instance;
            # their methods take no `self`.
            blocks.append(gen_singleton(cls_name) if is_sing else gen_construct(cls_name))
            for mn in methods:
                blocks.append(gen_method(cls_name, by_name[mn], builtins, classes, is_sing))

        # Transitive closure: emit an accessor for every engine type a bound
        # method references but the spec doesn't list.
        pulled = transitive_closure(api, spec)
        if pulled:
            blocks.append("// === auto-pulled dependencies ===")
            blocks.append("// Referenced by a bound method's arg/return but not "
                          "in the spec.\n// Accessor only (no methods); list the "
                          "class explicitly to bind its methods.")
            for name in sorted(pulled):
                blocks.append(gen_singleton(name) if pulled[name] == "singleton"
                              else gen_construct(name))
        desc = "classes: " + ", ".join(spec_classes.keys())
        h = header(api, desc, regen)
        body = ("//\n// Importable module - engine class bindings over the core runtime.\n"
                "// <class>_new() constructs via classdb_construct_object; each\n"
                "// method wrapper caches its MethodBind on first call, then\n"
                "// ptrcalls with marshalled args via the core runtime\n"
                "// (gd_method, gd_ptrcall, gd_string_name_new, gd_destroy).\n"
                "import godot_core;\n")
        with open(args.outdir + "/godot_classes.mc", "w") as f:
            f.write(h + body + "\n" + "\n\n".join(blocks) + "\n")

    # Utility functions -> one file. Free math/random functions wrapped as gd_<name>.
    utils = spec.get("utility", [])
    if utils:
        uf = {f["name"]: f for f in api["utility_functions"]}
        blocks = [gen_utility(uf[n], builtins, classes) for n in utils]
        h = header(api, "utility functions: " + ", ".join(utils), regen)
        body = ("//\n// Importable module - utility-function wrappers over the core runtime.\n"
                "// Free functions via the Variant utility table (gd_utility);\n"
                "// each is prefixed gd_ and caches its function pointer on first\n"
                "// call. Args/return marshal like a ptrcall (raw typed pointers).\n"
                "import godot_core;\n")
        with open(args.outdir + "/godot_utility.mc", "w") as f:
            f.write(h + body + "\n" + "\n\n".join(blocks) + "\n")


if __name__ == "__main__":
    main()
