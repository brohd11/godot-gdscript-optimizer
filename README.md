# GDScript Optimizer

Shared source transforms for Godot build tools. The first pass lowers `#! struct`
data classes to arrays, including constructors, type annotations, and field access.
It uses GDScriptParser and the shared dependency scanner through `utils_remote.gd`.
Tag discovery and indexing use `addons/addon_lib/tag_parser`; the old
`tag_registry.gd` remains a compatibility entry point.

```gdscript
const Optimizer = preload("res://addons/addon_lib/gdscript_optimizer/optimizer.gd")

var context = Optimizer.Context.new()
context.set_global_classes({"MyClass": "res://my_class.gd"})
var optimizer = Optimizer.new()
var sources = {"res://my_class.gd": "res://my_class.gd"}
var result = optimizer.prepare(sources, context, [Optimizer.StructPass])
if result.errors.is_empty():
    for key in optimizer.planned_files():
        var lines = Array(FileAccess.get_file_as_string(sources[key]).split("\n"))
        var edited = optimizer.apply(key, lines)
        # Commit edited.lines only after checking edited.errors.
```

Source keys are consumer-owned identities; values are existing, imported project
script paths. Supply the complete participating file set, including struct users.
References outside that set can be inspected for type lookup but are not rewritten.
This API does not import arbitrary external projects.

Context supplies global classes, removed global names, optional `map_path(key)` and
`scan_references(path)` callbacks, and the injected-preload comment header. Defaults
preserve resource paths and globals. Each prepare creates fresh passes and caches;
errors prevent replay, and a failed replay returns the original input lines.

A pass implements `prepare(sources, context)` returning `{errors, warnings}`, exposes
`plans` keyed by affected file identity, and implements `apply(key, lines)` returning
`{lines, errors}`. Passes run in the supplied order. Preparation sees original source;
consumers must preserve planned locations until replay, or treat conflicts as errors.
No writes, export lifecycle methods, or editor reporting belong in a pass.

Tests: `godot --headless --path . --script res://tests/gdscript_optimizer/run_headless.gd`.
