extends RefCounted
## Definitions are catalogued once; calls are resolved on replay after preceding passes finish.

const DebugTags = preload("res://addons/addon_lib/gdscript_optimizer/debug_tags.gd")
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
var _catalog:Dictionary = {}
var _building:Array = []
var _definition_errors:Dictionary = {}
var _discovery:Dictionary = {}
var _definition_parsers:Dictionary = {}
const MAX_DEPTH = 16
const MAX_TOKENS = 4096


func prepare(sources:Dictionary, context) -> Dictionary:
	plans.clear()
	_definitions.clear()
	_tagged.clear()
	_names.clear()
	_catalog.clear()
	_building.clear()
	_definition_errors.clear()
	_context = context
	_snapshots = context.source_snapshots.duplicate()
	var errors:Array = []
	var warnings:Array = []
	_definition_parsers.clear()
	_discovery = {"inline_candidates": 0, "inline_eligible": 0, "inline_definitions_skipped": 0}
	if context.inline_mode == "off":
		return {"errors": [], "warnings": [], "stats": _discovery}
	for key:String in sources:
		var path:String = sources[key]
		if path.get_extension() != "gd":
			continue
		if not FileAccess.file_exists(path):
			errors.append("%s: source file does not exist" % path)
			continue
		var lines:PackedStringArray = _snapshots.get(path, FileAccess.get_file_as_string(path)).split("\n")
		var tags:Array = Registry.scan_lines(lines, path).filter(func(entry): return entry.tag == "inline")
		var entries:Dictionary = {}
		var excluded:Dictionary = {}
		if context.inline_mode == "auto":
			var parser = _parser(path, "\n".join(lines))
			if parser == null:
				errors.append("%s: could not parse inline candidates" % path)
				continue
			for function in parser.get_class_object().functions.values():
				var identity:String = path + Registry.MEMBER_DELIM + function.name
				entries[identity] = {"identity": identity, "file": path, "owner_class": path,
					"attach": Registry.ATTACH_MEMBER, "target_kind": "func", "target_name": function.name,
					"line": function.declaration_line, "target": function.declaration_line,
					"mods": "", "args": "", "explicit": false}
			_definition_parsers[path] = parser
		for tag:Dictionary in tags:
			tag.explicit = true
			var options:Dictionary = Registry.Options.parse(tag.args)
			if options.options.has("off"):
				excluded[tag.identity] = true
				if not tag.mods.is_empty() or not options.errors.is_empty() or options.options != {"off": true}:
					warnings.append("%s:%d: invalid inline exclusion" % [path, tag.line + 1])
				continue
			entries[tag.identity] = tag
			_tagged[tag.identity] = true
		for identity:String in excluded:
			entries.erase(identity)
		for tag:Dictionary in entries.values():
			_catalog[tag.identity] = tag
			_names[tag.target_name] = true
	for identity:String in _catalog:
		_build_definition(identity)
	for parser in _definition_parsers.values():
		if parser != null:
			_dispose(parser)
	_definition_parsers.clear()
	for identity:String in _definition_errors:
		var tag:Dictionary = _catalog[identity]
		if tag.explicit:
			warnings.append("%s:%d: #! inline skipped: %s" % [tag.file, tag.line + 1, _definition_errors[identity]])
	if not _definitions.is_empty():
		for key:String in sources:
			if sources[key].get_extension() == "gd":
				plans[key] = sources[key]
	_discovery.inline_candidates = _catalog.size()
	_discovery.inline_eligible = _definitions.size()
	_discovery.inline_definitions_skipped = _catalog.size() - _definitions.size()
	return {"errors": errors, "warnings": warnings, "stats": _discovery}


func _build_definition(identity:String) -> Dictionary:
	if _definitions.has(identity):
		return _definitions[identity]
	if _definition_errors.has(identity):
		if not _definition_errors[identity].contains("depth limit"):
			return {}
		_definition_errors.erase(identity)
	if identity in _building or _building.size() >= MAX_DEPTH:
		_definition_errors[identity] = "recursive inline cycle" if identity in _building else "inline depth limit"
		return {}
	var tag:Dictionary = _catalog[identity]
	var source:String = _snapshots.get(tag.file, FileAccess.get_file_as_string(tag.file))
	if not _definition_parsers.has(tag.file):
		_definition_parsers[tag.file] = _parser(tag.file, source)
	var parser = _definition_parsers[tag.file]
	if parser == null:
		_definition_errors[identity] = "could not parse inline definition"
		return {}
	_building.append(identity)
	var definition := _definition(tag, source.split("\n"), parser)
	_building.pop_back()
	if definition.has("error") or _definition_errors.has(identity):
		_definition_errors[identity] = definition.get("error", _definition_errors.get(identity, "unsupported definition"))
		return {}
	_definitions[identity] = definition
	return definition


