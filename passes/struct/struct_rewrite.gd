extends RefCounted
## Text side of `#! struct`: reads a tagged data-only class, generates its array form and rewrites
## the sites naming it. Import-light so a headless suite can load it - struct_pass.gd resolves
## names against the export and applies the results.

const TagRegistry = preload("res://addons/addon_lib/gdscript_optimizer/tag_registry.gd")

const CREATE_FUNC = "create"
const ALLOWED_EXTENDS = ["", "RefCounted", "Object"]

const _CHAIN = r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*"

static var _regexes:Dictionary = {}
static var _variant_types:Dictionary = {}


#region Definition

## {class_path, fields:[{name, enum, type, default, fill, line}], args:[{name, text}], arg_slots,
## body_start, body_end, indent, literal_ok, errors}. `target` is the class line, or for a
## whole-file struct any header line. Errors are "line N: message".
static func parse_def(lines:PackedStringArray, target:int, is_file:bool, class_path:String) -> Dictionary:
	var def = {
		"class_path": class_path, "fields": [], "args": [], "arg_slots": [],
		"body_start": -1, "body_end": -1, "indent": "", "literal_ok": true, "errors": [],
	}
	var errors:Array = def.errors
	if target < 0 or target >= lines.size():
		errors.append(_err(target, "#! struct target line is out of range"))
		return def

	var decl_indent = _indent_of(lines[target])
	if not is_file:
		var cm = _rx("class").search(lines[target].strip_edges())
		if cm == null:
			errors.append(_err(target, "#! struct must sit above a class declaration"))
			return def
		if not cm.get_string("extends") in ALLOWED_EXTENDS:
			errors.append(_err(target, "a struct cannot extend " + cm.get_string("extends")))
		if cm.get_string("rest") != "":
			errors.append(_err(target, "a one-line struct class is not supported"))

	var state = {"quote": "", "depth": 0, "cont": false}
	var body_indent = -1
	var in_init = false
	var assigns:Array = [] # [field, arg, line]
	for i in range(0 if is_file else target + 1, lines.size()):
		var raw = lines[i]
		var continued:bool = state.cont
		var comment_idx = TagRegistry.scan_code(raw, state)
		var code = (raw.substr(0, comment_idx) if comment_idx > -1 else raw).strip_edges()
		if code.is_empty():
			continue
		var indent = _indent_of(raw)
		if not is_file and indent <= decl_indent and not continued:
			break
		if continued:
			errors.append(_err(i, "multi-line statements are not supported in a struct"))
			continue
		if is_file and indent == 0 and _is_header(code):
			var ext = _header_extends(code)
			if not ext in ALLOWED_EXTENDS:
				errors.append(_err(i, "a struct cannot extend " + ext))
			continue

		if def.body_start == -1:
			def.body_start = i
			body_indent = indent
			def.indent = raw.substr(0, indent)
		def.body_end = i

		if indent > body_indent:
			if not in_init:
				errors.append(_err(i, "unexpected indentation: " + code))
			elif code != "pass":
				_add_assign(code, i, assigns, errors)
			continue

		in_init = false
		var vm = _rx("var").search(code)
		if vm:
			def.fields.append({
				"name": vm.get_string("name"),
				"type": "" if vm.get_string("op") == ":=" else vm.get_string("type").strip_edges(),
				"default": vm.get_string("default").strip_edges(),
				"line": i,
			})
			continue
		var fm = _rx("func").search(code)
		if fm and fm.get_string("name") == "_init" and not code.begins_with("static"):
			_parse_init(code, i, def, assigns)
			in_init = true
			continue
		if code != "pass":
			errors.append(_err(i, "a struct only holds var fields and _init: " + code))

	_resolve_slots(def, target, assigns)
	return def


static func _parse_init(code:String, line:int, def:Dictionary, assigns:Array) -> void:
	var open = code.find("(")
	var close = _find_close(code, _string_mask(code), open)
	if close == -1:
		def.errors.append(_err(line, "a multi-line _init signature is not supported"))
		return
	for arg_text:String in _split_args(code.substr(open + 1, close - open - 1)):
		var am = _rx("arg").search(arg_text)
		if am == null:
			def.errors.append(_err(line, "unreadable _init argument: " + arg_text))
			continue
		def.args.append({"name": am.get_string("name"), "text": arg_text})

	var tail = code.substr(close + 1).strip_edges()
	if tail.begins_with("->"):
		tail = tail.substr(tail.find(":")) if tail.contains(":") else ""
	var inline = tail.trim_prefix(":").strip_edges()
	if inline != "" and inline != "pass":
		for stmt in inline.split(";", false):
			_add_assign(stmt.strip_edges(), line, assigns, def.errors)


static func _add_assign(code:String, line:int, assigns:Array, errors:Array) -> void:
	var am = _rx("assign").search(code)
	if am == null:
		errors.append(_err(line, "_init may only assign fields from its arguments: " + code))
	else:
		assigns.append([am.get_string("field"), am.get_string("arg"), line])


