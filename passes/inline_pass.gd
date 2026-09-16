extends RefCounted
## Definitions are catalogued once; calls are resolved on replay after preceding passes finish.

const Registry = preload("res://addons/addon_lib/tag_parser/registry.gd")
const Body = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/body.gd")
const DirectExpression = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/expression.gd")
const Arithmetic = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/arithmetic.gd")

var plans:Dictionary = {}
var _definitions:Dictionary = {}
var _tagged:Dictionary = {}
var _names:Dictionary = {}
var _snapshots:Dictionary = {}
var _context


func prepare(sources:Dictionary, context) -> Dictionary:
	plans.clear()
	_definitions.clear()
	_tagged.clear()
	_names.clear()
	_context = context
	_snapshots = context.source_snapshots.duplicate()
	var errors:Array = []
	var warnings:Array = []
	for key:String in sources:
		var path:String = sources[key]
		if path.get_extension() != "gd":
			continue
		if not FileAccess.file_exists(path):
			errors.append("%s: source file does not exist" % path)
			continue
		var lines:PackedStringArray = _snapshots.get(path, FileAccess.get_file_as_string(path)).split("\n")
		var tags:Array = Registry.scan_lines(lines, path).filter(func(entry): return entry.tag == "inline")
		if tags.is_empty():
			continue
		var parser = _parser(path, "\n".join(lines))
		if parser == null:
			errors.append("%s: could not parse inline definitions" % path)
			continue
		for tag:Dictionary in tags:
			_tagged[tag.identity] = true
			var definition := _definition(tag, lines, parser)
			if definition.has("error"):
				warnings.append("%s:%d: #! inline skipped: %s" % [path, tag.line + 1, definition.error])
			else:
				_definitions[tag.identity] = definition
				_names[tag.target_name] = true
		_dispose(parser)
	if not _definitions.is_empty():
		for key:String in sources:
			if sources[key].get_extension() == "gd":
				plans[key] = sources[key]
	return {"errors": errors, "warnings": warnings}


func _definition(tag:Dictionary, lines:PackedStringArray, parser) -> Dictionary:
	if tag.attach != Registry.ATTACH_MEMBER or tag.target_kind != "func" or tag.owner_class != tag.file:
		return {"error": "tag a top-level static function declaration"}
	var function = parser.get_class_object().functions.get(tag.target_name)
	if function == null or not function.is_static():
		return {"error": "only static functions are supported"}
	var params:Dictionary = {}
	var defaults:Dictionary = {}
	for name:String in function.get_arguments():
		var argument:Dictionary = function.get_arguments()[name]
		var type := Body.TypeInfo.normalize(argument.type, parser, function.declaration_line)
		if type == "" or not argument.has_static_type:
			type = "Variant"
		if not _direct_type(type) and (not Body.TypeInfo.supported(type, parser) or not argument.has_static_type):
			return {"error": "parameters must have supported explicit types"}
		params[name] = type
		if argument.assignment != "":
			defaults[name] = _default(parser, argument.assignment, function.declaration_line)
	var return_type := Body.TypeInfo.normalize(function.get_return_type_raw(), parser, function.declaration_line)
	if return_type == "":
		return_type = "Variant"
	if not Body.TypeInfo.supported(return_type, parser) and not _direct_type(return_type):
		return {"error": "a supported explicit return type is required"}
	var statements:Array = []
	var state := {"quote": "", "depth": 0, "cont": false}
	var base_indent := -1
	for index in range(function.declaration_line + 1, function.end_line + 1):
		var line:String = lines[index]
		var comment := Registry.scan_code(line, state)
		var code := (line.substr(0, comment) if comment >= 0 else line).strip_edges()
		if not code.is_empty():
			var indent := line.length() - line.strip_edges(true, false).length()
			if base_indent < 0:
				base_indent = indent
			statements.append({"code": code, "text": line.substr(base_indent), "line": index, "indent": indent - base_indent})
	var direct:Dictionary = {}
	var logical := _single_return(statements, parser, lines)
	if logical != "":
		var analyzed := _expression(logical, params, parser, statements[0].line)
		if analyzed.error == "" and _direct_return(analyzed.type, return_type):
			direct = {"expression": logical}
	var assessed := Body.assess(parser, statements, params, return_type)
	var template_eligible:bool = not assessed.has("error") and Body.TypeInfo.supported(return_type, parser)
	for type:String in params.values():
		template_eligible = template_eligible and Body.TypeInfo.supported(type, parser)
	if not template_eligible:
		if direct.is_empty():
			return assessed if assessed.has("error") else {"error": "unsupported template signature or direct expression"}
		assessed = {}
	assessed.merge({"file": tag.file, "params": params, "defaults": defaults, "return_type": return_type,
		"direct": direct, "template_eligible": template_eligible, "indent_width": base_indent})
	return assessed


