// build.mc — build the minc GDExtension examples and run a scene.
//
// Usage, from this folder:
//   minc run                 list the available examples
//   minc run cube            build all examples + run cube.tscn
//   minc run cube --no-run   compile only, don't launch Godot
//   minc build               compile only
//   minc clean               remove examples/bin + Godot's import cache
//
// Your example is examples/<name>.mc; it writes `import godot;` and
// defines gd_register(). It builds to the platform shared library
// matching examples/<name>.gdextension and runs examples/<name>.tscn.
//
// Engine: the first `minc run <example>` fetches a pinned,
// SHA-verified Godot 4.3 release into godot/ (kept across cleans;
// delete godot/ to force a re-fetch). Set GODOT to use an existing
// Godot 4.3 binary instead.
//
// The minc compiler is taken from MINC, then PATH, then this folder.
// Install minc from https://minc.dev.

@minc_min_version "0.9.14"

// Older minc ignores the tag above; this forces a clear error there.
when !defined(MINC_VERSION) || MINC_VERSION < 9014 {
    minc_0_9_14_or_newer_required please_update_minc;
}

import process;
import file;
import str;
import sha256;
import thread;

when os(windows) {
    str EXE_SUFFIX = ".exe";
    str OS_TARGET = "windows";
    str LIB_PREFIX = "";
    str LIB_SUFFIX = ".dll";
    str LIBMINC = "libminc.dll";
}
when os(linux) {
    str EXE_SUFFIX = "";
    str OS_TARGET = "linux";
    str LIB_PREFIX = "lib";
    str LIB_SUFFIX = ".so";
    str LIBMINC = "libminc.so";
}
when os(macos) {
    str EXE_SUFFIX = "";
    str OS_TARGET = "macos";
    str LIB_PREFIX = "lib";
    str LIB_SUFFIX = ".dylib";
    str LIBMINC = "libminc.dylib";
}

// Pinned upstream Godot release. To rotate: bump the version + SHAs,
// delete godot/, run once. An unpinned SHA ("<set-on-first-publish>")
// warns and prints the actual hash to paste in.
str GODOT_VERSION = "4.3-stable";
str GODOT_WIN_SHA256 = "<set-on-first-publish>";
str GODOT_MAC_SHA256 = "<set-on-first-publish>";
str GODOT_LINUX_SHA256 = "7de56444b130b10af84d19c7e0cf63cf9e9937ee4ba94364c3b7dd114253ca21";

void die(str s) {
    eprint("{}\n", s);
    exit(1);
    return;
}

// "<dir>/<name><ext>", without leaking the joined name.
string join_named(str dir, str name, str ext) {
    string base = str_concat(name, ext);
    defer free(base);
    return path_join(dir, base);
}

// MINC first (an install dir or the binary itself), then a sibling
// compiler-repo build (this tree doubles as the dev source), then
// PATH, then a binary sitting next to this script.
string find_minc() {
    string env = env_get("MINC");
    if env.len > 0 {
        if path_is_dir(env) {
            string cand = join_named(env, "minc", EXE_SUFFIX);
            free(env);
            return cand;
        }
        return env;
    }
    free(env);

    string dev = str_concat("../build/minc", EXE_SUFFIX);
    if path_exists(dev) { return dev; }
    free(dev);

    string onpath = path_which("minc");
    if onpath.len > 0 { return onpath; }
    free(onpath);

    string local = str_concat("./minc", EXE_SUFFIX);
    if path_exists(local) { return local; }
    free(local);

    return string{};
}

// --- Godot engine acquisition -----------------------------------------

// Fetch `url` to `dest`. curl ships with Windows 10+, macOS and most
// Linux distros; on Windows a curl-less setup falls back to
// PowerShell (TLS 1.2 forced — Windows PowerShell otherwise offers
// TLS 1.0, which GitHub's CDN rejects).
bool download(str url, str dest) {
    string curl = path_which("curl");
    if curl.len > 0 {
        ProcCmd c = { .args = {
            curl, "-fsSL", "--retry", "4", "--retry-delay", "1", "-o", dest, url
        } };
        ProcResult r = proc_run(&c);
        bool ok = r.spawned && r.exit_code == 0;
        proc_result_free(&r);
        free(curl);
        return ok && path_exists(dest);
    }
    free(curl);
    when os(windows) {
        string cmd = format("[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-WebRequest -UseBasicParsing -Uri '{}' -OutFile '{}'",
                            url, dest);
        defer free(cmd);
        ProcCmd c = { .args = { "powershell", "-NoProfile", "-Command", cmd } };
        ProcResult r = proc_run(&c);
        bool ok = r.spawned && r.exit_code == 0;
        proc_result_free(&r);
        return ok && path_exists(dest);
    }
    return false;
}