## Maps _init args onto slots and decides what fills the rest. A site can only be inlined as a
## literal when args already land in slot order (evaluation order is kept) and every other slot
## fills with a literal - a default naming something in the struct's scope means nothing elsewhere.
static func _resolve_slots(def:Dictionary, target:int, assigns:Array) -> void:
	var errors:Array = def.errors
	if def.fields.is_empty():
		errors.append(_err(target, "a struct needs at least one var field"))

	var slots = {}
	var enums = {}
	for idx in def.fields.size():
		var field:Dictionary = def.fields[idx]
		field.enum = field.name.to_upper()
		if enums.has(field.enum):
			errors.append(_err(field.line, "fields %s and %s both become enum %s" % [enums[field.enum], field.name, field.enum]))
		enums[field.enum] = field.name
		slots[field.name] = idx

	var arg_index = {}
	for k in def.args.size():
		arg_index[def.args[k].name] = k
	def.arg_slots.resize(def.args.size())
	def.arg_slots.fill(-1)
	var slot_taken = {}
	for a in assigns:
		if not slots.has(a[0]):
			errors.append(_err(a[2], "%s is not a field" % a[0]))
		elif not arg_index.has(a[1]):
			errors.append(_err(a[2], "%s is not an _init argument" % a[1]))
		elif slot_taken.has(slots[a[0]]):
			errors.append(_err(a[2], "field %s is assigned twice" % a[0]))
		elif def.arg_slots[arg_index[a[1]]] != -1:
			errors.append(_err(a[2], "argument %s is assigned twice" % a[1]))
		else:
			def.arg_slots[arg_index[a[1]]] = slots[a[0]]
			slot_taken[slots[a[0]]] = true
	for k in def.args.size():
		if def.arg_slots[k] == -1:
			errors.append(_err(target, "_init argument %s is never assigned to a field" % def.args[k].name))
		elif k > 0 and def.arg_slots[k] <= def.arg_slots[k - 1]:
			def.literal_ok = false

	for idx in def.fields.size():
		var field:Dictionary = def.fields[idx]
		field.fill = field.default if field.default != "" else type_default(field.type)
		if not slot_taken.has(idx) and _rx("literal").search(field.fill) == null:
			def.literal_ok = false


## What an unassigned typed var holds before anything writes it.
static func type_default(type:String) -> String:
	if type.begins_with("Array"):
		return "[]"
	if type.begins_with("Dictionary"):
		return "{}"
	match type:
		"int": return "0"
		"float": return "0.0"
		"bool": return "false"
		"String": return '""'
		"StringName": return '&""'
		"NodePath": return '^""'
	if _is_variant_type(type) and type != "Object" and type != "Nil":
		return type + "()"
	return "null"


## The class body that replaces lines body_start..body_end: slot enum plus a constructor.
static func build_body(def:Dictionary) -> PackedStringArray:
	var indent:String = def.indent
	var inner = indent + ("    " if indent.begins_with(" ") else "\t")
	var names = []
	for field in def.fields:
		names.append(field.enum)
	var args = []
	var arg_names = []
	for a in def.args:
		args.append(a.text)
		arg_names.append(a.name)
	return PackedStringArray([
		indent + "enum { %s }" % ", ".join(names),
		indent + "static func %s(%s) -> Array:" % [CREATE_FUNC, ", ".join(args)],
		inner + "return [%s]" % ", ".join(_slot_values(def, arg_names)),
	])


static func _slot_values(def:Dictionary, arg_values:Array) -> Array:
	var values = []
	for idx in def.fields.size():
		var k = def.arg_slots.find(idx)
		values.append(arg_values[k] if k > -1 else def.fields[idx].fill)
	return values

#endregion


#region Sites

## Rewrites constructors and type hints naming a struct. `resolve.call(head, line)` returns the
## class path a written name refers to, or "". Returns {lines, ops, errors}; `ops` is
## {line: [[from, to], ...]} in order, so apply_ops() can replay them on the export's copy of the
## file, which earlier passes may already have edited elsewhere on the line.
static func rewrite_lines(lines:PackedStringArray, resolve:Callable, structs:Dictionary) -> Dictionary:
	var out:PackedStringArray = lines.duplicate()
	var ops = {}
	var errors = []
	var state = {"quote": "", "depth": 0, "cont": false}
	for i in lines.size():
		var in_string = state.quote != ""
		var comment_idx = TagRegistry.scan_code(lines[i], state)
		if in_string:
			continue
		var code = lines[i].substr(0, comment_idx) if comment_idx > -1 else lines[i]
		var line_ops = []
		code = _rewrite_constructors(code, i, resolve, structs, line_ops)
		_check_is(code, i, resolve, structs, errors)
		code = _rewrite_hints(code, i, resolve, structs, line_ops)
		if line_ops.is_empty():
			continue
		out[i] = code + (lines[i].substr(comment_idx) if comment_idx > -1 else "")
		ops[i] = line_ops
	return {"lines": out, "ops": ops, "errors": errors}


