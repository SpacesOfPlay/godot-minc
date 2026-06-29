// Example minc GDExtension: a MincNode that builds a custom-shaded cube and
// spins it each frame. The minimal shape of a 3D extension: build the scene in
// _ready, animate it in _process.
//
// For a tour of the full binding surface (properties, signals, Variant,
// singletons, static and utility calls), see features.mc.
//
// Build + run: ../build.sh cube   (from the repo root, builds + launches)

import godot;

// Per-instance state.
struct MincInstance {
    GdObject* owner;
    GdObject* cube;       // the CSGBox3D, rotated each frame in _process
}

// Fragment shader
u8* GD_CUBE_SHADER = """
shader_type spatial;
render_mode unshaded;
varying vec3 v_normal;
void vertex() {
    v_normal = NORMAL;
}
void fragment() {
    float t = TIME;
    float cu = UV.x - 0.5;
    float cv = (1.0 - UV.y) - 0.5;
    float sa = sin(t);
    float ca = cos(t);
    float u = cu * ca - cv * sa + 0.5;
    float v = cu * sa + cv * ca + 0.5;
    float mx = u - 0.29;
    float my = v - 0.5;
    float sw = 0.035;
    float h = 0.15;
    float m1 = max(abs(mx) - sw, abs(my) - h);
    float m2 = max(abs(mx - 0.09) - sw, abs(my) - h);
    float m3 = max(abs(mx - 0.18) - sw, abs(my) - h);
    float m4 = max(abs(mx - 0.045) - 0.055, abs(my + h - sw) - sw);
    float m5 = max(abs(mx - 0.135) - 0.055, abs(my + h - sw) - sw);
    float md = min(min(min(m1, m2), min(m3, m4)), m5);
    float cx = u - 0.62;
    float cy = v - 0.5;
    float cw = 0.09;
    float ct = max(abs(cx) - cw, abs(cy - h + sw) - sw);
    float cb = max(abs(cx) - cw, abs(cy + h - sw) - sw);
    float cl = max(abs(cx + cw - sw) - sw, abs(cy) - h);
    float cd = min(min(ct, cb), cl);
    float letter = min(md, cd);
    float text = 1.0 - smoothstep(-0.002, 0.002, letter);
    vec3 n = v_normal;
    vec3 base = vec3(0.6, 0.2, 1.0);
    if (n.z < -0.5) base = vec3(1.0, 0.2, 0.2);
    else if (n.z > 0.5) base = vec3(0.2, 1.0, 0.2);
    else if (n.x < -0.5) base = vec3(0.2, 0.5, 1.0);
    else if (n.x > 0.5) base = vec3(1.0, 0.6, 0.2);
    else if (n.y < -0.5) base = vec3(1.0, 1.0, 0.2);
    base = pow(base, vec3(2.2));
    ALBEDO = mix(base, vec3(1.0), text);
}
""";

@c_abi void* mincnode_create(void* class_userdata) {
    var inst = new(MincInstance);
    inst.owner = gd_construct(class_userdata, cast(void*, inst));
    return cast(void*, inst.owner);
}

@c_abi void mincnode_free(void* class_userdata, void* instance) {
    if instance != null { free(instance); }
    return;
}

@c_abi void mincnode_ready(void* instance, void* args, void* ret) {
    var inst = cast(MincInstance*, instance);
    GdObject* self = inst.owner;

    GdObject* box = csgbox3d_new();
    GdVector3 sz = GdVector3{ 3.0f, 3.0f, 3.0f };
    csgbox3d_set_size(box, &sz);
    node_add_child(self, box);
    inst.cube = box;

    // Shader and ShaderMaterial are RefCounted Resources: claim a reference
    // (init_ref), attach to the cube, then drop our claim (unreference) so the
    // resource frees with its owner.
    GdObject* shader = shader_new();
    ignore refcounted_init_ref(shader);
    GdString code;
    gd_string_new(&code, GD_CUBE_SHADER);
    shader_set_code(shader, &code);
    gd_string_destroy(&code);
    GdObject* mat = shadermaterial_new();
    ignore refcounted_init_ref(mat);
    shadermaterial_set_shader(mat, shader);
    csgbox3d_set_material(box, mat);
    ignore refcounted_unreference(shader);
    ignore refcounted_unreference(mat);

    GdObject* cam = camera3d_new();
    camera3d_set_fov(cam, 40.0);
    GdVector3 campos = GdVector3{ 4.0f, 4.0f, 9.0f };
    node3d_set_position(cam, &campos);
    node_add_child(self, cam);
    GdVector3 target = GdVector3{ 0.0f, 0.0f, 0.0f };
    node3d_look_at(cam, &target);   // up defaults to Vector3(0, 1, 0)
    camera3d_make_current(cam);

    GdObject* light = directionallight3d_new();
    GdVector3 lrot = GdVector3{ -0.9f, 0.4f, 0.0f };
    node3d_set_rotation(light, &lrot);
    node_add_child(self, light);
    return;
}

@c_abi void mincnode_process(void* instance, void* p_args, void* ret) {
    var inst = cast(MincInstance*, instance);
    var args = cast(void**, p_args);
    f64 delta = *(cast(f64*, *args));

    // Tumble: incremental global-axis rotation each frame.
    if inst.cube != null {
        node3d_rotate_x(inst.cube, 0.3 * delta);
        node3d_rotate_y(inst.cube, 0.7 * delta);
    }
    return;
}

void gd_register() {
    i32 cls = gd_class("MincNode", "Node", mincnode_create, mincnode_free);
    gd_bind_virtual(cls, "_ready", mincnode_ready);
    gd_bind_virtual(cls, "_process", mincnode_process);
    return;
}