func _direct_type(type:String) -> bool:
	return DirectExpression.admitted(type, _context.inline_functions_allow_ref_counted, _context.inline_functions_allow_variants)


func _direct_return(actual:String, expected:String) -> bool:
	return actual == expected or (_context.inline_functions_allow_variants and "Variant" in [actual, expected])


func _expression(source:String, params:Dictionary, parser, line:int, column:int = -1) -> Dictionary:
	return DirectExpression.new().analyze(source, params, parser, line, column,
		_context.inline_functions_allow_ref_counted, _context.inline_functions_allow_variants)


func _single_return(statements:Array, parser, lines:PackedStringArray) -> String:
	if statements.is_empty() or not statements[0].code.begins_with("return "):
		return ""
	var source := "\n".join(lines.slice(statements[0].line, statements[-1].line + 1)).strip_edges().trim_prefix("return ")
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(source)
	# Keep literal bytes, including blank lines; remove comments by their token offsets.
	for index in range(tokens.size() - 1, -1, -1):
		var token:Dictionary = tokens[index]
		if token.text == "\n" and token.depth == 0:
			return ""
		if token.text == "comment" and source[token.offset] == "#":
			source = source.substr(0, token.offset) + source.substr(token.end)
	return source


func _default(parser, expression:String, line:int) -> Dictionary:
	var data := {"expression": expression, "globals": {}, "supported": false}
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(expression)
	for i in tokens.size():
		var token:Dictionary = tokens[i]
		if expression.substr(token.offset, token.end - token.offset) != token.text:
			continue
		if token.text in ["[", "{", "await", "func"]:
			return data
		if i + 1 < tokens.size() and tokens[i + 1].text == "(" and token.text not in Body.TYPES:
			return data
		if i > 1 and tokens[i - 1].text == ".":
			var start := Body._receiver_start(tokens, i - 2)
			var receiver := expression.substr(tokens[start].offset, tokens[i - 1].offset - tokens[start].offset)
			var receiver_type := Body.type_of(parser, receiver, line)
			if receiver_type.contains(".gd"):
				var parts := receiver_type.split("::", true, 1)
				var dependency = parser.get_parser_for_path(parts[0])
				var owner = dependency.get_class_object(parts[1] if parts.size() > 1 else "")
				var member:Variant = owner.get_member_data(token.text, true)
				if member == null or member.get("member_type") not in [parser.Keys.MEMBER_TYPE_CONST, parser.Keys.MEMBER_TYPE_ENUM]:
					return data
	var metadata := {"symbols": {}, "uses": {}, "globals": {}, "effectful": false}
	if Body._expression(parser, expression, line, metadata) != "":
		return data
	var type := Body.type_of(parser, expression, line)
	if expression != "null" and type not in Body.TYPES:
		return data
	for name:String in metadata.globals:
		var global:Dictionary = metadata.globals[name]
		if not global.is_empty() and Body.type_of(parser, name, line) not in Body.TYPES:
			var raw:String = parser.resolve_expression_to_type(name, line)
			if not raw.ends_with(".gd"):
				return data
	data.supported = true
	data.type = type
	data.globals = metadata.globals
	return data



