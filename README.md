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

## Optimization policy

```yaml
struct_mode: tagged # auto | tagged | off
inline_mode: tagged # auto | tagged | off
aggressive: false
debug_tags: false
```

`tagged` considers explicitly tagged definitions; `auto` discovers eligible definitions;
`off` disables the pass even for tagged definitions. `#! struct; off` and `#! inline; off`
exclude individual definitions from discovery. Missing settings inherit the defaults above.
Unknown keys and invalid values are errors; there are no legacy configuration aliases.

`Optimizer.Config.from_file(path = "")` loads one YAML mapping using YAMLParser;
`from_dictionary(data)` validates an in-memory mapping. Both return `{options, errors}`.
Use `context.configure(options)` to apply validated defaults and overrides; it returns errors.
Context exposes `struct_mode`, `inline_mode`, `aggressive`, and `debug_tags` directly too.
The explicit pass list still selects which passes run; modes cannot enable an omitted pass.

Auto discovery uses parsed declarations without changing source tags. It considers file-level
and nested data classes, and top-level static functions. Explicit tags retain their identity
and permissions. Unsupported automatic candidates are skipped; malformed explicit struct
contracts remain preflight errors. Supply all participating sources so use checks can run.

## Struct optimization

Structs contain fields and optionally a simple `_init` assigning arguments to fields.
Other methods, unsupported inheritance, accessors, and unsupported syntax prevent conversion.
Conservative mode requires proven value fields (explicit types or `:=`). Reference,
Variant, and unresolved fields exclude the whole class. Aggressive mode admits supported
reference and Variant fields, but retains constructor and usage checks. Automatically found
classes with unsupported Object operations or untyped/unresolved escapes remain objects.
Candidates are removed and revalidated before any edits are emitted.

Scalar replacement and typed-local field reads are always attempted for selected structs.
Scalar replacement removes nonescaping local allocations whose fields have representable
types and defaults. Aliases, reassignment, whole-value uses, captures, coroutine lifetimes,
and unsuitable constructors keep the Array form. Arguments evaluate once in order.
Scalarization after inline expansion is deferred.

Remaining field reads use typed captures at supported statement sites with safe evaluation
order. Conditional evaluation, mixed calls, complex receivers, and writes are skipped.
The optimizer never generates field-read casts. Aggressive mode admits reference types
for captures and scalar locals; this can extend lifetimes and change runtime checks.
Unknown field types still cannot be scalarized or captured. Mutable defaults are separate
per instance, and effectful defaults remain excluded from scalar replacement.

Preparation counts are available in `optimizer.stats`: `struct_candidates`,
`struct_eligible`, `struct_candidates_skipped`, `inline_candidates`, `inline_eligible`,
and `inline_definitions_skipped`. Replay adds `scalar_structs`, `scalar_accesses`,
`scalar_skipped`, `struct_typed_captures`, and `struct_reads_skipped`, plus inline counts.
Counts describe source sites, not runtime work or guaranteed speedups.

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
returns. It accepts
arithmetic (`+ - * / %`, unary `+ -`), comparisons, `and/or/not`, String/StringName
concatenation and literals, parameters, and String `begins_with`, `ends_with`, `contains`,
`is_empty`, `get_slice`, `trim_prefix`, and `trim_suffix`.
It substitutes matching literals or statically typed locals, retaining return types,
precedence, and short-circuiting. Direct calls may appear in `if`, `elif`, `while`, and
larger expressions. It emits no argument temporaries and supports immutable omitted defaults.

Static references retain their defining scope in both paths: constants, enums, nested types,
static variable reads/writes, and static method calls are supported. For example,
`Utils.add_type(value, type)` can become `(value + Utils.Keys.TYPE_DELIM + type)`.
Calls within the defining class retain bare member names unless a caller local shadows them.
External calls reuse their receiver; inaccessible names use verified aliases or template
preloads. Untagged static methods remain calls. Static state and calls remain effectful
when an expanded child is considered for substitution into an ordinary parent.

Conservative inlining requires supported value-type signatures. It preserves argument
order, conversions, and required captures. `aggressive: true` additionally admits supported
reference/Variant signatures and uses substitute-style conversion and lifetime reductions.
Arguments still must be proven before nested rewriting: any unproven call, getter, or index
argument leaves an aggressive call unchanged unless its helper explicitly has
`#! inline; substitute`. Simple local arguments and proven pure expressions qualify.

