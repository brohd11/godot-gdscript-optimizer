extends RefCounted
## Assess straight-line value computations and rewrite identifiers by their syntactic role.

const TYPES = ["bool", "int", "float", "String", "StringName", "NodePath", "Vector2", "Vector2i",
	"Vector3", "Vector3i", "Vector4", "Vector4i", "Rect2", "Rect2i", "Transform2D", "Transform3D",
	"Plane", "Quaternion", "AABB", "Basis", "Projection", "Color", "RID"]
const OPERATORS = ["true", "false", "and", "or", "not", "is", "as"]
const FORBIDDEN = ["await", "func", "return", "if", "else", "for", "while", "match", "self", "super",
	"preload", "load", "[", "]", "{", "}", ";", "\\"]


static func type_of(parser, expression:String, line:int, column:int = -1) -> String:
	var type:String = parser.resolve_expression_to_type(expression, line, column)
	if type.contains(parser.Keys.TYPE_DELIM):
		type = type.get_slice(parser.Keys.TYPE_DELIM, 1)
	return type.trim_suffix(parser.Keys.INS_DELIM)


static func compatible(actual:String, expected:String) -> bool:
	return actual == expected or (actual in ["int", "float"] and expected in ["int", "float"])


static func assess(parser, statements:Array, params:Dictionary, return_type:String) -> Dictionary:
	var symbols := params.duplicate()
	var globals:Dictionary = {}
	var body:Array = []
	var returned := false
	for statement:Dictionary in statements:
		var code:String = statement.code
		var expression := ""
		var declared := ""
		if returned:
			return {"error": "only one final return is supported"}
		if code.begins_with("return "):
			expression = code.trim_prefix("return ")
			returned = true
		elif code.begins_with("var ") or code.begins_with("const "):
			var data:Variant = parser.Utils.get_var_or_const_info(code)
			if data == null or data[2].is_empty() or symbols.has(data[0]):
				return {"error": "locals must have unique names and initializers"}
			declared = data[0]
			var type:String = data[1]
			if type.is_empty():
				if not data[3] and not code.begins_with("const "):
					return {"error": "Variant locals are not supported; use an explicit type or :="}
				type = type_of(parser, data[2], statement.line)
			if type not in TYPES:
				return {"error": "local types must be built-in values"}
			expression = data[2]
			statement = statement.duplicate()
			statement["local_type"] = type
		else:
			var assignment := RegEx.new()
			assignment.compile(r"^([A-Za-z_][A-Za-z_0-9]*)\s*(?:[+*/%\-]|\*\*)?=\s*(.+)$")
			var found := assignment.search(code)
			if found == null or not symbols.has(found.get_string(1)):
				return {"error": "body statements must declare or assign locals, then return"}
			expression = found.get_string(2)
		var error := _expression(parser, expression, statement.line, symbols, globals)
		if error != "":
			return {"error": error}
		if returned and not compatible(type_of(parser, expression, statement.line), return_type):
			return {"error": "return expression must resolve to a compatible built-in value"}
		if declared != "":
			symbols[declared] = statement.local_type
		body.append({"text": statement.text, "return": returned})
	if not returned:
		return {"error": "the body must end in a value return"}
	return {"body": body, "symbols": symbols, "globals": globals}


static func _expression(parser, expression:String, line:int, symbols:Dictionary, globals:Dictionary) -> String:
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(expression)
	var owner = parser.get_class_object(parser.get_class_at_line(line))
	for i in tokens.size():
		var token:Dictionary = tokens[i]
		var name:String = token.text
		if expression.substr(token.offset, token.end - token.offset) != name:
			continue
		if name in FORBIDDEN and (i == 0 or tokens[i - 1].text != "."):
			return "unsupported expression construct: " + name
		if not name.is_valid_ascii_identifier() or name in OPERATORS:
			continue
		if i > 0 and tokens[i - 1].text == ".":
			var start := _receiver_start(tokens, i - 2)
			var receiver := expression.substr(tokens[start].offset, tokens[i - 1].offset - tokens[start].offset)
			if receiver not in TYPES and type_of(parser, receiver, line) not in TYPES:
				return "member receivers must be built-in values"
			if i + 1 < tokens.size() and tokens[i + 1].text == "(":
				var end:int = parser.CodeEditParser.LambdaScanner._matching(tokens, i + 1)
				if end < 0 or type_of(parser, expression.substr(tokens[start].offset, tokens[end].end - tokens[start].offset), line) not in TYPES:
					return "method results must be built-in values"
			continue
		if symbols.has(name):
			continue
		if owner.get_member_data(name, true) != null:
			return "script-member references are not supported: " + name
		if name not in TYPES and name not in ["PI", "TAU", "INF", "NAN"] and not parser.BuiltInChecker.is_global_method(name):
			return "unresolved or non-built-in reference: " + name
		if parser.BuiltInChecker.is_global_method(name):
			if i + 1 >= tokens.size() or tokens[i + 1].text != "(":
				return "callable references are not supported"
			var end:int = parser.CodeEditParser.LambdaScanner._matching(tokens, i + 1)
			if end < 0 or type_of(parser, expression.substr(token.offset, tokens[end].end - token.offset), line) not in TYPES:
				return "built-in function results must be built-in values"
		globals[name] = true
	var type := type_of(parser, expression, line)
	return "" if type in TYPES else "expression must resolve to a built-in value"


static func _receiver_start(tokens:Array, end:int) -> int:
	var start := end
	var depth := 0
	while start >= 0:
		var text:String = tokens[start].text
		if text == ")":
			depth += 1
		elif text == "(":
			if depth == 0:
				break
			depth -= 1
		elif depth == 0 and (text in ["+", "-", "*", "/", "%", ",", "=", "<", ">", "&", "|", "!", "^"] or text in OPERATORS):
			break
		start -= 1
	return start + 1


static func rename(parser, source:String, bindings:Dictionary) -> String:
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(source)
	for i in range(tokens.size() - 1, -1, -1):
		var token:Dictionary = tokens[i]
		if (bindings.has(token.text) and (i == 0 or tokens[i - 1].text != ".")
				and source.substr(token.offset, token.end - token.offset) == token.text):
			source = source.substr(0, token.offset) + bindings[token.text] + source.substr(token.end)
	return source
