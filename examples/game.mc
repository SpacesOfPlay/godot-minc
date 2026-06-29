// 3D Sokoban in minc
//
// Build + run: ../build.sh game   (from the repo root, builds + launches)

import godot;


const i32 STRIDE = 16;          // grid row stride (max width); cells = STRIDE*STRIDE
const i32 MAXBOX = 16;
const i32 MAXPAD = 16;
const f64 CELL = 1.0;           // world units per grid cell

const f64 PLAYER_R = 0.4;
const f64 PLAYER_Y = 0.4;       // ball centre height = radius (resting on y=0)
const f64 BOX_Y = 0.4;

const f64 WALL_SX = 0.75;       // border cube size
const f64 WALL_SY = 0.25;       // 
const f64 WALL_SZ = 0.75;       // 
const f64 WALL_Y = 0.125;       // vertical pos


// The level. '#' wall, '.' pad (target), '$' crate, '@' player, ' ' floor.
u8* SOKO_LEVEL =
    "#########\n"
    "## ..   #\n"
    "#  $$ # #\n"
    "#.#@#$# #\n"
    "#  $$   #\n"
    "#  .. # #\n"
    "#########\n";


// --- GDSL shaders (one ShaderMaterial each) -------------------------------

// player: a dark sphere with silhouette
u8* SH_PLAYER = """
shader_type spatial;
void fragment() {
    vec3 n = normalize(NORMAL);
    float rim = pow(1.0 - clamp(dot(n, normalize(VIEW)), 0.0, 1.0), 2.5);
    float t = TIME * 1.5;
    vec3 a = vec3(1.0, 0.1, 0.7);
    vec3 b = vec3(0.1, 0.9, 1.0);
    vec3 col = mix(a, b, 0.5 + 0.5 * sin(t + n.y * 4.0));
    ALBEDO = vec3(0.03, 0.02, 0.06);
    EMISSION = col * rim * 2.2;
    METALLIC = 0.3;
    ROUGHNESS = 0.4;
}
""";

// push object: a magenta sphere with bayer dither
u8* SH_BOX = """
shader_type spatial;
uniform float fade = 0.0;
void fragment() {
    float bayer[16] = {
         0.0,  8.0,  2.0, 10.0,
        12.0,  4.0, 14.0,  6.0,
         3.0, 11.0,  1.0,  9.0,
        15.0,  7.0, 13.0,  5.0 };
    float px = 5.0;
    int ix = int(mod(floor(FRAGCOORD.x / px), 4.0));
    int iy = int(mod(floor(FRAGCOORD.y / px), 4.0));
    if ((bayer[ix + iy * 4] + 0.5) / 16.0 < fade) { discard; }
    vec3 c = vec3(0.6, 0.08, 0.36);
    ALBEDO = c * 0.7;
    EMISSION = c * 0.2;
    METALLIC = 0.2;
    ROUGHNESS = 0.35;
}
""";

// floor: a grid
u8* SH_FLOOR = """
shader_type spatial;
uniform float off_x = 0.0;
uniform float off_z = 0.0;
varying vec3 wpos;
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
    vec2 g = abs(fract(wpos.xz + vec2(off_x, off_z)) - 0.5);
    float line = smoothstep(0.47, 0.5, max(g.x, g.y));
    ALBEDO = vec3(0.06, 0.02, 0.15);
    EMISSION = vec3(0.0, 0.9, 1.0) * line * 1.3;
    ROUGHNESS = 0.4;
}
""";

// walls: dark blue box
u8* SH_WALL = """
shader_type spatial;
void fragment() {
    vec2 d = abs(UV - 0.5);
    float bevel = smoothstep(0.40, 0.5, max(d.x, d.y));
    vec3 o = MODEL_MATRIX[3].xyz;
    float ph = o.x * 1.7 + o.z * 1.1;
    float t = 0.5 + 0.5 * sin(TIME * 0.3 + ph);
    vec3 c = mix(vec3(0.05, 0.12, 0.55), vec3(0.12, 0.28, 0.85), t);
    c = mix(c, c * 0.4, bevel);
    ALBEDO = c;
    EMISSION = c * (0.3 + 0.25 * t);
    ROUGHNESS = 0.3;
}
""";

