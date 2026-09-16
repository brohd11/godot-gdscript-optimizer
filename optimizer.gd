extends RefCounted
## Each preparation owns fresh pass instances. Consumers can replay plans after their own edits,
## or render every file up front before committing any output.

const Context = preload("res://addons/addon_lib/gdscript_optimizer/context.gd")
const StructPass = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct_pass.gd")

var errors:Array = []
var warnings:Array = []
var _passes:Array = []
var _files:Dictionary = {}


func prepare(sources:Dictionary, context:Context, pass_scripts:Array = [StructPass]) -> Dictionary:
	errors = []
	warnings = []
	_passes = []
	_files = {}
	context.reset()
	for pass_script:GDScript in pass_scripts:
		var instance = pass_script.new()
		var result:Dictionary = instance.prepare(sources, context)
		errors.append_array(result.errors)
		warnings.append_array(result.warnings)
		_passes.append(instance)
		for key:String in instance.plans:
			_files[key] = true
	return {"errors": errors, "warnings": warnings}


func planned_files() -> Array:
	var paths = _files.keys()
	paths.sort()
	return paths


func apply(key:String, input_lines:Array) -> Dictionary:
	if not errors.is_empty():
		return {"lines": input_lines, "errors": errors}
	var lines = input_lines.duplicate()
	for instance in _passes:
		var result:Dictionary = instance.apply(key, lines)
		if not result.errors.is_empty():
			return {"lines": input_lines, "errors": result.errors}
		lines = result.lines
	return {"lines": lines, "errors": []}
