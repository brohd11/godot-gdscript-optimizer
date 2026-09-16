# GDScript Optimizer

Shared source transforms for Godot build tools. `StructPass` lowers `#! struct`
data classes to arrays. `InlinePass` expands supported tagged static calls.
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
aggregates these diagnostics on successful replay. Passes run in the supplied order. With InlinePass selected, preparation stages preceding transforms in memory. Inline
definitions and cross-file type resolution see the same post-struct snapshots.
Consumers must preserve planned locations until replay, or treat conflicts as errors.
No writes, export lifecycle methods, or editor reporting belong in a pass.

## Optional struct optimizations

```gdscript
context.scalar_replacement = true
context.struct_read_types = Optimizer.Context.StructReadTypes.TYPED_LOCALS
# Alternatives: OFF (default), AS_CASTS.
```

These settings extend `StructPass`; neither changes default output. Scalar replacement
plans against original bindings before lowering and inlining. It eliminates direct local
struct constructors only when all uses are field accesses and every field has a proven
built-in value type (explicit or `:=`). It supports branches, loops, field assignments,
compound updates, and value-component writes. Constructor arguments evaluate once in order
before parameter conversions. Field initialization and conversion remain typed.

Reference/dynamic fields, aliases, reassignment, whole-value uses, captures, coroutines,
multiline constructors, and unresolved/effectful defaults stay in the existing Array form.
Supported defaults are literals and built-in value constructors with immutable inputs.
Scalarization after inline expansion is deferred.

For remaining field reads, `TYPED_LOCALS` inserts typed captures only at supported statement
sites with safe evaluation order. It skips conditional/multiline evaluation, mixed calls,
complex receivers, and writes. `AS_CASTS` wraps reads in `(receiver[S.FIELD] as T)` without
moving them; it skips writes, multiline statements, and inline lambdas/semicolon statements.
Both use the same built-in value types as the inliner. No repeated-read caching is performed.

Stats are `scalar_structs`, `scalar_accesses`, `scalar_skipped`, `struct_typed_captures`,
`struct_read_casts`, and `struct_reads_skipped`. They count source sites, not runtime work.
Skipped scalar candidates and unsafe capture sites produce diagnostic reasons. Consumers
must benchmark their workloads: typed casts/captures can cost more than they save.

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

The template path supports explicit built-in value types, Array/Dictionary (including
typed collections), RefCounted, and typed RefCounted-derived scripts. Tagged structs
work as objects with inline alone and as arrays with StructPass followed by InlinePass.
Value types include bool, int, float, String, StringName, NodePath, Vector2/3/4 and
integer variants, Rect2/Rect2i, Transform2D/3D, Plane, Quaternion, AABB, Basis,
Projection, Color, and RID. Node/raw Object and packed-array extensions are deferred.

Preflight records parameter token slots, reference counts, rebinding, field/index
writes, and calls. Bodies may declare typed/inferred locals, assign locals/parameters
or their fields, and finish with a return or an exhaustive terminal if/elif/else tree.
Nested terminal branches are supported; every statement must occupy one line.
Immutable constants and script/type aliases retain their defining scope.

Replay chooses bindings separately for each parameter:

- Matching typed locals and cheap literals can substitute directly into token slots.
- Calls, properties and indexed arguments are evaluated once in argument order.
  Repeated member/index reads therefore never duplicate expensive lookup work.
- Reassigned parameters and mutated value-type arguments get typed local copies.
  Arrays/dictionaries keep shared mutation; rebinding stays local to the call.
- Script objects retain a strong local parameter reference, including unused parameters.
  This preserves accessors, reference ownership and destructor timing.
- Numeric conversions retain typed bindings. Effectful unused arguments still execute.

Expanded calls must be the whole initializer of a local declaration, assignment to a
simple local/parameter, or return. Argument/body locals live in a generated block.
A typed result crosses that block through a temporary Variant, is cast back to retain
`:=` inference, and the bridge is cleared after assignment. Imported locals therefore
do not extend reference lifetimes to the end of the caller.

Omitted defaults support literals/null, value constructors with constant inputs, and
resolvable immutable value constants. Mutable collection or executable defaults leave
the omitted-argument call unchanged; explicitly supplying that argument remains eligible.

Calls use a script constant/global class, or a direct call inside another static
function in the same script. Original definitions remain intact. Variant declarations,
loops, arbitrary early returns, lambdas/await in imported bodies, mutable external
bindings, and nested inlining remain unsupported. Ambiguous/unsupported sites stay
unchanged with diagnostics. No expansion is hoisted from a larger expression.
A single-iteration loop plus result/break for general early returns is a follow-up
experiment; its control-flow cost needs a separate benchmark.

Replay stats expose `inline_calls`, `inline_skipped`, `inline_direct_calls`,
`inline_expanded_calls`, `inline_substituted_args`, `inline_captured_args`, and
`inline_repeated_access_captures`. Counts describe source sites, not runtime invocations.
Tagging is opt-in: removal of call overhead does not guarantee a speedup for every body.

Tests: `godot --headless --path . --script res://tests/gdscript_optimizer/run_headless.gd`.