// Lowercase hex SHA-256 of a file; empty on read failure. Caller frees.
string file_sha256_hex(str path) {
    string none = { .data = null, .len = 0 };
    FileData fd = file_read(path);
    if fd.data == null { return none; }
    defer free(fd.data);
    noinit u8[32] digest;
    sha256_oneshot(fd.data, cast(u64, fd.len), &digest[0]);
    str hexdigits = "0123456789abcdef";
    u8* hex = alloc<u8>(64);
    for i32 i = 0; i < 32; i++ {
        hex[i * 2] = hexdigits.data[digest[i] >> 4];
        hex[i * 2 + 1] = hexdigits.data[digest[i] & 15];
    }
    string s = { .data = hex, .len = 64 };
    return s;
}

// Download + verify the pinned archive to godot/_godot.zip. True when
// the bytes match the pin. GitHub's CDN occasionally resets the first
// TLS handshake, and curl's --retry does not cover connection resets
// — hence the outer attempts loop.
bool fetch_godot_zip(str url, str pin) {
    ignore dir_create("godot");
    str zip = "godot/_godot.zip";
    print("downloading {}\n", url);
    bool got = false;
    for i32 attempt = 1; attempt <= 4 && !got; attempt++ {
        if attempt > 1 {
            print("  download failed (attempt {}/4), retrying...\n", attempt - 1);
            thread_sleep(300 * attempt);
        }
        ignore file_remove(zip);
        got = download(url, zip);
    }
    if !got {
        print("download failed — check your connection, or set GODOT to an\n"
              "existing Godot 4.3 binary.\n");
        return false;
    }
    string hex = file_sha256_hex(zip);
    defer free(hex);
    if str_equal(pin, "<set-on-first-publish>") {
        print("WARNING: Godot SHA-256 not pinned. Got: {}\n"
              "Paste it into build.mc's GODOT_*_SHA256 to enable verification.\n", hex);
        return true;
    }
    if !str_equal(hex, pin) {
        print("Godot download SHA-256 mismatch. Expected {}, got {}.\n"
              "Refusing to proceed.\n", pin, hex);
        ignore file_remove(zip);
        return false;
    }
    return true;
}

// The binary inside a completed godot/ download, or empty.
string local_godot() {
    when os(windows) {
        // The zip holds Godot_v<ver>_win64.exe and a *_console.exe
        // variant; prefer the GUI exe.
        DirList l = dir_list("godot", ".exe", false);
        defer dir_list_free(&l);
        for i32 i = 0; i < l.count; i++ {
            if str_contains(l.items[i], "_console") { continue; }
            return path_join("godot", l.items[i]);
        }
        return string{};
    }
    when os(macos) {
        str app = "godot/Godot.app/Contents/MacOS/Godot";
        if path_exists(app) { return string(app); }
        return string{};
    }
    when os(linux) {
        string bin = format("godot/Godot_v{}_linux.x86_64", GODOT_VERSION);
        if path_exists(bin) { return bin; }
        free(bin);
        return string{};
    }
}