// goal: a dark-gray disc
u8* SH_PAD = """
shader_type spatial;
uniform float fade = 0.0;
void fragment() {
    float bayer[16] = {
         0.0,  8.0,  2.0, 10.0,
        12.0,  4.0, 14.0,  6.0,
         3.0, 11.0,  1.0,  9.0,
        15.0,  7.0, 13.0,  5.0 };
    float px = 5.0;
    int ix = int(mod(floor(FRAGCOORD.x / px), 4.0));
    int iy = int(mod(floor(FRAGCOORD.y / px), 4.0));
    if ((bayer[ix + iy * 4] + 0.5) / 16.0 < fade) { discard; }
    vec3 o = MODEL_MATRIX[3].xyz;
    float ph = o.x * 1.7 + o.z * 1.1;
    float t = 0.5 + 0.5 * sin(TIME * 0.3 + ph);
    vec3 c = mix(vec3(0.12, 0.12, 0.14), vec3(0.22, 0.22, 0.26), t);
    ALBEDO = c * 0.6;
    EMISSION = c * (0.2 + 0.2 * t);
    ROUGHNESS = 0.5;
}
""";

// fake sphere shadow
u8* SH_SHADOW = """
shader_type spatial;
render_mode unshaded;
varying vec3 lp;
void vertex() { lp = VERTEX; }
void fragment() {
    float r = clamp(length(lp.xz) / 0.52, 0.0, 1.0);
    ALBEDO = vec3(0.0);
    ALPHA = (1.0 - smoothstep(0.7, 1.0, r)) * 0.6;
}
""";


// --- game state -------------------------------------------------------

struct SokoInstance {
    GdObject* owner;
    i32 w;
    i32 h;
    u8[STRIDE * STRIDE] wall;     // 1 = wall cell
    u8[STRIDE * STRIDE] target;   // 1 = pad cell
    i32 px;                       // player grid col/row
    i32 py;
    f64 pvx;                      // player visual world x/z (lerped toward grid)
    f64 pvz;
    GdObject* player_node;
    GdObject* player_shadow;      // blob shadows that follow each sphere
    GdObject*[MAXBOX] box_shadow;
    i32 nbox;
    i32[MAXBOX] bx;               // crate grid col/row
    i32[MAXBOX] by;
    f64[MAXBOX] bvx;              // crate visual world x/z
    f64[MAXBOX] bvz;
    f64[MAXBOX] bfade;            // crate dither-dissolve amount (0..1, 1 on a pad)
    GdObject*[MAXBOX] box_node;
    GdObject*[MAXBOX] box_mat;    // each crate's ShaderMaterial (fade uniform)
    u8[MAXBOX] bgone;             // crate removed from the playfield once placed
    i32 npad;                     // pads, each with its own fade material
    i32[MAXPAD] pad_x;
    i32[MAXPAD] pad_y;
    f64[MAXPAD] pfade;            // pad dither-dissolve (1 when a crate covers it)
    GdObject*[MAXPAD] pad_node;
    GdObject*[MAXPAD] pad_mat;
    u8[MAXPAD] pgone;             // pad removed with its crate
    i32 solved;
    GdStringName* act_up;         // cached input-action names (gd_intern pool)
    GdStringName* act_down;
    GdStringName* act_left;
    GdStringName* act_right;
    GdStringName* act_reset;
}

// --- small helpers --------------------------------------------------------

// Grid cell -> centred world coordinate.
f64 soko_wx(SokoInstance* s, i32 col) {
    return (cast(f64, col) - cast(f64, s.w) * 0.5 + 0.5) * CELL;
}
f64 soko_wz(SokoInstance* s, i32 row) {
    return (cast(f64, row) - cast(f64, s.h) * 0.5 + 0.5) * CELL;
}

void soko_set_pos(GdObject* node, f64 x, f64 y, f64 z) {
    GdVector3 v = GdVector3{ cast(f32, x), cast(f32, y), cast(f32, z) };
    node3d_set_position(node, &v);
}

// Move `cur` toward `target`.
f64 soko_approach(f64 cur, f64 target, f64 step) {
    if cur < target {
        cur = cur + step;
        if cur > target { cur = target; }
    } 
    else {
        cur = cur - step;
        if cur < target { cur = target; }
    }
    return cur;
}

