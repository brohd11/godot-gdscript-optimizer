extends RefCounted
## Definitions are catalogued once; calls are resolved on replay after preceding passes finish.

const Registry = preload("res://addons/addon_lib/tag_parser/registry.gd")
const Body = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/body.gd")
const Arithmetic = preload("res://addons/addon_lib/gdscript_optimizer/passes/inline/arithmetic.gd")

var plans:Dictionary = {}
var _definitions:Dictionary = {}
var _tagged:Dictionary = {}
var _names:Dictionary = {}
var _context


func prepare(sources:Dictionary, context) -> Dictionary:
	plans.clear()
	_definitions.clear()
	_tagged.clear()
	_names.clear()
	_context = context
	var errors:Array = []
	var warnings:Array = []
	for key:String in sources:
		var path:String = sources[key]
		if path.get_extension() != "gd":
			continue
		if not FileAccess.file_exists(path):
			errors.append("%s: source file does not exist" % path)
			continue
		var lines := FileAccess.get_file_as_string(path).split("\n")
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
	for name:String in function.get_arguments():
		var argument:Dictionary = function.get_arguments()[name]
		if argument.type not in Body.TYPES or not argument.has_static_type or argument.assignment != "":
			return {"error": "parameters must be explicit built-in value types without defaults"}
		params[name] = argument.type
	var return_type:String = function.get_return_type_raw().trim_suffix(_context.parser_script.Keys.INS_DELIM)
	if return_type not in Body.TYPES:
		return {"error": "an explicit built-in value return type is required"}
	var statements:Array = []
	var state := {"quote": "", "depth": 0, "cont": false}
	for index in range(function.declaration_line + 1, function.end_line + 1):
		var line:String = lines[index]
		var comment := Registry.scan_code(line, state)
		var code := (line.substr(0, comment) if comment >= 0 else line).strip_edges()
		if not code.is_empty():
			statements.append({"code": code, "text": line.strip_edges(), "line": index})
	var direct:Dictionary = {}
	if statements.size() == 1 and statements[0].code.begins_with("return "):
		var expression:String = statements[0].code.trim_prefix("return ")
		var analyzed := Arithmetic.new().analyze(expression, params)
		if analyzed.error == "" and analyzed.type == return_type:
			direct = {"tokens": analyzed.tokens}
	var assessed:Dictionary
	if not direct.is_empty():
		assessed = {"body": [{"text": statements[0].text, "return": true}], "symbols": params, "globals": {}}
	else:
		assessed = Body.assess(parser, statements, params, return_type)
		if assessed.has("error"):
			return assessed
	return {"file": tag.file, "params": params, "return_type": return_type,
		"direct": direct, "body": assessed.body, "symbols": assessed.symbols, "globals": assessed.globals}



func apply(key:String, input_lines:Array) -> Dictionary:
	var result := {"lines": input_lines, "errors": [], "warnings": [],
		"stats": {"inline_calls": 0, "inline_skipped": 0, "inline_direct_calls": 0, "inline_expanded_calls": 0}}
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
			result.warnings.append("%s:%d: inline candidate %s left unchanged (unsupported or unresolved call)" % [path, site.line + 1, site.callee])
		else:
			edits.append(replacement)
			result.stats["inline_" + replacement.mode + "_calls"] += 1
			result.stats.inline_calls += 1
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
	if args.size() != definition.params.size():
		return {}
	return {"definition": definition, "function": function, "locals": locals, "args": args}


