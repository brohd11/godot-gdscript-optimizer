extends RefCounted
## Templates retain relative indentation and parameter-use metadata independently of call sites.

const TypeInfo = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/types.gd")
const TYPES = TypeInfo.VALUES
const OPERATORS = ["true", "false", "null", "and", "or", "not", "is", "as"]
const FORBIDDEN = ["await", "func", "for", "while", "match", "self", "super", "load", "preload", ";", "\\"]

static func type_of(parser, expression:String, line:int, column:int = -1) -> String:
	return TypeInfo.expression_type(parser, expression, line, column)

static func compatible(actual:String, expected:String) -> bool:
	return TypeInfo.compatible(actual, expected)


static func assess(parser, statements:Array, params:Dictionary, return_type:String) -> Dictionary:
	var metadata := {"symbols": params.duplicate(), "globals": {}, "uses": {}, "effectful": false, "runtime_arithmetic": false}
	for name:String in params:
		metadata.uses[name] = {"count": 0, "positions": [], "rebound": false, "written": false, "member": false}
	var grammar := _block(statements, 0, 0)
	if not grammar.ok or grammar.end != statements.size():
		return {"error": "body must end in a return or an exhaustive terminal if/elif/else tree"}
	var body:Array = []
	for statement:Dictionary in statements:
		var code:String = statement.code
		if parser.CodeEditParser.LambdaScanner._tokens(code).any(func(token): return token.text in ["/", "%"]):
			metadata.runtime_arithmetic = true
		var expression := ""
		var declared := ""
		var declaration_type := ""
		var returned := code.begins_with("return ")
		if returned:
			expression = code.trim_prefix("return ")
		elif code.begins_with("if ") or code.begins_with("elif "):
			expression = code.substr(code.find(" ") + 1).trim_suffix(":")
		elif code == "else:":
			pass
		elif code.begins_with("var ") or code.begins_with("const "):
			var data:Variant = parser.Utils.get_var_or_const_info(code)
			if data == null or data[2].is_empty() or metadata.symbols.has(data[0]):
				return {"error": "locals must have unique names and initializers"}
			declared = data[0]
			declaration_type = TypeInfo.normalize(data[1], parser, statement.line)
			if data[1].is_empty():
				if not data[3] and not code.begins_with("const "):
					return {"error": "Variant locals are not supported; use an explicit type or :="}
				declaration_type = type_of(parser, data[2], statement.line)
			if not TypeInfo.supported(declaration_type, parser):
				return {"error": "unsupported local type: " + declaration_type}
			expression = data[2]
		else:
			var assignment := RegEx.new()
			assignment.compile(r"^([A-Za-z_][A-Za-z_0-9]*)(.*?)\s*(?:[+*/%\-]|\*\*)?=(?!=)\s*(.+)$")
			var found := assignment.search(code)
			if found != null:
				var root := found.get_string(1)
				if not metadata.symbols.has(root):
					return {"error": "assignment must target a parameter or local"}
				var tail := found.get_string(2).strip_edges().trim_suffix("+").trim_suffix("-").trim_suffix("*").trim_suffix("/")
				if metadata.uses.has(root):
					metadata.uses[root]["rebound" if tail.is_empty() else "written"] = true
				# Scan the full assignment so indexed targets and compound reads retain their uses.
				expression = code
			else:
				expression = code
				metadata.effectful = true
		var error := _expression(parser, expression, statement.line, metadata)
		if error != "":
			return {"error": error}
		if declared != "":
			metadata.symbols[declared] = declaration_type
		body.append({"text": statement.text, "tokens": parser.CodeEditParser.LambdaScanner._tokens(statement.text), "return": returned, "indent": statement.indent,
			"declared": declared, "type": declaration_type})
	metadata.body = body
	metadata.return_type = return_type
	return metadata