func _definition(tag:Dictionary, lines:PackedStringArray, parser) -> Dictionary:
	if tag.attach != Registry.ATTACH_MEMBER or tag.target_kind != "func" or tag.owner_class != tag.file:
		return {"error": "tag a top-level static function declaration"}
	var options:Dictionary = Registry.Options.parse(tag.args)
	if not tag.mods.is_empty() or not options.errors.is_empty():
		return {"error": "invalid inline options: " + str(options.errors)}
	for option:String in options.options:
		if option != "substitute" or options.options[option] != true:
			return {"error": "unknown inline option or unexpected value: " + option}
	var function = parser.get_class_object().functions.get(tag.target_name)
	if function == null or not function.is_static():
		return {"error": "only static functions are supported"}
	var force:bool = _context.aggressive or options.options.has("substitute")
	var params:Dictionary = {}
	var defaults:Dictionary = {}
	for name:String in function.get_arguments():
		var argument:Dictionary = function.get_arguments()[name]
		var type := Body.TypeInfo.normalize(argument.type, parser, function.declaration_line)
		if type == "" or not argument.has_static_type:
			type = "Variant"
		if not _direct_type(type, force) and (not Body.TypeInfo.supported(type, parser, force) or not argument.has_static_type):
			return {"error": "parameters must have supported explicit types"}
		if not force and type not in Body.TYPES:
			return {"error": "reference and Variant parameters require aggressive or substitute"}
		params[name] = type
		if argument.assignment != "":
			defaults[name] = _default(parser, argument.assignment, function.declaration_line)
	var rest:String = function.rest_argument
	var raw_return:String = function.get_return_type_raw().strip_edges()
	var return_type := "void" if raw_return == "void" else Body.TypeInfo.normalize(raw_return, parser, function.declaration_line)
	if return_type == "":
		return_type = "Variant"
	if return_type != "void" and not Body.TypeInfo.supported(return_type, parser) and not _direct_type(return_type, force):
		return {"error": "a supported explicit return type is required"}
	if not force and return_type != "void" and return_type not in Body.TYPES:
		return {"error": "reference and Variant returns require aggressive or substitute"}
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
	var nested:Array = []
	var normalized:Array = []
	for statement:Dictionary in statements:
		var rewritten := _compose_expression(statement.code, parser, tag.file, statement.line, 0, true)
		if rewritten.get("fatal", false):
			return {"error": rewritten.reason}
		var copy := statement.duplicate()
		copy.code = rewritten.text
		copy.text = statement.text.substr(0, statement.text.length() - statement.text.strip_edges(true, false).length()) + rewritten.text
		normalized.append(copy)
		nested.append_array(rewritten.events)
	if logical != "":
		var rewritten := _compose_expression(logical, parser, tag.file, statements[0].line, 0, true)
		if rewritten.get("fatal", false):
			return {"error": rewritten.reason}
		logical = rewritten.text
		nested = rewritten.events
	if logical != "":
		var analyzed := _expression(logical, params, parser, statements[0].line, -1, force)
		if analyzed.error == "" and _direct_return(analyzed.type, return_type, force):
			direct = {"expression": logical, "globals": analyzed.globals, "effectful": analyzed.effectful}
	var reduction := _reduction(statements, rest, return_type)
	var assessed := Body.assess(parser, normalized, params, return_type, force)
	var template_eligible:bool = not assessed.has("error") and (return_type == "void" or Body.TypeInfo.supported(return_type, parser, force))
	for type:String in params.values():
		template_eligible = template_eligible and Body.TypeInfo.supported(type, parser, force)
	if not template_eligible:
		if direct.is_empty() and reduction == "":
			return assessed if assessed.has("error") else {"error": "unsupported template signature or direct expression"}
		assessed = {}
	assessed.merge({"identity": tag.identity, "file": tag.file, "params": params, "defaults": defaults, "rest": rest,
		"return_type": return_type, "direct": direct, "template_eligible": template_eligible,
		"substitute": force, "explicit_substitute": options.options.has("substitute"), "explicit": tag.explicit, "reduction": reduction, "nested": nested,
		"indent_width": base_indent})
	return assessed


func _reduction(statements:Array, rest:String, return_type:String) -> String:
	if rest == "" or return_type != "bool" or statements.size() != 4:
		return ""
	var loop := RegEx.create_from_string(r"^for\s+(\w+)(?:\s*:\s*(?:bool|Variant))?\s+in\s+(\w+):$").search(statements[0].code)
	if loop == null or loop.get_string(2) != rest:
		return ""
	if statements[0].indent != 0 or statements[3].indent != 0 or statements[1].indent <= 0 or statements[2].indent <= statements[1].indent:
		return ""
	var name := loop.get_string(1)
	if statements[1].code == "if not " + name + ":" and statements[2].code == "return false" and statements[3].code == "return true":
		return "and"
	if statements[1].code == "if " + name + ":" and statements[2].code == "return true" and statements[3].code == "return false":
		return "or"
	return ""