func _direct(site:Dictionary, parser, call:Dictionary) -> String:
	var definition:Dictionary = call.definition
	if definition.direct.is_empty():
		return ""
	var args:Array = call.args
	var locals:Dictionary = call.locals
	var function = call.function
	var bindings:Dictionary = {}
	var types:Dictionary = {}
	var names:Array = definition.params.keys()
	for i in args.size():
		var argument:String = args[i].strip_edges()
		var type := ""
		if argument.is_valid_ascii_identifier():
			var data:Dictionary = locals.get(argument, {})
			if not data.has("has_static_type"):
				# Scope scans carry locations; declaration metadata carries static typing.
				for declaration:Dictionary in function.local_vars.values():
					if declaration.member_name == argument and declaration.line_index == data.get("line_index", -1):
						data = declaration
						break
			if not data.get("has_static_type", false):
				return ""
			type = parser.resolve_expression_to_type(argument, site.line, site.column)
			if type.contains(_context.parser_script.Keys.TYPE_DELIM):
				type = type.get_slice(_context.parser_script.Keys.TYPE_DELIM, 1)
			types[argument] = type
		else:
			if not argument.is_valid_int() and not argument.is_valid_float():
				return ""
			type = "int" if argument.is_valid_int() else "float"
		if type != definition.params[names[i]]:
			return ""
		bindings[names[i]] = argument
	var expanded := Arithmetic.render(definition.direct.tokens, bindings)
	var checked := Arithmetic.new().analyze(expanded, types)
	return expanded if checked.error == "" and checked.type == definition.return_type else ""


func _expand(site:Dictionary, parser, path:String, source:String) -> Dictionary:
	var call := _resolve_call(site, parser, path)
	if call.is_empty():
		return {}
	var direct := _direct(site, parser, call)
	if direct != "":
		return {"start": site.start, "end": site.end, "text": direct, "mode": "direct"}
	var definition:Dictionary = call.definition
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
	target.compile(r"^(?:var\s+[A-Za-z_][A-Za-z_0-9]*(?:\s*:\s*[A-Za-z_][A-Za-z_0-9]*)?\s*:?=|([A-Za-z_][A-Za-z_0-9]*)\s*=|return)$")
	var match_target := target.search(statement)
	if match_target == null:
		return {}
	if match_target.get_string(1) != "" and not call.locals.has(match_target.get_string(1)):
		return {}
	var caller = parser.get_class_object(parser.get_class_at_line(site.line))
	var required:Dictionary = definition.globals.duplicate()
	for type:String in definition.symbols.values() + [definition.return_type]:
		required[type] = true
	for name:String in required:
		if call.locals.has(name) or caller.get_member_data(name, true) != null:
			return {}
	var names:Array = definition.params.keys()
	for i in call.args.size():
		var argument:String = call.args[i].strip_edges()
		var argument_tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(argument)
		if argument_tokens.any(func(token): return token.text in ["await", "func"]):
			return {}
		for index in argument_tokens.size():
			var token:Dictionary = argument_tokens[index]
			if (call.locals.has(token.text) and (index == 0 or argument_tokens[index - 1].text != ".")
					and argument.substr(token.offset, token.end - token.offset) == token.text):
				var data:Dictionary = call.locals[token.text]
				if not data.has("has_static_type"):
					for declaration:Dictionary in call.function.local_vars.values():
						if declaration.member_name == token.text and declaration.line_index == data.get("line_index", -1):
							data = declaration
							break
				if not data.get("has_static_type", false):
					return {}
		var type := Body.type_of(parser, argument, site.line, site.column)
		if type not in Body.TYPES or not Body.compatible(type, definition.params[names[i]]):
			return {}
	var unique := "_inline_%d_" % site.start
	while source.contains(unique):
		unique += "_"
	var bindings:Dictionary = {}
	for name:String in definition.symbols:
		bindings[name] = unique + name
	var result_name := unique + "result"
	while bindings.values().has(result_name):
		result_name += "_"
	var indent := prefix.substr(0, prefix.length() - prefix.strip_edges(true, false).length())
	var lines:Array = []
	for i in call.args.size():
		lines.append(indent + "var %s:%s = %s" % [bindings[names[i]], definition.params[names[i]], call.args[i].strip_edges()])
	for body:Dictionary in definition.body:
		var text := Body.rename(parser, body.text, bindings)
		if body["return"]:
			text = "var %s:%s = %s" % [result_name, definition.return_type, text.trim_prefix("return ")]
		lines.append(indent + text)
	lines.append(prefix + result_name + suffix)
	return {"start": line_start, "end": line_end, "text": "\n".join(lines), "mode": "expanded"}


func _parser(path:String, source:String):
	var script = load(path) as GDScript
	if script == null:
		return null
	var parser = _context.parser_script.new()
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
