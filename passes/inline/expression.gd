extends RefCounted
## Direct substitutions need their own grammar: template eligibility does not prove purity.

const Types = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/types.gd")
const Arithmetic = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/arithmetic.gd")
const STRING_PREDICATES = {"begins_with": 1, "ends_with": 1, "contains": 1, "is_empty": 0}
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


static func reference_type(type:String) -> bool:
	return Types.is_reference(type) or ClassDB.class_exists(type) or type.begins_with("Packed") or type in ["Callable", "Signal"]


static func admitted(type:String, references:bool, variants:bool) -> bool:
	return type in Types.VALUES or type == "null" or (variants and type == "Variant") or (references and reference_type(type))


func analyze(source:String, params:Dictionary, parser, line:int, column:int, references:bool, variants:bool) -> Dictionary:
	_source = source
	_params = params
	_parser = parser
	_line = line
	_column = column
	_references = references
	_variants = variants
	_index = 0
	_error = ""
	_tokens = []
	var strings:Dictionary = {}
	for token:Dictionary in parser.CodeEditParser.LambdaScanner._tokens(source):
		if token.text == "string" and source[token.offset] in ['"', "'"]:
			strings[token.offset] = token.end
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
	var result := _binary(0)
	if _index != _tokens.size() or _tokens.is_empty():
		_error = "unsupported direct expression"
	return {"error": _error, "type": result.type}


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
		var dynamic:bool = "Variant" in [left.type, right.type]
		if op in ["and", "or"]:
			if not _variants and (left.type != "bool" or right.type != "bool"):
				_error = "boolean operands required"
			left.type = "bool"
		elif op in ["==", "!=", "<", "<=", ">", ">="]:
			if not dynamic and left.type != right.type and not (left.type in ["int", "float"] and right.type in ["int", "float"]) and not (_references and "null" in [left.type, right.type]):
				_error = "comparison requires matching operand types"
			left.type = "bool"
		else:
			if dynamic and _variants:
				left.type = "Variant"
			elif left.type in ["int", "float"] and right.type in ["int", "float"]:
				left.type = "float" if "float" in [left.type, right.type] else "int"
				var numeric := Arithmetic.new().analyze(_source.substr(left.start, right.end - left.start), _params)
				if numeric.error != "":
					_error = numeric.error
			else:
				_error = "unsupported arithmetic operands"
		left.end = right.end
	return left


func _primary() -> Dictionary:
	var value := {"type": "", "start": 0, "end": 0, "lookup": ""}
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
		value = _binary(0)
		value.start = token.start
		if _take(")"):
			value.end = _tokens[_index - 1].end
	elif token.string:
		value.type = "String"
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
		_error = "direct expressions may only reference parameters and literals"
	if not admitted(value.type, _references, _variants):
		_error = "direct expression type is not enabled: " + value.type
	while _peek() in [".", "["]:
		var postfix_start:int = _tokens[_index].start
		var receiver_type:String = value.type
		var dynamic:bool = receiver_type == "Variant" and _variants
		var reference:bool = reference_type(receiver_type) and _references
		if _peek() == "[":
			_index += 1
			_binary(0)
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
			var arguments:Array = []
			var method:bool = _peek() == "("
			if method:
				_index += 1
				if _peek() != ")":
					arguments.append(_binary(0))
					while _peek() == ",":
						_index += 1
						arguments.append(_binary(0))
				if not _take(")"):
					return value
			if receiver_type == "String" and method and STRING_PREDICATES.has(member):
				if arguments.size() != STRING_PREDICATES[member] or arguments.any(func(arg): return arg.type != "String" and not (_variants and arg.type == "Variant")):
					_error = "unsupported String predicate arguments"
				value.type = "bool"
				value.end = _tokens[_index - 1].end
				value.lookup += _source.substr(postfix_start, value.end - postfix_start)
				continue
			if not dynamic and not reference:
				_error = "member expression requires reference or Variant opt-in"
		value.end = _tokens[_index - 1].end
		value.lookup += _source.substr(postfix_start, value.end - postfix_start)
		value.type = "Variant" if dynamic else Types.expression_type(_parser, value.lookup, _line, _column)
		if value.type == "":
			value.type = "Variant"
		if not admitted(value.type, _references, _variants):
			_error = "member result type is not enabled: " + value.type
	return value