static func _block(lines:Array, start:int, indent:int) -> Dictionary:
	var i := start
	while i < lines.size() and lines[i].indent == indent:
		var code:String = lines[i].code
		if code.begins_with("return "):
			return {"ok": true, "end": i + 1}
		if code.begins_with("if ") and code.ends_with(":"):
			var has_else := false
			var first := true
			while i < lines.size() and lines[i].indent == indent:
				code = lines[i].code
				if not ((first and code.begins_with("if ")) or code.begins_with("elif ") or code == "else:"):
					break
				first = false
				if has_else or i + 1 >= lines.size() or lines[i + 1].indent <= indent:
					return {"ok": false, "end": i}
				has_else = code == "else:"
				var child := _block(lines, i + 1, lines[i + 1].indent)
				if not child.ok:
					return child
				i = child.end
			return {"ok": has_else, "end": i}
		if code.ends_with(":") or code.begins_with("return"):
			return {"ok": false, "end": i}
		i += 1
	return {"ok": false, "end": i}


static func _expression(parser, expression:String, line:int, metadata:Dictionary) -> String:
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(expression)
	var owner = parser.get_class_object(parser.get_class_at_line(line))
	for i in tokens.size():
		var token:Dictionary = tokens[i]
		var name:String = token.text
		if expression.substr(token.offset, token.end - token.offset) != name:
			continue
		var member:bool = i > 0 and tokens[i - 1].text == "."
		if _dictionary_key(tokens, i):
			continue
		if name in FORBIDDEN and not member:
			return "unsupported construct: " + name
		if not name.is_valid_ascii_identifier() or name in OPERATORS:
			continue
		if i + 1 < tokens.size() and tokens[i + 1].text == "(":
			metadata.effectful = true
		if member:
			var start := _receiver_start(tokens, i - 2)
			var receiver := expression.substr(tokens[start].offset, tokens[i - 1].offset - tokens[start].offset)
			var receiver_type := type_of(parser, receiver, line)
			if receiver_type not in ["Variant", ""] and not TypeInfo.supported(receiver_type, parser):
				return "unsupported member receiver: " + receiver_type
			if i + 1 < tokens.size() and tokens[i + 1].text == "(":
				var root:String = tokens[start].text
				if not metadata.symbols.has(root) and receiver_type.contains(".gd") and name != "new":
					return "nested script helper calls are deferred"
			continue
		if metadata.symbols.has(name):
			if metadata.uses.has(name):
				metadata.uses[name].count += 1
				metadata.uses[name].positions.append({"line": line, "offset": token.offset})
				if i + 1 < tokens.size() and tokens[i + 1].text in [".", "["]:
					metadata.uses[name].member = true
			continue
		var external:Variant = owner.get_member_data(name, true)
		if external != null:
			if external.get("member_type") not in [parser.Keys.MEMBER_TYPE_CONST, parser.Keys.MEMBER_TYPE_CLASS, parser.Keys.MEMBER_TYPE_ENUM]:
				return "script functions and mutable external bindings are unsupported: " + name
			metadata.globals[name] = {"file": owner.get_script_class_path().get_slice("::", 0), "name": name}
			continue
		if name in TYPES or name in ["Array", "Dictionary", "RefCounted", "PI", "TAU", "INF", "NAN"] or parser.BuiltInChecker.is_global_method(name):
			metadata.globals[name] = {}
			continue
		var type := type_of(parser, name, line)
		if TypeInfo.supported(type, parser):
			metadata.globals[name] = {"type": type}
		else:
			return "unresolved reference: " + name
	return ""


static func rename(parser, source:String, bindings:Dictionary, slots:Array = []) -> String:
	var tokens:Array = slots if not slots.is_empty() else parser.CodeEditParser.LambdaScanner._tokens(source)
	for i in range(tokens.size() - 1, -1, -1):
		var token:Dictionary = tokens[i]
		if (bindings.has(token.text) and (i == 0 or tokens[i - 1].text != ".") and not _dictionary_key(tokens, i)
				and source.substr(token.offset, token.end - token.offset) == token.text):
			source = source.substr(0, token.offset) + bindings[token.text] + source.substr(token.end)
	return source


static func _dictionary_key(tokens:Array, index:int) -> bool:
	return index > 0 and index + 1 < tokens.size() and tokens[index - 1].text in ["{", ","] and tokens[index + 1].text == "="


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
