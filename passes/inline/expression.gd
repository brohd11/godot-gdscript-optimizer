extends RefCounted
## Direct substitutions need their own grammar: template eligibility does not prove purity.

const Types = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/types.gd")
const Arithmetic = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/arithmetic.gd")
const Body = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/body.gd")
const STRING_METHODS = {"begins_with": ["bool", "String"], "ends_with": ["bool", "String"],
	"contains": ["bool", "String"], "is_empty": ["bool"], "get_slice": ["String", "String", "int"],
	"trim_prefix": ["String", "String"], "trim_suffix": ["String", "String"]}
const PRIORITY = {"or": 1, "and": 2, "==": 4, "!=": 4, "<": 4, "<=": 4, ">": 4, ">=": 4,
	"+": 5, "-": 5, "*": 6, "/": 6, "%": 6}

var _source:String
var _tokens:Array
var _index:int
var _params:Dictionary
var _parser
var _line:int
var _column:int
var _references:bool
var _variants:bool
var _error:String
var _globals:Dictionary
var _external_types:Dictionary
var _effectful:bool


static func reference_type(type:String) -> bool:
	return Types.is_reference(type) or ClassDB.class_exists(type) or type.begins_with("Packed") or type in ["Callable", "Signal"]


static func admitted(type:String, references:bool, variants:bool) -> bool:
	return type in Types.VALUES or type == "null" or (variants and type == "Variant") or (references and reference_type(type))


func analyze(source:String, params:Dictionary, parser, line:int, column:int, references:bool, variants:bool, globals:Dictionary = {}) -> Dictionary:
	_source = source
	_params = params
	_parser = parser
	_line = line
	_column = column
	_references = references
	_variants = variants
	_index = 0
	_error = ""
	_globals = {}
	_external_types = globals
	_effectful = false
	_tokens = []
	var strings:Dictionary = {}
	for token:Dictionary in parser.CodeEditParser.LambdaScanner._tokens(source):
		if token.text == "string" and source[token.offset] in ['"', "'"]:
			strings[token.offset] = token.end
			if token.offset > 0 and source[token.offset - 1] == "&":
				strings[token.offset - 1] = token.end
	var regex := RegEx.create_from_string(r"(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[A-Za-z_][A-Za-z_0-9]*|==|!=|<=|>=|[().,\[\]+*/%<>-]")
	var offset := 0
	while offset < source.length():
		if source[offset] in [" ", "\t", "\r", "\n"]:
			offset += 1
			continue
		var end:int
		var token_text:String
		if strings.has(offset):
			end = strings[offset]
			token_text = "string"
		else:
			var found := regex.search(source, offset)
			if found == null or found.get_start() != offset:
				return {"error": "unsupported direct expression token", "type": ""}
			end = found.get_end()
			token_text = found.get_string()
		_tokens.append({"string": strings.has(offset), "text": token_text, "start": offset, "end": end})
		offset = end
	var result := _conditional()
	if _index != _tokens.size() or _tokens.is_empty():
		_error = "unsupported direct expression"
	return {"error": _error, "type": result.type, "globals": _globals, "effectful": _effectful}


func _conditional() -> Dictionary:
	var value := _binary(0)
	if _peek() != "if":
		return value
	_index += 1
	var condition := _binary(0)
	if condition.type != "bool" and not _variants:
		_error = "boolean condition required"
	if not _take("else"):
		return value
	var other := _conditional()
	value.external_constant = value.external_constant or condition.external_constant or other.external_constant
	# A mixed branch type needs a conversion unless unchecked substitution is enabled.
	if value.type != other.type:
		value.type = "Variant"
		if not _variants:
			_error = "conditional branches require matching types"
	value.end = other.end
	return value


func _peek() -> String:
	return _tokens[_index].text if _index < _tokens.size() else ""


func _take(text:String) -> bool:
	if _peek() != text:
		_error = "expected " + text
		return false
	_index += 1
	return true


