// minc GDExtension core — the reusable runtime for driving Godot from minc.
//
// This is the core module behind `import godot;`. User code imports `godot`
// and defines gd_register() to register its classes with the API below 
// (gd_class / gd_bind_virtual / gd_bind_method / gd_add_property / 
// gd_add_signal). 
//
// The core owns the GDExtension entry point, the interface table, the 
// String/StringName and ptrcall helpers, and a universal get_virtual that 
// dispatches to the virtuals you bind.
//
// Struct layouts / signatures are from gdextension_interface.h
// (Godot 4.3-stable); sizes/hashes from extension_api.json (see bindgen/).

import godot_enums;

// Debug output goes to stderr, via the per-OS write below.
when os(macos) || os(ios) {
    extern "libSystem.B.dylib" i64 write(i64 fd, void* buf, i64 n);
}
when os(linux) || os(android) {
    extern "libc.so.6" i64 write(i64 fd, void* buf, i64 n);
}
when os(windows) {
    extern "kernel32.dll" i64 GetStdHandle(i32 std);
    extern "kernel32.dll" i32 WriteFile(i64 h, void* buf, u32 n, void* written, void* overlapped);
}

// Typed wrappers for Godot's values, so signatures carry a type, not bare
// void*. GdObject is a pointer-only handle to an engine object. The rest are
// value types sized to Godot's float_64 build — declare them typed, build the
// POD math types with struct literals, and pass them by pointer (&v).
struct GdObject;                                 // engine object (Node, Resource, …)
// Opaque ref-counted builtins: an 8/16-byte handle to engine-side storage.
// Build/read/destroy only through the interface (gd_string_new, …).
struct GdStringName { i64 v; }                   // 8
struct GdString { i64 v; }                       // 8
struct GdNodePath { i64 v; }                     // 8
struct GdVariant { i64 a; i64 b; i64 c; }        // 24
struct GdCallable { i64 a; i64 b; }              // 16
// POD math types: stable field layout in the float_64 build, so build them
// with struct literals (GdVector3{1.0f, 2.0f, 3.0f}) and pass by pointer.
struct GdVector2 { f32 x; f32 y; }               // 8
struct GdVector2i { i32 x; i32 y; }              // 8
struct GdVector3 { f32 x; f32 y; f32 z; }        // 12
struct GdVector3i { i32 x; i32 y; i32 z; }       // 12
struct GdVector4 { f32 x; f32 y; f32 z; f32 w; } // 16
struct GdColor { f32 r; f32 g; f32 b; f32 a; }   // 16
struct GdRect2 { f32 x; f32 y; f32 w; f32 h; }   // 16  (position + size)
struct GdPlane { f32 x; f32 y; f32 z; f32 d; }   // 16
struct GdQuaternion { f32 x; f32 y; f32 z; f32 w; } // 16
struct GdAABB { f32 px; f32 py; f32 pz;          // 24  (position + size)
                f32 sx; f32 sy; f32 sz; }
struct GdBasis { f32 xx; f32 xy; f32 xz;         // 36  (3 rows)
                 f32 yx; f32 yy; f32 yz;
                 f32 zx; f32 zy; f32 zz; }
struct GdTransform2D { f32 xx; f32 xy;           // 24  (x, y, origin)
                       f32 yx; f32 yy;
                       f32 ox; f32 oy; }
struct GdTransform3D { f32 bxx; f32 bxy; f32 bxz; // 48  (basis + origin)
                       f32 byx; f32 byy; f32 byz;
                       f32 bzx; f32 bzy; f32 bzz;
                       f32 ox; f32 oy; f32 oz; }

// GDExtensionInitialization (32 bytes).
struct GDInitialization {
    i32 min_init_level;
    void* userdata;
    void* initialize;
    void* deinitialize;
}

// GDExtensionClassCreationInfo3 (160 bytes). Only the exposed flag and the
// create/free/get_virtual callbacks matter here; the rest stay null/0.
struct GDClassCreationInfo3 {
    u8 is_virtual;
    u8 is_abstract;
    u8 is_exposed;
    u8 is_runtime;
    void* set_func;
    void* get_func;
    void* get_property_list_func;
    void* free_property_list_func;
    void* property_can_revert_func;
    void* property_get_revert_func;
    void* validate_property_func;
    void* notification_func;
    void* to_string_func;
    void* reference_func;
    void* unreference_func;
    void* create_instance_func;
    void* free_instance_func;
    void* recreate_instance_func;
    void* get_virtual_func;
    void* get_virtual_call_data_func;
    void* call_virtual_with_data_func;
    void* get_rid_func;
    void* class_userdata;
}

