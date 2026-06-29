// Feature tour: a MincFeatures node that exercises the whole binding surface in
// one place: core types, generated bindings, Variant, properties, signals,
// singletons, static and utility calls. Each step prints a `minc …:` line to
// stderr. It builds no visible scene, so it runs the same headless or in a
// window.
//
// For the minimal rendering example, see cube.mc.
//
// Build + run: ../build.sh features   (from the repo root, builds + launches)

import godot;

// Per-instance state.
struct FeatureState {
    GdObject* owner;
    i32 ticks;
    i64 value;            // backing store for the "value" property
    i32 signal_received;  // bumped by the on_value_changed handler
    i32 received_value;   // the int payload value_changed delivered
    i32 pair_sum;         // lo+hi from the 2-arg pair_set signal
}

// --- Registered method implementations (typed ptrcall) --------------------
@c_abi void mn_set_value(void* mud, void* instance, void* p_args, void* ret) {
    var inst = cast(FeatureState*, instance);
    var args = cast(void**, p_args);
    inst.value = *(cast(i64*, *args));
    return;
}

@c_abi void mn_get_value(void* mud, void* instance, void* p_args, void* ret) {
    var inst = cast(FeatureState*, instance);
    *(cast(i64*, ret)) = inst.value;
    return;
}

// Signal handler, connected to "value_changed".
@c_abi void mn_on_value_changed(void* mud, void* instance, void* p_args, void* ret) {
    var inst = cast(FeatureState*, instance);
    var args = cast(void**, p_args);
    inst.signal_received = inst.signal_received + 1;
    inst.received_value = cast(i32, *(cast(i64*, args[0])));
    return;
}

// Handler for the 2-arg "pair_set" signal.
@c_abi void mn_on_pair(void* mud, void* instance, void* p_args, void* ret) {
    var inst = cast(FeatureState*, instance);
    var args = cast(void**, p_args);
    i64 lo = *(cast(i64*, args[0]));
    i64 hi = *(cast(i64*, args[1]));
    inst.pair_sum = cast(i32, lo + hi);
    return;
}

// --- Class lifecycle ------------------------------------------------------
@c_abi void* features_create(void* class_userdata) {
    var inst = new(FeatureState);
    inst.owner = gd_construct(class_userdata, cast(void*, inst));
    return cast(void*, inst.owner);
}

@c_abi void features_free(void* class_userdata, void* instance) {
    if instance != null { free(instance); }
    return;
}