func _direct_type(type:String, force:bool = false) -> bool:
	return DirectExpression.admitted(type, force or _context.aggressive, force or _context.aggressive)


func _direct_return(actual:String, expected:String, force:bool = false) -> bool:
	return force or actual == expected or (_context.aggressive and "Variant" in [actual, expected])


func _expression(source:String, params:Dictionary, parser, line:int, column:int = -1, force:bool = false, globals:Dictionary = {}) -> Dictionary:
	return DirectExpression.new().analyze(source, params, parser, line, column,
		force or _context.aggressive, force or _context.aggressive, globals)


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
		if global.get("effectful", false):
			return data
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
		"stats": {"inline_calls": 0, "inline_skipped": 0, "inline_direct_calls": 0, "inline_expanded_calls": 0, "inline_early_return_calls": 0, "inline_substituted_args": 0, "inline_captured_args": 0, "inline_repeated_access_captures": 0}}
	if not plans.has(key):
		return result
	var path:String = plans[key]
	var source := "\n".join(input_lines)
	var candidates := _candidates(source)
	if candidates.is_empty():
		return result
	var parser = _parser(path, source)
	if parser == null:
		result.errors.append("%s: could not parse inline call sites" % path)
		return result
	var edits:Array = []
	for site:Dictionary in candidates:
		if edits.any(func(edit): return edit.start <= site.start and edit.end >= site.end):
			continue
		var replacement := _expand(site, parser, path, source)
		if replacement.is_empty():
			result.stats.inline_skipped += 1
			if _context.inline_mode != "auto":
				result.warnings.append("%s:%d: inline candidate %s left unchanged (%s)" % [path, site.line + 1, site.callee, site.get("reason", "unsupported or unresolved call")])
		else:
			replacement.origin = "%s:%d" % [path, site.line + 1]
			edits.append(replacement)
			result.stats["inline_" + replacement.mode + "_calls"] += 1
			result.stats.inline_calls += replacement.events.size()
			result.stats.inline_direct_calls += replacement.events.size() - 1
			for name:String in replacement.get("stats", {}):
				result.stats[name] += replacement.stats[name]
	_dispose(parser)
	edits.sort_custom(func(a, b): return a.start > b.start)
	var markers:Array = []
	for edit:Dictionary in edits:
		for marker:Dictionary in markers:
			if marker.offset >= edit.end:
				marker.offset += edit.text.length() - (edit.end - edit.start)
		if _context.debug_tags:
			for event:Dictionary in edit.events:
				var details := event.duplicate()
				details.site = edit.origin
				markers.append({"offset": edit.start, "kind": "inline", "details": details})
		source = source.substr(0, edit.start) + edit.text + source.substr(edit.end)
	result.lines = Array(source.split("\n"))
	if _context.debug_tags:
		for marker:Dictionary in markers:
			marker.line = source.substr(0, marker.offset).count("\n")
		result.lines = DebugTags.annotate(result.lines, markers)
	return result


func _resolve_call(site:Dictionary, parser, path:String, inside:bool = false) -> Dictionary:
	var class_obj = parser.get_class_object(parser.get_class_at_line(site.line))
	var function = class_obj.functions.get(parser.get_function_at_line(site.line))
	if function == null or class_obj.get_lambda_at_line(site.line, site.column) != null:
		return {}
	if not inside and _tagged.has(class_obj.get_script_class_path() + Registry.MEMBER_DELIM + function.name):
		return {}
	var callee:String = site.callee.replace(" ", "").replace("\t", "")
	var rich:Dictionary = parser.resolve_expression_to_type_rich(callee, site.line, site.column)
	var identity:String = rich.get("origin", "").trim_suffix(_context.parser_script.Keys.CALLABLE_SUFFIX)
	if not _catalog.has(identity):
		return {}
	var definition := _build_definition(identity)
	if definition.is_empty():
		site.reason = _definition_errors.get(identity, "unsupported nested inline")
		site.fatal = site.reason.contains("cycle") or site.reason.contains("limit")
		return {}
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
	var supplied:Array = _context.parser_script.Utils.MemberParse.safe_split_args(site.args)
	if site.args.strip_edges().is_empty():
		supplied = []
	var fixed:int = definition.params.size() - int(definition.rest != "")
	if supplied.size() > fixed and definition.rest == "":
		return {}
	if definition.substitute and not definition.explicit_substitute:
		var types := _local_types({"locals": locals, "function": function}, parser, site)
		for argument:String in supplied:
			var expression := argument.strip_edges()
			if not types.has(expression) and not _pure(expression, types, parser, site.line, site.column):
				site.reason = "unproven argument requires explicit inline; substitute"
				return {}
	var args:Array = supplied.slice(0, fixed)
	var default_indices:Array = []
	for name:String in definition.params.keys().slice(args.size(), fixed):
		if not definition.defaults.has(name) or not definition.defaults[name].supported:
			site.reason = "missing required argument or unsupported omitted default: " + name
			return {}
		default_indices.append(args.size())
		args.append(definition.defaults[name].expression)
	var rest_args:Array = supplied.slice(fixed)
	if definition.rest != "":
		args.append("[" + ", ".join(rest_args) + "]")
	return {"definition": definition, "function": function, "locals": locals, "args": args,
		"explicit_count": supplied.size(), "default_indices": default_indices, "rest_args": rest_args, "supplied": supplied}


