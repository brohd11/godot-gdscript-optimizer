extends RefCounted
## Optional rewrites retain original bindings and positions until every edit is planned.
## Newlines are inserted only at replay, so the existing struct body edits stay addressable.

const ValueTypes = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/types.gd")
const Rewrite = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct/struct_rewrite.gd")

var stats:Dictionary = {"scalar_structs": 0, "scalar_accesses": 0, "scalar_skipped": 0,
	"struct_typed_captures": 0, "struct_read_casts": 0, "struct_reads_skipped": 0}
var warnings:Array = []
var debug_events:Array = []
var declarations:Dictionary = {}
var prefixes:Dictionary = {}
var _scalars:Dictionary = {}
var _field_types:Dictionary = {}
var _types
var _lines:PackedStringArray
var _tokens:Array
var _mode:int
var _scalar_references:bool
var _read_references:bool
var type_dependencies:Dictionary = {}
var _source:String
var _prefix:String
var _codes:PackedStringArray = []
var _complete:Dictionary = {}


func _init(lines:PackedStringArray, types, context) -> void:
	_lines = lines
	_types = types
	_mode = context.struct_read_types
	_scalar_references = context.scalar_replacement_allow_ref_counted
	_read_references = context.struct_read_types_allow_ref_counted
	_source = types.parser.get_script_path()
	var source := "\n".join(lines)
	_prefix = "_struct_opt_"
	while source.contains(_prefix):
		_prefix += "x_"
	_tokens = types.parser.CodeEditParser.LambdaScanner._tokens(source)
	var state := {"quote": "", "depth": 0, "cont": false}
	for line in lines.size():
		var continued:bool = state.cont or state.quote != ""
		var comment:int = Rewrite.TagRegistry.scan_code(lines[line], state)
		_codes.append(lines[line].substr(0, comment) if comment >= 0 else lines[line])
		_complete[line] = not continued and not state.cont and state.quote == ""
	if context.scalar_replacement:
		_find_scalars()


func field_type(path:String, field:String) -> String:
	var key := path + "|" + field
	if _field_types.has(key):
		return _field_types[key]
	var def:Dictionary = _types.structs[path]
	var result := ""
	for item:Dictionary in def.fields:
		if item.name != field:
			continue
		var parser = _types.parser.get_parser_for_path(def.file)
		var owner = parser.get_class_object(parser.get_class_at_line(item.line))
		var declaration:Variant = parser.Utils.get_var_or_const_info(parser.code_edit.get_line(item.line).strip_edges())
		if declaration != null and (item.type != "" or declaration[3]):
			result = owner.get_member_type(field).trim_suffix(parser.Keys.INS_DELIM)
	_field_types[key] = result
	return result


func _supported_type(type:String, allow_references:bool) -> bool:
	if type in ValueTypes.VALUES:
		return true
	if not allow_references or type in ["", "Variant", "null"]:
		return false
	if type.contains("["):
		if type.get_slice("[", 0) not in ["Array", "Dictionary"]:
			return false
		for arg:String in _types.parser.Utils.MemberParse.safe_split_args(type.substr(type.find("[") + 1).trim_suffix("]")):
			if arg.strip_edges() != "Variant" and not _supported_type(arg.strip_edges(), allow_references):
				return false
		return true
	return type.contains(".gd") or ClassDB.class_exists(type) or _types._variant_types().has(type)


func _emit_type(type:String) -> String:
	if _types.structs.has(type):
		return "Array"
	if type.contains("["):
		var parts:Array[String] = []
		for arg:String in _types.parser.Utils.MemberParse.safe_split_args(type.substr(type.find("[") + 1).trim_suffix("]")):
			var element := _emit_type(arg.strip_edges())
			if element.is_empty():
				return ""
			parts.append(element)
		return type.get_slice("[", 0) + "[" + ", ".join(parts) + "]"
	if type.contains(".gd"):
		var end := type.find(".gd", type.rfind("/") + 1) + 3
		var path := type.substr(0, end)
		var tail := type.substr(end).trim_prefix(".").trim_prefix("::").replace("::", ".")
		if path == _source:
			return tail
		if not type_dependencies.has(path):
			type_dependencies[path] = _prefix + "type_%d" % type_dependencies.size()
		return type_dependencies[path] + ("." + tail if tail != "" else "")
	return type


