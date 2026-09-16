# GDScript Optimizer

Shared source transforms for Godot build tools. `StructPass` lowers `#! struct`
data classes to arrays. `InlinePass` expands supported tagged static arithmetic calls.
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
`{lines, errors}` with optional `warnings` and additive integer `stats`. The optimizer
aggregates these diagnostics on successful replay. Passes run in the supplied order. Preparation sees original source;
consumers must preserve planned locations until replay, or treat conflicts as errors.
No writes, export lifecycle methods, or editor reporting belong in a pass.

## Static function inlining

```gdscript
#! inline
static func affine(value:int, scale:int) -> int:
    return value * scale + value - 3
```

Select `[Optimizer.InlinePass]`, or `[Optimizer.StructPass, Optimizer.InlinePass]`
for both. The default remains `[Optimizer.StructPass]`. Inline replay resolves calls
against its input buffer, including line changes made by the struct pass.

Preflight assesses each tagged function once; replay chooses one of two paths.
The direct path retains the numeric arithmetic grammar (`+ - * / %`, parentheses,
unary `+ -`) and substitutes matching numeric literals or statically typed locals.
It emits no argument temporaries.

The expanded path supports explicit built-in value parameter/return types, local
initializers (`var` with a type or `:=`, and `const`), assignments to parameters or
locals, and one final return. Expressions may use resolved built-in constructors,
constants, functions, and value methods. Each statement must occupy one line.
Supported types are bool, int, float, String, StringName, NodePath, Vector2/3/4 and
integer variants, Rect2/Rect2i, Transform2D/3D, Plane, Quaternion, AABB, Basis,
Projection, Color, and RID.

Expanded calls must be the entire expression in a local declaration, assignment to
a simple local/parameter, or return. Argument expressions can include calls and
property reads with statically resolved matching value types. Numeric int/float
conversions are supported. Every argument, including unused ones, is bound once in
order to a fresh typed local. Body parameters/locals are renamed; the final value
is captured with the declared return type before completing the caller statement.
For example, a helper using `var scaled := value * scale` and then returning
`scaled.length_squared()` can accept a Vector2 expression and a float argument.

Calls use a script constant/global class, or a direct call inside another static
function in the same script. Original function definitions remain intact.
Collections, objects, Variant declarations, defaults, branches, loops, early
returns, lambdas, await, script-member references in imported bodies, and nested
inlining remain unsupported. Ambiguous names or unsupported sites stay unchanged
with diagnostics. No expansion is hoisted out of a larger expression.

Replay stats expose `inline_calls`, `inline_skipped`, `inline_direct_calls`, and
`inline_expanded_calls`; counts describe source sites, not runtime invocations.

Tests: `godot --headless --path . --script res://tests/gdscript_optimizer/run_headless.gd`.