func apply(key:String, input_lines:Array) -> Dictionary:
	var result := {"lines": input_lines, "errors": [], "warnings": [],
		"stats": {"inline_calls": 0, "inline_skipped": 0, "inline_direct_calls": 0, "inline_expanded_calls": 0, "inline_substituted_args": 0, "inline_captured_args": 0, "inline_repeated_access_captures": 0}}
	if not plans.has(key):
		return result
	var path:String = plans[key]
	var source := "\n".join(input_lines)
	var lexer = _context.parser_script.CodeEditParser.LambdaScanner
	var tokens:Array = lexer._tokens(source)
	var candidates:Array = []
	for i in range(1, tokens.size() - 1):
		var token:Dictionary = tokens[i]
		if not _names.has(token.text) or tokens[i + 1].text != "(" or tokens[i - 1].text == "func":
			continue
		if source.substr(token.offset, token.end - token.offset) != token.text:
			continue
		var start := i
		if i >= 2 and tokens[i - 1].text == "." and tokens[i - 2].text.is_valid_ascii_identifier():
			start = i - 2
		if start > 0 and tokens[start - 1].text in [".", ")", "]"]:
			continue
		var end:int = lexer._matching(tokens, i + 1)
		if end >= 0:
			candidates.append({"start": tokens[start].offset, "end": tokens[end].end,
				"line": tokens[start].line, "column": tokens[start].column,
				"callee": source.substr(tokens[start].offset, token.end - tokens[start].offset),
				"args": source.substr(tokens[i + 1].end, tokens[end].offset - tokens[i + 1].end)})
	if candidates.is_empty():
		return result
	var parser = _parser(path, source)
	if parser == null:
		result.errors.append("%s: could not parse inline call sites" % path)
		return result
	var edits:Array = []
	for site:Dictionary in candidates:
		var replacement:Dictionary = {}
		var nested:bool = candidates.any(func(other): return (other != site and
			((other.start < site.start and other.end > site.end) or (site.start < other.start and site.end > other.end))))
		if not nested:
			replacement = _expand(site, parser, path, source)
		if replacement.is_empty():
			result.stats.inline_skipped += 1
			result.warnings.append("%s:%d: inline candidate %s left unchanged (%s)" % [path, site.line + 1, site.callee, site.get("reason", "unsupported or unresolved call")])
		else:
			edits.append(replacement)
			result.stats["inline_" + replacement.mode + "_calls"] += 1
			result.stats.inline_calls += 1
			for name:String in replacement.get("stats", {}):
				result.stats[name] += replacement.stats[name]
	_dispose(parser)
	edits.reverse()
	for edit:Dictionary in edits:
		source = source.substr(0, edit.start) + edit.text + source.substr(edit.end)
	result.lines = Array(source.split("\n"))
	return result


func _resolve_call(site:Dictionary, parser, path:String) -> Dictionary:
	var class_obj = parser.get_class_object(parser.get_class_at_line(site.line))
	var function = class_obj.functions.get(parser.get_function_at_line(site.line))
	if function == null or class_obj.get_lambda_at_line(site.line, site.column) != null:
		return {}
	if _tagged.has(class_obj.get_script_class_path() + Registry.MEMBER_DELIM + function.name):
		return {}
	var callee:String = site.callee.replace(" ", "").replace("\t", "")
	var rich:Dictionary = parser.resolve_expression_to_type_rich(callee, site.line, site.column)
	var identity:String = rich.get("origin", "").trim_suffix(_context.parser_script.Keys.CALLABLE_SUFFIX)
	if not _definitions.has(identity):
		return {}
	var definition:Dictionary = _definitions[identity]
	var locals:Dictionary = function.get_in_scope_local_vars(site.line, site.column)
	if callee.contains("."):
		var alias := callee.get_slice(".", 0)
		if alias in ["self", "super"] or locals.has(alias) or class_obj.members.has(alias):
			return {}
		var member:Variant = class_obj.get_member_data(alias, true)
		if member is Dictionary and member.get("member_type") != _context.parser_script.Keys.MEMBER_TYPE_CONST:
			return {}
		var receiver:String = parser.resolve_expression_to_type(alias, site.line, site.column)
		if receiver.contains(_context.parser_script.Keys.TYPE_DELIM):
			receiver = receiver.get_slice(_context.parser_script.Keys.TYPE_DELIM, 1)
		if receiver != definition.file:
			return {}
	elif locals.has(callee) or not function.is_static() or path != definition.file:
		return {}
	var args:Array = _context.parser_script.Utils.GDScriptParse.safe_split_args(site.args)
	if site.args.strip_edges().is_empty():
		args = []
	if args.size() > definition.params.size():
		return {}
	var explicit_count := args.size()
	for name:String in definition.params.keys().slice(explicit_count):
		if not definition.defaults.has(name) or not definition.defaults[name].supported:
			site.reason = "missing required argument or unsupported omitted default: " + name
			return {}
		args.append(definition.defaults[name].expression)
	return {"definition": definition, "function": function, "locals": locals, "args": args, "explicit_count": explicit_count}


