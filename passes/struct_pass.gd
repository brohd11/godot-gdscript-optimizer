extends RefCounted
## Plans against original sources, then replays edits on a consumer's output text.
## Path relocation and surviving global names belong to the processing context.

const DebugTags = preload("res://addons/addon_lib/gdscript_optimizer/debug_tags.gd")
const TagRegistry = preload("res://addons/addon_lib/tag_parser/registry.gd")
const StructRewrite = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct/struct_rewrite.gd")
const StructTypes = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct/struct_types.gd")
const StructOptimize = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct/struct_optimize.gd")

var plans:Dictionary = {}
var structs:Dictionary = {}
var _parser_cache:Dictionary = {}
var _warnings:Array = []
var _context
var _source_keys:Dictionary = {}
var _discovery:Dictionary = {}
var _types_cache:Dictionary = {}


func prepare(sources:Dictionary, context) -> Dictionary:
	plans.clear()
	structs.clear()
	_parser_cache.clear()
	_warnings.clear()
	_context = context
	_source_keys.clear()
	for key:String in sources:
		_source_keys[sources[key]] = key
	_types_cache.clear()
	_discovery = {"struct_candidates": 0, "struct_eligible": 0, "struct_candidates_skipped": 0}
	var errors:Array = []
	if context.struct_mode == "off":
		return {"errors": [], "warnings": [], "stats": _discovery}
	for key:String in sources:
		var source:String = sources[key]
		if source.get_extension() != "gd":
			continue
		if not FileAccess.file_exists(source):
			errors.append("%s: source file does not exist" % source)
			continue
		var lines := FileAccess.get_file_as_string(source).split("\n")
		var tags:Array = TagRegistry.scan_lines(lines, source).filter(func(entry): return entry.tag == "struct")
		if context.struct_mode != "auto" and tags.is_empty():
			continue
		var entries:Dictionary = {}
		var excluded:Dictionary = {}
		var types = _types(source)
		if types.error != "":
			errors.append(types.error)
			continue
		if context.struct_mode == "auto":
			for access:String in types.parser.get_classes():
				var owner = types.parser.get_class_object(access)
				var identity:String = owner.get_script_class_path()
				entries[identity] = {"identity": identity, "target": maxi(0, owner.declaration_line),
					"attach": TagRegistry.ATTACH_FILE if identity == source else TagRegistry.ATTACH_MEMBER,
					"explicit": false}
		for entry:Dictionary in tags:
			var valid_attachment:bool = entry.attach == TagRegistry.ATTACH_FILE or (entry.attach == TagRegistry.ATTACH_MEMBER and entry.target_kind == "class")
			var options:Dictionary = TagRegistry.Options.parse(entry.args)
			if not valid_attachment or not entry.mods.is_empty() or not options.errors.is_empty() or (not options.options.is_empty() and options.options != {"off": true}):
				errors.append("%s:%d: invalid struct tag; use #! struct or #! struct; off above a class" % [source, entry.line + 1])
				continue
			if options.options.has("off"):
				excluded[entry.identity] = true
				continue
			entry.explicit = true
			entries[entry.identity] = entry
		for identity:String in excluded:
			entries.erase(identity)
		for entry:Dictionary in entries.values():
			_discovery.struct_candidates += 1
			var def := StructRewrite.parse_def(lines, entry.target, entry.attach == TagRegistry.ATTACH_FILE, entry.identity)
			if not def.errors.is_empty():
				if entry.explicit:
					for err:String in def.errors:
						errors.append("%s %s" % [source, err])
				continue
			def.file = source
			def.key = key
			def.explicit = entry.explicit
			if not context.aggressive and not _value_fields(def, types.parser):
				if entry.explicit:
					_warnings.append("%s: struct %s requires aggressive for reference, Variant, or unresolved fields" % [source, entry.identity])
				continue
			structs[entry.identity] = def
	if errors.is_empty():
		_validate_auto(sources)
	if errors.is_empty() and not structs.is_empty():
		var reach = _struct_reach(sources.values())
		for key:String in sources:
			var source:String = sources[key]
			if source.get_extension() != "gd":
				continue
			var plan = _plan_file(source, reach.has(source), errors)
			if not plan.is_empty():
				plans[key] = plan
	_release_parsers()
	_discovery.struct_eligible = structs.size()
	_discovery.struct_candidates_skipped = _discovery.struct_candidates - structs.size()
	return {"errors": errors, "warnings": _warnings, "stats": _discovery}


func _release_parsers() -> void:
	var parsers:Array = _types_cache.values().map(func(types): return types.parser)
	for data:Dictionary in _parser_cache.get(_context.parser_script.Keys.CACHE_ACTIVE_PARSERS, {}).values():
		parsers.append(data.get(_context.parser_script.Keys.CACHE_PARSER))
	for parser in parsers:
		if is_instance_valid(parser):
			parser.active_parser = null
			if is_instance_valid(parser.code_edit):
				parser.code_edit.free()
	_parser_cache.clear()
	_types_cache.clear()