// Fetch the pinned release into godot/ and unpack it.
bool fetch_godot() {
    print("Godot engine not found — fetching Godot {} into godot/ ...\n", GODOT_VERSION);
    str zip = "godot/_godot.zip";
    bool ok = false;
    when os(windows) {
        string url = format("https://github.com/godotengine/godot/releases/download/{}/Godot_v{}_win64.exe.zip",
                            GODOT_VERSION, GODOT_VERSION);
        defer free(url);
        if !fetch_godot_zip(url, GODOT_WIN_SHA256) { return false; }
        // Expand-Archive ships with PowerShell; tar.exe on older
        // setups may be GNU tar, which cannot read zip.
        ProcCmd c = { .args = {
            "powershell", "-NoProfile", "-Command",
            "Expand-Archive -LiteralPath 'godot/_godot.zip' -DestinationPath 'godot' -Force"
        } };
        ProcResult r = proc_run(&c);
        ok = r.spawned && r.exit_code == 0;
        proc_result_free(&r);
    }
    when os(macos) || os(linux) {
        string url = string{};
        when os(macos) {
            url = format("https://github.com/godotengine/godot/releases/download/{}/Godot_v{}_macos.universal.zip",
                         GODOT_VERSION, GODOT_VERSION);
        }
        when os(linux) {
            url = format("https://github.com/godotengine/godot/releases/download/{}/Godot_v{}_linux.x86_64.zip",
                         GODOT_VERSION, GODOT_VERSION);
        }
        defer free(url);
        str pin = GODOT_MAC_SHA256;
        when os(linux) { pin = GODOT_LINUX_SHA256; }
        if !fetch_godot_zip(url, pin) { return false; }
        ProcCmd c = { .args = { "unzip", "-q", "-o", zip, "-d", "godot" }, .capture = true };
        ProcResult r = proc_run(&c);
        ok = r.spawned && r.exit_code == 0;
        proc_result_free(&r);
    }
    ignore file_remove(zip);
    if !ok {
        print("could not unpack the Godot archive.\n");
        return false;
    }
    string bin = local_godot();
    defer free(bin);
    if bin.len == 0 {
        print("unexpected archive layout — no Godot binary found in godot/.\n");
        return false;
    }
    when os(linux) {
        // unzip may drop the exec bit.
        ProcCmd c = { .args = { "chmod", "+x", bin }, .capture = true };
        ProcResult r = proc_run(&c);
        proc_result_free(&r);
    }
    print("OK — Godot {} installed at {}\n", GODOT_VERSION, bin);
    return true;
}

// The engine binary: GODOT, then the local godot/ download, then
// PATH. Nothing found → fetch the pinned release. Caller frees.
string find_godot() {
    string env = env_get("GODOT");
    if env.len > 0 {
        if path_exists(env) { return env; }
    }
    free(env);

    string local = local_godot();
    if local.len > 0 { return local; }
    free(local);

    string onpath = path_which("godot");
    if onpath.len > 0 { return onpath; }
    free(onpath);

    if !fetch_godot() { return string{}; }
    return local_godot();
}

// --- Build --------------------------------------------------------------

// Build every example so all of the project's .gdextensions load
// cleanly; a library that fails to load silently drops its class from
// the scene. minc runs from the repo root so `import godot;` resolves
// to lib/godot.mc.
void build_examples(str cc) {
    ignore dir_create("examples/bin");
    DirList l = dir_list("examples", ".mc", false);
    defer dir_list_free(&l);
    for i32 i = 0; i < l.count; i++ {
        str name = path_stem(l.items[i]);
        string src = path_join("examples", l.items[i]);
        defer free(src);
        string lib = format("examples/bin/{}{}{}", LIB_PREFIX, name, LIB_SUFFIX);
        defer free(lib);
        print(":: building {} -> {}\n", src, lib);
        ProcCmd c = { .args = { cc, src, "--shared", "--target", OS_TARGET, "-o", lib } };
        ProcResult r = proc_run(&c);
        i32 rc = r.exit_code;
        proc_result_free(&r);
        if rc != 0 || !path_exists(lib) {
            eprint("compile failed: {}\n", src);
            exit(1);
        }
    }
    return;
}

// The asteroids example embeds the minc compiler: stage libminc next
// to the extension libraries (searched next to the compiler, then
// ../build/), plus the minc stdlib as bin/lib/ so runtime-compiled
// scripts can `import math;` (libminc anchors imports on its own
// directory).
void stage_libminc(str cc) {
    str cc_dir = path_dirname(cc);
    string dst = path_join("examples/bin", LIBMINC);
    defer free(dst);
    bool have = false;
    string lsrc = path_join(cc_dir, LIBMINC);
    if path_exists(lsrc) { have = file_copy(lsrc, dst); }
    free(lsrc);
    if !have {
        string alt = str_concat("../build/", LIBMINC);
        if path_exists(alt) { have = file_copy(alt, dst); }
        free(alt);
    }
    if !have && !path_exists(dst) {
        print("warning: {} not found next to minc — the asteroids extension\n"
              "will fail to load\n", LIBMINC);
    }

    string libdir = path_join(cc_dir, "lib");
    if !path_is_dir(libdir) {
        free(libdir);
        libdir = string("../lib");
    }
    if path_is_dir(libdir) {
        ignore dir_create("examples/bin/lib");
        DirList l = dir_list(libdir, ".mc", false);
        defer dir_list_free(&l);
        for i32 i = 0; i < l.count; i++ {
            string s = path_join(libdir, l.items[i]);
            defer free(s);
            string d = path_join("examples/bin/lib", l.items[i]);
            defer free(d);
            ignore file_copy(s, d);
        }
    }
    free(libdir);
    return;
}

