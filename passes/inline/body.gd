extends RefCounted
## Templates retain relative indentation and parameter-use metadata independently of call sites.

const TypeInfo = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/types.gd")
const TYPES = TypeInfo.VALUES
const OPERATORS = ["true", "false", "null", "and", "or", "not", "is", "as", "if", "else"]
const FORBIDDEN = ["await", "func", "for", "while", "match", "self", "super", "load", "preload", ";", "\\"]

static func type_of(parser, expression:String, line:int, column:int = -1) -> String:
	return TypeInfo.expression_type(parser, expression, line, column)

static func compatible(actual:String, expected:String) -> bool:
	return TypeInfo.compatible(actual, expected)


static func assess(parser, statements:Array, params:Dictionary, return_type:String, force:bool = false) -> Dictionary:
	if return_type != "void":
		statements = terminal_returns(statements)
	var metadata := {"symbols": params.duplicate(), "globals": {}, "uses": {}, "effectful": false, "runtime_arithmetic": false, "force": force}
	for name:String in params:
		metadata.uses[name] = {"count": 0, "positions": [], "rebound": false, "written": false, "member": false}
	var grammar := _block(statements, 0, 0)
	var terminal:bool = grammar.ok and grammar.end == statements.size()
	var flow := _flow(statements, 0, 0, return_type == "void")
	if not flow.ok or flow.end != statements.size() or (return_type != "void" and flow.falls):
		return {"error": "body must use supported conditionals and return a value on every path (or declare void)"}
	if not terminal and return_type != "void":
		return {"error": "single-iteration early-return expansion is limited to void helpers"}
	metadata.early_returns = return_type == "void"
	var body:Array = []
	for statement:Dictionary in statements:
		var code:String = statement.code
		if parser.CodeEditParser.LambdaScanner._tokens(code).any(func(token): return token.text in ["/", "%"]):
			metadata.runtime_arithmetic = true
		var expression := ""
		var declared := ""
		var declaration_type := ""
		var returned := code == "return" or code.begins_with("return ")
		if returned:
			expression = "" if code == "return" else code.trim_prefix("return ")
		elif code.begins_with("if ") or code.begins_with("elif "):
			expression = code.substr(code.find(" ") + 1).trim_suffix(":")
		elif code in ["else:", "pass"]:
			pass
		elif code.begins_with("var ") or code.begins_with("const "):
			var data:Variant = parser.Utils.get_var_or_const_info(code)
			if data == null or data[2].is_empty() or metadata.symbols.has(data[0]):
				return {"error": "locals must have unique names and initializers"}
			declared = data[0]
			declaration_type = TypeInfo.normalize(data[1], parser, statement.line)
			if data[1].is_empty():
				if not force and not data[3] and not code.begins_with("const "):
					return {"error": "Variant locals are not supported; use an explicit type or :="}
				declaration_type = type_of(parser, data[2], statement.line) if data[3] or code.begins_with("const ") else "Variant"
			if not TypeInfo.supported(declaration_type, parser, force):
				return {"error": "unsupported local type: " + declaration_type}
			expression = data[2]
		else:
			var assignment := RegEx.new()
			assignment.compile(r"^([A-Za-z_][A-Za-z_0-9]*)(.*?)\s*(?:[+*/%\-]|\*\*)?=(?!=)\s*(.+)$")
			var found := assignment.search(code)
			if found != null:
				var root := found.get_string(1)
				if not metadata.symbols.has(root):
					var external := external_symbol(parser, root, statement.line)
					if external.get("kind", "") != parser.Keys.MEMBER_TYPE_STATIC_VAR:
						return {"error": "assignment must target a parameter, local, or static variable"}
					metadata.effectful = true
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
			"declared": declared, "type": declaration_type,
			"value_type": type_of(parser, expression, statement.line) if returned and expression != "" else ""})
	metadata.body = body
	metadata.return_type = return_type
	return metadata