// GDExtensionPropertyInfo (48 bytes).
struct GDPropertyInfo {
    i32 type;
    GdStringName* name;
    GdStringName* class_name;
    u32 hint;
    GdString* hint_string;
    u32 usage;
}

// GDExtensionClassMethodInfo (88 bytes). Field order/alignment mirror the C
// struct.
struct GDClassMethodInfo {
    GdStringName* name;
    void* method_userdata;
    fn(void*, void*, void*, i64, void*, void*): void call_func;   // Variant path
    fn(void*, void*, void*, void*): void ptrcall_func;            // typed path
    u32 method_flags;
    u8 has_return_value;
    GDPropertyInfo* return_value_info;
    u32 return_value_metadata;
    u32 argument_count;
    GDPropertyInfo* arguments_info;
    u32* arguments_metadata;
    u32 default_argument_count;
    void* default_arguments;
}

// GDEXTENSION_INITIALIZATION_SCENE.
i32 GD_INIT_SCENE = 2;   // GDExtension interface enum (not in extension_api.json)

// Godot global enums (Variant.Type, PropertyUsageFlags, MethodFlags) come in
// via `import godot_enums;` at the top of this module.

// Interface functions, resolved once in the entry point.
fn(void*, u8*): void gd_string_name_new;          // (r_dest StringName, utf8)
fn(void*, u8*): void gd_string_new_utf8;          // (r_dest String, utf8)
fn(void*, u8*, i64): i64 gd_string_to_utf8;       // (String, r_text, max) -> len
fn(i32): void* gd_variant_get_ptr_destructor;     // (type) -> destructor fn
fn(void*): void* gd_construct_object;             // (StringName class) -> Object*
fn(void*): void* gd_global_get_singleton;         // (StringName name) -> Object*
fn(void*, void*, void*): void gd_object_set_instance;
fn(void*, void*, void*, void*): void gd_register_class3;
fn(void*, void*, i64): void* gd_get_method_bind;  // (class, method, hash) -> MethodBind*
fn(void*, void*, void*, void*): void gd_ptrcall;  // (bind, instance, args, ret)
fn(void*, void*, void*): void gd_register_method;            // (lib, class, *method_info)
fn(void*, void*, void*, void*, void*): void gd_register_property;  // (lib, class, *prop, setter, getter)
fn(void*, void*, void*, void*, i64): void gd_register_signal;     // (lib, class, signal, *args, n)
fn(i32): void* gd_variant_from_type;    // get_variant_from_type_constructor(type)
fn(i32): void* gd_variant_to_type;      // get_variant_to_type_constructor(type)
fn(void*): void gd_variant_destroy_fn;  // variant_destroy(Variant)
fn(void*, i64): void* gd_variant_utility;  // variant_get_ptr_utility_function(name, hash)
fn(i32, i32): void* gd_variant_get_ptr_ctor;  // variant_get_ptr_constructor(type, index)
fn(void*, void*, void*, i64, void*, void*): void gd_method_bind_call;  // object_method_bind_call

void* gd_library;

// Cached destructors for the opaque builtins.
void* gd_dtor_string;
void* gd_dtor_stringname;
void* gd_dtor_callable;
void* gd_dtor_nodepath;

// --- small helpers --------------------------------------------------------

i64 gd_strlen(u8* s) {
    i64 n = 0;
    while *(s + n) != 0 { n = n + 1; }
    return n;
}

void gd_write_stderr(void* buf, i64 n) {
    when os(windows) {
        u32 written = 0;
        WriteFile(GetStdHandle(0 - 12), buf, cast(u32, n), &written, null);  // STD_ERROR_HANDLE
    }
    when os(macos) || os(ios) || os(linux) || os(android) {
        write(2, buf, n);
    }
    return;
}

void gd_puts(u8* s) {
    gd_write_stderr(cast(void*, s), gd_strlen(s));
    return;
}