func _candidates(source:String, base_line:int = 0, base_column:int = 0) -> Array:
	var lexer = _context.parser_script.CodeEditParser.LambdaScanner
	var tokens:Array = lexer._tokens(source)
	var out:Array = []
	for i in range(tokens.size() - 1):
		var token:Dictionary = tokens[i]
		if not _names.has(token.text) or tokens[i + 1].text != "(" or (i > 0 and tokens[i - 1].text == "func"):
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
			out.append({"start": tokens[start].offset, "end": tokens[end].end,
				"line": base_line + tokens[start].line,
				"column": tokens[start].column + (base_column if tokens[start].line == 0 else 0),
				"callee": source.substr(tokens[start].offset, token.end - tokens[start].offset),
				"args_start": tokens[i + 1].end,
				"args": source.substr(tokens[i + 1].end, tokens[end].offset - tokens[i + 1].end)})
	return out


func _compose_expression(source:String, parser, path:String, line:int, column:int, inside:bool, depth:int = 0) -> Dictionary:
	var result := {"text": source, "events": [], "fatal": false, "reason": ""}
	if depth >= MAX_DEPTH:
		result.merge({"fatal": true, "reason": "inline depth limit"}, true)
		return result
	var candidates := _candidates(source, line, column)
	var edits:Array = []
	for site:Dictionary in candidates:
		if candidates.any(func(other): return other.start < site.start and other.end > site.end):
			continue
		var call := _resolve_call(site, parser, path, inside)
		var expanded := _direct_node(site, parser, call, path, inside, depth) if not call.is_empty() else {}
		if site.get("fatal", false):
			result.merge({"fatal": true, "reason": site.reason}, true)
			return result
		if expanded.is_empty():
			# A failed parent must not prevent independent expression children from optimizing.
			var children := _compose_expression(site.args, parser, path, site.line, site.column, inside, depth + 1)
			if children.fatal:
				return children
			if not children.events.is_empty():
				edits.append({"start": site.args_start, "end": site.end - 1, "text": children.text})
				result.events.append_array(children.events)
		else:
			edits.append({"start": site.start, "end": site.end, "text": expanded.text})
			result.events.append_array(expanded.events)
	edits.reverse()
	for edit:Dictionary in edits:
		result.text = result.text.substr(0, edit.start) + edit.text + result.text.substr(edit.end)
	if _context.parser_script.CodeEditParser.LambdaScanner._tokens(result.text).size() > MAX_TOKENS:
		return {"text": source, "events": [], "fatal": true, "reason": "inline token limit"}
	return result


func _local_types(call:Dictionary, parser, site:Dictionary) -> Dictionary:
	var types:Dictionary = {}
	for name:String in call.locals:
		var data := _local_data(call, name)
		var type := Body.type_of(parser, name, site.line, site.column) if data.get("has_static_type", false) else "Variant"
		types[name] = type if type != "" else "Variant"
	return types


func _pure(source:String, types:Dictionary, parser, line:int, column:int) -> bool:
	var analyzed := _expression(source, types, parser, line, column)
	if analyzed.error != "" or analyzed.effectful:
		return false
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(source)
	for token:Dictionary in tokens:
		if token.text in ["/", "%", "["] or DirectExpression.reference_type(types.get(token.text, "")) or types.get(token.text, "") == "Variant":
			return false
	return true


func _argument(source:String, site:Dictionary, parser, call:Dictionary, path:String, inside:bool, depth:int) -> Dictionary:
	var tokens:Array = parser.CodeEditParser.LambdaScanner._tokens(source)
	if tokens.any(func(token): return token.text in ["await", "func"]):
		return {}
	var rewritten := _compose_expression(source, parser, path, site.line, site.column, inside, depth + 1)
	if rewritten.fatal:
		site.fatal = true
		site.reason = rewritten.reason
		return {}
	var types := _local_types(call, parser, site)
	var text:String = rewritten.text.strip_edges()
	var checked := _expression(text, types, parser, site.line, site.column, call.definition.substitute)
	var type:String = checked.type if checked.error == "" else Body.type_of(parser, source, site.line, site.column)
	if types.has(text):
		type = types[text]
	if type == "":
		type = "Variant"
	var stable:bool = types.has(text) or (checked.error == "" and (text.is_valid_int() or text.is_valid_float() or text in ["true", "false", "null"] or (tokens.size() == 1 and tokens[0].text == "string")))
	return {"text": text, "type": type, "pure": stable or _pure(text, types, parser, site.line, site.column), "events": rewritten.events}


