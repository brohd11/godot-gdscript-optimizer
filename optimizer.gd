extends RefCounted
## Each preparation owns fresh pass instances. Consumers can replay plans after their own edits,
## or render every file up front before committing any output.

const Context = preload("res://addons/addon_lib/gdscript_optimizer/context.gd")
const Config = preload("res://addons/addon_lib/gdscript_optimizer/config.gd")
const StructPass = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct_pass.gd")
const InlinePass = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline_pass.gd")

var errors:Array = []
var warnings:Array = []
var stats:Dictionary = {}
var _passes:Array = []
var _files:Dictionary = {}


func prepare(sources:Dictionary, context:Context, pass_scripts:Array = [StructPass]) -> Dictionary:
	errors = []
	warnings = []
	stats = {}
	_passes = []
	_files = {}
	if context.struct_mode not in Config.MODES or context.inline_mode not in Config.MODES:
		errors.append("Optimizer modes must be auto, tagged, or off.")
		return {"errors": errors, "warnings": []}
	pass_scripts = pass_scripts.filter(func(pass_script): return not ((pass_script == StructPass and context.struct_mode == "off") or (pass_script == InlinePass and context.inline_mode == "off")))
	context.reset()
	var snapshots:Dictionary = {}
	if InlinePass in pass_scripts:
		for path:String in sources.values():
			if path.get_extension() == "gd" and FileAccess.file_exists(path):
				snapshots[path] = FileAccess.get_file_as_string(path)
	for index in pass_scripts.size():
		var pass_script:GDScript = pass_scripts[index]
		context.source_snapshots = snapshots.duplicate()
		var instance = pass_script.new()
		var result:Dictionary = instance.prepare(sources, context)
		errors.append_array(result.errors)
		warnings.append_array(result.warnings)
		stats.merge(result.get("stats", {}))
		_passes.append(instance)
		for key:String in instance.plans:
			_files[key] = true
		if not snapshots.is_empty() and index < pass_scripts.size() - 1 and errors.is_empty():
			for key:String in instance.plans:
				var path:String = sources[key]
				var staged:Dictionary = instance.apply(key, Array(snapshots[path].split("\n")))
				errors.append_array(staged.errors)
				snapshots[path] = "\n".join(staged.lines)
	return {"errors": errors, "warnings": warnings}


func planned_files() -> Array:
	var paths = _files.keys()
	paths.sort()
	return paths


func apply(key:String, input_lines:Array) -> Dictionary:
	if not errors.is_empty():
		return {"lines": input_lines, "errors": errors}
	var lines = input_lines.duplicate()
	var diagnostics:Array = []
	var stats:Dictionary = {}
	for instance in _passes:
		var result:Dictionary = instance.apply(key, lines)
		if not result.errors.is_empty():
			return {"lines": input_lines, "errors": result.errors}
		lines = result.lines
		diagnostics.append_array(result.get("warnings", []))
		for name:String in result.get("stats", {}):
			stats[name] = stats.get(name, 0) + result.stats[name]
	return {"lines": lines, "errors": [], "warnings": diagnostics, "stats": stats}
