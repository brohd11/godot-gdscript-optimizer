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
context.scalar_replacement_allow_ref_counted = false
context.struct_read_types_allow_ref_counted = false
```

These settings extend `StructPass`; neither changes default output. Scalar replacement
plans against original bindings before lowering and inlining. It eliminates direct local
struct constructors only when all uses are field accesses and every field has a proven
built-in value type (explicit or `:=`). It supports branches, loops, field assignments,
compound updates, and value-component writes. Constructor arguments evaluate once in order
before parameter conversions. Field initialization and conversion remain typed.

By default, reference/dynamic fields, aliases, reassignment, whole-value uses, captures, coroutines,
multiline constructors, and unresolved/effectful defaults stay in the existing Array form.
Supported defaults are literals and built-in value constructors with immutable inputs.
Scalarization after inline expansion is deferred.

For remaining field reads, `TYPED_LOCALS` inserts typed captures only at supported statement
sites with safe evaluation order. It skips conditional/multiline evaluation, mixed calls,
complex receivers, and writes. `AS_CASTS` wraps reads in `(receiver[S.FIELD] as T)` without
moving them; it skips writes, multiline statements, and inline lambdas/semicolon statements.
By default both use the same built-in value types as the inliner. No repeated-read caching is performed.

`scalar_replacement_allow_ref_counted` and `struct_read_types_allow_ref_counted`
independently admit known Object/Node/RefCounted and script types, collections, packed
arrays, Callable, Signal, and nested structs in their respective optimization.
This opt-in can prolong reference lifetimes and add runtime checks on freed objects.
Escape/evaluation-order checks and the inliner's type rules remain unchanged. Scalar
initializers additionally accept null, literal collections, and empty built-in constructors;
mutable defaults are created per instance. Effectful or incompatible defaults still skip.
Cross-file type names use dependency aliases and output-path mapping; nested structs emit
Array. Surviving collection reads use Array/Dictionary because lowering can erase element
metadata; scalar declarations preserve typed collections. Unknown types are skipped.

`Optimizer.Config.from_file(path = "")` loads one YAML mapping using the required YAMLParser dependency,
returning `{options, errors}`. `from_dictionary(data)` validates an in-memory mapping.
Export defaults enable structs, inline_functions, scalar_replacement, and typed_locals;
All reference and Variant opt-ins stay false. The old `allow_ref_counted` key is rejected;
replace it with the two struct flags above. Missing keys inherit defaults, and invalid/unknown options
produce errors with no usable options. `struct_read_types` accepts off, typed_locals,
or as_casts and normalizes to the Context enum. Context and prepare defaults are unchanged;
other hosts must explicitly select these export defaults.

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
The direct path supports a single returned expression, including parenthesized multiline
returns. It accepts arithmetic (`+ - * / %`, unary `+ -`), comparisons, `and/or/not`,
literals, parameters, and String `begins_with`, `ends_with`, `contains`, and `is_empty`.
It substitutes matching literals or statically typed locals, retaining return types,
precedence, and short-circuiting. Direct calls may appear in `if`, `elif`, `while`, and
larger expressions. It emits no argument temporaries and skips omitted arguments.

`context.inline_functions_allow_ref_counted = true` permits direct reference types,
including Object/Node, containers and script classes, with member/index reads and method
calls. It removes parameter lifetime protection and may change aliasing behavior.
`context.inline_functions_allow_variants = true` permits explicit/implicit Variant
signatures and Variant locals passed to typed parameters. Substitution is unchecked:
parameter/return conversions and checks can disappear, changing results or errors.
Unknown runtime values may themselves contain references; statically known reference
types still require the reference flag. Both flags default to false and affect only
direct substitution. Calls, properties, and indexed expressions supplied as arguments
require the helper’s `substitute` tag; the type flags alone do not permit them. The same flag names are YAML keys.

The template path supports explicit built-in value types, Array/Dictionary (including
typed collections), RefCounted, and typed RefCounted-derived scripts. Tagged structs
work as objects with inline alone and as arrays with StructPass followed by InlinePass.
Value types include bool, int, float, String, StringName, NodePath, Vector2/3/4 and
integer variants, Rect2/Rect2i, Transform2D/3D, Plane, Quaternion, AABB, Basis,
Projection, Color, and RID. Node/raw Object and packed-array extensions are deferred.

Preflight records parameter token slots, reference counts, rebinding, field/index
writes, and calls. Bodies may declare typed/inferred locals, assign locals/parameters
or their fields, and use nested if/elif/else branches. Value-returning helpers must
finish with a return or an exhaustive terminal return tree. Explicit `-> void` helpers allow early bare returns,
`pass`, and normal fallthrough. Every statement must occupy one line.
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

Only void bodies use a generated `for <unique_name> in 1:` loop; bare returns become
breaks. These helpers expand at standalone call statements without a result or bridge.
Value-returning guard-clause helpers remain calls: the benchmark showed little gain
from the result/bridge wrapper, so that expansion is deliberately unsupported.
Existing direct expressions and terminal return trees retain their previous lowering.
With `debug_tags: true`, wrapper sites include `control_flow="single_iteration"`.

Omitted defaults support literals/null, value constructors with constant inputs, and
resolvable immutable value constants. Mutable collection or executable defaults leave
the omitted-argument call unchanged; explicitly supplying that argument remains eligible.

Calls use a script constant/global class, or a direct call inside another static
function in the same script. Original definitions remain intact. Template Variant declarations,
loops, match, lambdas/await in imported bodies, mutable external
bindings, remain unsupported in templates. Ambiguous/unsupported sites stay
unchanged with diagnostics. No statement expansion is hoisted from a larger expression.
Loops inside imported bodies remain unsupported because a rewritten break would
otherwise exit the inner loop. Calls inside a caller's loop are supported.

Replay stats expose `inline_calls`, `inline_skipped`, `inline_direct_calls`,
`inline_expanded_calls`, `inline_early_return_calls` (a subset of expanded calls),
`inline_substituted_args`, `inline_captured_args`, and
`inline_repeated_access_captures`. Counts describe source sites, not runtime invocations.
Tagging is opt-in: removal of call overhead does not guarantee a speedup for every body.

Tests: `godot --headless --path . --script res://tests/gdscript_optimizer/run_headless.gd`.

