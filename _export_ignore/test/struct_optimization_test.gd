extends RefCounted

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_optimized.gd"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var original = load(FIXTURE)
	var text := FileAccess.get_file_as_string(FIXTURE)
	for debug in [false, true]:
		for inline_enabled in [false, true]:
			var label := "debug=%s inline=%s" % [debug, inline_enabled]
			var context = Optimizer.Context.new()
			context.debug_tags = debug
			context.aggressive = true
			var optimizer = Optimizer.new()
			var passes:Array = [Optimizer.StructPass]
			if inline_enabled:
				passes.append(Optimizer.InlinePass)
			var prepared:Dictionary = optimizer.prepare({FIXTURE: FIXTURE}, context, passes)
			if not prepared.errors.is_empty():
				failures.append(label + ": " + str(prepared.errors))
				continue
			var result:Dictionary = optimizer.apply(FIXTURE, Array(text.split("\n")))
			var source := "\n".join(result.lines)
			# In-memory compilation must reference its own transformed enum, not the disk original.
			source = RegEx.create_from_string(r"_inline_\w+_dep_\d+\.Point\.").sub(source, "Point.", true)
			var script := GDScript.new()
			script.source_code = source
			if not result.errors.is_empty() or script.reload() != OK:
				failures.append(label + ": compile/replay failed " + str(result.errors))
				continue
			for method:String in ["local_loop", "values", "ordering", "alias", "captured", "references", "dynamic", "conditional_null", "combined", "reads", "shadowing", "chained_constructors", "branch_checks", "reassignment", "collision", "statement_checks", "cast_checks", "literal_spelling"]:
				if script.call(method) != original.call(method):
					failures.append(label + ": different result for " + method)
			if (result.stats.get("scalar_structs", 0) < 5 or result.stats.get("scalar_accesses", 0) < 20):
				failures.append(label + ": missing scalar replacements " + str(result.stats) + str(prepared.warnings))
			if result.stats.get("scalar_skipped", 0) < 4:
				failures.append(label + ": missing escape/type skips")
			if result.stats.get("struct_typed_captures", 0) < 3:
				failures.append(label + ": missing typed captures " + str(result.stats))
			if source.contains("as float as float"):
				failures.append(label + ": redundant explicit cast")
			if not source.contains("((point[Point.X]) as float)"):
				failures.append(label + ": parenthesized explicit cast was changed")
			if source.contains("# optimizer-struct;") != debug:
				failures.append(label + ": struct debug markers incorrect")
			if debug and not source.contains("# optimizer-scalar-replacement;"):
				failures.append(label + ": scalar markers missing")
			if debug and not source.contains("# optimizer-struct-read;"):
				failures.append(label + ": read markers missing")
			var again:Dictionary = optimizer.apply(FIXTURE, Array(text.split("\n")))
			if again.lines != result.lines or again.stats != result.stats:
				failures.append(label + ": replay was not deterministic")
	return {"result": failures.size(), "output": ["struct optimization: %d failures" % failures.size()] + failures}