func _event(definition:Dictionary, depth:int, mode:String = "direct") -> Dictionary:
	return {"callee": definition.identity, "mode": mode, "args": "substitute" if definition.explicit_substitute else ("aggressive" if definition.substitute else ""),
		"depth": depth}


func _direct_node(site:Dictionary, parser, call:Dictionary, path:String, inside:bool, depth:int = 0) -> Dictionary:
	var definition:Dictionary = call.definition
	if depth >= MAX_DEPTH:
		site.merge({"fatal": true, "reason": "inline depth limit"}, true)
		return {}
	if definition.direct.is_empty() and definition.reduction == "":
		return {}
	var bindings:Dictionary = {}
	var types:Dictionary = {}
	var nodes:Array = []
	var events:Array = []
	var args:Array = call.rest_args if definition.reduction != "" else call.args
	if definition.reduction != "" and definition.params.size() != 1:
		return {}
	if definition.reduction == "" and definition.rest != "":
		return {}
	var logical:String = definition.direct.get("expression", "")
	var globals:Dictionary = definition.direct.get("globals", {})
	var aliases := {"prefix": "_inline_%d_" % site.start}
	var visible := _visible_types(site, parser, call)
	var external_bindings:Dictionary = {}
	for name:String in globals:
		external_bindings[name] = _bind_global(globals[name], site, parser, call, aliases, visible)
	var placeholders:Array = []
	for i in args.size():
		var node:Dictionary
		if i in call.default_indices:
			var value:Dictionary = definition.defaults[definition.params.keys()[i]]
			var default_bindings:Dictionary = {}
			for name:String in value.globals:
				if not value.globals[name].is_empty():
					default_bindings[name] = _bind_global(value.globals[name], site, parser, call, aliases, visible)
				elif call.locals.has(name) or parser.get_class_object(parser.get_class_at_line(site.line)).get_member_data(name, true) != null:
					return {}
			node = {"text": Body.rename(parser, value.expression, default_bindings), "type": value.type, "pure": true, "events": []}
		else:
			node = _argument(args[i], site, parser, call, path, inside, depth)
		if node.is_empty() or (not definition.substitute and not node.pure):
			return {}
		var expected:String = "bool" if definition.reduction != "" else definition.params.values()[i]
		if not _direct_type(node.type, definition.substitute) or not _direct_type(expected, definition.substitute) or not _direct_return(node.type, expected, definition.substitute):
			return {}
		var placeholder := "_optimizer_argument_%d" % i
		while logical.contains(placeholder) or bindings.has(placeholder):
			placeholder += "_"
		placeholders.append(placeholder)
		types[placeholder] = node.type
		bindings[placeholder] = "(" + node.text + ")"
		nodes.append(node)
	if definition.reduction != "":
		logical = (" " + definition.reduction + " ").join(placeholders)
		if logical == "":
			logical = "true" if definition.reduction == "and" else "false"
	else:
		var slots:Dictionary = {}
		for i in placeholders.size():
			slots[definition.params.keys()[i]] = placeholders[i]
		logical = Body.rename(parser, logical, slots)
	var slots_used:Array = parser.CodeEditParser.LambdaScanner._tokens(logical).map(func(token): return token.text)
	for i in nodes.size():
		if placeholders[i] in slots_used:
			events.append_array(nodes[i].events)
	var checked := _expression(logical, types, parser, site.line, site.column, definition.substitute, globals)
	if checked.error != "" or not _direct_return(checked.type, definition.return_type, definition.substitute):
		return {}
	var constants:Dictionary = {}
	for i in nodes.size():
		if nodes[i].text.is_valid_int() or nodes[i].text.is_valid_float():
			constants[placeholders[i]] = "(" + nodes[i].text + ")"
	var literal_check := _expression(Body.rename(parser, logical, constants), types, parser, site.line, site.column, definition.substitute, globals)
	if literal_check.error in ["constant zero divisor", "constant divisor requires capture"]:
		site.reason = literal_check.error
		return {}
	if aliases.size() > 1:
		return {}
	# Rename external roots before substituting caller expressions, whose names belong to the caller.
	logical = Body.rename(parser, logical, external_bindings)
	var text := "(" + Body.rename(parser, logical, bindings) + ")"
	# Recheck literal arithmetic so substitution cannot introduce a compile-time zero divisor.
	var locals := _local_types(call, parser, site)
	var concrete := _expression(text, locals, parser, site.line, site.column, definition.substitute)
	if concrete.error in ["constant zero divisor", "constant divisor requires capture"]:
		site.reason = concrete.error
		return {}
	for nested:Dictionary in definition.nested:
		var child := nested.duplicate()
		child.depth += depth + 1
		if child.depth >= MAX_DEPTH:
			site.merge({"fatal": true, "reason": "inline depth limit"}, true)
			return {}
		events.append(child)
	if parser.CodeEditParser.LambdaScanner._tokens(text).size() > MAX_TOKENS:
		site.merge({"fatal": true, "reason": "inline token limit"}, true)
		return {}
	events.append(_event(definition, depth))
	return {"text": text, "events": events, "type": checked.type}