Early-return benchmark:
`godot --headless --path . --script res://tests/gdscript_optimizer/benchmark_early_return.gd -- 200000 7`.
It compares original calls with optimizer output for first/second guards, fallthrough,
and mixed inputs. Void effects are inlined; typed-result helpers remain as a control
(the report includes `inlined`). Checksums verify behavior;
median timings exclude optimization, compilation, and warmup.

Predicate benchmark (original versus transformed code, median microseconds and checksum):
`godot --headless --path . --script res://tests/gdscript_optimizer/benchmark_expression.gd -- 200000 7`.
It reports typed and Variant callers with the Variant opt-in disabled/enabled; timings
exclude optimization, compilation, startup, and warmup. No fixed speedup is asserted.

## Substitution, variadic helpers, and nested calls

```gdscript
#! inline; substitute
static func all_values(...values:Array) -> bool:
    for value in values:
        if not value:
            return false
    return true
```

`all_values(get_cond(), node.get_cond())` can become
`(get_cond() and node.get_cond())`. The tag authorizes skipping, duplicating, and
reordering supplied expressions, according to parameter use in the helper. It does
not disable type checks: Variant/reference eligibility still uses the separate config
flags. A bool-returning method can be substituted without enabling reference types.
Normal inline only skips/repeats proven safe arguments; unknown methods/getters and
potentially throwing expressions stay calls or use existing eager template captures.
Await/lambda arguments remain excluded.

Rest parameters (`...args` or `...args:Array`) retain fixed/default argument binding.
Templates evaluate supplied arguments once in order before conversions and create a
fresh rest Array. The recognized all/any reductions have one rest parameter, one loop,
an immediate false/true return under `if not value`/`if value`, and the opposite final
return. Empty all is true; empty any is false. Recognition is structural, independent
of names. Other loops and the existing array-based Bool API are not rewritten.

Eligible expression children expand inside call arguments and private helper/template
copies; original definitions remain intact. Child substitution does not grant an
ordinary parent permission to duplicate an effectful result. Cycles, expansion depth
above 16, or expressions exceeding 4,096 tokens leave calls with diagnostics. Nested
helpers requiring new statement blocks remain deferred.

Set `debug_tags: true` in YAML, or `context.debug_tags = true`, to mark successful
inline, struct, scalar, and typed-read/cast sites with searchable `# optimizer-*;`
comments. Markers sit at logical statement boundaries and record source provenance;
inline markers include helper identity, mode, options and depth. Default is false.

Evaluation-aware benchmark:
`godot --headless --path . --script res://tests/gdscript_optimizer/benchmark_composition.gd -- 100000 7`.
It checks both result counts and the different expected call counts for ordinary and
substituted helpers before reporting median timings.