The explicit substitute tag overrides conservative eligibility for that helper and permits
skipped, repeated, or reordered arguments. A plain inline tag does not grant this permission,
and an inner helper's tag does not grant permission to an outer helper. Off modes and local
exclusions still win. Depth, cycle, size, syntax, and constant-divisor checks always apply.

The template path supports built-in value types. Aggressive or substitute templates also
support Array/Dictionary, typed collections, reference objects, Variant, packed arrays,
Callable, and Signal where their operations are supported.

Preflight records parameter token slots, reference counts, rebinding, field/index
writes, and calls. Bodies may declare typed/inferred locals, assign locals/parameters
or their fields, and use nested if/elif/else branches. Value-returning helpers must
finish with a return or an exhaustive terminal return tree. Return-only guard clauses
with a final fallback become terminal `if`/`elif`/`else` branches, preserving condition order.
The optimizer does not generate ternaries from branches; conditional helpers embedded
in larger expressions remain calls. Explicit `-> void` helpers allow early bare returns,
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
simple local/parameter, or return. Terminal branches assign an existing local directly
when its type preserves return conversion and no imported reference needs cleanup first.
Eligible declarations are emitted before the branches and assigned directly: `var x`
stays Variant, `:=` gets the helper's return type, and explicit annotations are retained.
One result slot remains when return conversion, cleanup, or initializer shadowing requires it.
Conditional expansions needing both a result slot and a reference-cleanup bridge remain calls.
Required argument captures and body locals are separate from this result-slot limit.
Tail-call expansions emit returns directly when conversion and cleanup permit it.
Argument/body locals live in a generated block only when scope is needed. Reference
results retain a temporary Variant bridge, cast and cleared after assignment, so imported
locals do not extend reference lifetimes to the end of the caller. Type annotations reuse
unshadowed caller aliases with matching resolved identities; other types use preload aliases.

Only void bodies use a generated `for <unique_name> in 1:` loop; bare returns become
breaks. These helpers expand at standalone call statements without a result or bridge.
Value-returning guards consisting only of conditions and returns become terminal branches.
Guards with local assignments or standalone effects remain calls; result/bridge loops
for value-returning helpers remain unsupported.
With `debug_tags: true`, wrapper sites include `control_flow="single_iteration"`.

Omitted defaults support literals/null, value constructors with constant inputs, and
resolvable immutable value constants. Mutable collection or executable defaults leave
the omitted-argument call unchanged; explicitly supplying that argument remains eligible.

Calls use a script constant/global class, or a direct call inside another static
function in the same script. Original functions remain available. Template Variant declarations
require aggressive mode or `substitute`. Loops, match, lambdas/await, and instance-dependent external
bindings remain unsupported in templates. Ambiguous/unsupported sites stay
unchanged with diagnostics. No statement expansion is hoisted from a larger expression.
Loops inside imported bodies remain unsupported because a rewritten break would
otherwise exit the inner loop. Calls inside a caller's loop are supported.

Replay stats expose `inline_calls`, `inline_skipped`, `inline_direct_calls`,
`inline_expanded_calls`, `inline_early_return_calls` (a subset of expanded calls),
`inline_substituted_args`, `inline_captured_args`, and
`inline_repeated_access_captures`. Counts describe source sites, not runtime invocations.
Default discovery is tagged: removal of call overhead does not guarantee a speedup for every body.

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
reordering supplied expressions, according to parameter use in the helper. This is a
per-helper override of the global aggressive setting, for direct and expanded
inlining. Parameter checks/conversions and strong reference captures can disappear;
direct assignment can also remove the helper's return conversion. Result/bridge storage
used solely for reference lifetime protection is omitted even with imported reference locals.
The author accepts
changes to evaluation, errors, aliasing, and destructor timing. Rebound parameters and
mutated value parameters still get local storage to avoid writing back to the caller.
Unsupported syntax and control flow remain excluded.
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
copies; original functions remain available. Child substitution does not grant an
ordinary parent permission to duplicate an effectful result. Cycles, expansion depth
above 16, or expressions exceeding 4,096 tokens leave calls with diagnostics. Nested
helpers requiring new statement blocks remain deferred.

Set `debug_tags: true` in YAML, or `context.debug_tags = true`, to mark successful
inline, struct, scalar, and typed-read sites with searchable `# optimizer-*;`
comments. Markers sit at logical statement boundaries and record source provenance;
inline markers include helper identity, mode, options and depth. Default is false.

Evaluation-aware benchmark:
`godot --headless --path . --script res://tests/gdscript_optimizer/benchmark_composition.gd -- 100000 7`.
It checks both result counts and the different expected call counts for ordinary and
substituted helpers before reporting median timings.