func _expand(site:Dictionary, parser, path:String, source:String) -> Dictionary:
	var call := _resolve_call(site, parser, path)
	if call.is_empty():
		return {}
	var direct := _direct_node(site, parser, call, path, false)
	if not direct.is_empty():
		return {"start": site.start, "end": site.end, "text": direct.text, "events": direct.events, "mode": "direct", "stats": {"inline_substituted_args": call.explicit_count}}
	if site.get("fatal", false):
		return {}
	# Unchecked templates would substitute the same divisor and can introduce a parse error.
	if call.definition.substitute and site.get("reason", "") in ["constant zero divisor", "constant divisor requires capture"]:
		return {}
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
	if call.definition.return_type == "void":
		if not statement.is_empty():
			return {}
	else:
		if match_target == null:
			return {}
		if match_target.get_string(1) != "" and not call.locals.has(match_target.get_string(1)):
			return {}
	var unique := "_inline_%d_" % site.start
	while source.contains(unique):
		unique += "_"
	var nested:Array = []
	for i in call.args.size():
		if i in call.default_indices:
			continue
		var composed := _compose_expression(call.args[i], parser, path, site.line, site.column, false, 1)
		if composed.fatal:
			site.reason = composed.reason
			return {}
		call.args[i] = composed.text
		nested.append_array(composed.events)
	if call.definition.rest != "":
		nested = []
		for i in call.supplied.size():
			var composed := _compose_expression(call.supplied[i], parser, path, site.line, site.column, false, 1)
			if composed.fatal:
				return {}
			call.supplied[i] = composed.text
			nested.append_array(composed.events)
	var rendered := _render_template(site, parser, call, unique, prefix, suffix, line_start, line_end)
	if not rendered.is_empty():
		rendered.events.append_array(nested)
	return rendered