## Replays rewrite_lines() ops onto `lines` in place; returns what could not be found.
static func apply_ops(lines:Array, ops:Dictionary) -> Array:
	var errors = []
	for i:int in ops:
		for op in ops[i]:
			var idx = lines[i].find(op[0]) if i < lines.size() else -1
			if idx == -1:
				errors.append(_err(i, "expected `%s` on this line" % op[0]))
				continue
			lines[i] = lines[i].substr(0, idx) + op[1] + lines[i].substr(idx + op[0].length())
	return errors


## Innermost first, so a constructor nested in another's args is already an array when the outer
## one splits its args.
static func _rewrite_constructors(code:String, line:int, resolve:Callable, structs:Dictionary, line_ops:Array) -> String:
	var limit = code.length()
	while true:
		var mask = _string_mask(code)
		var best:RegExMatch = null
		var def:Dictionary = {}
		for m in _rx("new").search_all(code):
			if m.get_start() >= limit:
				break
			if mask[m.get_start()] == 1:
				continue
			var found = _struct_for(m.get_string("head"), line, resolve, structs)
			if not found.is_empty():
				best = m
				def = found
		if best == null:
			return code

		var start = best.get_start()
		var open = best.get_end() - 1
		var head = best.get_string("head")
		var close = _find_close(code, mask, open)
		var from:String
		var to:String
		if close == -1: # args continue on the next line, which create() takes as they are
			from = code.substr(start, open + 1 - start)
			to = "%s.%s(" % [head, CREATE_FUNC]
		else:
			from = code.substr(start, close + 1 - start)
			var given = _split_args(code.substr(open + 1, close - open - 1))
			if def.literal_ok and given.size() == def.args.size():
				to = "[%s]" % ", ".join(_slot_values(def, given))
			else:
				to = "%s.%s%s" % [head, CREATE_FUNC, code.substr(open, close + 1 - open)]
		code = code.substr(0, start) + to + code.substr(start + from.length())
		line_ops.append([from, to])
		limit = start
	return code


static func _check_is(code:String, line:int, resolve:Callable, structs:Dictionary, errors:Array) -> void:
	var mask = _string_mask(code)
	for m in _rx("is").search_all(code):
		if mask[m.get_start()] == 1:
			continue
		if not _struct_for(m.get_string("chain"), line, resolve, structs).is_empty():
			errors.append(_err(line, "`is %s` cannot work once the struct is an Array" % m.get_string("chain")))


## `: S`, `-> S`, `as S`, `Array[S]`, `Dictionary[K, S]` -> Array. Right to left within a pattern so
## earlier match positions stay valid.
static func _rewrite_hints(code:String, line:int, resolve:Callable, structs:Dictionary, line_ops:Array) -> String:
	for key in ["hint", "typed_first", "typed_second"]:
		var mask = _string_mask(code)
		var matches = _rx(key).search_all(code)
		for k in range(matches.size() - 1, -1, -1):
			var m:RegExMatch = matches[k]
			if mask[m.get_start("chain")] == 1:
				continue
			if _struct_for(m.get_string("chain"), line, resolve, structs).is_empty():
				continue
			var to = m.get_string("pre") + "Array"
			line_ops.append([m.get_string(), to])
			code = code.substr(0, m.get_start()) + to + code.substr(m.get_end())
	return code


static func _struct_for(head:String, line:int, resolve:Callable, structs:Dictionary) -> Dictionary:
	if not head.contains(".") and (_is_variant_type(head) or ClassDB.class_exists(head)):
		return {}
	return structs.get(resolve.call(head, line), {})

#endregion


#region Field access