void soko_set_scale(GdObject* node, f64 s) {
    GdVector3 v = GdVector3{ cast(f32, s), cast(f32, s), cast(f32, s) };
    node3d_set_scale(node, &v);
}

// A flat blob-shadow disc (just above the floor), sharing `mat`.
GdObject* soko_shadow(GdObject* self, GdObject* mat) {
    GdObject* sh = csgcylinder3d_new();
    csgcylinder3d_set_radius(sh, 0.52);
    csgcylinder3d_set_height(sh, 0.02);
    csgcylinder3d_set_sides(sh, 24);
    csgcylinder3d_set_material(sh, mat);
    node_add_child(self, sh);
    return sh;
}

// Build a ShaderMaterial from GDSL code. Shader + material are RefCounted.
GdObject* soko_material(u8* code) {
    GdObject* shader = shader_new();
    ignore refcounted_init_ref(shader);
    GdString src;
    gd_string_new(&src, code);
    shader_set_code(shader, &src);
    gd_string_destroy(&src);
    GdObject* mat = shadermaterial_new();
    ignore refcounted_init_ref(mat);
    shadermaterial_set_shader(mat, shader);
    ignore refcounted_unreference(shader);   // mat owns the shader now
    return mat;
}

// Set a float shader uniform on a ShaderMaterial.
void soko_set_param(GdObject* mat, u8* name, f64 value) {
    GdStringName pn;
    gd_stringname_new(&pn, name);
    GdVariant v;
    gd_variant_from(&v, TYPE_FLOAT, cast(void*, &value));
    shadermaterial_set_shader_parameter(mat, &pn, &v);
    gd_variant_destroy(&v);
    gd_stringname_destroy(&pn);
}

i32 soko_box_at(SokoInstance* s, i32 x, i32 y) {
    for i32 i = 0; i < s.nbox; i++ {
        if s.bgone[i] == 0 && s.bx[i] == x && s.by[i] == y { return i; }
    }
    return 0 - 1;
}

// --- gameplay -------------------------------------------------------------

// parse level data
void soko_parse(SokoInstance* s) {
    u8* L = SOKO_LEVEL;
    i32 col = 0;
    i32 row = 0;
    i32 maxw = 0;
    i32 i = 0;
    while L[i] != 0 {
        u8 ch = L[i];
        i = i + 1;
        if ch == '\n' {
            if col > maxw { maxw = col; }
            row = row + 1;
            col = 0;
            continue;
        }
        i32 id = row * STRIDE + col;
        if ch == '#' {
            s.wall[id] = 1;
        } 
        else if ch == '.' {
            s.target[id] = 1;
        } 
        else if ch == '$' {
            s.bx[s.nbox] = col;
            s.by[s.nbox] = row;
            s.nbox = s.nbox + 1;
        } 
        else if ch == '@' {
            s.px = col;
            s.py = row;
        }
        col = col + 1;
    }
    if col > maxw { maxw = col; }
    s.w = maxw;
    s.h = row;
}

// detect win condition
void soko_update(SokoInstance* s) {
    i32 done = 1;
    for i32 i = 0; i < s.nbox; i++ {
        if s.bgone[i] == 0 && s.target[s.by[i] * STRIDE + s.bx[i]] == 0 { done = 0; }
    }
    if done == 1 { s.solved = 1; }
}

// try to step the player by (dx, dy), pushing a single crate if there's room.
void soko_try_move(SokoInstance* s, i32 dx, i32 dy) {
    i32 nx = s.px + dx;
    i32 ny = s.py + dy;
    if s.wall[ny * STRIDE + nx] != 0 { return; }
    i32 bi = soko_box_at(s, nx, ny);
    if bi >= 0 {
        // A crate already on a pad is committed (dissolving away) — can't push.
        if s.target[ny * STRIDE + nx] != 0 { return; }
        i32 bx2 = nx + dx;
        i32 by2 = ny + dy;
        if s.wall[by2 * STRIDE + bx2] != 0 { return; }
        if soko_box_at(s, bx2, by2) >= 0 { return; }
        s.bx[bi] = bx2;
        s.by[bi] = by2;
    }
    s.px = nx;
    s.py = ny;
    soko_update(s);
}

// --- scene construction ---------------------------------------------------