func _render_template(site:Dictionary, parser, call:Dictionary, unique:String, prefix:String, suffix:String, start:int, end:int) -> Dictionary:
	var definition:Dictionary = call.definition
	var is_void:bool = definition.return_type == "void"
	var early_returns:bool = definition.early_returns
	var aliases := {"prefix": unique}
	var visible := _visible_types(site, parser, call)
	var bindings:Dictionary = {}
	var captures:Array = []
	var owned_temporaries:bool = false
	var rest_bindings:Dictionary = {}
	if definition.rest != "":
		owned_temporaries = true
		var raw_names:Array = []
		for i in call.supplied.size():
			var raw := unique + "supplied_%d" % i
			captures.append("var %s = %s" % [raw, call.supplied[i]])
			raw_names.append(raw)
		var fixed:int = definition.params.size() - 1
		for i in mini(fixed, raw_names.size()):
			rest_bindings[i] = raw_names[i]
		rest_bindings[fixed] = "[" + ", ".join(raw_names.slice(fixed)) + "]"
	var stats := {"inline_substituted_args": 0, "inline_captured_args": 0, "inline_repeated_access_captures": 0}
	var caller = parser.get_class_object(parser.get_class_at_line(site.line))
	for name:String in definition.globals:
		var global:Dictionary = definition.globals[name]
		if global.is_empty():
			if call.locals.has(name) or caller.get_member_data(name, true) != null:
				site.reason = "built-in name is shadowed: " + name
				return {}
		else:
			bindings[name] = _bind_global(global, site, parser, call, aliases, visible)
	var names:Array = definition.params.keys()
	for i in call.args.size():
		var name:String = names[i]
		var argument:String = call.args[i].strip_edges()
		var expected:String = definition.params[name]
		var is_default:bool = i in call.default_indices
		if is_default:
			var globals:Dictionary = {}
			for key:String in definition.defaults[name].globals:
				var global:Dictionary = definition.defaults[name].globals[key]
				if not global.is_empty():
					globals[key] = _bind_global(global, site, parser, call, aliases, visible)
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
			if not stable and not definition.substitute:
				site.reason = "Variant local argument is unsupported; use a typed local or indexed lookup"
				return {}
		elif argument.is_valid_int() or argument.is_valid_float() or argument in ["true", "false", "null"]:
			stable = true
		elif tokens.size() == 1 and tokens[0].text == "string" and argument.begins_with('"'):
			stable = true
		if not definition.substitute and not Body.compatible(actual, expected):
			if not (actual in ["", "Variant", "null"] or lookup or Body.TypeInfo.is_reference(expected)):
				site.reason = "incompatible argument type for " + name
				return {}
		var usage:Dictionary = definition.uses[name]
		var captured:bool = (definition.rest != "" or not stable or actual != expected or usage.rebound
			or (definition.runtime_arithmetic and (argument.is_valid_int() or argument.is_valid_float()))
			or (usage.written and not Body.TypeInfo.is_reference(expected))
			or (definition.effectful and Body.TypeInfo.is_reference(expected)))
		# Object properties may have accessors; keep the original strong parameter reference.
		if expected.contains(".gd") or expected == "RefCounted":
			captured = true
		if definition.substitute:
			# Written value parameters still need storage; caller variables must not be rebound.
			captured = definition.rest != "" or usage.rebound or (usage.written and not DirectExpression.reference_type(expected))
		if captured:
			bindings[name] = unique + name
			var annotation:String = "" if definition.substitute else ":" + Body.TypeInfo.emit(expected, parser, aliases, visible)
			captures.append("var %s%s = %s" % [bindings[name], annotation, rest_bindings.get(i, argument)])
			owned_temporaries = owned_temporaries or _owns_reference(actual if definition.substitute else expected)
			stats.inline_captured_args += 1
			if lookup and usage.count > 1:
				stats.inline_repeated_access_captures += 1
		else:
			bindings[name] = "(" + argument + ")"
			stats.inline_substituted_args += 1
	for name:String in definition.symbols:
		if not definition.params.has(name):
			bindings[name] = unique + name
			owned_temporaries = owned_temporaries or _owns_reference(definition.symbols[name])
	if definition.substitute:
		owned_temporaries = false
	var result_name := unique + "result"
	while bindings.values().has(result_name):
		result_name += "_"
	var bridge := unique + "bridge"
	while bindings.values().has(bridge) or bridge == result_name:
		bridge += "_"
	var loop_name := unique + "once"
	while bindings.values().has(loop_name) or loop_name in [result_name, bridge]:
		loop_name += "_"
	var target:String = ""
	var target_type:String = "Variant"
	var target_declaration:String = ""
	var assignment := RegEx.create_from_string(r"^([A-Za-z_][A-Za-z_0-9]*)\s*=$").search(prefix.strip_edges())
	if not is_void and assignment != null and not owned_temporaries:
		var candidate:String = assignment.get_string(1)
		target_type = Body.type_of(parser, candidate, site.line, site.column) if _local_data(call, candidate).get("has_static_type", false) else "Variant"
		if definition.substitute or (target_type == definition.return_type and not _owns_reference(target_type)):
			target = candidate
	if not is_void and not owned_temporaries and prefix.strip_edges().begins_with("var "):
		var declaration:Variant = parser.Utils.get_var_or_const_info(prefix.strip_edges() + " null")
		if declaration != null:
			var candidate:String = declaration[0]
			target_type = definition.return_type if declaration[3] else ("Variant" if declaration[1] == "" else Body.TypeInfo.normalize(declaration[1], parser, site.line))
			var exact_returns:bool = definition.body.all(func(body): return not body["return"] or body.value_type == definition.return_type)
			var preserves_type:bool = not _owns_reference(definition.return_type) and (target_type == definition.return_type or exact_returns)
			# Declaring early must not shadow a name used by the initializer or imported body.
			var reads:Array = captures + bindings.values()
			for body:Dictionary in definition.body:
				reads.append(Body.rename(parser, body.text, bindings, body.tokens))
			var shadows:bool = reads.any(func(text): return parser.CodeEditParser.LambdaScanner._tokens(text).any(func(token): return token.text == candidate))
			if not shadows and (definition.substitute or preserves_type):
				target = candidate
				target_declaration = "var " + target
				if declaration[3]:
					target_declaration += ":" + Body.TypeInfo.emit(definition.return_type, parser, aliases, visible)
				elif declaration[1] != "":
					target_declaration += ":" + declaration[1]
	var tail_return:bool = prefix.strip_edges() == "return" and (definition.substitute or (not owned_temporaries and definition.body.all(func(body): return not body["return"] or body.value_type == definition.return_type)))
	var mode:String = "void" if is_void else ("return" if tail_return else ("target" if target != "" else ("bridge" if _owns_reference(definition.return_type) and not definition.substitute else "slot")))
	if mode == "bridge" and definition.body.any(func(body): return body.text.strip_edges().begins_with("if ")):
		site.reason = "conditional expansion requires more than one result local"
		return {}
	var return_type:String = Body.TypeInfo.emit(definition.return_type, parser, aliases, visible) if mode in ["slot", "bridge"] else ""
	var scoped:bool = mode != "return" and (mode == "bridge" or not captures.is_empty() or definition.symbols.size() > definition.params.size() or early_returns)
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
				text = text.replace(found.get_string(2), Body.TypeInfo.emit(body.type, parser, aliases, visible) + " ")
				slots = []
		text = Body.rename(parser, text, bindings, slots)
		text = unit.repeat(body.indent / definition.indent_width) + text.strip_edges(true, false)
		if body["return"]:
			var relative := text.substr(0, text.length() - text.strip_edges(true, false).length())
			if is_void:
				text = relative + "break"
			else:
				var expression:String = text.strip_edges().trim_prefix("return ")
				if mode == "target" and definition.substitute:
					var actual:String = Body.type_of(parser, expression, site.line, site.column)
					if actual != "" and target_type != "Variant" and actual not in ["Variant", "null"] and not Body.compatible(actual, target_type):
						site.reason = "substituted return is incompatible with assignment target"
						return {}
				text = relative + ("return " if mode == "return" else (target if mode == "target" else result_name) + " = ") + expression
		rendered.append(text)
	for path:String in aliases:
		if path != "prefix":
			lines.append(indent + 'const %s = preload("%s")' % [aliases[path], path])
	if target_declaration != "":
		lines.append(indent + target_declaration)
	if mode == "bridge":
		lines.append(indent + "var " + bridge + ":Variant")
	elif mode == "slot":
		lines.append(indent + "var %s:%s" % [result_name, return_type])
	if scoped:
		lines.append(indent + "if true:")
	var body_indent:String = indent + unit if scoped else indent
	for capture:String in captures:
		lines.append(body_indent + capture)
	if mode == "bridge":
		lines.append(indent + unit + "var %s:%s" % [result_name, return_type])
	if early_returns:
		lines.append(indent + unit + "for %s in 1:" % loop_name)
		body_indent += unit
		stats.inline_early_return_calls = 1
	for text:String in rendered:
		for line:String in text.split("\n"):
			lines.append(body_indent + line)
	if mode in ["void", "target", "return"]:
		if not suffix.strip_edges().is_empty():
			lines[0] += " " + suffix.strip_edges()
	elif mode == "slot":
		lines.append(prefix + result_name + suffix)
	else:
		lines.append(indent + unit + "%s = %s" % [bridge, result_name])
		# The typed cast retains := inference; the bridge is cleared after the caller consumes it.
		lines.append(prefix + "(" + bridge + " as " + return_type + ")" + suffix)
		if prefix.strip_edges() != "return":
			lines.append(indent + bridge + " = null")
	var events:Array = []
	for event:Dictionary in definition.nested:
		var child := event.duplicate()
		child.depth += 1
		if child.depth >= MAX_DEPTH:
			site.reason = "inline depth limit"
			return {}
		events.append(child)
	var event := _event(definition, 0, "expanded")
	if early_returns:
		event.control_flow = "single_iteration"
	events.append(event)
	return {"start": start, "end": end, "text": "\n".join(lines), "mode": "expanded", "stats": stats, "events": events}