func _function(line:int):
	var parser = _types.parser
	var owner = parser.get_class_object(parser.get_class_at_line(line))
	return owner.functions.get(parser.get_function_at_line(line))


func _binding(name:String, line:int, column:int) -> int:
	var function = _function(line)
	if function == null:
		return -1
	var data:Dictionary = function.get_in_scope_local_vars(line, column).get(name, {})
	return data.get("line_index", -1)


func _find_scalars() -> void:
	var declaration := RegEx.create_from_string(r"^\s*var\s+(\w+)\s*(?::[^=]*)?=\s*([\w.]+)\.new\((.*)\)\s*$")
	for line in _lines.size():
		if not _complete[line]:
			continue
		var code := _code(line)
		var found := declaration.search(code)
		if found == null:
			continue
		var function = _function(line)
		if function == null:
			continue
		var owner = _types.parser.get_class_object(_types.parser.get_class_at_line(line))
		if owner.get_lambda_at_line(line, found.get_start(1)) != null:
			continue
		var expression := found.get_string(2) + ".new(" + found.get_string(3) + ")"
		var constructor_tokens:Array = _types.parser.CodeEditParser.LambdaScanner._tokens(expression)
		if constructor_tokens.any(func(token): return token.text in ["func", ";"]):
			continue
		var open := -1
		for index in constructor_tokens.size():
			if constructor_tokens[index].text == "(":
				open = index
				break
		if open < 0 or _types.parser.CodeEditParser.LambdaScanner._matching(constructor_tokens, open) != constructor_tokens.size() - 1:
			continue
		var path:String = _types.type_of(expression, line, found.get_start(2))
		if path.is_empty():
			continue
		var candidate := {"line": line, "name": found.get_string(1), "path": path,
			"fields": {}, "function": function, "args": found.get_string(3)}
		var dependencies := type_dependencies.duplicate()
		var reason := _assess(candidate)
		if reason != "":
			type_dependencies = dependencies
			stats.scalar_skipped += 1
			warnings.append("line %d: scalar %s skipped (%s)" % [line + 1, candidate.name, reason])
		else:
			_scalars[line] = candidate
			stats.scalar_structs += 1
			debug_events.append({"line": line, "kind": "scalar-replacement", "details": {"struct": candidate.path, "mode": "declaration"}})


func _assess(candidate:Dictionary) -> String:
	var def:Dictionary = _types.structs[candidate.path]
	for field:Dictionary in def.fields:
		var type := field_type(candidate.path, field.name)
		if not _supported_type(type, _scalar_references):
			return "field %s has an unsupported or dynamic type" % field.name
		var emitted := _emit_type(type)
		if emitted.is_empty():
			return "unrepresentable field type"
		candidate.fields[field.name] = {"type": emitted,
			"name": _prefix + "%d_%s" % [candidate.line, field.name]}
	var function = candidate.function
	for index in _tokens.size():
		var token:Dictionary = _tokens[index]
		if token.line < function.declaration_line or token.line > function.end_line:
			continue
		if token.text == "await":
			return "coroutine lifetime"
		if token.line <= candidate.line:
			continue
		if _lines[token.line].substr(token.column, token.text.length()) != token.text:
			continue
		if token.text != candidate.name or (index > 0 and _tokens[index - 1].text == "."):
			continue
		if _binding(candidate.name, token.line, token.column) != candidate.line:
			continue
		var owner = _types.parser.get_class_object(_types.parser.get_class_at_line(token.line))
		if owner.get_lambda_at_line(token.line, token.column) != null:
			return "lambda capture"
		if index + 2 >= _tokens.size() or _tokens[index + 1].text != "." or not candidate.fields.has(_tokens[index + 2].text):
			return "whole-struct use or reassignment"
		if _tokens[index + 2].line != token.line:
			return "multiline field access"
	var initialization := _initialize(candidate, def)
	if initialization.is_empty():
		return "unsupported constructor arguments or defaults"
	declarations[candidate.line] = initialization
	return ""