// --- Run ----------------------------------------------------------------

// Editor import so Godot writes .godot/extension_list.cfg — the
// extensions load on run only if listed there. Re-import when any
// .gdextension is missing from the list: a stale one (extension added
// later, or its library failed to load during a prior import)
// silently drops the class from the scene ("Cannot get class ...",
// placeholder node).
void ensure_import(str godot) {
    bool need = false;
    string cfg = file_read_str("examples/.godot/extension_list.cfg");
    defer free(cfg);
    if cfg.len == 0 { need = true; }
    DirList l = dir_list("examples", ".gdextension", false);
    defer dir_list_free(&l);
    for i32 i = 0; i < l.count && !need; i++ {
        string want = str_concat("res://", l.items[i]);
        defer free(want);
        if str_find(cfg, want) < 0 { need = true; }
    }
    if !need { return; }
    print(":: importing project\n");
    ProcCmd c = { .args = {
        godot, "--headless", "--editor", "--path", "examples", "--quit-after", "300"
    }, .capture = true };
    ProcResult r = proc_run(&c);
    proc_result_free(&r);
    return;
}

i32 run_scene(str godot, str name) {
    string scene = format("res://{}.tscn", name);
    defer free(scene);
    print(":: running {} (close the window to quit)\n", scene);
    ProcCmd c = { .args = { godot, "--path", "examples", scene } };
    ProcResult r = proc_run(&c);
    i32 rc = r.exit_code;
    proc_result_free(&r);
    return rc;
}

void list_examples() {
    DirList l = dir_list("examples", ".mc", false);
    defer dir_list_free(&l);
    for i32 i = 0; i < l.count; i++ {
        print("  {}\n", path_stem(l.items[i]));
    }
    return;
}

void usage() {
    print("usage: minc <run|build|clean> [<example>] [--no-run]\n"
          "  minc run <example>    build all examples + run <example>.tscn\n"
          "  minc build            compile only, don't launch Godot\n"
          "  minc clean            remove examples/bin + Godot's import cache\n"
          "\n"
          "Available examples:\n");
    list_examples();
    print("\ne.g.  minc run cube\n");
    return;
}

i32 main() {
    i32 argc = get_argc();
    str verb = "run";
    str target = "";
    bool no_run = false;

    for i32 i = 1; i < argc; i++ {
        str a = str_from_cstr(get_arg(i));
        if str_equal(a, "--no-run") { no_run = true; }
        else if i == 1 { verb = a; }
        else if target.len == 0 { target = a; }
    }

    if str_equal(verb, "clean") {
        ignore dir_remove("examples/bin");
        ignore dir_remove("examples/.godot");
        print("clean. (godot/ kept — delete it to force an engine re-fetch.)\n");
        return 0;
    }
    if !str_equal(verb, "run") && !str_equal(verb, "build") {
        usage();
        return 1;
    }

    string minc = find_minc();
    defer free(minc);
    if minc.len == 0 {
        print("\nminc compiler not found.\n"
              "Install it:  powershell -c \"irm minc.dev/install.ps1 | iex\"\n"
              "or set MINC (see install_minc.md).\n");
        die("See README.md (Quickstart) and LICENSE.md.");
    }

    if !path_exists("lib/godot.mc") {
        die("missing lib/godot.mc — dist is incomplete");
    }

    if str_equal(verb, "run") && target.len == 0 {
        usage();
        return 0;
    }

    // `cube`, `cube.mc`, and `examples/cube.mc` all name the same example.
    target = path_stem(target);
    if target.len > 0 {
        string src = join_named("examples", target, ".mc");
        defer free(src);
        if !path_exists(src) {
            eprint("no examples/{}.mc\n", target);
            exit(1);
        }
        string gd = join_named("examples", target, ".gdextension");
        defer free(gd);
        if !path_exists(gd) {
            eprint("no examples/{}.gdextension\n", target);
            exit(1);
        }
    }

    build_examples(minc);
    stage_libminc(minc);

    if str_equal(verb, "build") || no_run || target.len == 0 {
        print(":: built (skipping run)\n");
        return 0;
    }

    string godot = find_godot();
    defer free(godot);
    if godot.len == 0 {
        print("\nGodot engine not found.\n"
              "Set GODOT to an existing Godot 4.3 binary, put godot on PATH,\n");
        die("or re-run with a network connection to fetch the pinned release.");
    }
    ensure_import(godot);
    return run_scene(godot, target);
}