// --- Virtuals -------------------------------------------------------------
@c_abi void features_ready(void* instance, void* args, void* ret) {
    gd_puts("MincFeatures._ready ran (minc GDExtension)\n");
    var inst = cast(FeatureState*, instance);
    GdObject* self = inst.owner;

    // String: construct, read to utf8, destroy.
    GdString str;
    gd_string_new(&str, "minc-core-types-ok");
    u8[64] sb;
    i64 n = gd_string_to_cstr(&str, &sb[0], 64);
    gd_puts("minc core: ");
    if n > 0 { gd_write_stderr(cast(void*, &sb[0]), n); }
    gd_puts("\n");
    gd_string_destroy(&str);

    // Generated bindings: rename self, add a child, read the count back.
    GdString nm;
    gd_string_new(&nm, "MincRenamed");
    node_set_name(self, &nm);
    gd_string_destroy(&nm);

    GdObject* child = node_new();
    node_add_child(self, child);
    i64 count = node_get_child_count(self);
    gd_puts("minc node: child_count=");
    gd_write_dec(count);
    gd_puts("\n");

    // Query the registered property/method/signal via Object.has_method /
    // has_signal (StringName -> bool).
    GdStringName qm;
    gd_stringname_new(&qm, "set_value");
    u8 has_m = object_has_method(self, &qm);
    gd_stringname_destroy(&qm);
    GdStringName qs;
    gd_stringname_new(&qs, "value_changed");
    u8 has_s = object_has_signal(self, &qs);
    gd_stringname_destroy(&qs);
    gd_puts("minc reg: method=");
    gd_write_dec(has_m);
    gd_puts(" signal=");
    gd_write_dec(has_s);
    gd_puts("\n");

    // Variant: print through UtilityFunctions, and an int -> Variant -> int
    // conversion through Godot's typed constructors.
    gd_print("minc print: hello from minc via UtilityFunctions.print");
    GdVariant vbuf;
    gd_variant_int(&vbuf, 42);
    i64 got = gd_variant_to_int(&vbuf);
    gd_variant_destroy(&vbuf);
    gd_puts("minc variant: roundtrip got=");
    gd_write_dec(got);
    gd_puts("\n");

    // Set the "value" property through Godot's property system (Object.set
    // passes a Variant), which dispatches to the registered setter; then read
    // it back with Object.get.
    GdStringName psn;
    gd_stringname_new(&psn, "value");
    GdVariant vset;
    gd_variant_int(&vset, 7);
    object_set(self, &psn, &vset);
    gd_variant_destroy(&vset);
    GdVariant vget;
    object_get(self, &psn, &vget);
    i64 pgot = gd_variant_to_int(&vget);
    gd_variant_destroy(&vget);
    gd_stringname_destroy(&psn);
    gd_puts("minc property: set/get got=");
    gd_write_dec(pgot);
    gd_puts("\n");

    // Connect "value_changed" (1 int arg) to on_value_changed via a
    // Callable(self, "on_value_changed"), then emit it with the int 7. The
    // handler runs synchronously inside emit.
    GdStringName hsn;
    gd_stringname_new(&hsn, "on_value_changed");
    GdCallable callable;
    gd_callable(&callable, self, &hsn);
    GdStringName sigsn;
    gd_stringname_new(&sigsn, "value_changed");
    ignore object_connect(self, &sigsn, &callable, 0);
    GdVariant sigval;
    gd_variant_int(&sigval, 7);
    gd_emit_signal(self, "value_changed", &sigval, 1);
    gd_variant_destroy(&sigval);
    gd_callable_destroy(&callable);
    gd_stringname_destroy(&sigsn);
    gd_stringname_destroy(&hsn);
    gd_puts("minc signal: emit+connect received=");
    gd_write_dec(inst.signal_received);
    gd_puts(" value=");
    gd_write_dec(inst.received_value);
    gd_puts("\n");

    // Multi-arg signal: connect "pair_set" (2 int args) to on_pair, then emit
    // (3, 4); the handler sums them.
    GdStringName phsn;
    gd_stringname_new(&phsn, "on_pair");
    GdCallable pcallable;
    gd_callable(&pcallable, self, &phsn);
    GdStringName psigsn;
    gd_stringname_new(&psigsn, "pair_set");
    ignore object_connect(self, &psigsn, &pcallable, 0);
    GdVariant[2] pargs;
    gd_variant_int(&pargs[0], 3);
    gd_variant_int(&pargs[1], 4);
    gd_emit_signal(self, "pair_set", &pargs[0], 2);
    gd_variant_destroy(&pargs[0]);
    gd_variant_destroy(&pargs[1]);
    gd_callable_destroy(&pcallable);
    gd_stringname_destroy(&psigsn);
    gd_stringname_destroy(&phsn);
    gd_puts("minc multiarg: pair_set sum=");
    gd_write_dec(inst.pair_sum);
    gd_puts("\n");

    // Singletons: global engine objects fetched via global_get_singleton. The
    // wrapper takes no self (Time is the one instance) and caches it.
    i64 ms = time_get_ticks_msec();
    gd_puts("minc singleton: Time.get_ticks_msec ok=");
    gd_write_dec(cast(i64, ms >= 0));
    gd_puts("\n");

    // Static methods: bound like any other, but ptrcalled with no instance.
    GdString path;
    gd_string_new(&path, "res://project.godot");
    u8 exists = fileaccess_file_exists(&path);
    gd_string_destroy(&path);
    gd_puts("minc static: FileAccess.file_exists ok=");
    gd_write_dec(cast(i64, exists));
    gd_puts("\n");

    // Utility functions: free math/random functions via UtilityFunctions, the
    // gd_<name> wrappers. deg_to_rad(180) ~= pi.
    f64 rad = gd_deg_to_rad(180.0);
    gd_puts("minc utility: deg_to_rad(180) ok=");
    gd_write_dec(cast(i64, rad > 3.14 && rad < 3.15));
    gd_puts("\n");
    return;
}

@c_abi void features_process(void* instance, void* p_args, void* ret) {
    var inst = cast(FeatureState*, instance);
    var args = cast(void**, p_args);
    f64 delta = *(cast(f64*, *args));
    inst.ticks = inst.ticks + 1;

    if inst.ticks == 2 {
        gd_puts("minc process: tick=");
        gd_write_dec(inst.ticks);
        gd_puts(" delta_ok=");
        if delta > 0.0 { gd_puts("1"); } else { gd_puts("0"); }
        gd_puts("\n");
    }
    return;
}

// --- Registration hook (called by the core at SCENE init) -----------------
void gd_register() {
    i32 cls = gd_class("MincFeatures", "Node", features_create, features_free);
    gd_bind_virtual(cls, "_ready", features_ready);
    gd_bind_virtual(cls, "_process", features_process);
    gd_bind_method(cls, "set_value", mn_set_value, 0 - 1, 1, TYPE_INT);
    gd_bind_method(cls, "get_value", mn_get_value, TYPE_INT, 0);
    gd_bind_method(cls, "on_value_changed", mn_on_value_changed, 0 - 1, 1, TYPE_INT);
    gd_bind_method(cls, "on_pair", mn_on_pair, 0 - 1, 2, TYPE_INT, TYPE_INT);
    gd_add_property(cls, TYPE_INT, "value", "set_value", "get_value");
    gd_add_signal(cls, "value_changed", 1, TYPE_INT);
    gd_add_signal(cls, "pair_set", 2, TYPE_INT, TYPE_INT);
    return;
}