func _initialize(candidate:Dictionary, def:Dictionary) -> String:
	var args:Array = Rewrite._split_args(candidate.args)
	if args.size() > def.args.size():
		return ""
	var indent := _lines[candidate.line].substr(0, Rewrite._indent_of(_lines[candidate.line]))
	var out:Array[String] = []
	var argument_names:Array = []
	var conversions:Array[String] = []
	for index in def.args.size():
		var arg:Dictionary = def.args[index]
		var info:Variant = _types.parser.Utils.get_var_or_const_info("var " + arg.text)
		if info == null:
			return ""
		var type:String = info[1]
		if type != "":
			var parser = _types.parser.get_parser_for_path(def.file)
			type = ValueTypes.normalize(type, parser, def.body_start)
			if not _supported_type(type, _scalar_references):
				return ""
			type = _emit_type(type)
			if type.is_empty():
				return ""
		var value:String = args[index] if index < args.size() else info[2]
		if value.is_empty() or (index >= args.size() and not _immutable(value)):
			return ""
		var name := _prefix + "%d_arg%d" % [candidate.line, index]
		var raw_name := name + "_raw"
		out.append(indent + "var " + raw_name + " = " + value)
		conversions.append(indent + "var " + name + (": " + type if type != "" else "") + " = " + raw_name)
		argument_names.append(name)
	out.append_array(conversions)
	# Field initializers precede _init assignments, including overwritten initial values.
	for field:Dictionary in def.fields:
		if not _immutable(field.fill):
			return ""
		var local:Dictionary = candidate.fields[field.name]
		if local.type.begins_with("Array") and field.fill == "null":
			return ""
		out.append(indent + "var %s: %s = %s" % [local.name, local.type, field.fill])
	for index in def.arg_slots.size():
		var local:Dictionary = candidate.fields[def.fields[def.arg_slots[index]].name]
		out.append(indent + "%s = %s" % [local.name, argument_names[index]])
	return "\n".join(out)


func _immutable(expression:String) -> bool:
	if _scalar_references:
		if expression == "null":
			return true
		if expression in ["[]", "{}"]:
			return true
		if expression.begins_with("[") and expression.ends_with("]"):
			return Rewrite._split_args(expression.substr(1, expression.length() - 2)).all(func(item): return _immutable(item))
		if expression.begins_with("{") and expression.ends_with("}"):
			for entry:String in Rewrite._split_args(expression.substr(1, expression.length() - 2)):
				var pair:Array = _dictionary_pair(entry)
				if pair.size() != 2 or not _immutable(pair[0].strip_edges()) or not _immutable(pair[1].strip_edges()):
					return false
			return true
		if expression.ends_with("()") and expression.trim_suffix("()") in ["Array", "Dictionary", "Callable", "Signal", "PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array", "PackedStringArray", "PackedVector2Array", "PackedVector3Array", "PackedVector4Array", "PackedColorArray"]:
			return true
	var tokens:Array = _types.parser.CodeEditParser.LambdaScanner._tokens(expression)
	if tokens.is_empty():
		return false
	for index in tokens.size():
		var token:Dictionary = tokens[index]
		if token.text == "string" and expression.substr(token.offset, token.end - token.offset) != "string":
			continue
		if token.text == ".":
			if index > 0 and index + 1 < tokens.size() and tokens[index - 1].text.is_valid_int() and tokens[index + 1].text.is_valid_int():
				continue
			if index > 0 and index + 1 < tokens.size() and tokens[index - 1].text in ValueTypes.VALUES and tokens[index + 1].text.is_valid_ascii_identifier():
				continue
			return false
		if token.text in ["[", "{", "/", "%", "**", "await", "func"]:
			return false
		if token.text.is_valid_ascii_identifier() and token.text not in ["true", "false"]:
			if index > 1 and tokens[index - 1].text == "." and tokens[index - 2].text in ValueTypes.VALUES:
				if index + 1 < tokens.size() and tokens[index + 1].text == "(":
					return false
				continue
			if token.text not in ValueTypes.VALUES or index + 1 >= tokens.size() or tokens[index + 1].text not in ["(", "."]:
				return false
	return true