func _direct(site:Dictionary, parser, call:Dictionary) -> String:
	var definition:Dictionary = call.definition
	if definition.direct.is_empty() or call.explicit_count != call.args.size():
		return ""
	var bindings:Dictionary = {}
	var types:Dictionary = {}
	var names:Array = definition.params.keys()
	for i in call.args.size():
		var argument:String = call.args[i].strip_edges()
		var type := ""
		if argument.is_valid_ascii_identifier() and argument not in ["true", "false", "null"]:
			if not call.locals.has(argument):
				return ""
			var data := _local_data(call, argument)
			type = Body.type_of(parser, argument, site.line, site.column) if data.get("has_static_type", false) else "Variant"
			if type == "":
				type = "Variant"
			types[argument] = type
		else:
			var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(argument)
			var literal:bool = argument.is_valid_int() or argument.is_valid_float() or argument in ["true", "false", "null"]
			literal = literal or (tokens.size() == 1 and tokens[0].text == "string" and argument[0] in ['"', "'"])
			if not literal:
				return ""
			var analyzed := _expression(argument, {}, parser, site.line, site.column)
			if analyzed.error != "":
				return ""
			type = analyzed.type
		var expected:String = definition.params[names[i]]
		if not _direct_type(type) or not _direct_type(expected) or not _direct_return(type, expected):
			return ""
		bindings[names[i]] = "(" + argument + ")"
	var expanded:String = "(" + Body.rename(parser, definition.direct.expression, bindings) + ")"
	var checked := _expression(expanded, types, parser, site.line, site.column)
	if checked.error != "":
		site.reason = checked.error
	return expanded if checked.error == "" and _direct_return(checked.type, definition.return_type) else ""


func _expand(site:Dictionary, parser, path:String, source:String) -> Dictionary:
	var call := _resolve_call(site, parser, path)
	if call.is_empty():
		return {}
	var direct := _direct(site, parser, call)
	if direct != "":
		return {"start": site.start, "end": site.end, "text": direct, "mode": "direct", "stats": {"inline_substituted_args": call.args.size()}}
	if not call.definition.template_eligible:
		return {}
	var line_start:int = source.rfind("\n", site.start - 1) + 1
	var line_end:int = source.find("\n", site.end)
	if line_end < 0:
		line_end = source.length()
	if source.substr(site.start, site.end - site.start).contains("\n"):
		return {}
	var prefix := source.substr(line_start, site.start - line_start)
	var suffix := source.substr(site.end, line_end - site.end)
	if not suffix.strip_edges().is_empty() and not suffix.strip_edges().begins_with("#"):
		return {}
	var statement := prefix.strip_edges()
	var target := RegEx.new()
	target.compile(r"^(?:var\s+[A-Za-z_][A-Za-z_0-9]*(?:\s*:\s*[A-Za-z_][A-Za-z_0-9.\[\], ]*)?\s*:?=|([A-Za-z_][A-Za-z_0-9]*)\s*=|return)$")
	var match_target := target.search(statement)
	if match_target == null:
		return {}
	if match_target.get_string(1) != "" and not call.locals.has(match_target.get_string(1)):
		return {}
	var unique := "_inline_%d_" % site.start
	while source.contains(unique):
		unique += "_"
	return _render_template(site, parser, call, unique, prefix, suffix, line_start, line_end)


