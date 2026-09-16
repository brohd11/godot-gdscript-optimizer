extends RefCounted
## Source identities stay stable while consumers choose output paths and global-name policy.
## Optional callbacks let a packaging host reuse its own reference and relocation rules.

const UtilsRemote = preload("res://addons/addon_lib/gdscript_optimizer/utils_remote.gd")

enum StructReadTypes { OFF, TYPED_LOCALS, AS_CASTS }

var parser_script:GDScript = UtilsRemote.GDScriptParser
var class_list:Dictionary = {}
var class_path_lookup:Dictionary = {}
var removed_globals:Dictionary = {}
var map_path:Callable
var scan_references:Callable
var injection_header:String = "### GDScript Optimizer Structs"
var source_snapshots:Dictionary = {}
var scalar_replacement:bool = false
var allow_ref_counted:bool = false
var struct_read_types:StructReadTypes = StructReadTypes.OFF

var _scanner
var _references:Dictionary = {}


func set_global_classes(classes:Dictionary) -> void:
	class_list = classes.duplicate()
	class_path_lookup.clear()
	for name:String in class_list:
		class_path_lookup[class_list[name]] = name
	reset()


func reset() -> void:
	source_snapshots = {}
	_references.clear()
	_scanner = null


func output_path(key:String) -> String:
	return map_path.call(key) if map_path.is_valid() else key


func resolve_name(script:GDScript, name:String) -> Variant:
	return parser_script.UClassDetail.resolve_script_access_path(script, name)


func references(path:String) -> Array:
	if _references.has(path):
		return _references[path]
	var paths:Array = []
	if scan_references.is_valid():
		paths = scan_references.call(path)
	else:
		if _scanner == null:
			_scanner = UtilsRemote.Dependencies.new()
			_scanner.max_depth = 1
			_scanner.include_missing = false
			_scanner.use_project_classes = false
			_scanner.class_map = class_list
		_scanner.roots = [path]
		var graph = _scanner.get_graph()
		for edge in graph.get_out_edges(path):
			if edge.to != "" and not paths.has(edge.to):
				paths.append(edge.to)
	_references[path] = paths
	return paths
