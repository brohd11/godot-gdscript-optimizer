extends RefCounted

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/"

static func run_tests() -> Dictionary:
	var failures:Array = []
	_value_types(failures)
	var path := BASE + "expanded.gd"
	var math := BASE + "math.gd"
	var source := FileAccess.get_file_as_string(path)
	var optimizer = Optimizer.new()
	var prepared = optimizer.prepare({path: path, math: math}, Optimizer.Context.new(), [Optimizer.InlinePass])
	if not prepared.errors.is_empty():
		failures.append(str(prepared.errors))
	var edited = optimizer.apply(path, Array(source.split("\n")))
	var text := "\n".join(edited.lines)
	if edited.stats.inline_expanded_calls != 8 or edited.stats.inline_direct_calls != 1:
		failures.append("expected 8 templates and one nested direct expansion; got " + str(edited.stats))
		print(text)
	var transformed := GDScript.new()
	transformed.source_code = text
	if transformed.reload() != OK:
		return {"result": 1, "output": ["expanded source did not compile", text]}
	var original = load(path)
	original.events = ""
	for method:String in ["order", "values", "text", "fields", "bound", "in_loop", "match_text"]:
		var args:Array = [3] if method == "bound" else []
		if transformed.callv(method, args) != original.callv(method, args):
			failures.append("different result: " + method)
	for value:float in [3.5, -2.5]:
		if transformed.numeric_conversion(value) != original.numeric_conversion(value):
			failures.append("different numeric conversion")
	if transformed.events != "ab" or original.events != "ab":
		failures.append("argument order or unused argument evaluation changed")
	if not text.contains("return false and vector(value, 2.0)") or not text.contains("return 1.0 + vector(value, 2.0)"):
		failures.append("expanded an embedded call")
	if FileAccess.get_file_as_string(path) != source:
		failures.append("source changed")
	if not text.contains("return compute(dynamic, 2)"):
		failures.append("expanded a Variant argument")
	if prepared.warnings.size() != 5:
		failures.append("unsupported definitions missing diagnostics: " + str(prepared.warnings))
	var caller := BASE + "expanded_caller.gd"
	optimizer.prepare({path: path, caller: caller}, Optimizer.Context.new(), [Optimizer.InlinePass])
	var cross = optimizer.apply(caller, Array(FileAccess.get_file_as_string(caller).split("\n")))
	var cross_text := "\n".join(cross.lines)
	var cross_script := GDScript.new()
	cross_script.source_code = cross_text
	if cross_script.reload() != OK:
		failures.append("cross script expansion failed compilation")
	elif cross.stats.inline_expanded_calls != 2:
		failures.append("expected two cross-script expansions: " + str(cross.warnings))
	else:
		for method:String in ["cross", "getter", "shadowed"]:
			if cross_script.call(method) != load(caller).call(method):
				failures.append("different cross result: " + method)
	if not cross_text.contains("return E.absolute(-4.0)") or not cross_text.contains("# retained comment"):
		failures.append("shadowed built-in or comment was rewritten")
	return {"result": failures.size(), "output": ["expanded inline: %d failures" % failures.size()] + failures}


static func _value_types(failures:Array) -> void:
	var samples := {
		"bool": "true", "int": "7", "float": "2.5", "String": '"hello"',
		"StringName": '&"hello"', "NodePath": '^"hello"', "Vector2": "Vector2(1, 2)",
		"Vector2i": "Vector2i(1, 2)", "Vector3": "Vector3(1, 2, 3)", "Vector3i": "Vector3i(1, 2, 3)",
		"Vector4": "Vector4(1, 2, 3, 4)", "Vector4i": "Vector4i(1, 2, 3, 4)",
		"Rect2": "Rect2(1, 2, 3, 4)", "Rect2i": "Rect2i(1, 2, 3, 4)",
		"Transform2D": "Transform2D.IDENTITY", "Transform3D": "Transform3D.IDENTITY",
		"Plane": "Plane(Vector3.UP, 2.0)", "Quaternion": "Quaternion.IDENTITY", "AABB": "AABB()",
		"Basis": "Basis.IDENTITY", "Projection": "Projection.IDENTITY", "Color": "Color(0.25, 0.5, 0.75)", "RID": "RID()",
	}
	var source := "extends RefCounted\n"
	for type:String in samples:
		source += ("\n#! inline\nstatic func identity_%s(value:%s) -> %s:\n" % [type, type, type]
			+ "\tvar copied:%s = value\n\treturn copied\n" % type
			+ "static func sample_%s() -> %s:\n\treturn identity_%s(%s)\n" % [type, type, type, samples[type]])
	var path := "user://expanded_inline_value_types.gd"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(source)
	file.close()
	var optimizer = Optimizer.new()
	var prepared = optimizer.prepare({path: path}, Optimizer.Context.new(), [Optimizer.InlinePass])
	var edited = optimizer.apply(path, Array(source.split("\n")))
	var rendered := GDScript.new()
	rendered.source_code = "\n".join(edited.lines)
	if not prepared.errors.is_empty() or rendered.reload() != OK:
		failures.append("value type batch did not compile")
	else:
		var original = load(path)
		for type:String in samples:
			var method := "sample_" + type
			if rendered.call(method) != original.call(method):
				failures.append("different value type result: " + type)
		if edited.stats.inline_expanded_calls != samples.size():
			failures.append("missing value type expansions: " + str(edited.warnings) + str(prepared.warnings))
	DirAccess.remove_absolute(path)