func _dictionary_pair(entry:String) -> Array:
	var depth := 0
	for token:Dictionary in _types.parser.CodeEditParser.LambdaScanner._tokens(entry):
		if token.text in ["[", "{", "("]:
			depth += 1
		elif token.text in ["]", "}", ")"]:
			depth -= 1
		elif token.text == ":" and depth == 0:
			return [entry.substr(0, token.offset), entry.substr(token.end)]
	return []


func replacement(path:String, field:String, receiver:String, lowered:String, line:int, start:int, end:int) -> String:
	if receiver.is_valid_ascii_identifier():
		var binding := _binding(receiver, line, start)
		if _scalars.has(binding):
			var scalar:Dictionary = _scalars[binding]
			if scalar.name == receiver and scalar.path == path:
				stats.scalar_accesses += 1
				debug_events.append({"line": line, "kind": "scalar-replacement", "details": {"field": field, "mode": "access"}})
				return scalar.fields[field].name
	if _mode == 0:
		return lowered
	if declarations.has(line):
		return lowered
	var type := field_type(path, field)
	var code := _code(line)
	if not _supported_type(type, _read_references) or _write_target(code, start, end):
		return lowered
	var tokens:Array = _types.parser.CodeEditParser.LambdaScanner._tokens(code)
	if not _complete[line] or tokens.any(func(token): return token.text in [";", "func"]):
		stats.struct_reads_skipped += 1
		return lowered
	var suffix := code.substr(end).strip_edges()
	# Packed-array casts can copy storage, so receiver mutations must stay on the field.
	if type.begins_with("Packed") and RegEx.create_from_string(r"^\.\w+\s*\(").search(suffix) != null:
		return lowered
	if _explicit_cast(code, start, end, type, line):
		return lowered
	if _mode == 1:
		if not _capture_safe(code, receiver, line):
			stats.struct_reads_skipped += 1
			warnings.append("line %d: typed field capture skipped (evaluation order or unsupported statement)" % [line + 1])
			return lowered
		var declaration := RegEx.create_from_string(r"^\s*var\s+\w+\s*:\s*([\w.\[\], ]*)\s*=\s*")
		var found := declaration.search(code)
		if found != null and found.get_end() == start and suffix == "":
			var destination := found.get_string(1).strip_edges()
			if destination == "" or ValueTypes.normalize(destination, _types.parser, line) == type:
				return lowered
	# Struct lowering can erase collection element metadata; keep the container type.
	type = type.get_slice("[", 0) if type.contains("[") else _emit_type(type)
	if type.is_empty():
		return lowered
	if _mode == 2:
		stats.struct_read_casts += 1
		debug_events.append({"line": line, "kind": "struct-read", "details": {"field": field, "mode": "as_casts"}})
		return "(%s as %s)" % [lowered, type]
	var name := _prefix + "read_%d_%d" % [line, start]
	var indent := code.substr(0, Rewrite._indent_of(code))
	prefixes.get_or_add(line, []).append(indent + "var %s: %s = %s" % [name, type, lowered])
	stats.struct_typed_captures += 1
	debug_events.append({"line": line, "kind": "struct-read", "details": {"field": field, "mode": "typed_locals"}})
	return name


func _explicit_cast(code:String, start:int, end:int, type:String, line:int) -> bool:
	var before := start - 1
	var after := end
	while true:
		while before >= 0 and code[before] in " \t":
			before -= 1
		while after < code.length() and code[after] in " \t":
			after += 1
		if before < 0 or after >= code.length() or code[before] != "(" or code[after] != ")":
			break
		var previous := before - 1
		while previous >= 0 and code[previous] in " \t":
			previous -= 1
		if previous >= 0:
			if code[previous] in ")]":
				break
			if Rewrite._is_ident_char(code[previous]):
				var word_start := previous
				while word_start > 0 and Rewrite._is_ident_char(code[word_start - 1]):
					word_start -= 1
				if code.substr(word_start, previous - word_start + 1) not in ["return", "not", "if", "elif", "else", "while", "and", "or"]:
					break
		before -= 1
		after += 1
	var found := RegEx.create_from_string(r"^as\s+([\w.]+(?:\[[^\]]+\])?)").search(code.substr(after).strip_edges())
	return found != null and ValueTypes.normalize(found.get_string(1), _types.parser, line) == type