func _render_template(site:Dictionary, parser, call:Dictionary, unique:String, prefix:String, suffix:String, start:int, end:int) -> Dictionary:
	var definition:Dictionary = call.definition
	var aliases := {"prefix": unique}
	var bindings:Dictionary = {}
	var captures:Array = []
	var stats := {"inline_substituted_args": 0, "inline_captured_args": 0, "inline_repeated_access_captures": 0}
	var caller = parser.get_class_object(parser.get_class_at_line(site.line))
	for name:String in definition.globals:
		var global:Dictionary = definition.globals[name]
		if global.is_empty():
			if call.locals.has(name) or caller.get_member_data(name, true) != null:
				site.reason = "built-in name is shadowed: " + name
				return {}
		else:
			bindings[name] = _global(global, parser, aliases)
	var names:Array = definition.params.keys()
	for i in call.args.size():
		var name:String = names[i]
		var argument:String = call.args[i].strip_edges()
		var expected:String = definition.params[name]
		var is_default:bool = i >= call.explicit_count
		if is_default:
			var globals:Dictionary = {}
			for key:String in definition.defaults[name].globals:
				var global:Dictionary = definition.defaults[name].globals[key]
				if not global.is_empty():
					globals[key] = _global(global, parser, aliases)
				elif call.locals.has(key) or caller.get_member_data(key, true) != null:
					site.reason = "default built-in name is shadowed: " + key
					return {}
			argument = Body.rename(parser, argument, globals)
		var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(argument)
		if tokens.any(func(token): return token.text in ["await", "func"]):
			site.reason = "argument uses await or a lambda"
			return {}
		var actual:String = definition.defaults[name].type if is_default else Body.type_of(parser, argument, site.line, site.column)
		if not is_default:
			if argument.is_valid_int():
				actual = "int"
			elif argument.is_valid_float():
				actual = "float"
			elif argument in ["true", "false"]:
				actual = "bool"
		var lookup := tokens.any(func(token): return token.text in [".", "["])
		var stable := false
		if not is_default and argument.is_valid_ascii_identifier() and call.locals.has(argument):
			stable = _local_data(call, argument).get("has_static_type", false)
			if not stable:
				site.reason = "Variant local argument is unsupported; use a typed local or indexed lookup"
				return {}
		elif argument.is_valid_int() or argument.is_valid_float() or argument in ["true", "false", "null"]:
			stable = true
		elif tokens.size() == 1 and tokens[0].text == "string" and argument.begins_with('"'):
			stable = true
		if not Body.compatible(actual, expected):
			if not (actual in ["", "Variant", "null"] or lookup or Body.TypeInfo.is_reference(expected)):
				site.reason = "incompatible argument type for " + name
				return {}
		var usage:Dictionary = definition.uses[name]
		var captured:bool = (not stable or actual != expected or usage.rebound
			or (definition.runtime_arithmetic and (argument.is_valid_int() or argument.is_valid_float()))
			or (usage.written and not Body.TypeInfo.is_reference(expected))
			or (definition.effectful and Body.TypeInfo.is_reference(expected)))
		# Object properties may have accessors; keep the original strong parameter reference.
		if expected.contains(".gd") or expected == "RefCounted":
			captured = true
		if captured:
			bindings[name] = unique + name
			captures.append("var %s:%s = %s" % [bindings[name], Body.TypeInfo.emit(expected, parser, aliases), argument])
			stats.inline_captured_args += 1
			if lookup and usage.count > 1:
				stats.inline_repeated_access_captures += 1
		else:
			bindings[name] = "(" + argument + ")"
			stats.inline_substituted_args += 1
	for name:String in definition.symbols:
		if not definition.params.has(name):
			bindings[name] = unique + name
	var result_name := unique + "result"
	while bindings.values().has(result_name):
		result_name += "_"
	var bridge := unique + "bridge"
	while bindings.values().has(bridge) or bridge == result_name:
		bridge += "_"
	var return_type := Body.TypeInfo.emit(definition.return_type, parser, aliases)
	var indent := prefix.substr(0, prefix.length() - prefix.strip_edges(true, false).length())
	var unit := "\t"
	if indent.contains(" "):
		var source_lines:PackedStringArray = parser.code_edit.text.split("\n")
		var declaration:String = source_lines[call.function.declaration_line]
		var declaration_indent := declaration.length() - declaration.strip_edges(true, false).length()
		for line_index in range(call.function.declaration_line + 1, site.line + 1):
			var line:String = source_lines[line_index]
			if not line.strip_edges().is_empty() and not line.strip_edges().begins_with("#"):
				unit = " ".repeat(line.length() - line.strip_edges(true, false).length() - declaration_indent)
				break
	var lines:Array = []
	var rendered:Array = []
	for body:Dictionary in definition.body:
		var text:String = body.text
		var slots:Array = body.tokens
		if body.declared != "":
			var annotation := RegEx.new()
			annotation.compile(r"^((?:var|const)\s+[A-Za-z_][A-Za-z_0-9]*)\s*:\s*([^=]+)=")
			var found := annotation.search(text.strip_edges())
			if found != null:
				text = text.replace(found.get_string(2), Body.TypeInfo.emit(body.type, parser, aliases) + " ")
				slots = []
		text = Body.rename(parser, text, bindings, slots)
		text = unit.repeat(body.indent / definition.indent_width) + text.strip_edges(true, false)
		if body["return"]:
			var relative := text.substr(0, text.length() - text.strip_edges(true, false).length())
			text = relative + result_name + " = " + text.strip_edges().trim_prefix("return ")
		rendered.append(text)
	for path:String in aliases:
		if path != "prefix":
			lines.append(indent + 'const %s = preload("%s")' % [aliases[path], path])
	lines.append(indent + "var " + bridge + ":Variant")
	lines.append(indent + "if true:")
	for capture:String in captures:
		lines.append(indent + unit + capture)
	lines.append(indent + unit + "var %s:%s" % [result_name, return_type])
	for text:String in rendered:
		lines.append(indent + unit + text)
	lines.append(indent + unit + "%s = %s" % [bridge, result_name])
	# The typed cast retains := inference; the bridge is cleared after the caller consumes it.
	lines.append(prefix + "(" + bridge + " as " + return_type + ")" + suffix)
	if prefix.strip_edges() != "return":
		lines.append(indent + bridge + " = null")
	return {"start": start, "end": end, "text": "\n".join(lines), "mode": "expanded", "stats": stats}


