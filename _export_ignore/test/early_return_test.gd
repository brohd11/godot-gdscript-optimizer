extends RefCounted
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/early_return/"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var path := BASE + "caller.gd"
	var original = load(path)
	for debug:bool in [false, true]:
		var context = Optimizer.Context.new()
		context.debug_tags = debug
		var optimizer = Optimizer.new()
		var prepared:Dictionary = optimizer.prepare({path: path, BASE + "helpers.gd": BASE + "helpers.gd"}, context, [Optimizer.InlinePass])
		if not prepared.errors.is_empty() or prepared.warnings.size() != 7:
			failures.append("unexpected preparation: " + str(prepared))
		for spaces:bool in [false, true]:
			var source := FileAccess.get_file_as_string(path)
			if spaces:
				source = source.replace("\t", "  ")
			var result:Dictionary = optimizer.apply(path, Array(source.split("\n")))
			var text:String = "\n".join(result.lines)
			var script := GDScript.new()
			script.source_code = text
			if script.reload() != OK:
				failures.append("early return compilation failed")
				print(text)
				continue
			if result.stats.inline_early_return_calls != 2 or result.stats.inline_expanded_calls != 3:
				failures.append("missing wrapper expansions: " + str(result.stats) + str(result.warnings))
			for retained:String in ["Helpers.classify(value)", "Helpers.classify(value, 2)", "Helpers.owned(events, stop)", "Helpers.unused(Events.make()", "Helpers.touch(events, value)"]:
				if not text.contains(retained):
					failures.append("value-returning guard helper expanded: " + retained)
			for removed:String in ["Helpers.ordered(argument("]:
				if text.contains(removed):
					failures.append("return-only guard helper remained a call: " + removed)
			if text.contains(" else "):
				failures.append("guard expansion generated a ternary")
			for method:String in ["classify", "assign", "touch"]:
				for value:int in [-3, -1, 0, 1, 2, 9]:
					if script.call(method, value) != original.call(method, value):
						failures.append("different result: %s(%s)" % [method, value])
			for method:String in ["loops", "ordering"]:
				if script.call(method) != original.call(method):
					failures.append("different effects: " + method)
			for stop:bool in [false, true]:
				for method:String in ["lifetime", "lifetime_void", "owned", "local_lifetime"]:
					if script.call(method, stop) != original.call(method, stop):
						failures.append("different lifetime: " + method)
			if script.lifetime_void(true) != ["make", "deleted", "after"] or script.ordering() != [-2.0, "ab", TYPE_FLOAT]:
				failures.append("lifetime or eager evaluation changed")
			if not text.contains("return false and Helpers.classify(value)") or not text.contains("Helpers.inner_loop(value)"):
				failures.append("unsupported expression/body was expanded")
			if not text.contains("# retained void comment") or text.contains('control_flow="single_iteration"') != debug:
				failures.append("comment or debug metadata missing")
			var collision := "_inline_%d_once" % source.find("Helpers.touch(events, value)")
			var indent := "  " if spaces else "\t"
			var colliding := source.replace(indent + 'events.append("after")', indent + "var " + collision + ":int = 1\n" + indent + 'events.append("after")')
			var collision_result:Dictionary = optimizer.apply(path, Array(colliding.split("\n")))
			var collision_script := GDScript.new()
			collision_script.source_code = "\n".join(collision_result.lines)
			if collision_script.reload() != OK or collision_script.touch(0) != original.touch(0):
				failures.append("generated name collision")
	for sample:Array in [[true, ["if value:", "\treturn", "pass"], true], [false, ["if value:", "\treturn 1"], false],
		[false, ["return"], false], [true, ["return 1"], false], [false, ["return 1", "pass"], false]]:
		var lines:Array = []
		for line:String in sample[1]:
			lines.append({"code": line.strip_edges(), "indent": line.length() - line.strip_edges().length()})
		var flow:Dictionary = Optimizer.InlinePass.Body._flow(lines, 0, 0, sample[0])
		var accepted:bool = flow.ok and flow.end == lines.size() and (sample[0] or not flow.falls)
		if accepted != sample[2]:
			failures.append("incorrect return flow: " + str(sample))
	return {"result": failures.size(), "output": ["early return inline: %d failures" % failures.size()] + failures}
