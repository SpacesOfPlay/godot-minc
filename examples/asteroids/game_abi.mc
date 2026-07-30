// game_abi.mc — the engine <-> script contract for the asteroids example.
//

const u32 GAME_ABI_VERSION = 3;

const i32 MAX_ROCKS = 64;
const i32 MAX_SHOTS = 32;

type RockId = i32;
const RockId ROCK_BIG_ID   = 0;
const RockId ROCK_MED_ID   = 1;
const RockId ROCK_SMALL_ID = 2;

struct Ship {
    float2 pos;
    float2 vel;
    f32    angle;      // radians; 0 = pointing up (-y)
    f32    cooldown;   // seconds until the next shot
    f32    invuln;     // seconds of spawn protection left
}

struct Rock {
    float2 pos;
    float2 vel;
    f32    radius;
    RockId size;       // big, medium, small
    u32    seed;       // shape seed; the engine draws from it
    bool   alive;
}

struct Shot {
    float2 pos;
    float2 vel;
    f32    life;       // seconds left
    bool   alive;
}

// Owned by the engine; persists across script reloads.
struct World {
    Ship            ship;
    Rock[MAX_ROCKS] rocks;
    Shot[MAX_SHOTS] shots;
    i32 score;
    i32 lives;
    i32 wave;
    f32 size_x;        // playfield size, set by the engine
    f32 size_y;
    // Script-private heap block, layout unknown to the engine. Survives
    // reloads because the root lives here. Rules: allocate via api.alloc
    // / api.free (the builtin alloc() may die with the module), no
    // pointers into the script image (literals, fn ptrs), stamp the
    // block with a magic word so a layout edit re-inits instead of
    // misreading old bytes. See apps/hotreload for the pattern.
    void* script_state;
}

struct InputState {
    f32  turn;         // -1 left .. +1 right
    bool thrust;
    bool fire;
}

// Engine services handed to the script. alloc/free come from the
// engine image, which never unloads — allocate script_state (and
// anything it points at) through them, never the builtin alloc().
struct HostApi {
    u32 abi_version;
    fn(u8*): void  log;
    fn(): f32      rnd;    // uniform [0,1)
    fn(i64): void* alloc;
    fn(void*): void free;
}

struct ScriptCtx {
    HostApi*   api;
    World*     world;
    f32        dt;
    InputState input;
}

// Script module entry points, resolved by name after a reload.
type ScriptHook    = fn(ScriptCtx*): void;   // script_update, script_reloaded
type ScriptVersion = fn(): u32;              // script_abi_version