static func _flow(lines:Array, start:int, indent:int, is_void:bool) -> Dictionary:
	var i := start
	var falls := true
	while i < lines.size() and lines[i].indent >= indent:
		if not falls or lines[i].indent != indent:
			return {"ok": false, "end": i, "falls": falls}
		var code:String = lines[i].code
		if code == "return" or code.begins_with("return "):
			if (code == "return") != is_void:
				return {"ok": false, "end": i, "falls": falls}
			falls = false
			i += 1
		elif code.begins_with("if ") and code.ends_with(":"):
			var has_else := false
			var branch_falls := false
			var first := true
			while i < lines.size() and lines[i].indent == indent:
				code = lines[i].code
				if not (first or code.begins_with("elif ") or code == "else:"):
					break
				if has_else or not code.ends_with(":") or i + 1 >= lines.size() or lines[i + 1].indent <= indent:
					return {"ok": false, "end": i, "falls": falls}
				first = false
				has_else = code == "else:"
				var child := _flow(lines, i + 1, lines[i + 1].indent, is_void)
				if not child.ok:
					return child
				branch_falls = branch_falls or child.falls
				i = child.end
			falls = not has_else or branch_falls
		else:
			if code.ends_with(":") or code.begins_with("return") or code.begins_with("elif ") or code in ["break", "continue"]:
				return {"ok": false, "end": i, "falls": falls}
			i += 1
	return {"ok": true, "end": i, "falls": falls}


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
			if receiver_type not in ["Variant", ""] and not TypeInfo.supported(receiver_type, parser, metadata.get("force", false)):
				return "unsupported member receiver: " + receiver_type
			continue
		if metadata.symbols.has(name):
			if metadata.uses.has(name):
				metadata.uses[name].count += 1
				metadata.uses[name].positions.append({"line": line, "offset": token.offset})
				if i + 1 < tokens.size() and tokens[i + 1].text in [".", "["]:
					metadata.uses[name].member = true
			continue
		var external := external_symbol(parser, name, line)
		if not external.is_empty():
			metadata.globals[name] = external
			metadata.effectful = metadata.effectful or external.get("effectful", false)
			continue
		if owner.get_member_data(name, true) != null:
			return "instance-dependent reference: " + name
		if name in TYPES or name in ["Array", "Dictionary", "RefCounted", "PI", "TAU", "INF", "NAN"] or parser.BuiltInChecker.is_global_method(name):
			metadata.globals[name] = {}
			continue
		var type := type_of(parser, name, line)
		if TypeInfo.supported(type, parser, metadata.get("force", false)):
			metadata.globals[name] = {"type": type}
		else:
			return "unresolved reference: " + name
	return ""


static func external_symbol(parser, name:String, line:int) -> Dictionary:
	var owner = parser.get_class_object(parser.get_class_at_line(line))
	var member:Variant = static_member_data(owner, name)
	if member == null:
		return {}
	var kind:String = member.get("member_type", "")
	if kind not in [parser.Keys.MEMBER_TYPE_CONST, parser.Keys.MEMBER_TYPE_CLASS, parser.Keys.MEMBER_TYPE_ENUM,
		parser.Keys.MEMBER_TYPE_STATIC_VAR, parser.Keys.MEMBER_TYPE_STATIC_FUNC]:
		return {}
	var enums:Variant = owner.get_enum_members(name) if kind == parser.Keys.MEMBER_TYPE_ENUM else {}
	return {"file": owner.get_script_class_path(), "name": name, "kind": kind,
		"enum_members": enums if enums is Dictionary else {},
		"effectful": kind in [parser.Keys.MEMBER_TYPE_STATIC_VAR, parser.Keys.MEMBER_TYPE_STATIC_FUNC]}


static func static_member_data(owner, name:String) -> Variant:
	if owner.functions.has(name):
		return owner.functions[name].member_data
	var member:Variant = owner.get_member_data(name, true)
	return member.get("member_data") if member is Object else member


static func terminal_returns(lines:Array) -> Array:
	if lines.is_empty():
		return lines
	var result := _return_tree(lines, 0, lines[0].indent)
	return result.body if result.end == lines.size() else lines


static func _return_tree(lines:Array, start:int, indent:int) -> Dictionary:
	var failed := {"body": [], "end": start}
	if start >= lines.size() or lines[start].indent != indent:
		return failed
	var code:String = lines[start].code
	if code.begins_with("return "):
		return {"body": [lines[start]], "end": start + 1}
	if not code.begins_with("if "):
		return failed
	var branches:Array = []
	var i := start
	var has_else := false
	var child_indent:int = 0
	while i < lines.size() and lines[i].indent == indent:
		code = lines[i].code
		if not (code.begins_with("if ") and i == start or code.begins_with("elif ") or code == "else:"):
			break
		if not code.ends_with(":") or i + 1 >= lines.size() or lines[i + 1].indent <= indent:
			return failed
		var child := _return_tree(lines, i + 1, lines[i + 1].indent)
		if child.body.is_empty() or (child.end < lines.size() and lines[child.end].indent > indent):
			return failed
		child_indent = lines[i + 1].indent
		branches.append(lines[i])
		branches.append_array(child.body)
		i = child.end
		if code == "else:":
			has_else = true
			break
	if not has_else:
		var tail := _return_tree(lines, i, indent)
		if tail.body.is_empty():
			return failed
		# A following guard becomes elif; a final return becomes the else body.
		if tail.body[0].code.begins_with("if "):
			var header:Dictionary = tail.body[0].duplicate()
			header.code = "elif " + header.code.trim_prefix("if ")
			header.text = " ".repeat(indent) + header.code
			branches.append(header)
			branches.append_array(tail.body.slice(1))
		else:
			var header:Dictionary = lines[start].duplicate()
			header.code = "else:"
			header.text = " ".repeat(indent) + header.code
			branches.append(header)
			for statement:Dictionary in tail.body:
				var moved := statement.duplicate()
				moved.indent += child_indent - indent
				moved.text = " ".repeat(moved.indent) + moved.code
				branches.append(moved)
		i = tail.end
	return {"body": branches, "end": i}


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