func _local_data(call:Dictionary, name:String) -> Dictionary:
	var data:Dictionary = call.locals[name]
	if not data.has("has_static_type"):
		for declaration:Dictionary in call.function.local_vars.values():
			if declaration.member_name == name and declaration.line_index == data.get("line_index", -1):
				return declaration
	return data


func _global(global:Dictionary, parser, aliases:Dictionary) -> String:
	if global.has("type"):
		return Body.TypeInfo.emit(global.type, parser, aliases)
	return Body.TypeInfo.dependency(global.file, aliases) + "." + global.name


func _parser(path:String, source:String):
	var script = load(path) as GDScript
	if script == null:
		return null
	var parser = _context.parser_script.new()
	parser.set_source_provider(func(target:String): return _snapshots.get(target))
	parser.set_use_native_backend(false)
	parser.set_parser_cache({})
	parser.set_parser_cache_size(-1)
	parser.active_parser = parser
	parser.set_current_script(script)
	parser.set_source_code(source)
	parser.parse()
	return parser


func _dispose(parser) -> void:
	# Each replay owns its cache; break active-parser cycles and release temporary buffers.
	for data:Dictionary in parser._parser_cache.get(_context.parser_script.Keys.CACHE_ACTIVE_PARSERS, {}).values():
		var dependency = data.get(_context.parser_script.Keys.CACHE_PARSER)
		if is_instance_valid(dependency):
			dependency.active_parser = null
			if is_instance_valid(dependency.code_edit):
				dependency.code_edit.free()
	parser._parser_cache.clear()
	parser.active_parser = null
	if is_instance_valid(parser.code_edit):
		parser.code_edit.free()