func _local_data(call:Dictionary, name:String) -> Dictionary:
	var data:Dictionary = call.locals[name]
	if not data.has("has_static_type"):
		for declaration:Dictionary in call.function.local_vars.values():
			if declaration.member_name == name and declaration.line_index == data.get("line_index", -1):
				return declaration
	return data


func _owns_reference(type:String) -> bool:
	return type in ["", "Variant"] or DirectExpression.reference_type(type)


func _visible_types(site:Dictionary, parser, call:Dictionary) -> Dictionary:
	var caller = parser.get_class_object(parser.get_class_at_line(site.line))
	var candidates:Array = caller.constants.keys() + caller.inner_classes.keys()
	var visible:Dictionary = {}
	for name:String in _context.class_list:
		if call.locals.has(name) or caller.get_member_data(name, true) != null or _context.removed_globals.has(name):
			continue
		var path:String = _context.class_list[name]
		if FileAccess.file_exists(path):
			visible[path] = name
	for name:String in candidates:
		if call.locals.has(name) or caller.members.has(name):
			continue
		var type:String = Body.type_of(parser, name, site.line, site.column)
		if type.contains(".gd") and not type.contains(parser.Keys.TYPE_DELIM):
			visible[type] = name
	return visible


func _global(global:Dictionary, parser, aliases:Dictionary, visible:Dictionary = {}) -> String:
	if global.has("type"):
		return Body.TypeInfo.emit(global.type, parser, aliases, visible)
	return Body.TypeInfo.emit(global.file, parser, aliases, visible) + "." + global.name


func _bind_global(global:Dictionary, site:Dictionary, parser, call:Dictionary, aliases:Dictionary, visible:Dictionary) -> String:
	if global.has("file"):
		var owner = parser.get_class_object(parser.get_class_at_line(site.line))
		if owner.get_script_class_path() == global.file and not call.locals.has(global.name):
			return global.name
		if global.file == call.definition.file and site.callee.contains("."):
			return site.callee.substr(0, site.callee.rfind(".")) + "." + global.name
	return _global(global, parser, aliases, visible)


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