func _types(source:String):
	if not _types_cache.has(source):
		_types_cache[source] = StructTypes.new(_context.parser_script, source, structs, _parser_cache)
	return _types_cache[source]


func _value_fields(def:Dictionary, parser) -> bool:
	for field:Dictionary in def.fields:
		var declaration:Variant = parser.Utils.get_var_or_const_info(parser.code_edit.get_line(field.line).strip_edges())
		if declaration == null or (field.type == "" and not declaration[3]):
			return false
		var owner = parser.get_class_object(parser.get_class_at_line(field.line))
		var type:String = owner.get_member_type(field.name).trim_suffix(parser.Keys.INS_DELIM)
		if type not in StructOptimize.ValueTypes.VALUES:
			return false
	return true


func _validate_auto(sources:Dictionary) -> void:
	# Remove complete candidates before planning edits; repeat after dependent types change.
	while structs.values().any(func(def): return not def.explicit):
		var rejected:Dictionary = {}
		var reach := _struct_reach(sources.values())
		for source:String in sources.values():
			if source.get_extension() != "gd" or not reach.has(source):
				continue
			var types = _types(source)
			for access:String in types.parser.get_classes():
				var owner = types.parser.get_class_object(access)
				for inherited:String in owner.get_inherited_scripts():
					if structs.has(inherited) and not structs[inherited].explicit:
						rejected[inherited] = true
			var lines := FileAccess.get_file_as_string(source).split("\n")
			var flow := StructRewrite.check_flow(lines, types.lookups(), structs, true)
			for identity:String in flow.rejected:
				if structs.has(identity) and not structs[identity].explicit:
					rejected[identity] = true
		if rejected.is_empty():
			break
		for identity:String in rejected:
			structs.erase(identity)



## Field access and the flow check first, on the source text the parser sees; then phase-1 sites on
## that result, while line indexes still match; then each struct body here, bottom first.
func _plan_file(source:String, reachable:bool, errors:Array) -> Dictionary:
	if not reachable and not structs.values().any(func(def): return def.file == source):
		return {}
	var lines = FileAccess.get_file_as_string(source).split("\n")
	var owners = []
	TagRegistry.scan_lines(lines, source, owners)
	var script = load(source) as GDScript
	if script == null:
		errors.append("%s: could not load GDScript" % source)
		return {}
	var cache = {}
	var names = {} # class path -> how this file already spells it at file scope
	var resolve = func(head:String, line:int) -> String:
		var found = _resolve(script, source, owners, head, line, cache)
		if found != "" and not names.has(found) and line < owners.size() and owners[line] == source:
			names[found] = head
		return found

	var ops = {}
	var injected = {}
	var sites = lines
	var optimization
	if reachable:
		StructRewrite.rewrite_lines(lines, resolve, structs) # only fills `names`
		var types = _types(source)
		if types.error != "":
			errors.append(types.error)
			return {}
		var flow = StructRewrite.check_flow(lines, types.lookups(), structs)
		for err in flow.errors:
			errors.append("%s %s" % [source, err])
		for warning in flow.warnings:
			_warnings.append("%s %s" % [source, warning])
		var name_for = func(path:String) -> String:
			if not names.has(path):
				names[path] = _injection(path, lines, injected)
			return names[path]
		optimization = StructOptimize.new(lines, types, _context)
		var access = StructRewrite.rewrite_access(lines, types.type_of, structs, name_for, types.annotation, optimization)
		ops = access.ops
		sites = access.lines

	var result = StructRewrite.rewrite_lines(sites, resolve, structs)
	for err in result.errors:
		errors.append("%s %s" % [source, err])
	for line in result.ops:
		ops.get_or_add(line, []).append_array(result.ops[line])
	if optimization != null:
		optimization.finish(result.lines, ops)
		for path:String in optimization.type_dependencies:
			injected[optimization.type_dependencies[path]] = {"key": _source_keys.get(path, path), "tail": ""}
		for warning:String in optimization.warnings:
			_warnings.append("%s: %s" % [source, warning])

	var bodies = []
	for def:Dictionary in structs.values():
		if def.file != source:
			continue
		var body_resolve = func(head:String, _line:int) -> String:
			return resolve.call(head, def.body_start)
		var body = StructRewrite.rewrite_lines(StructRewrite.build_body(def), body_resolve, structs)
		bodies.append({
			"class_path": def.class_path, "start": def.body_start, "end": def.body_end,
			"expect": result.lines[def.body_start], "lines": body.lines,
		})
	bodies.sort_custom(func(a, b): return a.start > b.start)

	if ops.is_empty() and bodies.is_empty() and injected.is_empty():
		return {}
	return {"ops": ops, "bodies": bodies, "injected": injected,
		"stats": optimization.stats if optimization != null else {},
		"debug_events": optimization.debug_events if optimization != null else [], "source": source}


