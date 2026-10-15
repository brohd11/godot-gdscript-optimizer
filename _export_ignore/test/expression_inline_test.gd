extends RefCounted

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/expression_inline/predicates.gd"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var original = load(FIXTURE)
	for aggressive in [false, true]:
		var context = Optimizer.Context.new()
		context.aggressive = aggressive
		var optimizer = Optimizer.new()
		var prepared:Dictionary = optimizer.prepare({FIXTURE: FIXTURE}, context, [Optimizer.InlinePass])
		if not prepared.errors.is_empty():
			failures.append(str(prepared.errors))
			continue
		var result:Dictionary = optimizer.apply(FIXTURE, Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
		var text:String = "\n".join(result.lines)
		var transformed := GDScript.new()
		transformed.source_code = text
		if transformed.reload() != OK:
			failures.append("expression compilation failed: aggressive=%s" % aggressive)
			continue
		for path:String in ["res://test.gd", "test.gd.remap", "test.gd::Inner", "res://other.txt", "", "res://file_path.gd::Inner"]:
			for method:String in ["typed", "dynamic", "implicit"]:
				if transformed.call(method, path) != original.call(method, path):
					failures.append("expression result differs: " + method + " " + path)
		var typed_body:String = text.split("static func typed(")[1].split("static func dynamic(")[0]
		if typed_body.contains("if is_gdscript_path(path):") or text.contains("while within(count, 0, 3):") or text.contains("elif multiline(path):"):
			failures.append("typed conditional was not inlined: " + str(result.warnings))
		if text.contains("if positive(payload):") == aggressive:
			failures.append("reference gate aggressive=%s: %s %s" % [aggressive, prepared.warnings, result.warnings])
		if text.contains("return false or is_gdscript_path(path)") == aggressive or text.contains("if variant_predicate(path):") == aggressive:
			failures.append("Variant gate did not control direct calls")
		if not transformed.literal_check() or transformed.literal_check() != original.literal_check():
			failures.append("literal bytes or parameter named string changed")
		if transformed.node_check() != original.node_check():
			failures.append("Node result differs")
		if text.contains("false or node_name(node)") == aggressive:
			failures.append("Node gate aggressive=%s: %s %s" % [aggressive, prepared.warnings, result.warnings])
		if transformed.reference_check() != original.reference_check() or transformed.variant_return(7) != 7:
			failures.append("reference or Variant return result differs")
		if not transformed.array_check() or text.contains("return false or first_positive(values)") == aggressive:
			failures.append("typed array indexing gate or result differs")
		if not transformed.dynamic_reference_check() or text.contains("return false or dynamic_field(value)") == aggressive:
			failures.append("unknown Variant reference gate or result differs")
		if transformed.implicit_return_check(7) != 7 or text.contains("return implicit_identity(value)") == aggressive:
			failures.append("implicit Variant return gate or result differs")
		if transformed.unchecked_return(3.75) != (3.75 if aggressive else 3):
			failures.append("unchecked mode did not remove return conversion")
		if transformed.unchecked(3.75) != (3.75 if aggressive else 3):
			failures.append("unchecked mode did not remove parameter conversion")
		if not text.contains("is_gdscript_path(next_path())") or not text.contains("is_gdscript_path(paths[0])"):
			failures.append("nonlocal argument substituted")
		if text.contains("within(number, 0, 4)") == aggressive:
			failures.append("known numeric mismatch substituted")
		transformed.effects = 0
		if transformed.effects_once(false) or transformed.effects != 0:
			failures.append("short circuit moved argument evaluation")
		if not transformed.effects_once(true) or transformed.effects != 1:
			failures.append("effectful argument was duplicated")
	return {"result": failures.size(), "output": ["expression inline: %d failures" % failures.size()] + failures}