func _binary(minimum:int) -> Dictionary:
	var left := _primary()
	while _index < _tokens.size() and PRIORITY.get(_peek(), -1) >= minimum:
		var op := _peek()
		_index += 1
		var right := _binary(PRIORITY[op] + 1)
		if op in ["/", "%"] and right.external_constant:
			_error = "constant divisor requires capture"
		left.external_constant = left.external_constant or right.external_constant
		var dynamic:bool = "Variant" in [left.type, right.type]
		if op in ["and", "or"]:
			if not _variants and (left.type != "bool" or right.type != "bool"):
				_error = "boolean operands required"
			left.type = "bool"
		elif op in ["==", "!=", "<", "<=", ">", ">="]:
			if not dynamic and left.type != right.type and not (left.type in ["int", "float"] and right.type in ["int", "float"]) and not (left.type in ["String", "StringName"] and right.type in ["String", "StringName"]) and not (_references and "null" in [left.type, right.type]):
				_error = "comparison requires matching operand types"
			left.type = "bool"
		else:
			if dynamic and _variants:
				left.type = "Variant"
			elif op == "+" and left.type in ["String", "StringName"] and right.type in ["String", "StringName"]:
				left.type = "String"
			elif left.type in ["int", "float"] and right.type in ["int", "float"]:
				left.type = "float" if "float" in [left.type, right.type] else "int"
				if op == "%" and left.type != "int":
					_error = "remainder requires integers"
				if op in ["/", "%"]:
					var divisor := Arithmetic.new().analyze(_source.substr(right.start, right.end - right.start), _params)
					if divisor.get("known", false) and divisor.get("value") == 0:
						_error = "constant zero divisor"
			else:
				_error = "unsupported arithmetic operands"
		left.end = right.end
	return left


func _primary() -> Dictionary:
	var value := {"type": "", "start": 0, "end": 0, "lookup": "", "static": false, "enum_members": {}, "external_constant": false}
	if _index >= _tokens.size():
		_error = "missing expression operand"
		return value
	var token:Dictionary = _tokens[_index]
	_index += 1
	value.start = token.start
	value.end = token.end
	value.lookup = _source.substr(token.start, token.end - token.start)
	var name:String = token.text
	if name in ["not", "+", "-"]:
		value = _binary(3) if name == "not" else _primary()
		value.start = token.start
		if name == "not":
			if value.type != "bool" and not _variants:
				_error = "boolean operand required"
			value.type = "bool"
		elif value.type not in ["int", "float"] and not (_variants and value.type == "Variant"):
			_error = "numeric operand required"
		return value
	elif name == "(":
		value = _conditional()
		value.start = token.start
		if _take(")"):
			value.end = _tokens[_index - 1].end
	elif token.string:
		value.type = "StringName" if _source[token.start] == "&" else "String"
	elif name in ["true", "false"]:
		value.type = "bool"
	elif name == "null":
		value.type = "null"
	elif name.is_valid_int():
		value.type = "int"
	elif name.is_valid_float():
		value.type = "float"
	elif _params.has(name):
		value.type = _params[name]
	else:
		var external:Dictionary = _external_types.get(name, Body.external_symbol(_parser, name, _line))
		var raw:String = _parser.resolve_expression_to_type(name, _line, _column)
		if external.is_empty() and raw.contains(".gd") and not raw.ends_with(_parser.Keys.INS_DELIM):
			external = {"type": Types.normalize(raw, _parser, _line)}
		if external.is_empty():
			_error = "unresolved or instance-dependent reference: " + name
		else:
			external = external.duplicate()
			value.type = external.get("value_type", Types.expression_type(_parser, name, _line, _column))
			value.external_constant = external.get("kind", "") == _parser.Keys.MEMBER_TYPE_CONST and value.type in ["int", "float"]
			value.enum_members = external.get("enum_members", {})
			value.static = not value.enum_members.is_empty() or external.get("static", value.type.contains(".gd") and not raw.ends_with(_parser.Keys.INS_DELIM))
			external.value_type = value.type
			external.static = value.static
			_globals[name] = external
			_effectful = _effectful or external.get("effectful", false)
			if external.get("kind", "") == _parser.Keys.MEMBER_TYPE_STATIC_FUNC and _peek() == "(":
				_arguments()
				value.end = _tokens[_index - 1].end
				value.type = external.get("return_type", _parser.get_class_object(_parser.get_class_at_line(_line)).get_member_type(name, true))
				value.type = Types.normalize(value.type, _parser, _line)
				external.return_type = value.type
	if not value.static and not admitted(value.type, _references, _variants):
		_error = "direct expression type is not enabled: " + value.type
	while _peek() in [".", "["]:
		var postfix_start:int = _tokens[_index].start
		var receiver_type:String = value.type
		var known_type := ""
		var dynamic:bool = receiver_type == "Variant" and _variants
		var reference:bool = reference_type(receiver_type) and _references
		if _peek() == "[":
			if receiver_type.contains("["):
				var elements:Array = _parser.Utils.MemberParse.safe_split_args(receiver_type.substr(receiver_type.find("[") + 1).trim_suffix("]"))
				known_type = elements[-1].strip_edges() if not elements.is_empty() else ""
			_index += 1
			_conditional()
			if not _take("]"):
				return value
			if not dynamic and not reference:
				_error = "indexed expressions require reference or Variant opt-in"
		else:
			_index += 1
			var member := _peek()
			if not member.is_valid_ascii_identifier():
				_error = "missing member name"
				return value
			_index += 1
			known_type = _member_type(receiver_type, member)
			var static_member:Dictionary = {}
			if not value.enum_members.is_empty():
				if value.enum_members.has(member):
					static_member = {"member_type": _parser.Keys.MEMBER_TYPE_CONST}
					known_type = "int"
			elif value.static:
				static_member = _static_member(receiver_type, member)
			value.external_constant = static_member.get("member_type", "") == _parser.Keys.MEMBER_TYPE_CONST and known_type in ["int", "float"]
			if value.static and static_member.is_empty():
				_error = "unresolved or instance-dependent static member: " + member
			var arguments:Array = []
			var method:bool = _peek() == "("
			if method:
				arguments = _arguments()
			if receiver_type in ["String", "StringName"] and method and STRING_METHODS.has(member):
				var signature:Array = STRING_METHODS[member]
				if arguments.size() != signature.size() - 1:
					_error = "unsupported String method arguments"
				for i in mini(arguments.size(), signature.size() - 1):
					if arguments[i].type != signature[i + 1] and not (signature[i + 1] == "String" and arguments[i].type == "StringName") and not (_variants and arguments[i].type == "Variant"):
						_error = "unsupported String method argument type"
				value.type = signature[0]
				value.static = false
				value.end = _tokens[_index - 1].end
				value.lookup += _source.substr(postfix_start, value.end - postfix_start)
				continue
			_effectful = _effectful or method or static_member.get("member_type", "") == _parser.Keys.MEMBER_TYPE_STATIC_VAR or not value.static
			if not dynamic and not reference and not value.static:
				_error = "member expression requires reference or Variant opt-in"
			value.enum_members = static_member.get("enum_members", {})
			value.static = not value.enum_members.is_empty() or (value.static and not method and static_member.get("member_type", "") in [_parser.Keys.MEMBER_TYPE_CONST, _parser.Keys.MEMBER_TYPE_CLASS] and known_type.contains(".gd"))
		value.end = _tokens[_index - 1].end
		value.lookup += _source.substr(postfix_start, value.end - postfix_start)
		value.type = "Variant" if dynamic else (known_type if known_type != "" else Types.expression_type(_parser, value.lookup, _line, _column))
		if value.type == "":
			value.type = "Variant"
		if not value.static and not admitted(value.type, _references, _variants):
			_error = "member result type is not enabled: " + value.type
	return value