void gd_write_dec(i64 n) {
    u8[24] buf;
    i32 i = 24;
    if n <= 0 {
        i = i - 1;
        buf[i] = 48;
    } else {
        var u = n;
        while u > 0 {
            i = i - 1;
            buf[i] = cast(u8, 48 + (u % 10));
            u = u / 10;
        }
    }
    gd_write_stderr(cast(void*, &buf[i]), 24 - i);
    return;
}

// Builtins are opaque buffers of the size Godot reports; all construction
// and conversion goes through interface functions, never field pokes.
void gd_destroy(void* dtor, void* obj) {
    cast(fn(void*): void, dtor)(obj);
    return;
}

// Resolve a MethodBind by class/method/hash (used by the generated bindings).
// Builds temporary StringNames and destroys them afterward.
void* gd_method(u8* cls, u8* meth, i64 hash) {
    i64 csn = 0;
    i64 msn = 0;
    gd_string_name_new(cast(void*, &csn), cls);
    gd_string_name_new(cast(void*, &msn), meth);
    void* bind = gd_get_method_bind(cast(void*, &csn), cast(void*, &msn), hash);
    gd_destroy(gd_dtor_stringname, cast(void*, &csn));
    gd_destroy(gd_dtor_stringname, cast(void*, &msn));
    return bind;
}

// Resolve a Variant utility function (UtilityFunctions.<name>) by name + hash —
// the backing for the generated gd_<name> math/random wrappers.
void* gd_utility(u8* name, i64 hash) {
    i64 nsn = 0;
    gd_string_name_new(cast(void*, &nsn), name);
    void* uf = gd_variant_utility(cast(void*, &nsn), hash);
    gd_destroy(gd_dtor_stringname, cast(void*, &nsn));
    return uf;
}

// --- Builtin value helpers -------------------------------------------------
// Typed wrappers over the void* interface: construct/read/destroy String,
// StringName, Callable. Your code stays typed; the cast to void* happens here.

void gd_stringname_new(GdStringName* dest, u8* s) {
    gd_string_name_new(cast(void*, dest), s);
    return;
}
void gd_string_new(GdString* dest, u8* s) {
    gd_string_new_utf8(cast(void*, dest), s);
    return;
}
i64 gd_string_to_cstr(GdString* s, u8* out, i64 max) {
    return gd_string_to_utf8(cast(void*, s), out, max);
}
void gd_stringname_destroy(GdStringName* sn) {
    gd_destroy(gd_dtor_stringname, cast(void*, sn));
    return;
}
void gd_string_destroy(GdString* s) {
    gd_destroy(gd_dtor_string, cast(void*, s));
    return;
}
void gd_callable_destroy(GdCallable* c) {
    gd_destroy(gd_dtor_callable, cast(void*, c));
    return;
}
// Build a NodePath from a path string (NodePath's String constructor, index 2).
void gd_nodepath_new(GdNodePath* dest, u8* path) {
    GdString s;
    gd_string_new(&s, path);
    void*[1] args;
    args[0] = cast(void*, &s);
    cast(fn(void*, void*): void, gd_variant_get_ptr_ctor(TYPE_NODE_PATH, 2))(cast(void*, dest), cast(void*, &args[0]));
    gd_string_destroy(&s);
    return;
}
void gd_nodepath_destroy(GdNodePath* np) {
    gd_destroy(gd_dtor_nodepath, cast(void*, np));
    return;
}

// --- Variant ---------------------------------------------------------------
// A 24-byte tagged value; build/read through Godot's typed constructors, never
// by poking fields. `value` is a pointer to the typed payload for the type.
void gd_variant_from(GdVariant* vdest, i32 type, void* value) {
    cast(fn(void*, void*): void, gd_variant_from_type(type))(cast(void*, vdest), value);
    return;
}
void gd_variant_to(void* dest, i32 type, GdVariant* variant) {
    cast(fn(void*, void*): void, gd_variant_to_type(type))(dest, cast(void*, variant));
    return;
}
void gd_variant_destroy(GdVariant* variant) {
    gd_variant_destroy_fn(cast(void*, variant));
    return;
}

// Int <-> Variant convenience.
void gd_variant_int(GdVariant* vdest, i64 value) {
    gd_variant_from(vdest, TYPE_INT, cast(void*, &value));
    return;
}
i64 gd_variant_to_int(GdVariant* variant) {
    i64 out = 0;
    gd_variant_to(cast(void*, &out), TYPE_INT, variant);
    return out;
}