// Static scene — floor + border cubes.
void soko_build_static(SokoInstance* s, GdObject* self) {
    GdObject* floor = csgbox3d_new();
    GdVector3 fs = GdVector3{ cast(f32, cast(f64, s.w) * CELL),
                             0.4f, cast(f32, cast(f64, s.h) * CELL) };
    csgbox3d_set_size(floor, &fs);
    soko_set_pos(floor, 0.0, 0.0 - 0.2, 0.0);
    GdObject* floormat = soko_material(SH_FLOOR);
    csgbox3d_set_material(floor, floormat);
    soko_set_param(floormat, "off_x", cast(f64, s.w) * 0.5);
    soko_set_param(floormat, "off_z", cast(f64, s.h) * 0.5);
    ignore refcounted_unreference(floormat);
    node_add_child(self, floor);

    GdObject* wallmat = soko_material(SH_WALL);   // shared by every border cube
    for i32 y = 0; y < s.h; y++ {
        for i32 x = 0; x < s.w; x++ {
            if s.wall[y * STRIDE + x] != 0 {
                GdObject* wb = csgbox3d_new();
                GdVector3 ws = GdVector3{ cast(f32, CELL * WALL_SX), cast(f32, CELL * WALL_SY), cast(f32, CELL * WALL_SZ) };
                csgbox3d_set_size(wb, &ws);
                soko_set_pos(wb, soko_wx(s, x), WALL_Y, soko_wz(s, y));
                csgbox3d_set_material(wb, wallmat);
                node_add_child(self, wb);
            }
        }
    }
    ignore refcounted_unreference(wallmat);
}

// Camera + light — built once in _ready, after the meshes exist.
void soko_build_view(SokoInstance* s, GdObject* self) {
    f64 span = cast(f64, s.w);
    if s.h > s.w { span = cast(f64, s.h); }
    span = span * CELL;
    GdObject* cam = camera3d_new();
    node_add_child(self, cam);   // in the tree before look_at
    soko_set_pos(cam, 0.0, span * 1.18, span * 0.28);
    GdVector3 ctr = GdVector3{ 0.0f, 0.0f, 0.0f };
    node3d_look_at(cam, &ctr);   // up defaults to Vector3(0, 1, 0)
    camera3d_set_fov(cam, 50.0);
    camera3d_make_current(cam);

    GdObject* light = directionallight3d_new();
    node_add_child(self, light);
    GdVector3 lrot = GdVector3{ -1.1f, -0.6f, 0.0f };
    node3d_set_rotation(light, &lrot);
}

