extends RefCounted
## Export defaults are separate from Context's conservative programmatic defaults.

const DEFAULTS = {"debug_tags": false, "structs": true, "inline_functions": true, "scalar_replacement": true,
	"struct_read_types": "typed_locals", "scalar_replacement_allow_ref_counted": false, "struct_read_types_allow_ref_counted": false,
	"inline_functions_allow_ref_counted": false, "inline_functions_allow_variants": false}
const READ_MODES = ["off", "typed_locals", "as_casts"]


static func from_file(path:String = "") -> Dictionary:
	if path.is_empty():
		return from_dictionary({})
	if not path.is_absolute_path():
		path = "res://" + path
	var parser = YAMLParser.new()
	if parser.parse_all_file(path) != OK:
		return {"options": {}, "errors": ["%s: %s" % [path, parser.get_error_message()]]}
	if parser.data.size() != 1:
		return {"options": {}, "errors": ["%s: expected one YAML mapping document." % path]}
	var result := from_dictionary(parser.data[0])
	for index in result.errors.size():
		result.errors[index] = "%s: %s" % [path, result.errors[index]]
	return result


static func from_dictionary(data:Variant) -> Dictionary:
	var errors:Array = []
	var options := DEFAULTS.duplicate()
	if not data is Dictionary:
		return {"options": {}, "errors": ["Optimizer config must be a YAML mapping."]}
	for key in data:
		if key == "allow_ref_counted":
			errors.append("allow_ref_counted was replaced by scalar_replacement_allow_ref_counted and struct_read_types_allow_ref_counted.")
		elif not DEFAULTS.has(key):
			errors.append("Unknown optimizer option: %s" % str(key))
		elif key == "struct_read_types":
			if not data[key] is String or data[key] not in READ_MODES:
				errors.append("struct_read_types must be off, typed_locals, or as_casts.")
			else:
				options[key] = data[key]
		elif not data[key] is bool:
			errors.append("%s must be a boolean." % key)
		else:
			options[key] = data[key]
	options.struct_read_types = READ_MODES.find(options.struct_read_types)
	return {"options": options if errors.is_empty() else {}, "errors": errors}
