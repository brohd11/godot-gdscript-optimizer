extends RefCounted
## Every `#!` tag in the scanned scripts, resolved to what it is attached to, so each file is read
## once and passes can ask which members carry a tag. Queries only see files already scanned;
## scan_files() the input set before relying on get_entries(). No editor dependencies.

## Parser type-path member delimiter (Keys.MEMBER_DELIM), split like Keys does it.
const MEMBER_DELIM = ":" + ":"

## Tag line(s) directly above a func/var/const/signal/class/enum declaration.
const ATTACH_MEMBER = &"member"
## A header tag - blank line after it, or directly above class_name/extends.
const ATTACH_FILE = &"file"
## A tag trailing code on the same line.
const ATTACH_LINE = &"line"

static var _tag_regex:RegEx
static var _decl_regex:RegEx
static var _header_regex:RegEx
static var _annotation_regex:RegEx

var _files:Dictionary = {} # {path: entries}
var _by_tag:Dictionary = {} # {tag: entries}
var _by_identity:Dictionary = {} # {identity: {tag: first entry}}


func scan_file(path:String) -> Array:
	if _files.has(path):
		return _files[path]
	var entries:Array = []
	if path.get_extension() == "gd" and FileAccess.file_exists(path):
		entries = scan_lines(FileAccess.get_file_as_string(path).split("\n"), path)
	_files[path] = entries
	for entry:Dictionary in entries:
		_by_tag.get_or_add(entry.tag, []).append(entry)
		var tags:Dictionary = _by_identity.get_or_add(entry.identity, {})
		if not tags.has(entry.tag):
			tags[entry.tag] = entry
	return entries


func scan_files(paths:Array) -> void:
	for path:String in paths:
		scan_file(path)


func get_entries(tag:String) -> Array:
	return _by_tag.get(tag, [])


func get_file_entries(path:String) -> Array:
	return scan_file(path)


func has_tag(identity:String, tag:String) -> bool:
	return _by_identity.get(identity, {}).has(tag)


## The first entry for `tag` on `identity`, or {}.
func get_tag_data(identity:String, tag:String) -> Dictionary:
	return _by_identity.get(identity, {}).get(tag, {})


## Entries as {tag, mods, args, file, line, attach, identity, target}, `target` being the line the
## tag attaches to (the declaration, or its own line). Identity is a parser type path:
## "res://a.gd" (file/line), "res://a.gd.Outer.Inner" (class), "res://a.gd.Outer::field" (member).
## `owners`, when passed, receives the enclosing class path of every line.
static func scan_lines(lines:PackedStringArray, path:String, owners:Array = []) -> Array:
	_ensure_regex()
	var entries:Array = []
	var state = {"quote": "", "depth": 0, "cont": false}
	var classes:Array = [] # [{indent, name}] enclosing the current line
	var pending:Array = []
	var blank_after_pending = false
	var seen_code = false

	for i in lines.size():
		var line:String = lines[i].trim_suffix("\r")
		var continued:bool = state.cont
		var comment_idx = scan_code(line, state)
		var code = (line.substr(0, comment_idx) if comment_idx > -1 else line).strip_edges()
		var tag:Dictionary = {}
		if comment_idx > -1:
			tag = _parse_tag(line.substr(comment_idx).strip_edges(false, true), path, i)

		if continued:
			owners.append(_class_path(path, classes))
			if not tag.is_empty():
				_add(entries, tag, ATTACH_LINE, owners.back())
			continue

		if code.is_empty():
			owners.append(_class_path(path, classes))
			if not tag.is_empty():
				pending.append(tag)
				blank_after_pending = false
			elif comment_idx == -1 and not pending.is_empty():
				blank_after_pending = true
			continue

		var indent = line.length() - line.strip_edges(true, false).length()
		while not classes.is_empty() and classes.back().indent >= indent:
			classes.pop_back()
		var owner = _class_path(path, classes)
		owners.append(owner)
		if not tag.is_empty():
			_add(entries, tag, ATTACH_LINE, owner)

		if _annotation_regex.search(code):
			continue # `@tool` / `@export` sit between a tag and what it tags

		var decl = _decl_regex.search(code)
		if decl:
			var kind = decl.get_string("kind")
			var decl_name = decl.get_string("name")
			var identity = owner
			if kind == "class":
				identity = owner + "." + decl_name
				classes.append({"indent": indent, "name": decl_name})
			elif decl_name != "":
				identity = owner + MEMBER_DELIM + decl_name
			var header_block = not seen_code and blank_after_pending
			for t in pending:
				_add(entries, t, ATTACH_FILE if header_block else ATTACH_MEMBER, path if header_block else identity, i)
		elif (classes.is_empty() and _header_regex.search(code) != null) or not seen_code:
			for t in pending:
				_add(entries, t, ATTACH_FILE, path, i)

		seen_code = true
		pending.clear()
		blank_after_pending = false

	return entries


