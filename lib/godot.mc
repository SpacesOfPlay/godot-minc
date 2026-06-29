// godot — main module for the minc GDExtension bindings.
//
// User code does `import godot;`, then defines gd_register() to register its
// classes (gd_class / gd_bind_virtual / gd_bind_method / gd_add_property /
// gd_add_signal). This pulls in the whole binding surface:
//   godot_core      the GDExtension entry point + runtime (ptrcall, String,
//                   StringName, Variant, registration API)
//   godot_enums     Godot global enums (Variant.Type, PropertyUsageFlags, …)
//   godot_classes   engine class bindings (node3d_*, camera3d_*, <class>_new)
//   godot_utility   utility-function wrappers (gd_sin, gd_lerp, gd_randf, …)
//
// godot_classes / godot_utility are generated from the Godot API spec; see
// bindgen/README.md to extend the bound surface.

import godot_core;
import godot_enums;
import godot_classes;
import godot_utility;