## `recv.field` -> `recv[S.FIELD]` wherever `type_of.call(recv, line)` returns the class path of a
## struct owning `field`; `name_for.call(class_path)` is how this file spells that struct. Only the
## `.field` text changes, so `a.b.c` needs no ordering. Run it before rewrite_lines(): the receiver
## text must still be what the type resolver parsed. Returns {lines, ops, used:{class_path: true}}.
##
## Indexing an Array yields Variant, which `:=` cannot infer from, so a `var x := <rhs>` whose rhs had a
## read rewritten becomes `var x: T =` with T from `annotate.call(rhs, line, column)` (the type the
## source inferred), or plain `=` when that is "".
static func rewrite_access(lines:PackedStringArray, type_of:Callable, structs:Dictionary, name_for:Callable,
		annotate:Callable = Callable()) -> Dictionary:
	var out:PackedStringArray = lines.duplicate()
	var ops = {}
	var used = {}
	var regex = _field_regex(structs)
	if regex == null:
		return {"lines": out, "ops": ops, "used": used}

	var state = {"quote": "", "depth": 0, "cont": false}
	for i in lines.size():
		var in_string = state.quote != ""
		var comment_idx = TagRegistry.scan_code(lines[i], state)
		if in_string:
			continue
		var code = lines[i].substr(0, comment_idx) if comment_idx > -1 else lines[i]
		var mask = _string_mask(code)
		var edits = [] # [receiver start, dot, field end, replacement]
		for m in regex.search_all(code):
			var dot = m.get_start()
			if mask[dot] == 1:
				continue
			var start = receiver_start(code, mask, dot)
			if start == dot:
				continue
			var path:String = type_of.call(code.substr(start, dot - start), i, start)
			var enum_name = _enum_of(structs.get(path, {}), m.get_string("field"))
			if enum_name == "":
				continue
			edits.append([start, dot, m.get_end(), "[%s.%s]" % [name_for.call(path), enum_name]])
			used[path] = true
		if edits.is_empty():
			continue
		var inferred = _rx("decl_infer").search(code)
		if inferred and edits.back()[1] < inferred.get_end():
			inferred = null # every read sits before the `:=`, in no rhs of it

		# Left to right against the edited text; an earlier edit shifts every position after its dot.
		var line_ops = []
		var applied = [] # [dot, length delta]
		for e in edits:
			var s = e[0] + _shift(applied, e[0])
			var d = e[1] + _shift(applied, e[1])
			var f = e[2] + _shift(applied, e[2])
			var from = code.substr(s, f - s)
			var to = code.substr(s, d - s) + e[3]
			code = code.substr(0, s) + to + code.substr(f)
			applied.append([e[1], to.length() - from.length()])
			line_ops.append([from, to])
		if inferred:
			var rhs_start = inferred.get_end()
			while rhs_start < lines[i].length() and lines[i][rhs_start] in " \t":
				rhs_start += 1
			var rhs = lines[i].substr(rhs_start, (comment_idx if comment_idx > -1 else lines[i].length()) - rhs_start).strip_edges()
			var annotation:String = annotate.call(rhs, i, rhs_start) if annotate.is_valid() else ""
			var decl:String = inferred.get_string("decl")
			var head = decl.substr(0, decl.rfind(":=")).strip_edges(false, true)
			var typed_decl = head + (": %s =" % annotation if annotation != "" else " =")
			var at = code.find(decl) # the declaration precedes every edit, so it is unchanged
			code = code.substr(0, at) + typed_decl + code.substr(at + decl.length())
			line_ops.append([decl, typed_decl])
		out[i] = code + (lines[i].substr(comment_idx) if comment_idx > -1 else "")
		ops[i] = line_ops
	return {"lines": out, "ops": ops, "used": used}


## Start of the expression a `.` at `dot` is accessed on: identifiers, dots, and call/index groups.
## Returns `dot` when there is nothing to resolve, e.g. a string literal.
static func receiver_start(code:String, mask:PackedByteArray, dot:int) -> int:
	var i = dot - 1
	while i >= 0:
		if mask[i] == 1:
			return dot
		var c = code[i]
		if c == ")" or c == "]":
			var open = _find_open(code, mask, i)
			if open == -1:
				return dot
			i = open - 1
			continue
		if not _is_ident_char(c):
			break
		while i >= 0 and mask[i] == 0 and _is_ident_char(code[i]):
			i -= 1
		if i >= 0 and mask[i] == 0 and code[i] == ".":
			i -= 1
			continue
		break
	return i + 1


static func _shift(applied:Array, pos:int) -> int:
	var total = 0
	for a in applied:
		if a[0] < pos:
			total += a[1]
	return total


static func _enum_of(def:Dictionary, field:String) -> String:
	for f in def.get("fields", []):
		if f.name == field:
			return f.enum
	return ""


static var _field_regexes:Dictionary = {}

## `.name` not followed by a call, for every field name of every struct.
static func _field_regex(structs:Dictionary) -> RegEx:
	var names = {}
	for def in structs.values():
		for f in def.fields:
			names[f.name] = true
	if names.is_empty():
		return null
	var keys = names.keys()
	keys.sort()
	var key = "|".join(keys)
	if not _field_regexes.has(key):
		var regex = RegEx.new()
		regex.compile(r"\.(?<field>" + key + r")\b(?!\s*\()")
		_field_regexes[key] = regex
	return _field_regexes[key]

#endregion


#region Flow

## Name-based lookups that stop working once the value is an Array.
const NAME_LOOKUPS = ["get", "set", "has_method", "get_script", "call", "is_class"]
const ARRAY_INSERTS = ["append", "push_back", "push_front", "insert", "append_array"]
const CALL_SKIP = ["if", "elif", "while", "for", "match", "return", "not", "and", "or", "in", "await",
	"func", "super", "preload", "load", "assert"]
## Array methods that call back per element: {method: lambda parameter indexes holding an element}.
const ITERATORS = {"map": [0], "filter": [0], "any": [0], "all": [0], "find_custom": [0],
	"rfind_custom": [0], "reduce": [1], "sort_custom": [0, 1]}
## Where a struct leaves for receivers this pass cannot see - warned, not refused.
const CALLABLE_SINKS = ["emit", "emit_signal", "call", "call_deferred", "callv", "bind", "bindv",
	"set_meta", "rpc", "rpc_id"]
