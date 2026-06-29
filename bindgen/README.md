# minc → Godot bindings (bindgen/)

This directory holds the binding generator and its spec. The bound surface it
emits is in `lib/` and is consumed with `import godot;`. Write
`gd_register()` and your node callbacks, build with `--shared`, and load the
result as a GDExtension. See `examples/hello.mc` (empty template) and
`examples/cube.mc` (3D example).

## What's here

- `godot_to_minc.py`: generates the `lib/godot_{enums,classes,utility}.mc`
  modules from the Godot API spec.
- `extension_api.json`: the Godot 4.3 API spec the generator reads.
- `bindings.json`: the used-set spec listing which classes, methods, and enums
  to generate. The API has ~14k methods, so this is an explicit allow-list.

The modules it produces (in `lib/`):

- `godot_core.mc`: the reusable core (hand-written, not generated). It holds the
  GDExtension entry point, the interface table, the typed value types (below),
  the String / Variant / ptrcall / ref-counting helpers, and the registration
  API (`gd_class`, `gd_bind_virtual`, `gd_bind_method`, `gd_add_property`,
  `gd_add_signal`).
- `godot_enums.mc`, `godot_classes.mc`, `godot_utility.mc`: generated,
  imported by `godot.mc`. Do not hand-edit. Regenerate from the spec.
- `godot.mc`: the main header that `import godot;` resolves to.

All generator commands below run from the repo root; `./regen.sh`
(`.\regen.ps1` on Windows) wraps the validate + generate step.

## Adding a binding

To add a missing method, edit and regen.

1. Find where the method lives. Methods are declared on the class that
   introduces them, not on every subclass. List a class:

   ```sh
   python3 bindgen/godot_to_minc.py bindgen/extension_api.json --list Node3D
   ```

   This prints every bindable method with its signature, flags any that would
   land as `void*` (an untyped builtin), and lists what's not bindable and
   why. `Node3D.set_position` shows up under `Node3D`; `MeshInstance3D.set_mesh`
   under `MeshInstance3D`, but `set_position` on a mesh instance is inherited.
   List it under `Node3D`.

2. Add it to `bindings.json` under its class (or add a new
   `"ClassName": [...]` entry; a class with `[]` still gets a `<class>_new()`
   constructor).

3. Validate, then regenerate:

   ```sh
   ./regen.sh                                          # validate + regenerate (recommended)

   # …or run the steps by hand, from the repo root:
   python3 bindgen/godot_to_minc.py bindgen/extension_api.json \
       --spec bindgen/bindings.json --check            # friendly errors, no write
   python3 bindgen/godot_to_minc.py bindgen/extension_api.json \
       --spec bindgen/bindings.json --outdir lib
   ```

   `--check` reports every problem at once with a hint: a typo gets a
   "did you mean", an inherited method tells you which base class to list it
   under, and a virtual / vararg / static method is named with the reason.

Inherited methods work on subclasses for free: every wrapper takes a
`GdObject*` self, so `node3d_set_position(my_camera3d, &v)` is fine. A
`Camera3D` is a `Node3D`.

## Typed values, not `void*`

Engine objects are a single opaque handle, `GdObject*`. Builtin value types map
to typed structs sized to Godot's `float_64` build, so your code stays typed and
casts only at the C-ABI edge:

```mc
GdObject* cam = camera3d_new();
GdVector3 pos = GdVector3{ 4.0f, 4.0f, 9.0f };
node3d_set_position(cam, &pos);          // typed; no void*, no cast
GdString name; gd_string_new(&name, "Main");
node_set_name(cam, &name); gd_string_destroy(&name);
```

Typed builtins: `GdString`, `GdStringName`, `GdNodePath`, `GdVariant`,
`GdCallable`, `GdVector2/2i/3/3i/4`, `GdColor`, `GdRect2`, `GdPlane`,
`GdQuaternion`, `GdAABB`, `GdBasis`, `GdTransform2D/3D`. Construct the opaque
ones (`String`, `StringName`, `NodePath`, `Callable`) with their `gd_*_new`
helpers and free them with `gd_*_destroy`; the POD math types are plain struct
literals. Any other builtin (`Array`, `Dictionary`, `RID`, …) currently binds as
`void*`. To give one a type: define a struct in `lib/godot_core.mc` sized to the
`float_64` build, then add it to `BUILTIN_TYPE` in `bindgen/godot_to_minc.py`.

## Singletons

Global engine objects (`Input`, `Engine`, `Time`, `OS`, …) aren't constructed.
The generator detects them from the API's singleton list and emits a cached
`<class>_singleton()` accessor instead of `<class>_new()`, and their method
wrappers take no `self` (there's only one instance, fetched internally):

```mc
GdStringName jump; gd_stringname_new(&jump, "ui_accept");
if input_is_action_pressed(&jump, 0) { /* … */ }   // no self
gd_stringname_destroy(&jump);

i64 ms = time_get_ticks_msec();                     // no self
```

Add singleton methods exactly like any other (list them under `Input`, `Engine`,
…); `--list Input` tags the class as a singleton. Use `input_singleton()` if you
need the raw `GdObject*`.

## Static methods

Class methods with no instance (`FileAccess.file_exists`, `JSON.parse_string`,
`Image.create`, …) bind like any other. List them under their class. The
wrapper takes no `self` and is ptrcalled with a null instance:

```mc
GdString p; gd_string_new(&p, "res://save.json");
if fileaccess_file_exists(&p) { ... }   // no self
gd_string_destroy(&p);
```

`--list` tags them `[static - no self]`. A class can have both static methods
and a `<class>_new()` constructor (e.g. `FileAccess`).

## Utility functions

Godot's global utility functions (`lerp`, `clamp`, `deg_to_rad`, `sin`, `sqrt`,
`randf`, …) are bound as `gd_<name>` wrappers, prefixed so they don't clash
with engine methods or minc's own math builtins. List them under a top-level
`"utility"` key in `bindings.json`:

```json
{ "classes": { ... },
  "utility": ["deg_to_rad", "sin", "cos", "lerpf", "clampf", "randf_range"] }
```

```mc
f64 r = gd_deg_to_rad(180.0);          // ~= 3.14159
f64 x = gd_clampf(v, 0.0, 1.0);
f64 n = gd_randf_range(1.0, 10.0);
```

The scalar-typed ones (`*f`/`*i` and the trig/exp family) take and return
`f64`/`i64` directly. The polymorphic ones (`lerp`, `clamp`, `abs`, `floor`, …)
are typed `Variant` in Godot, so their wrappers take/return `GdVariant*`. Use
the scalar variant (`lerpf`, `clampf`, `absf`) when you want plain floats.
Vararg utilities (`print`, `max`, `min`, `str`) aren't bound; `--check` flags
them. (For printing, the core has `gd_print`.)

## Default arguments

minc has no default-parameter syntax, but it does have arity overloading, so the
generator emits a short overload for each trailing argument Godot defaults. You
can omit them:

```mc
node_add_child(self, child);          // force_readable_name=false, internal=0
node_add_child(self, child, 1);       // internal=0
i64 n = node_get_child_count(self);   // include_internal=false
node3d_look_at(self, &target);        // up=Vector3(0,1,0), use_model_front=false
```

Simple-literal defaults (bool/int/float/null) are filled inline. Non-literal
defaults are built into a temporary in the overload: an empty/constant `String`,
`StringName`, or `NodePath` (`gd_string_new(&t, "…")`, freed after the call); a
nil or int `Variant`; and flat POD math defaults (`Vector3(0,1,0)`,
`Color(1,1,1,1)`, `Transform2D(1,0,0,1,0,0)`, …) as struct literals. A default
the generator can't construct (an empty `Array`/`Dictionary`/`Callable`, a
nested aggregate) stops the peel. That argument and everything before it stay
explicit.

## Transitive dependencies

When a bound method takes or returns an engine class you didn't list, the
generator auto-pulls a `<class>_new()` constructor for it (if the class is
instantiable) so you can obtain one without listing it by hand. For example,
binding `MeshInstance3D.set_mesh(mesh: Mesh)` and `set_material_override(material:
Material)` auto-emits `mesh_new()`, `material_new()`, `texture2d_new()`. These
are accessor-only. To bind a dependency's methods, list the class explicitly
(which also removes it from the auto-pull set). `--check` reports what gets
pulled. Abstract (non-instantiable) dependencies are skipped; they're still
reachable as a `GdObject*` returned by some other call.

## Your own methods & signals (with arguments)

`gd_bind_method` and `gd_add_signal` are variadic over `TYPE_*` ids: pass the
argument count, then that many types. The method impl reads its arguments
through the ptrcall ABI (`args[0..n]`); the same impl serves both the typed
ptrcall path and the Variant path (`Object.call`, `Object.set`/`get`, signal
callbacks):

```mc
// ret_type, then nargs, then nargs TYPE_* ids
gd_bind_method(cls, "set_value",  mn_set_value, -1,         1, TYPE_INT);
gd_bind_method(cls, "get_value",  mn_get_value, TYPE_INT,   0);
gd_bind_method(cls, "move",       mn_move,      -1,         2, TYPE_VECTOR3, TYPE_FLOAT);

gd_add_signal(cls, "value_changed", 1, TYPE_INT);
gd_add_signal(cls, "pair_set",      2, TYPE_INT, TYPE_INT);

@c_abi void mn_move(void* mud, void* inst, void* p_args, void* ret) {
    var args = cast(void**, p_args);
    GdVector3* to = cast(GdVector3*, args[0]);   // ptrcall ABI: one ptr per arg
    f64 speed     = *(cast(f64*, args[1]));
    // …
}
```

Emit carries Variant payloads (signals are Variant-typed, so the caller builds
the Variants; Godot's int is 64-bit, so use `gd_variant_int` etc.):

```mc
GdVariant v; gd_variant_int(&v, 7);
gd_emit_signal(self, "value_changed", &v, 1);
gd_variant_destroy(&v);

gd_emit_signal(self, "ready");   // no-payload overload
```

The per-method/per-signal argument cap is `GD_MAX_METHOD_ARGS` (8). The
registration calls use minc's native varargs only for the compile-time `TYPE_*`
ids; values always travel as typed `GdVariant`s, never an untyped pack.

## What doesn't bind

`--list` and `--check` flag these:

- virtual methods: you implement these (`gd_bind_virtual(cls, "_ready",
  …)`), they aren't called as bindings.
- vararg methods: go through the Variant call path (e.g. `gd_emit_signal`).

(Instance, static, and singleton methods all bind; only virtual and vararg
don't.)
