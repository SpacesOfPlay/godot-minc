// Asteroids with hot-reloaded game logic.
//
// This node is the engine. It owns the world, samples input, draws, and
// embeds the minc compiler (libminc) to compile asteroids/script.mc at
// runtime. 
//
// Edit + save the script while the game runs. A file watch triggers a 
// recompile and the new code is swapped in with the world untouched. 
// The contract between the two sides is asteroids/game_abi.mc.
//

import godot;
import libminc;
import file;
import math;

#include "asteroids/game_abi.mc"

const f32 VIEW_X = 1152.0f;   // Godot default window size
const f32 VIEW_Y = 648.0f;

// --- the reloadable script module -----------------------------------

const i32 MAX_CLOSURE = 16;

struct ScriptModule {
    void*           handle;
    ScriptHook      update;
    ScriptHook      reloaded;
    u64             src_hash;    // FNV of source
    FileStamp       stamp;
    // import closure of the last successful compile (game_abi, math, ...)
    u8*[MAX_CLOSURE]       cl_path;
    FileStamp[MAX_CLOSURE] cl_stamp;
    i32                    cl_count;
}

// per-instance state.
struct State {
    GdObject*       owner;
    World           world;
    ScriptModule    mod;
    void*           ctx;              // libminc context
    FileWatch       watch;
    u8*             script_path;      // absolute path to asteroids/script.mc
    InputState      input;            // last sampled input, reused by _draw
    u32             rng;
    i32             shown_score;      // last score/lives drawn into the label
    i32             shown_lives;
    GdObject*       label;
    GdObject*       toast;            // "script recompile" notice, top right
    f32             toast_left;       // seconds until it hides
    GdStringName*   act_left;
    GdStringName*   act_right;
    GdStringName*   act_thrust;
    GdStringName*   act_fire;
}

// --- helpers ---------------------------------------------------------

// FNV-1a of a file's contents; 0 when unreadable.
u64 hash_file(str path) {
    FileData fd = file_read(path);
    if fd.data == null { return 0; }
    u64 h = 0xCBF29CE484222325;
    for i32 i = 0; i < fd.len; i++ { h = (h ^ cast(u64, fd.data[i])) * 1099511628211; }
    free(fd.data);
    return h;
}

// res://... -> owned absolute path (caller frees).
u8* globalize(u8* res_path) {
    GdString in;
    GdString out;
    gd_string_new(&in, res_path);
    projectsettings_globalize_path(&in, &out);
    u8[512] buf;
    i64 n = gd_string_to_cstr(&out, &buf[0], 512);
    gd_string_destroy(&in);
    gd_string_destroy(&out);
    u8* r = alloc<u8>(n + 1);
    memcpy(r, &buf[0], n);
    *(r + n) = 0;
    return r;
}

f32 st_rnd(State* s) {
    // xorshift32
    u32 x = s.rng;
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    s.rng = x;
    return cast(f32, x >> 8) * (1.0f / 16777216.0f);
}

// HostApi callbacks
State* g_cur;
void api_log(u8* msg) { gd_print(msg); }
f32 api_rnd() { return st_rnd(g_cur); }
// Engine-image allocator: blocks outlive every script module.
void* api_alloc(i64 n) { return alloc(n); }
void api_free(void* p) { free(p); }

HostApi g_api;
void build_api() {
    g_api.abi_version = GAME_ABI_VERSION;
    g_api.log = api_log;
    g_api.rnd = api_rnd;
    g_api.alloc = api_alloc;
    g_api.free = api_free;
}

// --- script reload ----------------------------------------------------

// Remember the import closure of a successful compile, with stamps, so
// edits to imported files also trigger a reload.
void capture_closure(State* s) {
    for i32 i = 0; i < s.mod.cl_count; i++ { free(s.mod.cl_path[i]); }
    s.mod.cl_count = 0;
    i32 n = minc_closure_count(s.ctx);
    if n > MAX_CLOSURE { n = MAX_CLOSURE; }
    for i32 i = 0; i < n; i++ {
        u8* p = minc_closure_path(s.ctx, i);   // valid until the next compile
        if p == null { continue; }
        i32 len = 0;
        while *(p + len) != 0 { len++; }
        u8* z = alloc<u8>(len + 1);
        memcpy(z, p, len + 1);
        i32 k = s.mod.cl_count;
        s.mod.cl_path[k] = z;
        s.mod.cl_stamp[k] = file_stamp(str_from_cstr(z));
        s.mod.cl_count = k + 1;
    }
}

