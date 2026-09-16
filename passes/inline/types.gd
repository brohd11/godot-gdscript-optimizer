extends RefCounted

const VALUES = ["bool", "int", "float", "String", "StringName", "NodePath", "Vector2", "Vector2i",
	"Vector3", "Vector3i", "Vector4", "Vector4i", "Rect2", "Rect2i", "Transform2D", "Transform3D",
	"Plane", "Quaternion", "AABB", "Basis", "Projection", "Color", "RID"]


static func normalize(type:String, parser, line:int) -> String:
	type = type.trim_suffix(parser.Keys.INS_DELIM).replace(".gd.", ".gd::")
	if type.contains("["):
		var base := type.get_slice("[", 0)
		if base not in ["Array", "Dictionary"]:
			return ""
		var args:Array = parser.Utils.GDScriptParse.safe_split_args(type.substr(base.length() + 1).trim_suffix("]"))
		var parts:Array = []
		for arg:String in args:
			parts.append(normalize(arg.strip_edges(), parser, line))
		return base + "[" + ", ".join(parts) + "]"
	if type in VALUES or type in ["Array", "Dictionary", "Variant", "RefCounted", "null"] or type.contains(".gd"):
		return type
	return expression_type(parser, type, line)


static func expression_type(parser, expression:String, line:int, column:int = -1) -> String:
	var type:String = parser.resolve_expression_to_type(expression, line, column)
	if type.contains(parser.Keys.TYPE_DELIM):
		type = type.get_slice(parser.Keys.TYPE_DELIM, 1)
	return type.trim_suffix(parser.Keys.INS_DELIM).replace(".gd.", ".gd::")


static func is_reference(type:String) -> bool:
	return type == "RefCounted" or type.contains(".gd") or type.get_slice("[", 0) in ["Array", "Dictionary"]


static func supported(type:String, parser) -> bool:
	if type in VALUES or type in ["Array", "Dictionary", "RefCounted"]:
		return true
	if type.contains("["):
		var base := type.get_slice("[", 0)
		if base not in ["Array", "Dictionary"]:
			return false
		for arg:String in parser.Utils.GDScriptParse.safe_split_args(type.substr(base.length() + 1).trim_suffix("]")):
			if arg.strip_edges() != "Variant" and not supported(arg.strip_edges(), parser):
				return false
		return true
	if type.contains(".gd"):
		var parts := type.split("::", true, 1)
		var script = load(parts[0]) as GDScript
		if parts.size() > 1:
			for member:String in parts[1].replace("::", ".").split("."):
				var nested:Variant = script.get_script_constant_map().get(member) if script != null else null
				script = nested if nested is GDScript else null
		return script != null and ClassDB.is_parent_class(script.get_instance_base_type(), "RefCounted")
	return false


static func compatible(actual:String, expected:String) -> bool:
	return actual == expected or (actual in ["int", "float"] and expected in ["int", "float"])


static func emit(type:String, parser, aliases:Dictionary) -> String:
	if type.contains("["):
		var base := type.get_slice("[", 0)
		var parts:Array = []
		for arg:String in parser.Utils.GDScriptParse.safe_split_args(type.substr(base.length() + 1).trim_suffix("]")):
			parts.append(emit(arg.strip_edges(), parser, aliases))
		return base + "[" + ", ".join(parts) + "]"
	if type.contains(".gd"):
		var parts := type.split("::", true, 1)
		return dependency(parts[0], aliases) + ("." + parts[1].replace("::", ".") if parts.size() > 1 else "")
	return type


static func dependency(path:String, aliases:Dictionary) -> String:
	if not aliases.has(path):
		aliases[path] = aliases.prefix + "dep_%d" % aliases.size()
	return aliases[path]
