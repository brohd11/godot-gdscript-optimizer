extends RefCounted
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/composition/"

static func run_tests() -> Dictionary:
	var failures:Array = []
	for debug in [false, true]:
		var context = Optimizer.Context.new()
		context.debug_tags = debug
		var optimizer = Optimizer.new()
		var prepared:Dictionary = optimizer.prepare({BASE + "caller.gd": BASE + "caller.gd", BASE + "helpers.gd": BASE + "helpers.gd"}, context, [Optimizer.InlinePass])
		if not prepared.errors.is_empty() or not str(prepared.warnings).contains("cycle") or not str(prepared.warnings).contains("unknown inline option"):
			failures.append("definition diagnostics missing: " + str(prepared))
		var result:Dictionary = optimizer.apply(BASE + "caller.gd", Array(FileAccess.get_file_as_string(BASE + "caller.gd").split("\n")))
		var text:String = "\n".join(result.lines)
		var script := GDScript.new()
		script.source_code = text
		if script.reload() != OK:
			failures.append("composition compilation failed")
			print(text)
			continue
		for entry:Array in [["lazy", false, "a"], ["repeated", false, "aa"], ["reversed", true, "ba"], ["dropped", true, "a"],
			["ordinary", false, "ab"], ["all_variadic", false, "ab"], ["any_variadic", true, "ab"], ["safe_variadic", false, "ab"],
			["packed", [4, 5, 3], "abc"], ["defaults", [7], ""], ["no_tail", [2], ""], ["policy_boundary", false, "aab"]]:
			script.events = ""
			var actual:Variant = script.call(entry[0])
			if actual != entry[1] or script.events != entry[2]:
				failures.append("%s: result=%s events=%s expected=%s" % [entry[0], actual, script.events, entry])
		if not script.empty() or not script.pure_variadic("res://test.gd") or script.pure_variadic("file.txt"):
			failures.append("empty/pure boolean reduction changed")
		if script.nested(3) != 24 or script.template_nested(3) != 49:
			failures.append("nested expansion changed numeric result")
		for removed:String in ["Helpers.chained(", "Helpers.templated(", "Helpers.twice(", "Helpers.all_values(", "Helpers.any_values("]:
			if text.contains(removed):
				failures.append("eligible helper remained: " + removed + " " + str(result.warnings))
		if not text.contains('Helpers.divides(number("a", 1), 0)'):
			failures.append("substitution introduced constant zero divisor")
		if not text.contains("Helpers.packed(") or not text.contains("Helpers.safe_all(probe(") or not text.contains("Helpers.cycle_a(value)"):
			failures.append("unsafe normal reduction or recursive definition expanded")
		if text.contains("# optimizer-inline;") != debug or (debug and not text.contains('args="substitute"')):
			failures.append("inline debug markers missing or enabled by default")
		if debug and not text.contains('depth=1'):
			failures.append("nested markers missing")
	# Keep pathological expressions out of the editor's native workspace index.
	var limit_path := "user://optimizer_composition_limits_%d.gd" % OS.get_process_id()
	var limit_source := FileAccess.get_file_as_string(BASE + "limits.gd.txt")
	var limit_file := FileAccess.open(limit_path, FileAccess.WRITE)
	if limit_file == null:
		return {"result": 1, "output": ["Could not create composition limit fixture"]}
	limit_file.store_string(limit_source)
	limit_file.close()
	var limited = Optimizer.new()
	var prepared:Dictionary = limited.prepare({limit_path: limit_path}, Optimizer.Context.new(), [Optimizer.InlinePass])
	var result:Dictionary = limited.apply(limit_path, Array(limit_source.split("\n")))
	DirAccess.remove_absolute(limit_path)
	var text:String = "\n".join(result.lines)
	if not str(prepared.warnings).contains("limit") or not text.contains("return depth_0(value)") or not text.contains("return wide(value)"):
		failures.append("depth/token limits did not retain the call")
	var shallow:String = text.split("static func shallow(")[1].split("static func oversized(")[0]
	if shallow.contains("depth_19(value)"):
		failures.append("deep candidate poisoned independent shallow helper")
	return {"result": failures.size(), "output": ["inline composition: %d failures" % failures.size()] + failures}