// Compile the script file (its imports resolve as siblings + stdlib),
// validate, swap create-before-destroy. Any failure keeps the previous
// module running.
bool reload_script(State* s) {
    void* newmod = minc_compile_file(s.ctx, s.script_path);
    if newmod == null {
        gd_print("asteroids: script compile failed:");
        gd_print(minc_errors(s.ctx));
        return false;
    }
    capture_closure(s);
    bool keep = false;
    defer { if !keep { minc_module_free(newmod); } }

    var fn_version = cast(ScriptVersion, minc_sym(newmod, "script_abi_version"));
    var fn_update  = minc_sym(newmod, "script_update");
    if fn_version == null || fn_update == null {
        gd_print("asteroids: script is missing an entry point — keeping previous");
        return false;
    }
    if fn_version() != GAME_ABI_VERSION {
        gd_print("asteroids: script ABI version mismatch — keeping previous");
        return false;
    }
    void* rp = minc_sym(newmod, "script_reloaded");   // optional

    if s.mod.handle != null { minc_module_free(s.mod.handle); }
    s.mod.handle = newmod;
    s.mod.update = cast(ScriptHook, fn_update);
    if rp != null { s.mod.reloaded = cast(ScriptHook, rp); }
    else { s.mod.reloaded = null; }
    keep = true;

    if s.mod.reloaded != null {
        g_cur = s;
        ScriptCtx rc = { .api = &g_api, .world = &s.world, .dt = 0.0f, .input = s.input };
        s.mod.reloaded(&rc);
    }
    return true;
}

// Recompile and swap
void apply_reload(State* s) {
    bool was_loaded = s.mod.handle != null;
    i64 t0 = time_get_ticks_usec();
    if reload_script(s) && was_loaded {
        // show notification
        i64 tenths = (time_get_ticks_usec() - t0) / 100;   // 0.1 ms units
        string msg = format("script recompiled in {}.{} ms", tenths / 10, tenths % 10);
        defer free(msg);
        u8* cmsg = str_to_cstr(msg);
        defer free(cmsg);
        // gd_print require null-terminated string
        gd_print(cmsg);
        GdString gs;
        gd_string_new(&gs, cmsg);
        label_set_text(s.toast, &gs);
        gd_string_destroy(&gs);
        canvasitem_set_visible(s.toast, 1);
        s.toast_left = 2.5f;
    }
}

// Watch fired: reload only if the script content changed.
void check_reload(State* s) {
    if s.ctx == null || s.script_path == null { return; }
    str spath = str_from_cstr(s.script_path);
    FileStamp st = file_stamp(spath);
    if !st.ok || !file_stamp_changed(st, s.mod.stamp) { return; }
    s.mod.stamp = st;
    u64 h = hash_file(spath);
    if h == 0 || h == s.mod.src_hash { return; }
    s.mod.src_hash = h;
    apply_reload(s);
}

// check imported file metadata for changes
void check_closure(State* s) {
    for i32 i = 0; i < s.mod.cl_count; i++ {
        FileStamp st = file_stamp(str_from_cstr(s.mod.cl_path[i]));
        if st.ok && file_stamp_changed(st, s.mod.cl_stamp[i]) {
            s.mod.cl_stamp[i] = st;
            apply_reload(s);
            return;
        }
    }
}

// --- Godot callbacks --------------------------------------------------

void* ast_create(void* class_userdata) {
    var s = new(State);
    s.owner = gd_construct(class_userdata, cast(void*, s));
    return cast(void*, s.owner);
}

void ast_free(void* class_userdata, void* instance) {
    var s = cast(State*, instance);
    if s == null { return; }
    file_watch_close(&s.watch);
    for i32 i = 0; i < s.mod.cl_count; i++ { free(s.mod.cl_path[i]); }
    if s.mod.handle != null { minc_module_free(s.mod.handle); }
    if s.ctx != null { minc_destroy(s.ctx); }
    free(instance);
    return;
}