static func _add(entries:Array, tag:Dictionary, attach:StringName, identity:String, target:int = -1) -> void:
	var entry = tag.duplicate()
	entry.attach = attach
	entry.identity = identity
	entry.target = tag.line if target == -1 else target
	entries.append(entry)


static func _class_path(path:String, classes:Array) -> String:
	var out = path
	for c in classes:
		out += "." + c.name
	return out


## TagParser's grammar (`#! tag mods; args`, a lone value being args), with hyphens allowed in the
## tag name. The tag has to open the comment, so prose mentioning one never fires.
static func _parse_tag(comment:String, path:String, line_no:int) -> Dictionary:
	var m = _tag_regex.search(comment)
	if m == null:
		return {}
	var mods = m.get_string("mod").strip_edges()
	var args = m.get_string("args").strip_edges()
	if args.is_empty() and not comment.contains(";"):
		args = mods
		mods = ""
	return {"tag": m.get_string("tag"), "mods": mods, "args": args, "file": path, "line": line_no}


## Index the comment starts at, or -1. `state` carries open triple-quoted strings and bracket depth
## across lines; `state.cont` is set when the statement continues onto the next line.
static func scan_code(line:String, state:Dictionary) -> int:
	var quote:String = state.quote
	var comment_idx = -1
	var i = 0
	var n = line.length()
	while i < n:
		var c = line[i]
		if quote != "":
			if c == "\\":
				i += 2
			elif line.substr(i, quote.length()) == quote:
				i += quote.length()
				quote = ""
			else:
				i += 1
			continue
		if c == "#":
			comment_idx = i
			break
		if c == '"' or c == "'":
			var triple = c + c + c
			quote = triple if line.substr(i, 3) == triple else c
			i += quote.length()
			continue
		if c in "([{":
			state.depth += 1
		elif c in ")]}":
			state.depth = maxi(state.depth - 1, 0)
		i += 1

	if quote.length() == 1: # only a triple quote spans lines
		quote = ""
	state.quote = quote
	var code = line.substr(0, comment_idx) if comment_idx > -1 else line
	state.cont = state.depth > 0 or quote != "" or code.strip_edges(false, true).ends_with("\\")
	return comment_idx


static func _ensure_regex() -> void:
	if _tag_regex != null:
		return
	_tag_regex = RegEx.new()
	_tag_regex.compile("^#!\\s*(?<tag>[\\w-]+)(?:\\s+(?<mod>[^;]+?))?(?:\\s*;\\s*(?<args>.*))?\\s*$")
	const ANNOTATIONS = "(?:@\\w+(?:\\([^)]*\\))?\\s+)*"
	_decl_regex = RegEx.new()
	_decl_regex.compile("^" + ANNOTATIONS + "(?:static\\s+)?(?<kind>func|var|const|signal|class|enum)\\b\\s*(?<name>\\w*)")
	_header_regex = RegEx.new()
	_header_regex.compile("^" + ANNOTATIONS + "(?:class_name|extends)\\b")
	_annotation_regex = RegEx.new()
	_annotation_regex.compile("^@\\w+(?:\\(.*\\))?$")
