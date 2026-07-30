// script.mc — asteroids game logic, hot-reloaded by the engine.
//
// Edit and save while the game runs: the engine recompiles this file and
// swaps it in without touching World.
//
// Keep this file stateless.

import game_abi;
import math;

const f32 SHIP_TURN   = 4.2f;     // rad/s
const f32 SHIP_ACCEL  = 320.0f;   // px/s^2
const f32 SHIP_DRAG   = 0.4f;     // fraction of velocity lost per second
const f32 SHIP_R      = 11.0f;    // collision radius

const f32 SHOT_SPEED  = 520.0f;
const f32 SHOT_LIFE   = 0.9f;     // seconds
const f32 FIRE_DELAY  = 0.22f;

const f32 ROCK_BIG    = 42.0f;
const f32 ROCK_MED    = 24.0f;
const f32 ROCK_SMALL  = 12.0f;


u32 script_abi_version() { return GAME_ABI_VERSION; }

void script_reloaded(ScriptCtx* ctx) {
    ctx.api.log("script: reloaded");
}

// Radius from size class
f32 rock_radius(RockId size) {
    if size == ROCK_BIG_ID { return ROCK_BIG; }
    if size == ROCK_MED_ID { return ROCK_MED; }
    return ROCK_SMALL;
}

// Wrap with a margin
f32 wrapf(f32 v, f32 max, f32 m) {
    if v < -m { return v + max + m * 2.0f; }
    if v > max + m { return v - max - m * 2.0f; }
    return v;
}

void wrap_pos(float2* p, World* w, f32 margin) {
    p.x = wrapf(p.x, w.size_x, margin);
    p.y = wrapf(p.y, w.size_y, margin);
}

void spawn_rock(ScriptCtx* ctx, float2 pos, RockId size) {
    World* w = ctx.world;
    for i32 i = 0; i < MAX_ROCKS; i++ {
        if !w.rocks[i].alive {
            f32 rad = ctx.api.rnd() * 6.2831853f;
            f32 speed = 40.0f + ctx.api.rnd() * 60.0f + cast(f32, size) * 40.0f;
            w.rocks[i] = {
                .pos = pos,
                .vel = { cosf(rad) * speed, sinf(rad) * speed },
                .radius = rock_radius(size),
                .size = size,
                .seed = cast(u32, ctx.api.rnd() * 65536.0f) + 1,
                .alive = true,
            };
            return;
        }
    }
}

// New wave: rocks enter from the playfield edges, away from the ship.
void spawn_wave(ScriptCtx* ctx) {
    World* w = ctx.world;
    w.wave++;
    i32 n = 2 + w.wave;
    if n > 8 { n = 8; }
    for i32 i = 0; i < n; i++ {
        float2 pos = { ctx.api.rnd() * w.size_x, 0.0f };
        if ctx.api.rnd() < 0.5f {
            pos = float2{ 0.0f, ctx.api.rnd() * w.size_y }; 
        }
        spawn_rock(ctx, pos, 0);
    }
}

void reset_ship(World* w) {
    w.ship = {
        .pos    = { w.size_x * 0.5f, w.size_y * 0.5f },
        .vel    = { 0.0f, 0.0f },
        .angle  = 0.0f,
        .invuln = 2.0f,
    };
}

void kill_rock(ScriptCtx* ctx, i32 i) {
    World* w = ctx.world;
    Rock* rock = &w.rocks[i];
    rock.alive = false;
    if rock.size == ROCK_BIG_ID {
        w.score += 20;
    }
    else if rock.size == ROCK_MED_ID {
        w.score += 50;
    }
    else {  // ROCK_SMALL_ID
        w.score += 100;
    }
    // big and medium rocks split in two
    if rock.size < ROCK_SMALL_ID {
        spawn_rock(ctx, rock.pos, rock.size + 1);
        spawn_rock(ctx, rock.pos, rock.size + 1);
    }
}

void ship_hit(ScriptCtx* ctx) {
    World* w = ctx.world;
    w.lives--;
    if w.lives < 0 {
        ctx.api.log("game over — restarting");
        w.score = 0;
        w.lives = 3;
        w.wave = 0;
        for i32 i = 0; i < MAX_ROCKS; i++ { w.rocks[i].alive = false; }
        for i32 i = 0; i < MAX_SHOTS; i++ { w.shots[i].alive = false; }
    }
    reset_ship(w);
}

void script_update(ScriptCtx* ctx) {
    World* w = ctx.world;
    f32 dt = ctx.dt;

    // first frame after engine start: no ship yet
    if w.lives == 0 && w.wave == 0 && w.score == 0 {
        w.lives = 3;
        reset_ship(w);
    }

    // --- ship ---
    Ship* ship = &w.ship;
    ship.angle += ctx.input.turn * SHIP_TURN * dt;
    float2 dir = { sinf(ship.angle), -cosf(ship.angle) };
    if ctx.input.thrust {
        ship.vel = ship.vel + dir * (SHIP_ACCEL * dt);
    }
    ship.vel = ship.vel * (1.0f - SHIP_DRAG * dt);
    ship.pos = ship.pos + ship.vel * dt;
    wrap_pos(&ship.pos, w, 14.0f);
    if ship.cooldown > 0.0f { ship.cooldown -= dt; }
    if ship.invuln > 0.0f { ship.invuln -= dt; }

    // --- fire ---
    if ctx.input.fire && ship.cooldown <= 0.0f {
        for i32 i = 0; i < MAX_SHOTS; i++ {
            if !w.shots[i].alive {
                w.shots[i] = {
                    .pos = ship.pos + dir * 14.0f,
                    .vel = ship.vel + dir * SHOT_SPEED,
                    .life = SHOT_LIFE,
                    .alive = true,
                };
                ship.cooldown = FIRE_DELAY;
                break;
            }
        }
    }

    // --- shots ---
    for i32 i = 0; i < MAX_SHOTS; i++ {
        Shot* shot = &w.shots[i];
        if !shot.alive { continue; }
        shot.life -= dt;
        if shot.life <= 0.0f {
            shot.alive = false; 
            continue;
        }
        shot.pos = shot.pos + shot.vel * dt;
        wrap_pos(&shot.pos, w, 3.0f);
    }

    // --- rocks + collisions ---
    i32 alive_rocks = 0;
    for i32 i = 0; i < MAX_ROCKS; i++ {
        Rock* rock = &w.rocks[i];
        if !rock.alive { continue; }
        alive_rocks++;
        rock.radius = rock_radius(rock.size);
        rock.pos = rock.pos + rock.vel * dt;
        wrap_pos(&rock.pos, w, rock.radius);

        for i32 j = 0; j < MAX_SHOTS; j++ {
            Shot* shot = &w.shots[j];
            if !shot.alive { continue; }
            float2 dv = shot.pos - rock.pos;
            if dv.x * dv.x + dv.y * dv.y < rock.radius * rock.radius {
                shot.alive = false;
                kill_rock(ctx, i);
                break;
            }
        }
        if !rock.alive { continue; }

        if ship.invuln <= 0.0f {
            // check ship - rock collision
            float2 dv = ship.pos - rock.pos;
            f32 rr = rock.radius + SHIP_R;
            if dv.x * dv.x + dv.y * dv.y < rr * rr {
                ship_hit(ctx);
            }
        }
    }

    if alive_rocks == 0 { spawn_wave(ctx); }
}