void ast_ready(void* instance, void* args, void* ret) {
    var s = cast(State*, instance);
    s.world.size_x = VIEW_X;
    s.world.size_y = VIEW_Y;

    // Scale the fixed playfield to the window, aspect kept (letterboxed).
    GdObject* win = node_get_window(s.owner);
    if win != null {
        GdVector2i logical = GdVector2i{ cast(i32, VIEW_X), cast(i32, VIEW_Y) };
        window_set_content_scale_size(win, &logical);
        window_set_content_scale_mode(win, 1);     // CONTENT_SCALE_MODE_CANVAS_ITEMS
        window_set_content_scale_aspect(win, 1);   // CONTENT_SCALE_ASPECT_KEEP
    }
    s.rng = 0x12345678;
    s.act_left = gd_intern("ui_left");
    s.act_right = gd_intern("ui_right");
    s.act_thrust = gd_intern("ui_up");
    s.act_fire = gd_intern("ui_select");
    build_api();

    // score/lives readout
    GdStringName* fsz = gd_intern("font_size");
    s.label = label_new();
    control_add_theme_font_size_override(s.label, fsz, 24);
    node_add_child(s.owner, s.label);

    // reload notice, hidden until a script recompile sets its text
    s.toast = label_new();
    control_add_theme_font_size_override(s.toast, fsz, 24);
    GdVector2 tpos = GdVector2{ VIEW_X - 360.0f, 8.0f };
    control_set_position(s.toast, &tpos);
    canvasitem_set_visible(s.toast, 0);
    node_add_child(s.owner, s.toast);

    if minc_abi_version() != MINC_ABI_VERSION {
        gd_print("asteroids: libminc ABI mismatch");
        return;
    }
    s.ctx = minc_create();
    if s.ctx == null { return; }

    s.script_path = globalize("res://asteroids/script.mc");

    check_reload(s);   // initial compile + load

    // event-driven reload: watch the script dir
    u8* dir = globalize("res://asteroids");
    s.watch = file_watch_dir(str_from_cstr(dir));
    free(dir);
    return;
}

void ast_process(void* instance, void* p_args, void* ret) {
    var s = cast(State*, instance);
    void** args = cast(void**, p_args);
    f64 delta = *(cast(f64*, *args));

    if !s.watch.ok || file_watch_poll(&s.watch) { check_reload(s); }
    check_closure(s);

    if s.toast_left > 0.0f {
        s.toast_left -= cast(f32, delta);
        if s.toast_left <= 0.0f { canvasitem_set_visible(s.toast, 0); }
    }

    s.input.turn = 0.0f;
    if input_is_action_pressed(s.act_left) != 0 { s.input.turn -= 1.0f; }
    if input_is_action_pressed(s.act_right) != 0 { s.input.turn += 1.0f; }
    s.input.thrust = input_is_action_pressed(s.act_thrust) != 0;
    s.input.fire = input_is_action_pressed(s.act_fire) != 0;

    if s.mod.update != null {
        g_cur = s;
        ScriptCtx c = {
            .api = &g_api,
            .world = &s.world,
            .dt = cast(f32, delta),
            .input = s.input
        };
        s.mod.update(&c);
    }

    if s.world.score != s.shown_score || s.world.lives != s.shown_lives {
        s.shown_score = s.world.score;
        s.shown_lives = s.world.lives;
        string msg = format("  SCORE {}   SHIPS {}", s.world.score, s.world.lives);
        defer free(msg);
        u8* cmsg = str_to_cstr(msg);
        defer free(cmsg);
        GdString gs;
        gd_string_new(&gs, cmsg);
        label_set_text(s.label, &gs);
        gd_string_destroy(&gs);
    }

    canvasitem_queue_redraw(s.owner);
    return;
}

// --- drawing ----------------------------------------------------------

GdColor COL_BG    = GdColor{ 0.02f, 0.02f, 0.04f, 1.0f };
GdColor COL_SHIP  = GdColor{ 0.9f, 0.95f, 1.0f, 1.0f };
GdColor COL_ROCK  = GdColor{ 0.75f, 0.8f, 0.85f, 1.0f };
GdColor COL_SHOT  = GdColor{ 1.0f, 0.9f, 0.4f, 1.0f };
GdColor COL_FLAME = GdColor{ 1.0f, 0.5f, 0.15f, 1.0f };