// Dynamic scene — pads, crates, the player, and shadows.
void soko_build_dynamic(SokoInstance* s, GdObject* self) {
    GdObject* shadowmat = soko_material(SH_SHADOW);   // shared by all blob shadows

    // pads — each its own material (per-pad fade uniform)
    for i32 y = 0; y < s.h; y++ {
        for i32 x = 0; x < s.w; x++ {
            if s.target[y * STRIDE + x] != 0 {
                GdObject* pad = csgcylinder3d_new();   // a flat disc = a circle
                csgcylinder3d_set_radius(pad, 0.4);
                csgcylinder3d_set_height(pad, 0.08);
                csgcylinder3d_set_sides(pad, 32);
                soko_set_pos(pad, soko_wx(s, x), 0.04, soko_wz(s, y));
                GdObject* pmat = soko_material(SH_PAD);
                csgcylinder3d_set_material(pad, pmat);
                ignore refcounted_unreference(pmat);   // pad owns it
                s.pad_node[s.npad] = pad;
                s.pad_mat[s.npad] = pmat;
                s.pad_x[s.npad] = x;
                s.pad_y[s.npad] = y;
                s.pfade[s.npad] = 0.0;
                if soko_box_at(s, x, y) >= 0 { s.pfade[s.npad] = 1.0; }
                soko_set_param(pmat, "fade", s.pfade[s.npad]);
                s.npad = s.npad + 1;
                node_add_child(self, pad);
            }
        }
    }

    // magenta spheres, each its own material (fade uniform)
    for i32 i = 0; i < s.nbox; i++ {
        GdObject* bn = csgsphere3d_new();
        csgsphere3d_set_radius(bn, 0.4);
        csgsphere3d_set_radial_segments(bn, 28);
        csgsphere3d_set_rings(bn, 14);
        csgsphere3d_set_smooth_faces(bn, 1);
        GdObject* bm = soko_material(SH_BOX);
        csgsphere3d_set_material(bn, bm);
        ignore refcounted_unreference(bm);
        s.box_node[i] = bn;
        s.box_mat[i] = bm;
        s.bfade[i] = 0.0;
        if s.target[s.by[i] * STRIDE + s.bx[i]] != 0 { s.bfade[i] = 1.0; }
        soko_set_param(bm, "fade", s.bfade[i]);
        s.bvx[i] = soko_wx(s, s.bx[i]);
        s.bvz[i] = soko_wz(s, s.by[i]);
        soko_set_pos(bn, s.bvx[i], BOX_Y, s.bvz[i]);
        node_add_child(self, bn);
        s.box_shadow[i] = soko_shadow(self, shadowmat);
        soko_set_pos(s.box_shadow[i], s.bvx[i], 0.015, s.bvz[i]);
    }

    // player ball
    GdObject* ball = csgsphere3d_new();
    csgsphere3d_set_radius(ball, PLAYER_R);
    csgsphere3d_set_radial_segments(ball, 48);   // smooth
    csgsphere3d_set_rings(ball, 24);
    csgsphere3d_set_smooth_faces(ball, 1);
    GdObject* pm = soko_material(SH_PLAYER);
    csgsphere3d_set_material(ball, pm);
    ignore refcounted_unreference(pm);
    s.player_node = ball;
    s.pvx = soko_wx(s, s.px);
    s.pvz = soko_wz(s, s.py);
    soko_set_pos(ball, s.pvx, PLAYER_Y, s.pvz);
    node_add_child(self, ball);
    s.player_shadow = soko_shadow(self, shadowmat);
    soko_set_pos(s.player_shadow, s.pvx, 0.015, s.pvz);
    ignore refcounted_unreference(shadowmat);
}

// Reset to the start of the level: free the live dynamic nodes, re-parse the
// level (restoring crates, targets, and the player start), and rebuild.
void soko_reset(SokoInstance* s, GdObject* self) {
    node_queue_free(s.player_node);
    node_queue_free(s.player_shadow);
    for i32 i = 0; i < s.nbox; i++ {
        if s.bgone[i] == 0 {
            node_queue_free(s.box_node[i]);
            node_queue_free(s.box_shadow[i]);
        }
    }
    for i32 j = 0; j < s.npad; j++ {
        if s.pgone[j] == 0 { node_queue_free(s.pad_node[j]); }
    }
    s.nbox = 0;
    s.npad = 0;
    s.solved = 0;
    for i32 i = 0; i < STRIDE * STRIDE; i++ { s.target[i] = 0; }
    soko_parse(s);   // restores w/h/px/py/bx/by/nbox/target
    for i32 i = 0; i < MAXBOX; i++ { s.bgone[i] = 0; }
    for i32 j = 0; j < MAXPAD; j++ { s.pgone[j] = 0; }
    soko_build_dynamic(s, self);
}

// --- virtuals -------------------------------------------------------------

@c_abi void* soko_create(void* class_userdata) {
    var s = new(SokoInstance);
    s.owner = gd_construct(class_userdata, cast(void*, s));
    return cast(void*, s.owner);
}

@c_abi void soko_free(void* class_userdata, void* instance) {
    if instance != null { free(instance); }
    return;
}

@c_abi void soko_ready(void* instance, void* args, void* ret) {
    var s = cast(SokoInstance*, instance);
    soko_parse(s);
    s.act_up = gd_intern("ui_up");
    s.act_down = gd_intern("ui_down");
    s.act_left = gd_intern("ui_left");
    s.act_right = gd_intern("ui_right");
    s.act_reset = gd_intern("ui_select");   // spacebar
    soko_build_static(s, s.owner);
    soko_build_dynamic(s, s.owner);
    soko_build_view(s, s.owner);
    soko_update(s);          // initial on_target colours
    gd_puts("minc sokoban: built\n");
    return;
}

