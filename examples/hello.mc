// Starter GDExtension in minc. Copy this file, rename things, and build
// (./build.sh hello): write your callbacks, register them in gd_register().
// `import godot;` brings in the GDExtension entry point, the engine bindings,
// and the registration API.

import godot;

// Per-instance state. `owner` is the Godot Object this node wraps — keep it
// so your virtuals can call engine methods on `self`.
struct State {
    GdObject* owner;
    i64 frames;
}

// Constructor: allocate state, then gd_construct builds the registered base
// object and attaches the state to it.
@c_abi void* hello_create(void* class_userdata) {
    var s = new(State);
    s.owner = gd_construct(class_userdata, cast(void*, s));
    return cast(void*, s.owner);
}

@c_abi void hello_free(void* class_userdata, void* instance) {
    if instance != null { free(instance); }
    return;
}

// _ready runs once when the node enters the scene tree.
@c_abi void hello_ready(void* instance, void* args, void* ret) {
    gd_print("Hello from minc! (HelloMinc._ready)");
    return;
}

// _process runs every frame; args[0] is the float delta (8-byte double).
@c_abi void hello_process(void* instance, void* p_args, void* ret) {
    var s = cast(State*, instance);
    s.frames = s.frames + 1;
    return;
}

// The core calls this at scene init — register your classes here.
void gd_register() {
    i32 cls = gd_class("HelloMinc", "Node", hello_create, hello_free);
    gd_bind_virtual(cls, "_ready", hello_ready);
    gd_bind_virtual(cls, "_process", hello_process);
    return;
}