// print(text) via UtilityFunctions — the cached ptr-utility function.
void* gd_print_fn;
void gd_print(u8* s) {
    if gd_print_fn == null {
        GdStringName psn;
        gd_stringname_new(&psn, "print");
        gd_print_fn = gd_variant_utility(cast(void*, &psn), 2648703342);
        gd_stringname_destroy(&psn);
    }
    GdString str;
    gd_string_new(&str, s);
    GdVariant vbuf;
    gd_variant_from(&vbuf, TYPE_STRING, cast(void*, &str));
    void*[1] args;
    args[0] = cast(void*, &vbuf);
    // void (*)(r_return, const TypePtr* args, int argc)
    cast(fn(void*, void*, i32): void, gd_print_fn)(null, cast(void*, &args[0]), 1);
    gd_variant_destroy(&vbuf);
    gd_string_destroy(&str);
    return;
}

// Build a Callable(object, method) into `dest` (Callable constructor index 2).
// Connect a signal to it to invoke the named registered method.
void gd_callable(GdCallable* dest, GdObject* object, GdStringName* method_sn) {
    void*[2] args;
    args[0] = cast(void*, &object);     // ptr to the Object pointer
    args[1] = cast(void*, method_sn);   // ptr to the StringName
    cast(fn(void*, void*): void, gd_variant_get_ptr_ctor(TYPE_CALLABLE, 2))(cast(void*, dest), cast(void*, &args[0]));
    return;
}

// Emit a signal on `self` with `nargs` Variant arguments. Object.emit_signal is
// vararg: the signal name goes first, the payload Variants after. The caller
// builds the Variants; the no-arg overload below covers the no-payload case.
void gd_emit_signal(GdObject* self, u8* signal_name, GdVariant* args, i32 nargs) {
    void* bind = gd_method("Object", "emit_signal", 4047867050);
    GdStringName ssn;
    gd_stringname_new(&ssn, signal_name);
    GdVariant svar;
    gd_variant_from(&svar, TYPE_STRING_NAME, cast(void*, &ssn));
    i32 n = nargs;
    if n > GD_MAX_METHOD_ARGS { n = GD_MAX_METHOD_ARGS; }
    void*[9] vargs;        // [name] + up to GD_MAX_METHOD_ARGS payload Variants
    vargs[0] = cast(void*, &svar);
    for i32 i = 0; i < n; i = i + 1 { vargs[i + 1] = cast(void*, args + i); }
    GdVariant rret;
    i32[4] cerr;        // GDExtensionCallError (3x i32), error field zeroed
    cerr[0] = 0;
    gd_method_bind_call(bind, cast(void*, self), cast(void*, &vargs[0]), cast(i64, 1 + n),
                       cast(void*, &rret), cast(void*, &cerr[0]));
    gd_variant_destroy(&rret);
    gd_variant_destroy(&svar);
    gd_stringname_destroy(&ssn);
    return;
}

// Emit a no-payload signal.
void gd_emit_signal(GdObject* self, u8* signal_name) {
    gd_emit_signal(self, signal_name, null, 0);
    return;
}

// Generated engine bindings (node_*/node3d_*/<class>_new()) and utility-
// function wrappers (gd_sin/gd_lerp/gd_randf) are defined in the godot_classes
// and godot_utility modules. Regenerate them via bindgen/ (see bindgen/README.md).

// --- StringName interning + cleanup ---------------------------------------
// Each StringName the registration API creates gets its own stable heap slot,
// tracked here and destroyed at deinitialize. Godot stores the pointer
// long-term, so slots are allocated individually and never moved; only the
// tracking array grows.

i64** gd_sn_slots;   // each entry -> a heap 8-byte StringName slot
i32 gd_sn_count;
i32 gd_sn_cap;

// Intern `s` into a fresh, tracked StringName slot; returns a stable handle.
GdStringName* gd_intern(u8* s) {
    if gd_sn_count == gd_sn_cap {
        i32 ncap = gd_sn_cap;
        if ncap == 0 { ncap = 16; } else { ncap = ncap * 2; }
        i64** ns = alloc<i64*>(ncap);
        for i32 i = 0; i < gd_sn_count; i = i + 1 { ns[i] = gd_sn_slots[i]; }
        gd_sn_slots = ns;
        gd_sn_cap = ncap;
    }
    i64* slot = alloc<i64>(1);
    *slot = 0;
    gd_string_name_new(cast(void*, slot), s);
    gd_sn_slots[gd_sn_count] = slot;
    gd_sn_count = gd_sn_count + 1;
    return cast(GdStringName*, slot);
}

