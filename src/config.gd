extends RefCounted
## Shared policy for project exports, plugin packaging, and programmatic consumers.

const DEFAULTS = {"struct_mode": "tagged", "inline_mode": "tagged", "aggressive": false, "debug_tags": false}
const MODES = ["auto", "tagged", "off"]


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
		if not DEFAULTS.has(key):
			errors.append("Unknown optimizer option: %s" % str(key))
		elif key in ["struct_mode", "inline_mode"]:
			if not data[key] is String or data[key] not in MODES:
				errors.append("%s must be auto, tagged, or off." % key)
			else:
				options[key] = data[key]
		elif not data[key] is bool:
			errors.append("%s must be a boolean." % key)
		else:
			options[key] = data[key]
	return {"options": options if errors.is_empty() else {}, "errors": errors}