## Words after which `[` opens a literal rather than a subscript.
const LITERAL_KEYWORDS = ["return", "in", "and", "or", "not", "else", "if", "elif", "while", "match",
	"await", "when"]

## Every place a struct value would lose its static type, after which a field read compiles against
## Variant and only fails at runtime. Returns {errors, warnings}. `lookups` callables all take a
## position (line, character column), since two lambdas on one line are separate scopes:
##   type_of(expr) -> struct class path or ""       raw_type(expr) -> resolved type, no instance mark
##   return_raw() -> written return type of the innermost lambda or func there, or ""
##   params(callee) / lambda_params(name) -> has_static_type per parameter, or null when unknown
##   lambda_body() -> whether the position is inside a lambda's body
## A statement spanning lines is checked as one; lambda body lines inside it are checked as their own.
static func check_flow(lines:PackedStringArray, lookups:Dictionary, structs:Dictionary) -> Dictionary:
	var ctx = {"lookups": lookups, "structs": structs, "errors": [], "warnings": []}
	var state = {"quote": "", "depth": 0, "cont": false}
	var i = 0
	while i < lines.size():
		var parts = []
		var positions:Array[Vector2i] = [] # joined-text offset -> (line, column)
		while i < lines.size():
			var comment_idx = TagRegistry.scan_code(lines[i], state)
			var part:String = lines[i].substr(0, comment_idx) if comment_idx > -1 else lines[i]
			if not parts.is_empty():
				positions.append(Vector2i(i - 1, parts.back().length())) # the joining space
				_check_body_line(part, i, ctx)
			for c in part.length():
				positions.append(Vector2i(i, c))
			parts.append(part)
			i += 1
			if not state.cont:
				break
		var raw_code = " ".join(parts)
		if raw_code.strip_edges().is_empty():
			continue
		var lead = raw_code.length() - raw_code.strip_edges(true, false).length()
		_check_statement(raw_code.strip_edges(), lead, positions, ctx)
		_check_literals(raw_code, positions, ctx)
		_check_calls(raw_code, positions, ctx)
	return {"errors": ctx.errors, "warnings": ctx.warnings}


## A continuation line that starts a statement in a lambda body: joined, its `var` or `return` would
## sit mid-statement where the statement rules never look.
static func _check_body_line(part:String, line:int, ctx:Dictionary) -> void:
	var code = part.strip_edges()
	if code.is_empty():
		return
	var lead = part.length() - part.strip_edges(true, false).length()
	if not ctx.lookups.lambda_body.call(line, lead):
		return
	var positions:Array[Vector2i] = []
	for c in part.length():
		positions.append(Vector2i(line, c))
	_check_statement(code, lead, positions, ctx)


static func _at(positions:Array[Vector2i], offset:int) -> Vector2i:
	if positions.is_empty():
		return Vector2i.ZERO
	return positions[clampi(offset, 0, positions.size() - 1)]


static func _type(ctx:Dictionary, expr:String, pos:Vector2i) -> String:
	return ctx.lookups.type_of.call(expr, pos.x, pos.y)


static func _raw(ctx:Dictionary, expr:String, pos:Vector2i) -> String:
	return ctx.lookups.raw_type.call(expr, pos.x, pos.y)


## `code` is stripped and starts at offset `lead` of `positions`.
static func _check_statement(code:String, lead:int, positions:Array[Vector2i], ctx:Dictionary) -> void:
	var here = _at(positions, lead)
	var m = _rx("flow_var").search(code)
	if m:
		if _type(ctx, m.get_string("rhs"), _at(positions, lead + m.get_start("rhs"))) != "":
			ctx.errors.append(_err(here.x, "untyped `var %s` holds a struct - give it the struct's type or `:=`" % m.get_string("name")))
		return
	m = _rx("flow_typed_var").search(code)
	if m:
		# The written type, not the var: on its own declaration line the var is not in scope yet.
		var held = _type(ctx, m.get_string("rhs"), _at(positions, lead + m.get_start("rhs")))
		if held != "" and _raw(ctx, m.get_string("type"), _at(positions, lead + m.get_start("type"))) != held:
			ctx.errors.append(_err(here.x, "`var %s` is not typed as the struct it holds" % m.get_string("name")))
		return
	m = _rx("flow_return").search(code)
	if m:
		var returned = _type(ctx, m.get_string("rhs"), _at(positions, lead + m.get_start("rhs")))
		var written:String = ctx.lookups.return_raw.call(here.x, here.y)
		if returned != "" and (written == "" or _raw(ctx, written, here) != returned):
			ctx.errors.append(_err(here.x, "returns a struct from a func whose return type is not that struct"))
		return
	m = _rx("flow_assign").search(code)
	if m:
		var assigned = _type(ctx, m.get_string("rhs"), _at(positions, lead + m.get_start("rhs")))
		if assigned != "" and _raw(ctx, m.get_string("target"), here) != assigned:
			ctx.errors.append(_err(here.x, "struct assigned into `%s`, which is not typed as that struct" % m.get_string("target")))