// An empty StringName / String for PropertyInfo's class_name / hint_string.
GdStringName* gd_empty_sn;
i64 gd_empty_str_slot;
GdString* gd_empty_str;

// Fill an existing GDPropertyInfo for a scalar of `type` named `name`.
void gd_fill_prop(GDPropertyInfo* pi, i32 type, u8* name) {
    pi.type = type;
    pi.name = gd_intern(name);
    pi.class_name = gd_empty_sn;
    pi.hint = 0;
    pi.hint_string = gd_empty_str;
    pi.usage = cast(u32, PROPERTY_USAGE_DEFAULT);
    return;
}

// Fill a fresh GDPropertyInfo for a scalar of `type` named `name`.
GDPropertyInfo* gd_make_prop(i32 type, u8* name) {
    var pi = new(GDPropertyInfo);
    gd_fill_prop(pi, type, name);
    return pi;
}

// arg<i> into `out` (i < 10), for method/signal argument names.
void gd_argname(u8* out, i32 i) {
    out[0] = 'a';
    out[1] = 'r';
    out[2] = 'g';
    out[3] = cast(u8, '0' + i);
    out[4] = 0;
    return;
}

// A contiguous GDPropertyInfo[n] for `types` (named arg0..arg<n-1>) — the array
// form Godot wants for a method's arguments_info or a signal's argument list.
GDPropertyInfo* gd_make_props(i32* types, i32 n) {
    var arr = alloc<GDPropertyInfo>(n);
    for i32 i = 0; i < n; i = i + 1 {
        u8[8] nm;
        gd_argname(&nm[0], i);
        gd_fill_prop(arr + i, types[i], &nm[0]);
    }
    return arr;
}

// --- Class registry + virtual dispatch ------------------------------------

struct GdClass {
    void* name_sn;               // StringName* (a tracked gd_intern slot)
    void* parent_sn;             // parent class StringName* (for gd_construct)
    GDClassCreationInfo3 info;   // persistent; Godot copies it on register
}
// Both tables grow geometrically, indexed by id (class_userdata). Godot copies
// each class's info at register time, and the StringName handles are separate
// gd_intern slots, so growth never invalidates anything Godot holds.
GdClass* gd_classes;
i32 gd_class_count;
i32 gd_class_cap;

// Virtual bindings: parallel (class_id, interned virtual-name _Data, callback).
i32* gd_vt_class;
i64* gd_vt_name;
void** gd_vt_cb;
i32 gd_vt_count;
i32 gd_vt_cap;

// The one get_virtual all classes share: looks the (class, name) pair up in
// the binding table and returns the callback, or null.
@c_abi void* gd_core_get_virtual(void* class_userdata, void* p_name) {
    i32 class_id = cast(i32, cast(i64, class_userdata));
    i64 name_data = *(cast(i64*, p_name));
    for i32 i = 0; i < gd_vt_count; i = i + 1 {
        if gd_vt_class[i] == class_id && gd_vt_name[i] == name_data {
            return gd_vt_cb[i];
        }
    }
    return null;
}

// Upper bound on a bound method's argument count (and a signal's). Sizes the
// per-call decode buffers in gd_core_method_call.
i32 GD_MAX_METHOD_ARGS = 8;

// Per-method metadata, carried as method_userdata so the generic Variant
// call_func can bridge to the typed ptrcall_func.
struct GdMethodMeta {
    void* ptrcall_fn;
    i32 ret_type;     // TYPE_* or -1 (void)
    i32 nargs;        // argument count
    i32* arg_types;   // TYPE_* per argument (null when nargs == 0)
}