void draw_seg(GdObject* self, f32 ax, f32 ay, f32 bx, f32 by, GdColor* col) {
    GdVector2 a = GdVector2{ ax, ay };
    GdVector2 b = GdVector2{ bx, by };
    canvasitem_draw_line(self, &a, &b, col, 1.5, 1);
}

const i32 ROCK_SEGS = 11;

// Rocks are drawn from their seed: a jittered radius per vertex.
f32 rock_r(Rock* r, i32 i) {
    u32 h = r.seed * 2654435761 + cast(u32, i) * 2246822519;
    h = (h ^ (h >> 15)) * 0x9E3779B9;
    return r.radius * (0.72f + 0.28f * cast(f32, (h >> 8) & 0xFFFF) / 65535.0f);
}

void ast_draw(void* instance, void* args, void* ret) {
    var s = cast(State*, instance);
    GdObject* self = s.owner;
    World* w = &s.world;

    GdRect2 bg = GdRect2{ 0.0f, 0.0f, w.size_x, w.size_y };
    canvasitem_draw_rect(self, &bg, &COL_BG, 1, -1.0, 0);

    // rocks
    for i32 i = 0; i < MAX_ROCKS; i++ {
        Rock* r = &w.rocks[i];
        if !r.alive { continue; }
        f32 px = 0.0f;
        f32 py = 0.0f;
        for i32 k = 0; k <= ROCK_SEGS; k++ {
            f32 a = cast(f32, k % ROCK_SEGS) * (6.2831853f / cast(f32, ROCK_SEGS));
            f32 rad = rock_r(r, k % ROCK_SEGS);
            f32 x = r.pos.x + cosf(a) * rad;
            f32 y = r.pos.y + sinf(a) * rad;
            if k > 0 { draw_seg(self, px, py, x, y, &COL_ROCK); }
            px = x;
            py = y;
        }
    }

    // shots
    for i32 i = 0; i < MAX_SHOTS; i++ {
        Shot* sh = &w.shots[i];
        if !sh.alive { continue; }
        GdVector2 p = GdVector2{ sh.pos.x, sh.pos.y };
        canvasitem_draw_circle(self, &p, 2.2, &COL_SHOT, 1, -1.0, 1);
    }

    // ship: triangle from angle, blinks while invulnerable
    Ship* sp = &w.ship;
    if w.lives >= 0 {
        bool blink = sp.invuln > 0.0f && (cast(i32, sp.invuln * 8.0f) & 1) == 1;
        if !blink {
            f32 ca = cosf(sp.angle);
            f32 sa = sinf(sp.angle);
            // local points rotated by angle (0 = up)
            f32 nx = sp.pos.x + sa * 14.0f;          // nose
            f32 ny = sp.pos.y - ca * 14.0f;
            f32 lx = sp.pos.x - sa * 10.0f - ca * 8.0f;   // left wing
            f32 ly = sp.pos.y + ca * 10.0f - sa * 8.0f;
            f32 rx = sp.pos.x - sa * 10.0f + ca * 8.0f;   // right wing
            f32 ry = sp.pos.y + ca * 10.0f + sa * 8.0f;
            draw_seg(self, nx, ny, lx, ly, &COL_SHIP);
            draw_seg(self, nx, ny, rx, ry, &COL_SHIP);
            draw_seg(self, lx, ly, rx, ry, &COL_SHIP);
            if s.input.thrust {
                f32 tx = sp.pos.x - sa * 16.0f;
                f32 ty = sp.pos.y + ca * 16.0f;
                draw_seg(self, lx, ly, tx, ty, &COL_FLAME);
                draw_seg(self, rx, ry, tx, ty, &COL_FLAME);
            }
        }
    }
}

// --- registration -------------------------------------------------------

void gd_register() {
    i32 cls = gd_class("AsteroidsGame", "Node2D", ast_create, ast_free);
    gd_bind_virtual(cls, "_ready", ast_ready);
    gd_bind_virtual(cls, "_process", ast_process);
    gd_bind_virtual(cls, "_draw", ast_draw);
}