func _arguments() -> Array:
	var arguments:Array = []
	_take("(")
	if _peek() != ")":
		arguments.append(_conditional())
		while _peek() == ",":
			_index += 1
			arguments.append(_conditional())
	_take(")")
	return arguments


func _static_member(type:String, member:String) -> Dictionary:
	if not type.contains(".gd"):
		return {}
	var parts := type.split("::", true, 1)
	var dependency = _parser.get_parser_for_path(parts[0])
	var owner = dependency.get_class_object(parts[1].replace("::", ".") if parts.size() > 1 else "")
	var data:Variant = Body.static_member_data(owner, member) if owner != null else null
	if data is Dictionary and data.get("member_type") in [_parser.Keys.MEMBER_TYPE_CONST, _parser.Keys.MEMBER_TYPE_CLASS,
		_parser.Keys.MEMBER_TYPE_ENUM, _parser.Keys.MEMBER_TYPE_STATIC_VAR, _parser.Keys.MEMBER_TYPE_STATIC_FUNC]:
		var result:Dictionary = data.duplicate()
		if data.get("member_type") == _parser.Keys.MEMBER_TYPE_ENUM:
			var enums:Variant = owner.get_enum_members(member)
			result.enum_members = enums if enums is Dictionary else {}
		return result
	return {}


func _member_type(type:String, member:String) -> String:
	if type.contains(".gd"):
		var parts := type.split("::", true, 1)
		var dependency = _parser.get_parser_for_path(parts[0])
		var owner = dependency.get_class_object(parts[1].replace("::", ".") if parts.size() > 1 else "")
		if owner != null:
			return owner.get_member_type(member, true).trim_suffix(_parser.Keys.INS_DELIM).replace(".gd.", ".gd::")
	return _parser.BuiltInChecker.get_member_type(type.get_slice("[", 0), member)