// The Variant-path call_func shared by every method bound through
// gd_bind_method. Godot dispatches here for Variant calls (Object.set/get,
// scripts, signal callbacks): it unmarshals the Variant args to typed values,
// calls the same ptrcall impl you wrote, and marshals the return back.
@c_abi void gd_core_method_call(void* mud, void* instance, void* p_args, i64 argc, void* r_ret, void* r_error) {
    var meta = cast(GdMethodMeta*, mud);
    i64[64] valbuf;        // GD_MAX_METHOD_ARGS slots x 8 i64 (64 bytes) each
    void*[8] targs;
    void* targs_ptr = null;
    i32 n = meta.nargs;
    if n > GD_MAX_METHOD_ARGS { n = GD_MAX_METHOD_ARGS; }
    if n > 0 {
        var args = cast(void**, p_args);
        for i32 i = 0; i < n; i = i + 1 {
            void* slot = cast(void*, &valbuf[i * 8]);
            gd_variant_to(slot, meta.arg_types[i], cast(GdVariant*, args[i]));
            targs[i] = slot;
        }
        targs_ptr = cast(void*, &targs[0]);
    }
    i64[8] retbuf;         // room for the widest value type (Projection, 64 B)
    void* retptr = null;
    if meta.ret_type >= 0 { retptr = cast(void*, &retbuf[0]); }
    cast(fn(void*, void*, void*, void*): void, meta.ptrcall_fn)(mud, instance, targs_ptr, retptr);
    if meta.ret_type >= 0 {
        gd_variant_from(r_ret, meta.ret_type, cast(void*, &retbuf[0]));
    }
    // Free decoded ref-counted args (String/Array/…); POD types have no
    // destructor (get_ptr_destructor returns null), so this is a no-op for them.
    for i32 i = 0; i < n; i = i + 1 {
        void* d = gd_variant_get_ptr_destructor(meta.arg_types[i]);
        if d != null { gd_destroy(d, targs[i]); }
    }
    if r_error != null { *(cast(i32*, r_error)) = 0; }  // GDExtensionCallError OK
    return;
}

// --- Registration API (call these from gd_register) -----------------------

// Register a class. create/free are the constructor/destructor callbacks
// (create_instance / free_instance). Returns a class id used by the calls
// below.
i32 gd_class(u8* name, u8* parent, fn(void*): void* create_fn,
             fn(void*, void*): void free_fn) {
    if gd_class_count == gd_class_cap {
        i32 ncap = gd_class_cap;
        if ncap == 0 { ncap = 4; } else { ncap = ncap * 2; }
        GdClass* ng = alloc<GdClass>(ncap);
        for i32 i = 0; i < gd_class_count; i = i + 1 { ng[i] = gd_classes[i]; }
        gd_classes = ng;
        gd_class_cap = ncap;
    }
    i32 id = gd_class_count;
    gd_class_count = gd_class_count + 1;
    var c = &gd_classes[id];
    c.name_sn = cast(void*, gd_intern(name));
    c.parent_sn = cast(void*, gd_intern(parent));
    // Zero-fill a local, then copy into the slot. alloc<> doesn't zero, and
    // Godot calls every callback pointer here, so the fields left unset must be
    // null, not heap garbage.
    GDClassCreationInfo3 info;
    info.is_exposed = 1;
    info.create_instance_func = cast(void*, create_fn);
    info.free_instance_func = cast(void*, free_fn);
    info.get_virtual_func = cast(void*, gd_core_get_virtual);
    info.class_userdata = cast(void*, cast(i64, id));   // identifies the class
    c.info = info;
    gd_register_class3(gd_library, c.name_sn, c.parent_sn, cast(void*, &c.info));
    return id;
}

// The class's own name StringName — pass to object_set_instance in create().
void* gd_class_name(i32 class_id) {
    return gd_classes[class_id].name_sn;
}

// Construct this class's registered base object and attach `instance` to it.
// `class_userdata` is the value passed to the create callback. Returns the new
// Object.
GdObject* gd_construct(void* class_userdata, void* instance) {
    var c = &gd_classes[cast(i32, cast(i64, class_userdata))];
    GdObject* obj = cast(GdObject*, gd_construct_object(c.parent_sn));
    gd_object_set_instance(cast(void*, obj), c.name_sn, instance);
    return obj;
}

