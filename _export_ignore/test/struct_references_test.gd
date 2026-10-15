extends RefCounted

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_reference_types.gd"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var original = load(FIXTURE)
	for aggressive:bool in [false, true]:
		var context = Optimizer.Context.new()
		context.aggressive = aggressive
		var optimizer = Optimizer.new()
		var prepared:Dictionary = optimizer.prepare({FIXTURE: FIXTURE}, context)
		if not prepared.errors.is_empty():
			failures.append(str(prepared.errors))
			continue
		var result:Dictionary = optimizer.apply(FIXTURE, Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
		var script := GDScript.new()
		script.source_code = "\n".join(result.lines)
		if script.reload() != OK:
			failures.append("reference compile failed: aggressive=%s" % aggressive)
			continue
		for method:String in ["scalar", "surviving", "cross_file", "nested", "constructor_reference", "objects"]:
			if script.call(method) != original.call(method):
				failures.append("reference result changed: %s aggressive=%s" % [method, aggressive])
		if (result.stats.get("scalar_structs", 0) > 0) != aggressive:
			failures.append("reference scalar eligibility incorrect: %s %s" % [aggressive, prepared.warnings])
		if (result.stats.get("struct_typed_captures", 0) >= 8) != aggressive:
			failures.append("reference reads missing: %s %s" % [aggressive, result.stats])
	var context = Optimizer.Context.new()
	context.aggressive = true
	context.map_path = func(key:String): return "res://relocated/" + key + ".gd"
	var optimizer = Optimizer.new()
	var prepared:Dictionary = optimizer.prepare({"main": FIXTURE,
		"payload": "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/reference_payload.gd"}, context)
	var relocated:Dictionary = optimizer.apply("main", Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
	if not prepared.errors.is_empty() or not "\n".join(relocated.lines).contains('preload("res://relocated/payload.gd")'):
		failures.append("reference type dependency ignored source identity/output mapping")
	return {"result": failures.size(), "output": ["struct references: %d failures" % failures.size()] + failures}