func _write_target(code:String, start:int, end:int) -> bool:
	var tokens:Array = _types.parser.CodeEditParser.LambdaScanner._tokens(code)
	for token:Dictionary in tokens:
		if token.text in ["=", "+=", "-=", "*=", "/=", "%=", "**=", "&=", "|=", "^=", "<<=", ">>="]:
			if token.offset >= end:
				return true
			if token.offset < start:
				return false
	return false


func _capture_safe(code:String, receiver:String, line:int) -> bool:
	var statement := RegEx.create_from_string(r"^\s*(?:return\s|var\s|\w+\s*(?:[+*\-]?=)|\w+(?:\.\w+)?\s*\()")
	if statement.search(code) == null:
		return false
	var function = _function(line)
	if function == null or not receiver.is_valid_ascii_identifier():
		return false
	var owner = _types.parser.get_class_object(_types.parser.get_class_at_line(line))
	if owner.get_lambda_at_line(line, code.find(receiver)) != null:
		return false
	var locals:Dictionary = function.get_in_scope_local_vars(line)
	if not locals.has(receiver):
		return false
	var tokens:Array = _types.parser.CodeEditParser.LambdaScanner._tokens(code)
	var calls := 0
	for index in tokens.size():
		var token:Dictionary = tokens[index]
		if token.text in ["and", "or", "if", "else", "elif", "while", "for", "match", "func", "await", ";", "\\", "[", "{", "/", "%", "**"]:
			return false
		if token.text == "(" and index > 0 and tokens[index - 1].text.is_valid_ascii_identifier():
			calls += 1
			if calls > 1 or _types.parser.CodeEditParser.LambdaScanner._matching(tokens, index) != tokens.size() - 1:
				return false
		if token.text == ".":
			if index > 0 and index + 1 < tokens.size() and tokens[index - 1].text.is_valid_int() and tokens[index + 1].text.is_valid_int():
				continue
			if index == 0 or index + 1 >= tokens.size():
				return false
			var base:String = tokens[index - 1].text
			if not base.is_valid_ascii_identifier():
				return false
			var is_callee:bool = index + 2 < tokens.size() and tokens[index + 2].text == "("
			if not is_callee and (not locals.has(base) or _types.type_of(base, line, tokens[index - 1].column) == ""):
				return false
		if token.text.is_valid_ascii_identifier() and code.substr(token.offset, token.end - token.offset) == token.text:
			if token.text in ["return", "var", "true", "false", "null", "not", "as", "is"] or token.text in ValueTypes.VALUES:
				continue
			if index > 0 and tokens[index - 1].text in [".", "var"]:
				continue
			if index + 1 < tokens.size() and tokens[index + 1].text == "(":
				if not locals.has(token.text) and not owner.functions.has(token.text):
					return false
				continue
			if not locals.has(token.text):
				return false
	# Capturing before an assignment must not precede evaluation of a complex destination.
	var assignment := RegEx.create_from_string(r"^\s*(?:var\s+\w+\s*(?::[^=]*)?|\w+\s*[+*\-]?)=")
	if code.contains("=") and assignment.search(code) == null:
		return false
	return true


func finish(lines:PackedStringArray, ops:Dictionary) -> void:
	for line:int in declarations:
		var declaration:String = declarations[line]
		for op:Array in ops.get(line, []):
			var at := Rewrite.code_match(declaration, op[0])
			while at >= 0:
				declaration = declaration.substr(0, at) + op[1] + declaration.substr(at + op[0].length())
				at = Rewrite.code_match(declaration, op[0], at + op[1].length())
		ops.get_or_add(line, []).append([lines[line], declaration])
		lines[line] = declaration
	for line:int in prefixes:
		# Constructor sites are replaced as a unit and cannot reuse captures of their old RHS.
		var replacement_text := "\n".join(prefixes[line]) + "\n" + lines[line]
		ops.get_or_add(line, []).append([lines[line], replacement_text])
		lines[line] = replacement_text


func _code(line:int) -> String:
	return _codes[line]