// Bind a Godot virtual (e.g. "_ready", "_process") to a callback.
void gd_bind_virtual(i32 class_id, u8* vname, fn(void*, void*, void*): void cb) {
    if gd_vt_count == gd_vt_cap {
        i32 ncap = gd_vt_cap;
        if ncap == 0 { ncap = 8; } else { ncap = ncap * 2; }
        i32* nclass = alloc<i32>(ncap);
        i64* nname = alloc<i64>(ncap);
        void** ncb = alloc<void*>(ncap);
        for i32 i = 0; i < gd_vt_count; i = i + 1 {
            nclass[i] = gd_vt_class[i];
            nname[i] = gd_vt_name[i];
            ncb[i] = gd_vt_cb[i];
        }
        gd_vt_class = nclass;
        gd_vt_name = nname;
        gd_vt_cb = ncb;
        gd_vt_cap = ncap;
    }
    GdStringName* sn = gd_intern(vname);
    i32 i = gd_vt_count;
    gd_vt_count = gd_vt_count + 1;
    gd_vt_class[i] = class_id;
    gd_vt_name[i] = *(cast(i64*, sn));
    gd_vt_cb[i] = cast(void*, cb);
    return;
}

// Register a callable method backed by a GDExtensionClassMethodPtrCall.
// ret_type is a TYPE_* id or -1 (void). `nargs` is the argument count, followed
// by that many TYPE_* ids as loose args — e.g.
//   gd_bind_method(cls, "move", mn_move, TYPE_VECTOR3, 2, TYPE_VECTOR3, TYPE_FLOAT);
//   gd_bind_method(cls, "tick", mn_tick, 0 - 1, 0);
// The impl reads the same args via the ptrcall ABI (args[0..nargs]); the shared
// call_func unmarshals Variants into them on the Variant path.
void gd_bind_method(i32 class_id, u8* name, fn(void*, void*, void*, void*): void ptrcall_fn,
                    i32 ret_type, i32 nargs, ...) {
    var ap = &...;
    i32* arg_types = null;
    if nargs > 0 {
        arg_types = alloc<i32>(nargs);
        for i32 i = 0; i < nargs; i = i + 1 { arg_types[i] = arg_read_i32(ap); }
    }
    var meta = new(GdMethodMeta);
    meta.ptrcall_fn = cast(void*, ptrcall_fn);
    meta.ret_type = ret_type;
    meta.nargs = nargs;
    meta.arg_types = arg_types;
    var mi = new(GDClassMethodInfo);
    mi.name = gd_intern(name);
    mi.method_userdata = cast(void*, meta);   // bridges the Variant call_func
    mi.call_func = gd_core_method_call;
    mi.ptrcall_func = ptrcall_fn;
    mi.method_flags = cast(u32, METHOD_FLAG_NORMAL);
    if ret_type >= 0 {
        mi.has_return_value = 1;
        mi.return_value_info = gd_make_prop(ret_type, "ret");
    }
    if nargs > 0 {
        // arguments_metadata must be a non-null array of argument_count
        // entries (0 = NONE) or Godot crashes in register_extension_class_method.
        u32* argmeta = alloc<u32>(nargs);
        for i32 i = 0; i < nargs; i = i + 1 { argmeta[i] = 0; }
        mi.argument_count = cast(u32, nargs);
        mi.arguments_info = gd_make_props(arg_types, nargs);
        mi.arguments_metadata = argmeta;
    }
    gd_register_method(gd_library, gd_classes[class_id].name_sn, cast(void*, mi));
    return;
}

// Register a property backed by setter/getter method names.
void gd_add_property(i32 class_id, i32 type, u8* name, u8* setter, u8* getter) {
    var pi = gd_make_prop(type, name);
    gd_register_property(gd_library, gd_classes[class_id].name_sn, cast(void*, pi),
                        cast(void*, gd_intern(setter)), cast(void*, gd_intern(getter)));
    return;
}

// Register a signal. `nargs` is the argument count, followed by that many
// TYPE_* ids as loose args — e.g. gd_add_signal(cls, "damaged", 2, TYPE_INT,
// TYPE_FLOAT) or gd_add_signal(cls, "ready", 0).
void gd_add_signal(i32 class_id, u8* name, i32 nargs, ...) {
    var ap = &...;
    GDPropertyInfo* args_info = null;
    if nargs > 0 {
        i32* types = alloc<i32>(nargs);
        for i32 i = 0; i < nargs; i = i + 1 { types[i] = arg_read_i32(ap); }
        args_info = gd_make_props(types, nargs);
    }
    gd_register_signal(gd_library, gd_classes[class_id].name_sn,
                      cast(void*, gd_intern(name)), cast(void*, args_info), nargs);
    return;
}