static func _check_calls(code:String, positions:Array[Vector2i], ctx:Dictionary) -> void:
	var mask = _string_mask(code)
	for m in _rx("call").search_all(code):
		if mask[m.get_start()] == 1:
			continue
		var callee = m.get_string("callee")
		if callee in CALL_SKIP or code.substr(0, m.get_start()).strip_edges().ends_with("func"):
			continue
		var here = _at(positions, m.get_start())
		var dot = callee.rfind(".")
		var last = callee.substr(dot + 1)
		var receiver = callee.substr(0, dot) if dot > -1 else ""
		if receiver != "" and last in NAME_LOOKUPS and _type(ctx, receiver, here) != "":
			ctx.errors.append(_err(here.x, "`%s` looks a struct up by name, which cannot work on an Array" % callee))
			continue

		var close = _find_close(code, mask, m.get_end() - 1)
		var end = close if close != -1 else code.length()
		var args = _split_args_at(code.substr(m.get_end(), end - m.get_end()))
		if receiver != "" and ITERATORS.has(last) and not args.is_empty():
			_check_iterator(callee, receiver, ITERATORS[last], args[0][0], _at(positions, m.get_end() + args[0][1]), here, ctx)

		var param_types = null
		for k in args.size():
			var arg:String = args[k][0]
			var arg_pos = _at(positions, m.get_end() + args[k][1])
			if arg == "" or _type(ctx, arg, arg_pos) == "":
				continue
			if callee == "is_instance_valid":
				ctx.errors.append(_err(arg_pos.x, "is_instance_valid() on a struct cannot work once it is an Array"))
			elif receiver != "" and last in ARRAY_INSERTS:
				if _raw(ctx, receiver, here) in ["Array", "", "Variant"]:
					ctx.errors.append(_err(arg_pos.x, "struct added to `%s`, which is not typed as an Array of that struct" % receiver))
			elif last in CALLABLE_SINKS:
				ctx.warnings.append(_err(arg_pos.x, "struct passed to `%s` - its receivers are not checked; type their parameters as the struct" % callee))
			else:
				if param_types == null:
					param_types = ctx.lookups.params.call(callee, here.x, here.y)
				if param_types is Array and k < param_types.size() and not param_types[k]:
					ctx.errors.append(_err(arg_pos.x, "struct passed to untyped parameter %d of `%s`" % [k + 1, callee]))


## `map`/`filter`/... on an Array of structs hand each element to a lambda whose parameter must be
## typed, or `e.x` in its body compiles against Variant. A Callable that is neither inline nor a lambda
## bound to a var in scope cannot be seen into, so it only warns.
static func _check_iterator(callee:String, receiver:String, indexes:Array, arg:String, arg_pos:Vector2i,
		here:Vector2i, ctx:Dictionary) -> void:
	var element = _collection_element(_raw(ctx, receiver, here))
	if element == "" or not ctx.structs.has(_raw(ctx, element, here)):
		return
	var typed = null
	if arg.begins_with("func") and _rx("lambda").search(arg):
		typed = _lambda_params(arg).map(func(p): return p.type != "")
	elif arg.is_valid_ascii_identifier():
		typed = ctx.lookups.lambda_params.call(arg, arg_pos.x, arg_pos.y)
	if typed == null:
		ctx.warnings.append(_err(here.x, "`%s` takes a Callable over an Array of structs - its parameters are not checked" % callee))
		return
	for idx in indexes:
		if idx >= typed.size() or not typed[idx]:
			ctx.errors.append(_err(here.x, "`%s` over an Array of structs needs lambda parameter %d typed" % [callee, idx + 1]))


## A struct inside an array or dict literal is only kept typed when the literal is the whole value of
## a var, assignment or return declared `Array[S]` / `Dictionary[K, S]`. One report per statement.
static func _check_literals(code:String, positions:Array[Vector2i], ctx:Dictionary) -> void:
	var stripped = code.strip_edges()
	if stripped.begins_with("enum"):
		return
	var lead = code.length() - code.strip_edges(true, false).length()
	var context = _literal_context(stripped, lead, positions, ctx)
	var mask = _string_mask(code)
	for i in code.length():
		if mask[i] == 1 or not code[i] in "[{":
			continue
		if code[i] == "[" and not _is_literal_open(code, mask, i):
			continue
		var close = _find_close(code, mask, i)
		if close == -1:
			continue
		var text = code.substr(i, close - i + 1)
		var allowed:String = context[1] if text == context[0] else ""
		for element in _literal_elements(text):
			if element[0] == "":
				continue
			var pos = _at(positions, i + element[1])
			var held = _type(ctx, element[0], pos)
			if held != "" and held != allowed:
				ctx.errors.append(_err(pos.x, "struct inside a literal - only a var, assignment or return typed Array[S] or Dictionary[K, S] may hold one; bind it to one first"))
				return