## Files whose references reach a struct script. Only these can hold a value the parser types as a
## struct - a type travels through preloads, extends and global classes - so only these are parsed.
func _struct_reach(roots:Array) -> Dictionary:
	var refs = {}
	var queue = roots.duplicate()
	while not queue.is_empty():
		var path:String = queue.pop_back()
		if refs.has(path) or path.get_extension() != "gd" or not FileAccess.file_exists(path):
			continue
		var out = []
		out.append_array(_context.references(path))
		refs[path] = out
		queue.append_array(out)

	var reach = {}
	for def in structs.values():
		reach[def.file] = true
	var changed = true
	while changed:
		changed = false
		for path in refs:
			if reach.has(path):
				continue
			for target in refs[path]:
				if reach.has(target):
					reach[path] = true
					changed = true
					break
	return reach


## How a file that never spells a struct reaches its enum: a global class name that survives the
## export is used as is, anything else gets a const preload appended to the file.
func _injection(path:String, lines:PackedStringArray, injected:Dictionary) -> String:
	var def:Dictionary = structs[path]
	var tail = path.substr(def.file.length() + 1) if path.length() > def.file.length() else ""
	var base:String
	if tail != "":
		base = tail.get_slice(".", tail.get_slice_count(".") - 1)
	else:
		var global_name:String = _context.class_path_lookup.get(def.file, "")
		if global_name != "" and not _context.removed_globals.has(global_name):
			return global_name
		base = global_name if global_name != "" else def.file.get_file().get_basename().to_pascal_case()

	var text = "\n".join(lines)
	var const_name = base
	var n = 1
	while injected.has(const_name) or RegEx.create_from_string("\\b%s\\b" % const_name).search(text) != null:
		const_name = "%sStruct%s" % [base, "" if n == 1 else str(n)]
		n += 1
	injected[const_name] = {"key": def.key, "tail": tail}
	return const_name


## An unqualified name is tried as an inner class from the innermost enclosing class outward, as
## GDScript scopes it; anything else goes through the script's consts and the global classes.
func _resolve(script:GDScript, source:String, owners:Array, head:String, line:int, cache:Dictionary) -> String:
	var owner:String = owners[line] if line >= 0 and line < owners.size() else source
	var cache_key = owner + "|" + head
	if cache.has(cache_key):
		return cache[cache_key]

	var found = ""
	var scope = owner
	while true:
		if structs.has(scope + "." + head):
			found = scope + "." + head
			break
		if scope.length() <= source.length():
			break
		scope = scope.substr(0, scope.rfind("."))
	if found == "" and script != null:
		var resolved = _context.resolve_name(script, head)
		if resolved is String and structs.has(resolved):
			found = resolved
	cache[cache_key] = found
	return found


func apply(key:String, input_lines:Array) -> Dictionary:
	var plan = plans.get(key)
	if plan == null:
		return {"lines": input_lines, "errors": []}
	var lines = input_lines.duplicate()
	var errors = StructRewrite.apply_ops(lines, plan.ops)
	var events:Array = []
	if _context.debug_tags:
		events = plan.debug_events.duplicate(true)
		for line:int in plan.ops:
			for op:Array in plan.ops[line]:
				if op[0] != op[1]:
					events.append({"line": line, "kind": "struct", "details": {"mode": "rewrite"}})
		for body:Dictionary in plan.bodies:
			events.append({"line": body.start, "kind": "struct", "details": {"mode": "lower", "class": body.class_path}})
		for event:Dictionary in events:
			event.details.site = "%s:%d" % [plan.source, event.line + 1]
	for body in plan.bodies:
		if body.start >= lines.size() or lines[body.start] != body.expect:
			errors.append("could not find the body of %s" % body.class_path)
			continue
		var edited = lines.slice(0, body.start)
		edited.append_array(body.lines)
		edited.append_array(lines.slice(body.end + 1))
		lines = edited
		for event:Dictionary in events:
			if event.line > body.end:
				event.line += body.lines.size() - (body.end - body.start + 1)
			elif event.line >= body.start:
				event.line = body.start
	if not errors.is_empty():
		return {"lines": input_lines, "errors": errors}

	if not plan.injected.is_empty():
		var names = plan.injected.keys()
		names.sort()
		lines.append("")
		lines.append(_context.injection_header)
		for name in names:
			var inj = plan.injected[name]
			var line = 'const %s = preload("%s")' % [name, _context.output_path(inj.key)]
			if inj.tail != "":
				line += "." + inj.tail
			if _context.debug_tags:
				events.append({"line": lines.size(), "kind": "struct", "details": {"mode": "dependency", "site": plan.source}})
			lines.append(line)
	var offsets:Array = []
	var physical := 0
	for line:String in lines:
		offsets.append(physical)
		physical += line.count("\n") + 1
	for event:Dictionary in events:
		event.line = offsets[event.line]
	var output:Array = Array("\n".join(lines).split("\n"))
	if _context.debug_tags:
		output = DebugTags.annotate(output, events)
	return {"lines": output, "errors": [], "stats": plan.get("stats", {})}
