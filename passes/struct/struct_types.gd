extends RefCounted
## Parser-backed lookups for struct_rewrite.gd's access and flow passes, over one source file. The
## GDScriptParser script is passed in rather than preloaded, so this stays import-free for headless
## suites and consumers can supply their parser dependency.
## Positions are (line, character column): two lambdas on one line are separate scopes.

var parser
var error:String = ""
var structs:Dictionary
var _ins:String
var _type_delim:String


func _init(parser_script:GDScript, source:String, p_structs:Dictionary, cache:Dictionary) -> void:
	structs = p_structs
	_ins = parser_script.Keys.INS_DELIM
	_type_delim = parser_script.Keys.TYPE_DELIM
	var ucd = parser_script.URClassDetail
	if ucd.global_class_registry.is_empty(): # filled by an editor signal, absent headless
		ucd.global_class_registry = ucd.get_all_global_class_paths()

	var script = load(source) as GDScript
	if script == null:
		error = "%s: could not load GDScript" % source
		return
	parser = parser_script.new()
	parser.set_autoload_cache()
	parser.set_parser_cache(cache)
	parser.set_parser_cache_size(-1) # never evicts, so nothing is written to the on-disk parse cache
	parser.active_parser = parser
	parser.set_current_script(script)
	parser.set_source_code(script.source_code)
	parser.parse()


## The callables StructRewrite.check_flow takes.
func lookups() -> Dictionary:
	return {
		"type_of": type_of, "raw_type": raw_type, "return_raw": return_raw, "params": params,
		"lambda_params": lambda_params, "lambda_body": lambda_body, "parameter_types": parameter_types,
	}


## Class path of the struct `expr` holds at the position, or "". A bare class reference resolves
## without the instance mark, so `StructVec` itself never reads as a struct value.
func type_of(expr:String, line:int, column:int = -1) -> String:
	var resolved = _resolve(expr, line, column)
	if not resolved.ends_with(_ins):
		return ""
	var path = resolved.trim_suffix(_ins)
	return path if structs.has(path) else ""


func raw_type(expr:String, line:int, column:int = -1) -> String:
	return _resolve(expr, line, column).trim_suffix(_ins)


## A member read resolves to its declaration ("res://a.gd::y##float"); only the part after the type
## delimiter is the value's type.
func _resolve(expr:String, line:int, column:int) -> String:
	var resolved:String = parser.resolve_expression_to_type(expr, line, column)
	if resolved.contains(_type_delim):
		resolved = resolved.get_slice(_type_delim, 1)
	return resolved


## The annotation a `:=` declaration of `expr` needs once its field reads index an Array: a built-in
## type as the source inferred it, `Array` for a struct or typed collection, or "" to leave it untyped.
func annotation(expr:String, line:int, column:int = -1) -> String:
	var resolved = _resolve(expr, line, column)
	if resolved.ends_with(_ins):
		return "Array" if structs.has(resolved.trim_suffix(_ins)) else ""
	if resolved.begins_with("Array[") or resolved.begins_with("Dictionary["):
		return resolved.get_slice("[", 0)
	return resolved if _variant_types().has(resolved) else ""


static var _variant_type_names:Dictionary = {}

static func _variant_types() -> Dictionary:
	if _variant_type_names.is_empty():
		for i in TYPE_MAX:
			_variant_type_names[type_string(i)] = true
		_variant_type_names.erase("Nil")
		_variant_type_names.erase("Object")
	return _variant_type_names


## Written return type of the innermost lambda or func at the position, e.g. "Array[StructVec]";
## "" when it has none, since the parser would otherwise infer one from the very return being checked.
func return_raw(line:int, column:int = -1) -> String:
	var class_obj = _class_at(line)
	if class_obj == null:
		return ""
	var function = class_obj.get_lambda_at_line(line, column)
	if function == null:
		function = class_obj.functions.get(parser.get_function_at_line(line))
	if function == null or not function.has_static_return():
		return ""
	return function.get_return_type_raw().trim_suffix(_ins)


func _function_arguments(callee:String, line:int, column:int = -1) -> Dictionary:
	var origin:String = parser.resolve_expression_to_type_rich(callee, line, column).get("origin", "")
	if parser.Utils.is_absolute_path(origin) and origin.ends_with(parser.Keys.CALLABLE_SUFFIX):
		var data:Dictionary = parser.get_parser_and_class_obj_for_script(origin)
		var owner = data.get("class_obj")
		if owner == null:
			return {}
		var function = owner.get_function(parser.Utils.type_path_get_member(origin))
		if function == null:
			return {}
		return {"args": function.get_arguments(), "parser": data.parser, "line": function.declaration_line}
	var arguments:Variant = parser.get_function_data(callee, line).get(&"func_args")
	return {"args": arguments, "parser": parser, "line": line} if arguments is Dictionary else {}


func parameter_types(callee:String, line:int, column:int = -1) -> Array:
	var data := _function_arguments(callee, line, column)
	if data.is_empty():
		return []
	var result:Array = []
	for argument:Dictionary in data.args.values():
		var type:String = argument.get(&"type", "").trim_suffix(_ins)
		var resolved:String = data.parser.resolve_expression_to_type(type, data.line).trim_suffix(_ins) if type != "" else ""
		result.append(resolved.get_slice(_type_delim, 1) if resolved.contains(_type_delim) else resolved)
	return result


## has_static_type per parameter of `callee`, or null when the parser cannot find it.
func params(callee:String, line:int, _column:int = -1) -> Variant:
	var args:Variant = _function_arguments(callee, line).get("args")
	if not args is Dictionary or args.is_empty():
		return null
	return _static_flags(args)


## has_static_type per parameter of the lambda bound to `name` as seen from the position, or null.
## Scopes are searched innermost first; within one, the latest binding at or before the line wins.
func lambda_params(name:String, line:int, column:int = -1) -> Variant:
	var class_obj = _class_at(line)
	if class_obj == null:
		return null
	var levels = []
	var stack:Array = class_obj.get_lambda_stack_at_line(line, column)
	for i in range(stack.size() - 1, -1, -1):
		levels.append(stack[i].get_lambdas().values())
	var function = class_obj.functions.get(parser.get_function_at_line(line))
	if function != null:
		levels.append(function.get_lambdas().values())
	levels.append(class_obj.lambdas.values())

	for level in levels:
		var found = null
		for lambda in level:
			# local bindings are keyed "name-line-column"
			if lambda.owner_variable.get_slice("-", 0) != name or lambda.declaration_line > line:
				continue
			if found == null or lambda.declaration_line > found.declaration_line:
				found = lambda
		if found != null:
			return _static_flags(found.get_arguments())
	return null


## True when the position is inside a lambda's body rather than on its declaration line.
func lambda_body(line:int, column:int = -1) -> bool:
	var class_obj = _class_at(line)
	if class_obj == null:
		return false
	var lambda = class_obj.get_lambda_at_line(line, column)
	return lambda != null and lambda.declaration_line < line


func _class_at(line:int):
	return parser.get_class_object(parser.get_class_at_line(line))


static func _static_flags(args:Dictionary) -> Array:
	var out = []
	for arg in args.values():
		out.append(arg.get(&"has_static_type", true))
	return out