## [rhs, class path of the struct that rhs may hold] for a statement whose declared type is a typed
## collection, or ["", ""]. `code` is stripped and starts at offset `lead`.
static func _literal_context(code:String, lead:int, positions:Array[Vector2i], ctx:Dictionary) -> Array:
	var here = _at(positions, lead)
	var m = _rx("flow_typed_var").search(code)
	if m:
		return [m.get_string("rhs"), _element_path(m.get_string("type"), _at(positions, lead + m.get_start("type")), ctx)]
	if _rx("flow_var").search(code):
		return ["", ""]
	m = _rx("flow_return").search(code)
	if m:
		return [m.get_string("rhs"), _element_path(ctx.lookups.return_raw.call(here.x, here.y), here, ctx)]
	m = _rx("flow_assign").search(code)
	if m:
		return [m.get_string("rhs"), _element_path(_raw(ctx, m.get_string("target"), here), here, ctx)]
	return ["", ""]


static func _element_path(type_text:String, pos:Vector2i, ctx:Dictionary) -> String:
	var element = _collection_element(type_text)
	return _raw(ctx, element, pos) if element != "" else ""


## "Array[X]" -> "X", "Dictionary[K, X]" -> "X", anything else -> "".
static func _collection_element(type_text:String) -> String:
	var t = type_text.strip_edges()
	if not t.ends_with("]"):
		return ""
	if t.begins_with("Array["):
		return t.substr(6, t.length() - 7).strip_edges()
	if t.begins_with("Dictionary["):
		var parts = _split_args(t.substr(11, t.length() - 12))
		return parts[1] if parts.size() == 2 else ""
	return ""


## A `[` opens a literal unless it follows an expression - a name, a call or another subscript -
## where it indexes instead.
static func _is_literal_open(code:String, mask:PackedByteArray, i:int) -> bool:
	var j = i - 1
	while j >= 0 and code[j] in " \t":
		j -= 1
	if j < 0:
		return true
	if mask[j] == 1 or code[j] == ")" or code[j] == "]":
		return false
	if not _is_ident_char(code[j]):
		return true
	var k = j
	while k >= 0 and _is_ident_char(code[k]):
		k -= 1
	return code.substr(k + 1, j - k) in LITERAL_KEYWORDS


## Elements of a literal as [text, offset in the literal]: array items, or both sides of each dict entry.
static func _literal_elements(text:String) -> Array:
	var out = []
	for part in _split_args_at(text.substr(1, text.length() - 2)):
		var entry:String = part[0]
		var at:int = part[1] + 1
		if text.begins_with("["):
			out.append([entry, at])
			continue
		var mask = _string_mask(entry)
		var depth = 0
		var sep = -1
		for i in entry.length():
			if mask[i] == 1:
				continue
			var c = entry[i]
			if c in "([{":
				depth += 1
			elif c in ")]}":
				depth -= 1
			elif depth == 0 and (c == ":" or c == "="):
				sep = i
				break
		if sep == -1:
			out.append([entry, at])
		else:
			var key = _stripped_at(entry, 0, sep)
			var value = _stripped_at(entry, sep + 1, entry.length())
			out.append([key[0], at + key[1]])
			out.append([value[0], at + value[1]])
	return out


## [{name, type}] of the lambda `text` starts with; `type` is "" for an untyped or `:=` parameter.
static func _lambda_params(text:String) -> Array:
	var open = text.find("(")
	if open == -1:
		return []
	var close = _find_close(text, _string_mask(text), open)
	if close == -1:
		return []
	var out = []
	for p in _split_args(text.substr(open + 1, close - open - 1)):
		var am = _rx("arg").search(p)
		if am == null:
			continue
		var typed = am.get_string("op") != ":="
		out.append({"name": am.get_string("name"), "type": am.get_string("type").strip_edges() if typed else ""})
	return out

#endregion


#region Text helpers

## 1 for every character inside a string literal on this single line.
static func _string_mask(code:String) -> PackedByteArray:
	var mask = PackedByteArray()
	mask.resize(code.length())
	var quote = ""
	var i = 0
	while i < code.length():
		var c = code[i]
		if quote == "" and (c == '"' or c == "'"):
			var triple = c + c + c
			quote = triple if code.substr(i, 3) == triple else c
			for k in quote.length():
				mask[i + k] = 1
			i += quote.length()
			continue
		if quote != "":
			mask[i] = 1
			if c == "\\" and i + 1 < code.length():
				mask[i + 1] = 1
				i += 2
				continue
			if code.substr(i, quote.length()) == quote:
				for k in quote.length():
					mask[i + k] = 1
				i += quote.length()
				quote = ""
				continue
		i += 1
	return mask


static func _find_open(code:String, mask:PackedByteArray, close:int) -> int:
	var depth = 0
	for i in range(close, -1, -1):
		if mask[i] == 1:
			continue
		var c = code[i]
		if c in ")]}":
			depth += 1
		elif c in "([{":
			depth -= 1
			if depth == 0:
				return i
	return -1


