extends RefCounted
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/static_inline/"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var sources:Dictionary = {}
	for name:String in ["keys", "helpers", "caller"]:
		sources[BASE + name + ".gd"] = BASE + name + ".gd"
	var optimizer = Optimizer.new()
	var prepared = optimizer.prepare(sources, Optimizer.Context.new(), [Optimizer.InlinePass])
	if not prepared.errors.is_empty() or prepared.warnings.any(func(warning): return not warning.contains("require aggressive or substitute")):
		failures.append("prepare: " + str(prepared))
	for name:String in ["caller", "helpers"]:
		var path := BASE + name + ".gd"
		var result = optimizer.apply(path, Array(FileAccess.get_file_as_string(path).split("\n")))
		var text:String = "\n".join(result.lines)
		var script := GDScript.new()
		script.source_code = text
		if script.reload() != OK:
			failures.append("did not compile: " + name + "\n" + text)
			continue
		var original = load(path)
		for value:String in ["", "res://test.gd", "path##String", "other"]:
			var methods:Array = ["default_value", "shadow", "ordinary_branch", "composed"] if name == "caller" else ["local_use", "local_shadow"]
			for method:String in methods:
				if script.call(method, value) != original.call(method, value):
					failures.append("result changed: " + method + " " + value)
			if name == "caller":
				for method:String in ["add", "ordinary"]:
					if script.call(method, value, "int") != original.call(method, value, "int"):
						failures.append("concatenation changed: " + method)
				for include_type:bool in [false, true]:
					for method:String in ["branch", "branch_statement", "branch_return"]:
						if script.call(method, value, include_type) != original.call(method, value, include_type):
							failures.append("branch changed: " + method + " " + value)
		if name == "helpers":
			var body := _body(text, "local_use")
			if not body.contains("Keys.TYPE_DELIM") or body.contains("add_type(") or body.contains("_dep_"):
				failures.append("local static scope was not retained: " + body)
			continue
		if script.static_effects() != original.static_effects():
			failures.append("static effects changed: " + str(script.static_effects()))
		if script.mutable_default() != original.mutable_default() or not _body(text, "mutable_default").contains("Helpers.mutable_default()"):
			failures.append("mutable omitted default was substituted")
		for value:int in [-1, 2]:
			if script.storage(value) != original.storage(value):
				failures.append("local storage changed")
			for method:String in ["enum_value", "numeric_call"]:
				if script.call(method, value) != original.call(method, value):
					failures.append("static value changed: " + method)
		for method:String in ["add", "ordinary", "default_value", "shadow", "composed"]:
			var body := _body(text, method)
			if body.contains("_inline_") or body.contains("preload(") or body.contains("Helpers.add_type(") or body.contains("Helpers.composed(") or body.contains("Helpers.ordinary_"):
				failures.append("unnecessary wrapper/call: " + method + "\n" + body + str(result.warnings))
		for method:String in ["branch_statement", "branch_return"]:
			var body := _body(text, method)
			if body.contains("Helpers.path(") or body.contains("_inline_") or not body.contains("\n\tif ") or not body.contains("\n\telif ") or not body.contains("\n\telse:"):
				failures.append("expected direct branch statements: " + method + "\n" + body)
		if text.contains(" else "):
			failures.append("generated a ternary")
		if not _body(text, "branch").contains("Helpers.path(") or not _body(text, "ordinary_branch").contains("Helpers.ordinary_path("):
			failures.append("embedded branch call was rewritten")
		if not _body(text, "composed").contains("Helpers.path("):
			failures.append("nested branch call was rewritten")
		for choose:bool in [false, true]:
			if script.reference_branch(choose) != original.reference_branch(choose):
				failures.append("reference result changed")
		if not _body(text, "reference_branch").contains("Helpers.reference_branch("):
			failures.append("conditional cleanup bridge exceeded the result-local limit")
		if not _body(text, "add").contains("Helpers.Keys.TYPE_DELIM"):
			failures.append("static receiver was not reused")
		if not _body(text, "enum_value").contains("Helpers.Mode.SECOND") or not _body(text, "numeric_call").contains("Helpers.next()"):
			failures.append("enum or static call expression was not qualified")
		for method:String in ["write", "read", "step", "ordered", "twice"]:
			if _body(text, "static_effects").contains("Helpers." + method + "("):
				failures.append("static body remained a call: " + method)
		if _body(text, "storage").contains("_bridge") or _body(text, "storage").contains("_result"):
			failures.append("substitute retained lifetime-only result storage")
		for method:String in ["constant_divisor", "default_divisor"]:
			if _body(text, method).contains("Helpers.divide(") or not _body(text, method).contains("_divisor:int"):
				failures.append("constant divisor did not retain runtime evaluation: " + method)
		for method:String in ["forced_divisor", "forced_literal_divisor"]:
			if not _body(text, method).contains("Helpers.forced_divide("):
				failures.append("unchecked substitution introduced constant zero division: " + method)
	return {"result": failures.size(), "output": ["static inline: %d failures" % failures.size()] + failures}

static func _body(source:String, method:String) -> String:
	return source.split("static func " + method + "(")[1].split("\nstatic func ")[0]
