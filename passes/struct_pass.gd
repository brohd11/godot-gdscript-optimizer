extends RefCounted
## Plans against original sources, then replays edits on a consumer's output text.
## Path relocation and surviving global names belong to the processing context.

const TagRegistry = preload("res://addons/addon_lib/tag_parser/registry.gd")
const StructRewrite = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct/struct_rewrite.gd")
const StructTypes = preload("res://addons/addon_lib/gdscript_optimizer/passes/struct/struct_types.gd")

var plans:Dictionary = {}
var structs:Dictionary = {}
var _parser_cache:Dictionary = {}
var _warnings:Array = []
var _context


func prepare(sources:Dictionary, context) -> Dictionary:
	plans.clear()
	structs.clear()
	_parser_cache.clear()
	_warnings.clear()
	_context = context
	var registry = TagRegistry.new()
	var errors:Array = []
	for key:String in sources:
		var source:String = sources[key]
		if source.get_extension() != "gd":
			continue
		if not FileAccess.file_exists(source):
			errors.append("%s: source file does not exist" % source)
			continue
		for entry:Dictionary in registry.get_file_entries(source):
			if entry.tag != "struct":
				continue
			var valid_attachment:bool = entry.attach == TagRegistry.ATTACH_FILE or \
				(entry.attach == TagRegistry.ATTACH_MEMBER and entry.target_kind == "class")
			if not valid_attachment:
				errors.append("%s:%d: put #! struct on its own line above a class" % [source, entry.line + 1])
				continue
			var lines = FileAccess.get_file_as_string(source).split("\n")
			var def = StructRewrite.parse_def(lines, entry.target, entry.attach == TagRegistry.ATTACH_FILE, entry.identity)
			for err in def.errors:
				errors.append("%s %s" % [source, err])
			def.file = source
			def.key = key
			structs[entry.identity] = def
	if not errors.is_empty() or structs.is_empty():
		return {"errors": errors, "warnings": _warnings}

	var reach = _struct_reach(sources.values())
	for key:String in sources:
		var source:String = sources[key]
		if source.get_extension() != "gd":
			continue
		var plan = _plan_file(source, reach.has(source), errors)
		if not plan.is_empty():
			plans[key] = plan
	return {"errors": errors, "warnings": _warnings}


## Field access and the flow check first, on the source text the parser sees; then phase-1 sites on
## that result, while line indexes still match; then each struct body here, bottom first.
func _plan_file(source:String, reachable:bool, errors:Array) -> Dictionary:
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
	if reachable:
		StructRewrite.rewrite_lines(lines, resolve, structs) # only fills `names`
		var types = StructTypes.new(_context.parser_script, source, structs, _parser_cache)
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
		var access = StructRewrite.rewrite_access(lines, types.type_of, structs, name_for, types.annotation)
		ops = access.ops
		sites = access.lines

	var result = StructRewrite.rewrite_lines(sites, resolve, structs)
	for err in result.errors:
		errors.append("%s %s" % [source, err])
	for line in result.ops:
		ops.get_or_add(line, []).append_array(result.ops[line])

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
	return {"ops": ops, "bodies": bodies, "injected": injected}


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
	for body in plan.bodies:
		if body.start >= lines.size() or lines[body.start] != body.expect:
			errors.append("could not find the body of %s" % body.class_path)
			continue
		var edited = lines.slice(0, body.start)
		edited.append_array(body.lines)
		edited.append_array(lines.slice(body.end + 1))
		lines = edited
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
			lines.append(line)
	return {"lines": lines, "errors": []}
