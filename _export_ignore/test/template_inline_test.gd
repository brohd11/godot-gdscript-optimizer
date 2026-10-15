extends RefCounted
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var sources:Dictionary = {}
	for name:String in ["templates", "template_caller", "reference", "events", "defaults"]:
		sources[BASE + name + ".gd"] = BASE + name + ".gd"
	var optimizer = Optimizer.new()
	var prepared = optimizer.prepare(sources, Optimizer.Context.new(), [Optimizer.InlinePass])
	if not prepared.errors.is_empty() or prepared.warnings.any(func(warning): return not warning.contains("require aggressive or substitute")):
		failures.append("prepare: " + str(prepared))
	var path := BASE + "template_caller.gd"
	var result = optimizer.apply(path, Array(FileAccess.get_file_as_string(path).split("\n")))
	var source := "\n".join(result.lines)
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		return {"result": 1, "output": ["templates did not compile", source]}
	if result.stats.inline_calls != 9:
		failures.append("expected 9 value-only sites: " + str(result.stats) + str(result.warnings))
	var original = load(path)
	for method:String in ["lookup", "mixed", "reference_rebind", "containers", "defaults", "supplied", "ordering", "lifetime", "getter", "reference_getter", "converted", "vector_default", "mutable_supplied", "constant_default", "reference_count", "dictionary_keys"]:
		if script.call(method) != original.call(method):
			failures.append("different result: " + method)
	for label:String in ["x", "y", "z"]:
		if script.branch(label) != original.branch(label):
			failures.append("different branch: " + label)
	if source.count('values["value"]') != 1 or result.stats.inline_repeated_access_captures != 3:
		failures.append("repeated lookup was not captured once")
	if not source.contains("return Helpers.executable()"):
		failures.append("executable default was expanded")
	if result.stats.inline_substituted_args == 0 or result.stats.inline_captured_args == 0:
		failures.append("mixed bindings missing")
	if script.lifetime() != [2, ["make", "deleted", "after"]]:
		failures.append("captured reference outlived its call scope")
	if not source.contains("return Helpers.changing_default()"):
		failures.append("mutable external default was expanded")
	if not source.contains("return Helpers.mutable_default()"):
		failures.append("mutable omitted default was expanded")
	var spaced_source := FileAccess.get_file_as_string(path).replace("\t", "  ")
	spaced_source = spaced_source.replace("static func branch(label:String) -> float:\n", "static func branch(label:String) -> float:\n# Unindented comments do not establish the body indentation.\n")
	var spaced = optimizer.apply(path, Array(spaced_source.split("\n")))
	var spaced_script := GDScript.new()
	spaced_script.source_code = "\n".join(spaced.lines)
	if spaced_script.reload() != OK or spaced_script.branch("y") != 3.0:
		failures.append("space-indented caller did not retain valid nested branches")
	for code:Array in [
		["if value:", "\treturn 1", "return 2"],
		["if value:", "\treturn 1", "if other:", "\treturn 2", "else:", "\treturn 3"],
		["if value:", "\treturn 1", "else:", "\treturn 2", "return 3"],
	]:
		var lines:Array = []
		for line:String in code:
			lines.append({"code": line.strip_edges(), "indent": line.length() - line.strip_edges().length()})
		var grammar = Optimizer.InlinePass.Body._block(lines, 0, 0)
		if grammar.ok and grammar.end == lines.size():
			failures.append("nonterminal control flow was accepted: " + str(code))
	return {"result": failures.size(), "output": ["template inline: %d failures" % failures.size()] + failures}
