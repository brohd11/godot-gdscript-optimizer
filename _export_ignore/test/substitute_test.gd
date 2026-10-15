extends RefCounted
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/substitute/"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var sources:Dictionary = {}
	for name:String in ["caller", "helpers", "record", "node"]:
		sources[BASE + name + ".gd"] = BASE + name + ".gd"
	var optimizer = Optimizer.new()
	var context = Optimizer.Context.new()
	context.set_global_classes({"StaleOptimizerClass": "res://missing_optimizer_class.gd"})
	var prepared = optimizer.prepare(sources, context, [Optimizer.InlinePass])
	if not prepared.errors.is_empty() or prepared.warnings.any(func(warning): return not warning.contains("require aggressive or substitute")):
		failures.append("prepare: " + str(prepared))
	var path:String = BASE + "caller.gd"
	var result:Dictionary = optimizer.apply(path, Array(FileAccess.get_file_as_string(path).split("\n")))
	var text:String = "\n".join(result.lines)
	var script := GDScript.new()
	script.source_code = text
	if script.reload() != OK:
		return {"result": 1, "output": ["substitute output did not compile", text]}
	var original = load(path)
	for method:String in ["dynamic_existing", "declarations", "ordinary_alias", "shadowed_alias", "rebinding", "variants", "native", "local_reference", "shadowed_initializer"]:
		if script.call(method) != original.call(method):
			failures.append("different result: " + method)
	for value:String in ["", "existing"]:
		if script.existing(value) != original.existing(value):
			failures.append("target-as-argument changed: " + value)
	for first in [false, true]:
		if script.ordinary_declarations(first) != original.ordinary_declarations(first):
			failures.append("declaration typing or conversion changed")
		for second in [false, true]:
			if script.nested(first, second) != original.nested(first, second):
				failures.append("nested terminal branches changed")
	if script.repeated() != [3, ["first", "first"]] or script.reordered() != [3, ["second", "first"]]:
		failures.append("force did not substitute supplied expressions")
	var counts:Array = script.reference_counts()
	if counts != [counts[0], counts[0], counts[0]] or original.reference_counts()[1] <= counts[1]:
		failures.append("force retained reference captures: " + str(counts))
	if script.conversions() != [2.0, 2.75] or original.conversions() != [2.0, 2.0]:
		failures.append("ordinary conversion / forced unchecked assignment changed")
	for method:String in ["existing", "dynamic_existing", "nested"]:
		var body:String = _body(text, method)
		for marker:String in ["_bridge", "_result", "_dep_", "if true:", "Helpers."]:
			if body.contains(marker):
				failures.append(method + " retained " + marker)
	var declarations:String = _body(text, "declarations")
	for marker:String in ["_bridge", "_result", "if true:", "Helpers."]:
		if declarations.contains(marker):
			failures.append("declarations retained " + marker)
	for declaration:String in ["var dynamic\n", "var inferred:String\n", "var typed:String\n"]:
		if not declarations.contains(declaration) or not _body(text, "ordinary_declarations").contains(declaration):
			failures.append("missing direct declaration: " + declaration)
	var shadowed := _body(text, "shadowed_initializer")
	if shadowed.count("var _inline_") != 1 or not shadowed.contains("_result:String"):
		failures.append("shadowed initializer must use exactly one result local")
	if text.contains(" else "):
		failures.append("branch expansion generated a ternary")
	for method:String in ["ordinary_alias", "shadowed_alias"]:
		if not _body(text, method).contains("Helpers.ordinary_path("):
			failures.append("ordinary reference helper bypassed conservative policy")
	if not _body(text, "local_reference").contains("_result:String") or not _body(text, "local_reference").contains("if true:"):
		failures.append("owned reference local lost its cleanup scope")
	if _body(text, "local_reference").contains("Helpers.local_reference("):
		failures.append("helper with an owned local remained a call")
	if _body(text, "native").contains("Helpers.native(") or _body(text, "native").contains("Helpers.script_native("):
		failures.append("native reference calls remained")
	for method:String in ["variants", "reference_counts", "repeated", "reordered"]:
		if _body(text, method).contains("Helpers."):
			failures.append("force call remained: " + method + " " + str(result.warnings))
	return {"result": failures.size(), "output": ["substitute: %d failures" % failures.size()] + failures}

static func _body(source:String, method:String) -> String:
	return source.split("static func " + method + "(")[1].split("\nstatic func ")[0]