// --- Initialization -------------------------------------------------------

@c_abi void gd_initialize(void* userdata, i32 level) {
    if level != GD_INIT_SCENE { return; }
    gd_empty_sn = gd_intern("");
    gd_empty_str_slot = 0;
    gd_string_new_utf8(cast(void*, &gd_empty_str_slot), "");
    gd_empty_str = cast(GdString*, &gd_empty_str_slot);
    gd_register();   // user hook: register your classes here
    return;
}

@c_abi void gd_deinitialize(void* userdata, i32 level) {
    if level != GD_INIT_SCENE { return; }
    for i32 i = 0; i < gd_sn_count; i = i + 1 {
        gd_destroy(gd_dtor_stringname, cast(void*, gd_sn_slots[i]));
    }
    gd_destroy(gd_dtor_string, cast(void*, &gd_empty_str_slot));
    return;
}

// --- Entry point ----------------------------------------------------------
@c_abi u8 minc_gdextension_init(void* p_get_proc_address, void* p_library, void* r_initialization) {
    var get_proc = cast(fn(u8*): void*, p_get_proc_address);
    gd_library = p_library;

    gd_string_name_new = cast(fn(void*, u8*): void,
        get_proc("string_name_new_with_utf8_chars"));
    gd_string_new_utf8 = cast(fn(void*, u8*): void,
        get_proc("string_new_with_utf8_chars"));
    gd_string_to_utf8 = cast(fn(void*, u8*, i64): i64,
        get_proc("string_to_utf8_chars"));
    gd_variant_get_ptr_destructor = cast(fn(i32): void*,
        get_proc("variant_get_ptr_destructor"));
    gd_construct_object = cast(fn(void*): void*,
        get_proc("classdb_construct_object"));
    gd_global_get_singleton = cast(fn(void*): void*,
        get_proc("global_get_singleton"));
    gd_object_set_instance = cast(fn(void*, void*, void*): void,
        get_proc("object_set_instance"));
    gd_register_class3 = cast(fn(void*, void*, void*, void*): void,
        get_proc("classdb_register_extension_class3"));
    gd_get_method_bind = cast(fn(void*, void*, i64): void*,
        get_proc("classdb_get_method_bind"));
    gd_ptrcall = cast(fn(void*, void*, void*, void*): void,
        get_proc("object_method_bind_ptrcall"));
    gd_register_method = cast(fn(void*, void*, void*): void,
        get_proc("classdb_register_extension_class_method"));
    gd_register_property = cast(fn(void*, void*, void*, void*, void*): void,
        get_proc("classdb_register_extension_class_property"));
    gd_register_signal = cast(fn(void*, void*, void*, void*, i64): void,
        get_proc("classdb_register_extension_class_signal"));
    gd_variant_from_type = cast(fn(i32): void*,
        get_proc("get_variant_from_type_constructor"));
    gd_variant_to_type = cast(fn(i32): void*,
        get_proc("get_variant_to_type_constructor"));
    gd_variant_destroy_fn = cast(fn(void*): void,
        get_proc("variant_destroy"));
    gd_variant_utility = cast(fn(void*, i64): void*,
        get_proc("variant_get_ptr_utility_function"));
    gd_variant_get_ptr_ctor = cast(fn(i32, i32): void*,
        get_proc("variant_get_ptr_constructor"));
    gd_method_bind_call = cast(fn(void*, void*, void*, i64, void*, void*): void,
        get_proc("object_method_bind_call"));

    gd_dtor_string = gd_variant_get_ptr_destructor(TYPE_STRING);
    gd_dtor_stringname = gd_variant_get_ptr_destructor(TYPE_STRING_NAME);
    gd_dtor_callable = gd_variant_get_ptr_destructor(TYPE_CALLABLE);
    gd_dtor_nodepath = gd_variant_get_ptr_destructor(TYPE_NODE_PATH);

    var init = cast(GDInitialization*, r_initialization);
    init.min_init_level = GD_INIT_SCENE;
    init.userdata = null;
    init.initialize = cast(void*, gd_initialize);
    init.deinitialize = cast(void*, gd_deinitialize);
    return 1;
}