static func _is_ident_char(c:String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")


static func _find_close(code:String, mask:PackedByteArray, open:int) -> int:
	var depth = 0
	for i in range(open, code.length()):
		if mask[i] == 1:
			continue
		var c = code[i]
		if c in "([{":
			depth += 1
		elif c in ")]}":
			depth -= 1
			if depth == 0:
				return i
	return -1


static func _split_args(text:String) -> Array:
	return _split_args_at(text).map(func(part): return part[0])


## Top-level comma-separated parts as [stripped text, offset of that text in `text`].
static func _split_args_at(text:String) -> Array:
	if text.strip_edges() == "":
		return []
	var mask = _string_mask(text)
	var out = []
	var depth = 0
	var last = 0
	for i in text.length():
		if mask[i] == 1:
			continue
		var c = text[i]
		if c in "([{":
			depth += 1
		elif c in ")]}":
			depth -= 1
		elif c == "," and depth == 0:
			out.append(_stripped_at(text, last, i))
			last = i + 1
	out.append(_stripped_at(text, last, text.length()))
	return out


static func _stripped_at(text:String, from:int, to:int) -> Array:
	var raw = text.substr(from, to - from)
	return [raw.strip_edges(), from + raw.length() - raw.strip_edges(true, false).length()]


static func _is_header(code:String) -> bool:
	return code.begins_with("extends") or code.begins_with("class_name") or _rx("annotation").search(code) != null


static func _header_extends(code:String) -> String:
	var m = _rx("extends").search(code)
	return m.get_string("name") if m else ""


static func _indent_of(line:String) -> int:
	return line.length() - line.strip_edges(true, false).length()


static func _is_variant_type(type:String) -> bool:
	if _variant_types.is_empty():
		for i in TYPE_MAX:
			_variant_types[type_string(i)] = true
	return _variant_types.has(type)


static func _err(line:int, msg:String) -> String:
	return "line %d: %s" % [line + 1, msg]


static func _rx(key:String) -> RegEx:
	if _regexes.is_empty():
		var patterns = {
			"class": r"^class\s+(?<name>\w+)(?:\s+extends\s+(?<extends>[\w.]+))?\s*:\s*(?<rest>.*)$",
			"var": r"^var\s+(?<name>\w+)\s*(?::\s*(?<type>[\w.\[\], ]+?))?\s*(?:(?<op>:?=)\s*(?<default>.+?))?\s*$",
			"func": r"^(?:static\s+)?func\s+(?<name>\w+)\s*\(",
			"arg": r"^(?<name>\w+)\s*(?::\s*(?<type>[^=]+?))?\s*(?:(?<op>:?=)\s*(?<default>.+?))?\s*$",
			"assign": r"^(?:self\.)?(?<field>\w+)\s*=\s*(?<arg>\w+)$",
			"extends": r"(?:^|\s)extends\s+(?<name>\S+)",
			"annotation": r"^@\w+(?:\(.*\))?$",
			"new": r"(?<![\w.])(?<head>" + _CHAIN + r")\.new\(",
			"is": r"\bis\s+(?<chain>" + _CHAIN + ")",
			"hint": r"(?<pre>->\s*|\bas\s+|\b\w+\s*:\s*)(?<chain>" + _CHAIN + r")(?![\w.(\[])",
			"typed_first": r"(?<pre>\b(?:Array|Dictionary)\[\s*)(?<chain>" + _CHAIN + r")(?=\s*[\],])",
			"typed_second": r"(?<pre>\bDictionary\[\s*" + _CHAIN + r"\s*,\s*)(?<chain>" + _CHAIN + r")(?=\s*\])",
			"literal": r'^(?:-?\d[\d_.eE+-]*|true|false|null|"[^"\\]*"|&"[^"\\]*"|\^"[^"\\]*"|\[\s*\]|\{\s*\}|[A-Z]\w*\(\s*\))$',
			"flow_var": r"^(?:static\s+)?var\s+(?<name>\w+)\s*=(?!=)\s*(?<rhs>.+?)\s*$",
			"flow_typed_var": r"^(?:static\s+)?var\s+(?<name>\w+)\s*:\s*(?<type>[^=]+?)\s*=(?!=)\s*(?<rhs>.+?)\s*$",
			"flow_return": r"^return\s+(?<rhs>.+?)\s*$",
			"flow_assign": r"^(?<target>[A-Za-z_][\w.\[\]()\x22\x27]*?)\s*(?<![!<>=+\-*/%&|^:~])=(?!=)\s*(?<rhs>.+?)\s*$",
			"call": r"(?<![\w.])(?<callee>" + _CHAIN + r")\s*\(",
			"lambda": r"\bfunc\s*\(",
			"decl_infer": r"^\s*(?<decl>(?:static\s+)?var\s+\w+\s*:=)",
		}
		for k in patterns:
			var regex = RegEx.new()
			regex.compile(patterns[k])
			_regexes[k] = regex
	return _regexes[key]

#endregion
