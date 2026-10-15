extends RefCounted

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/"

static var _failures:Array = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	_test_prepare_and_replay()
	_test_failure_and_reset()
	_test_selection_and_mapping()
	_test_invalid_tag_attachments()
	var output:Array = ["optimizer: %d passed, %d failed" % [_passed, _failures.size()]]
	output.append_array(_failures)
	return {"result": _failures.size(), "output": output}


static func _sources() -> Dictionary:
	var sources = {}
	for name in ["struct_vec", "struct_fixture", "struct_access", "struct_user", "struct_blind"]:
		var path = BASE + name + ".gd"
		sources[path] = path
	return sources


static func _test_prepare_and_replay() -> void:
	var optimizer = Optimizer.new()
	var context = Optimizer.Context.new()
	var sources = _sources()
	var result = optimizer.prepare(sources, context)
	_check("prepare valid batch", result.errors, [])
	_check("all affected scripts planned", optimizer.planned_files().size(), 5)
	for key in sources:
		var lines = Array(FileAccess.get_file_as_string(key).split("\n"))
		var before = lines.duplicate()
		var edited = optimizer.apply(key, lines)
		_check("replay " + key.get_file(), edited.errors, [])
		_check("input untouched " + key.get_file(), lines, before)
	var blind = _render(optimizer, BASE + "struct_blind.gd")
	_check("injected enum preload", blind.contains('const StructVec = preload("' + BASE + 'struct_vec.gd")'), true)
	var access = _render(optimizer, BASE + "struct_access.gd")
	_check("field rewrite", access.contains("v[StructVec.X]"), true)
	_check("inferred lambda local", access.contains("var y: float = e[StructVec.Y]"), true)
	var first = _render(optimizer, BASE + "struct_fixture.gd")
	optimizer.prepare(sources, context)
	_check("deterministic repeat", _render(optimizer, BASE + "struct_fixture.gd"), first)


static func _test_failure_and_reset() -> void:
	var optimizer = Optimizer.new()
	var context = Optimizer.Context.new()
	var sources = _sources()
	var invalid = BASE + "untyped_scenario.gd"
	sources[invalid] = invalid
	var result = optimizer.prepare(sources, context)
	_check("invalid flow rejects batch", result.errors.is_empty(), false)
	_check("warnings retained separately", result.warnings.is_empty(), false)
	var vec = BASE + "struct_vec.gd"
	var lines = Array(FileAccess.get_file_as_string(vec).split("\n"))
	var blocked = optimizer.apply(vec, lines)
	_check("invalid batch cannot replay", blocked.errors.is_empty(), false)
	_check("invalid batch retains input", blocked.lines, lines)
	optimizer.prepare(_sources(), context)
	var stale = lines.duplicate()
	stale[5] = "var changed: float"
	var replay = optimizer.apply(vec, stale)
	_check("stale body is an error", replay.errors.is_empty(), false)
	_check("failed replay is atomic", replay.lines, stale)
	optimizer.prepare({}, context)
	_check("reset errors", optimizer.errors, [])
	_check("reset plans", optimizer.planned_files(), [])
	_check("no stale edits", optimizer.apply(vec, lines).lines, lines)
	result = optimizer.prepare({"missing": BASE + "missing.gd"}, context)
	_check("missing input is an error", result.errors.size(), 1)


static func _test_selection_and_mapping() -> void:
	var optimizer = Optimizer.new()
	var context = Optimizer.Context.new()
	optimizer.prepare(_sources(), context, [])
	_check("explicitly empty pass selection", optimizer.planned_files(), [])
	var sources = _sources()
	var source = BASE + "struct_vec.gd"
	sources.erase(source)
	sources["res://logical/vec.gd"] = source
	context.map_path = func(key:String) -> String: return "../relocated/" + key.get_file()
	optimizer.prepare(sources, context)
	_check("replacement identity remains logical", optimizer.planned_files().has("res://logical/vec.gd"), true)
	var blind = _render(optimizer, BASE + "struct_blind.gd")
	_check("injection uses host output path", blind.contains('preload("../relocated/vec.gd")'), true)


static func _test_invalid_tag_attachments() -> void:
	var path := "user://optimizer_tag_attachment.gd"
	for source:String in [
		"extends RefCounted\n#! struct",
		"extends RefCounted\nfunc f():\n\t#! struct\n\tprint(1)",
		"extends RefCounted\nfunc f():\n\t#! struct\n\tvar local = 1",
	]:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(source)
		file.close()
		var optimizer = Optimizer.new()
		var result = optimizer.prepare({path: path}, Optimizer.Context.new())
		_check("unsupported struct attachment is reported", result.errors.size(), 1)
	DirAccess.remove_absolute(path)


static func _render(optimizer, key:String) -> String:
	return "\n".join(optimizer.apply(key, Array(FileAccess.get_file_as_string(key).split("\n"))).lines)


static func _check(label:String, actual:Variant, expected:Variant) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("  FAIL %s: expected %s, got %s" % [label, expected, actual])