@c_abi void soko_process(void* instance, void* p_args, void* ret) {
    var s = cast(SokoInstance*, instance);
    var args = cast(void**, p_args);
    f64 delta = *(cast(f64*, *args));

    // spacebar resets level
    if input_is_action_just_pressed(s.act_reset) != 0 {
        soko_reset(s, s.owner);
        return;
    }

    // input: one cell per arrow press
    if s.solved == 0 {
        i32 dx = 0;
        i32 dy = 0;
        if input_is_action_just_pressed(s.act_up) != 0 {
            dy = 0 - 1;
        } 
        else if input_is_action_just_pressed(s.act_down) != 0 {
            dy = 1;
        } 
        else if input_is_action_just_pressed(s.act_left) != 0 {
            dx = 0 - 1;
        } 
        else if input_is_action_just_pressed(s.act_right) != 0 {
            dx = 1;
        }
        if dx != 0 || dy != 0 { soko_try_move(s, dx, dy); }
    }

    // smooth the ball + crates toward their grid cells; roll the ball.
    f64 k = 12.0 * delta;
    if k > 1.0 { k = 1.0; }
    f64 tx = soko_wx(s, s.px);
    f64 tz = soko_wz(s, s.py);
    f64 ox = s.pvx;
    f64 oz = s.pvz;
    s.pvx = ox + (tx - ox) * k;
    s.pvz = oz + (tz - oz) * k;
    soko_set_pos(s.player_node, s.pvx, PLAYER_Y, s.pvz);
    soko_set_pos(s.player_shadow, s.pvx, 0.015, s.pvz);
    node3d_rotate_z(s.player_node, (0.0 - (s.pvx - ox)) / PLAYER_R);
    node3d_rotate_x(s.player_node, (s.pvz - oz) / PLAYER_R);

    f64 step = 3.0 * delta;   // linear dither dissolve
    for i32 i = 0; i < s.nbox; i++ {
        if s.bgone[i] != 0 { continue; }
        f64 bgx = soko_wx(s, s.bx[i]);
        f64 bgz = soko_wz(s, s.by[i]);
        s.bvx[i] = s.bvx[i] + (bgx - s.bvx[i]) * k;
        s.bvz[i] = s.bvz[i] + (bgz - s.bvz[i]) * k;
        soko_set_pos(s.box_node[i], s.bvx[i], BOX_Y, s.bvz[i]);
        // Dither out on a pad
        f64 onpad = 0.0;
        if s.target[s.by[i] * STRIDE + s.bx[i]] != 0 { onpad = 1.0; }
        s.bfade[i] = soko_approach(s.bfade[i], onpad, step);
        soko_set_param(s.box_mat[i], "fade", s.bfade[i]);
        // shadow follows the crate and shrinks away as it dissolves
        soko_set_pos(s.box_shadow[i], s.bvx[i], 0.015, s.bvz[i]);
        soko_set_scale(s.box_shadow[i], 1.0 - s.bfade[i]);
        // fully dissolved on a pad: remove the crate, its shadow, and the pad
        if onpad > 0.5 && s.bfade[i] >= 0.999 {
            node_queue_free(s.box_node[i]);
            node_queue_free(s.box_shadow[i]);
            for i32 j = 0; j < s.npad; j++ {
                if s.pgone[j] == 0 && s.pad_x[j] == s.bx[i] && s.pad_y[j] == s.by[i] {
                    node_queue_free(s.pad_node[j]);
                    s.pgone[j] = 1;
                }
            }
            s.target[s.by[i] * STRIDE + s.bx[i]] = 0;   // cell is plain floor now
            s.bgone[i] = 1;
        }
    }
    // pads dither out together with the crate covering them.
    for i32 i = 0; i < s.npad; i++ {
        if s.pgone[i] != 0 { continue; }
        f64 covered = 0.0;
        if soko_box_at(s, s.pad_x[i], s.pad_y[i]) >= 0 { covered = 1.0; }
        s.pfade[i] = soko_approach(s.pfade[i], covered, step);
        soko_set_param(s.pad_mat[i], "fade", s.pfade[i]);
    }
    return;
}

void gd_register() {
    i32 cls = gd_class("SokoGame", "Node", soko_create, soko_free);
    gd_bind_virtual(cls, "_ready", soko_ready);
    gd_bind_virtual(cls, "_process", soko_process);
    return;
}
