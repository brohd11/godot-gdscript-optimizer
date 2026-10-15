@tool
extends EditorScript

## Tests for the text side of `#! struct` (passes/struct/struct_rewrite.gd): reading a data-only
## class, generating its array form, and rewriting constructor and type-hint sites.
##
##     load("res://addons/_lib/gdscript_optimizer/_export_ignore/test/struct_test.gd").run_tests()

const StructRewrite = preload("res://addons/_lib/gdscript_optimizer/src/passes/struct/struct_rewrite.gd")
const StructTypes = preload("res://addons/_lib/gdscript_optimizer/src/passes/struct/struct_types.gd")
const P = "res://s.gd"

const VEC = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_vec.gd"
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_fixture.gd"
const ACCESS = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_access.gd"
const UNTYPED = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/untyped_scenario.gd"

static var _failures:Array[String] = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0

	_test_inner_def()
	_test_file_def()
	_test_def_errors()
	_test_type_default()
	_test_rewrite_sites()
	_test_receiver_start()
	_test_rewrite_access()
	_test_access_with_parser()
	_test_flow_with_parser()
	_test_literals_and_lambdas()

	var output:Array[String] = []
	output.append("struct: %d passed, %d failed" % [_passed, _failures.size()])
	for failure in _failures:
		output.append("  FAIL  " + failure)
	return {"result": _failures.size(), "output": output}


func _run() -> void: # EditorScript entry, for running this from the editor
	print("\n".join(run_tests().output))


static func _point_lines() -> PackedStringArray:
	return PackedStringArray([
		"extends RefCounted",
		"#! struct",
		"class Point:",
		"\t## doc",
		"\tvar x: int",
		"\tvar y: float = 1.5",
		'\tvar tag := "p"',
		"\tvar parent: Point",
		"",
		"\tfunc _init(_x: int, _y: float = 1.5) -> void:",
		"\t\tx = _x",
		"\t\tself.y = _y",
		"",
		"func use():",
		"\tpass",
	])


static func _test_inner_def() -> void:
	var def = StructRewrite.parse_def(_point_lines(), 2, false, P + ".Point")
	_check("inner: no errors", def.errors, [])
	_check("inner: enums", def.fields.map(func(f): return f.enum), ["X", "Y", "TAG", "PARENT"])
	_check("inner: types", def.fields.map(func(f): return f.type), ["int", "float", "", "Point"])
	_check("inner: body range skips the leading comment", [def.body_start, def.body_end], [4, 11])
	_check("inner: arg slots", def.arg_slots, [0, 1])
	_check("inner: literal ok", def.literal_ok, true)
	_check("inner: body", Array(StructRewrite.build_body(def)), [
		"\tenum { X, Y, TAG, PARENT }",
		"\tstatic func create(_x: int, _y: float = 1.5) -> Array:",
		'\t\treturn [_x, _y, "p", null]',
	])


static func _test_file_def() -> void:
	var lines = PackedStringArray(["#! struct", "class_name Vec extends RefCounted", "", "var a", "var b = 2"])
	var def = StructRewrite.parse_def(lines, 1, true, P)
	_check("file: no errors", def.errors, [])
	_check("file: body range", [def.body_start, def.body_end], [3, 4])
	_check("file: body", Array(StructRewrite.build_body(def)), ["enum { A, B }", "static func create() -> Array:", "\treturn [null, 2]"])

	var bad = StructRewrite.parse_def(PackedStringArray(["#! struct", "extends Node", "", "var a"]), 1, true, P)
	_check("file: extends Node rejected", _has(bad.errors, "cannot extend Node"), true)


static func _test_def_errors() -> void:
	_check("error: method", _errors(["class S:", "\tvar a", "\tfunc len():", "\t\treturn a"]), "only holds var fields and _init: func len")
	_check("error: annotation", _errors(["class S:", "\t@export var a"]), "only holds var fields")
	_check("error: setter", _errors(["class S:", "\tvar b", "\tvar a: int:", "\t\tset(v): pass"]), "var a: int:")
	_check("error: signal", _errors(["class S:", "\tvar a", "\tsignal s"]), "signal s")
	_check("error: _init logic", _errors(["class S:", "\tvar a", "\tfunc _init(v):", "\t\ta = v * 2"]), "_init may only assign")
	_check("error: unused arg", _errors(["class S:", "\tvar a", "\tfunc _init(v, w):", "\t\ta = v"]), "w is never assigned")
	_check("error: extends", _errors(["class S extends Node:", "\tvar a"]), "cannot extend Node")
	_check("error: no fields", _errors(["class S:", "\tpass"]), "at least one var field")
	_check("error: enum collision", _errors(["class S:", "\tvar a", "\tvar A"]), "both become enum A")
	_check("error: not a class", _errors(["var a"]), "must sit above a class")
	_check("error: one-line class", _errors(["class S: var a"]), "one-line struct")
	_check("error: line numbers are 1-based", _errors(["class S:", "\tvar a", "\tsignal s"]).begins_with("line 3:"), true)

	var swap = _def(["class Swap:", "\tvar a", "\tvar b", "\tfunc _init(b_in, a_in):", "\t\ta = a_in", "\t\tb = b_in"])
	_check("literal: args out of slot order", [swap.arg_slots, swap.literal_ok], [[1, 0], false])
	var deferred = _def(["class D:", "\tvar a", "\tvar c = SOME_CONST", "\tfunc _init(a_in):", "\t\ta = a_in"])
	_check("literal: non-literal default", deferred.literal_ok, false)
	var inline = _def(["class I:", "\tvar a", "\tfunc _init(v): a = v"])
	_check("inline _init body", [inline.errors, inline.arg_slots], [[], [0]])


static func _test_type_default() -> void:
	var types = ["int", "float", "bool", "String", "StringName", "Vector2", "Array[int]", "Dictionary", "Node", "", "Object"]
	_check("type defaults", types.map(func(t): return StructRewrite.type_default(t)),
		["0", "0.0", "false", '""', '&""', "Vector2()", "[]", "{}", "null", "null", "null"])


static func _test_rewrite_sites() -> void:
	var structs = {
		P + ".Point": StructRewrite.parse_def(_point_lines(), 2, false, P + ".Point"),
		P + ".Swap": _def(["class Swap:", "\tvar a", "\tvar b", "\tfunc _init(b_in, a_in):", "\t\ta = a_in", "\t\tb = b_in"], P + ".Swap"),
		P + ".D": _def(["class D:", "\tvar a", "\tvar c = SOME_CONST", "\tfunc _init(a_in):", "\t\ta = a_in"], P + ".D"),
	}
	var names = {"Point": P + ".Point", "Inner.Point": P + ".Point", "Swap": P + ".Swap", "D": P + ".D"}
	var resolve = func(head:String, _line:int) -> String:
		return names.get(head, "")

	var cases = [
		["var p: Point = Point.new(1, 2.0)", 'var p: Array = [1, 2.0, "p", null]'],
		["var q := Point.new(1)", "var q := Point.create(1)"],
		["func f(a: Point, b: Array[Point]) -> Point:", "func f(a: Array, b: Array[Array]) -> Array:"],
		["var d: Dictionary[Inner.Point, Point] = {}", "var d: Dictionary[Array, Array] = {}"],
		["var r = x as Point", "var r = x as Array"],
		['var s = "Point.new(1, 2)" # Point.new(3)', 'var s = "Point.new(1, 2)" # Point.new(3)'],
		["var n = Point.new(Point.new(1, 2).size(), 3)", 'var n = [[1, 2, "p", null].size(), 3, "p", null]'],
		["var m = Point.new(", "var m = Point.create("],
		["\t1, 2)", "\t1, 2)"],
		["var w = Swap.new(1, 2)", "var w = Swap.create(1, 2)"],
		["var e = D.new(1)", "var e = D.create(1)"],
		["if p is Point: pass", "if p is Point: pass"],
		["var i: int = 0", "var i: int = 0"],
		["var node: Node = Node.new()", "var node: Node = Node.new()"],
		['var t = """', 'var t = """'],
		["Point.new(1, 2)", "Point.new(1, 2)"],
		['"""', '"""'],
	]
	var source = PackedStringArray(cases.map(func(c): return c[0]))
	var result = StructRewrite.rewrite_lines(source, resolve, structs)
	for i in cases.size():
		_check("site: " + cases[i][0], result.lines[i], cases[i][1])
	_check("site: `is` on a struct is an error", result.errors.size(), 1)
	_check("site: error names the line", _has(result.errors, "line 12:"), true)

	var replay = Array(source)
	_check("replay: no misses", StructRewrite.apply_ops(replay, result.ops), [])
	_check("replay: ops reproduce the rewrite", replay, Array(result.lines))
	_check("replay: missing text is reported", StructRewrite.apply_ops(["nothing here"], {0: [["Point.new(", "x"]]}).size(), 1)


static func _test_receiver_start() -> void:
	for c in [
		["foo(1).bar[2].x", "foo(1).bar[2]"],
		["-v.x", "v"],
		["(a + b).x", "(a + b)"],
		['"s".x', ""],
		["self.held.y", "self.held"],
	]:
		var code:String = c[0]
		var dot = code.rfind(".")
		var start = StructRewrite.receiver_start(code, StructRewrite._string_mask(code), dot)
		_check("receiver: " + code, code.substr(start, dot - start), c[1])


## Only the `.field` text changes, so a nested chain replays in order and each receiver is resolved
## as it was written.
static func _test_rewrite_access() -> void:
	var structs = {
		P + ".Outer": _def(["class Outer:", "\tvar inner", "\tvar n"], P + ".Outer"),
		P + ".Inner": _def(["class Inner:", "\tvar c"], P + ".Inner"),
	}
	var types = {"a": P + ".Outer", "a.inner": P + ".Inner"}
	# line 5 holds two sibling lambdas whose `a` differs by column
	var type_of = func(expr:String, line:int, column:int) -> String:
		if line == 5 and expr == "a":
			return P + (".Outer" if column < 30 else ".Inner")
		return types.get(expr, "")
	var name_for = func(path:String) -> String:
		return path.get_slice(".gd.", 1)

	var cases = [
		["x = a.inner.c + a.n", "x = a[Outer.INNER][Inner.C] + a[Outer.N]"],
		['var s = "a.n" # a.n', 'var s = "a.n" # a.n'],
		["a.n()", "a.n()"],
		["a.inner_long", "a.inner_long"],
		["b.n", "b.n"],
		["[func(a): return a.n, func(a): return a.c]", "[func(a): return a[Outer.N], func(a): return a[Inner.C]]"],
		# `:=` cannot infer from an Array index, so the declaration takes the source's inferred type
		["var y := a.n", "var y: float = a[Outer.N]"],
		["var z := a.inner", "var z: Array = a[Outer.INNER]"],
		["static var w := a.inner.c # note", "static var w = a[Outer.INNER][Inner.C] # note"],
		["var k := 1.0", "var k := 1.0"],
	]
	var annotations = {"a.n": "float", "a.inner": "Array"}
	var annotate = func(expr:String, _line:int, _column:int) -> String:
		return annotations.get(expr, "")
	var source = PackedStringArray(cases.map(func(c): return c[0]))
	var result = StructRewrite.rewrite_access(source, type_of, structs, name_for, annotate)
	for i in cases.size():
		_check("access: " + cases[i][0], result.lines[i], cases[i][1])
	_check("access: used", result.used.keys().size(), 2)
	var replay = Array(source)
	_check("access: replay no misses", StructRewrite.apply_ops(replay, result.ops), [])
	_check("access: replay reproduces", replay, Array(result.lines))


static func _real_structs() -> Dictionary:
	var vec = _source_lines(VEC)
	var fixture = _source_lines(FIXTURE)
	return {
		VEC: StructRewrite.parse_def(vec, _line_of(vec, "extends RefCounted"), true, VEC),
		FIXTURE + ".Pair": StructRewrite.parse_def(fixture, _line_of(fixture, "class Pair:"), false, FIXTURE + ".Pair"),
	}


## The real parser over the phase-2 fixture: every typed route resolves, and nothing in it trips
## the flow check.
static func _test_access_with_parser() -> void:
	var structs = _real_structs()
	var lines = _source_lines(ACCESS)
	var types = StructTypes.new(GDScriptParser, ACCESS, structs, {})
	var names = {VEC: "StructVec", FIXTURE + ".Pair": "StructFixture.Pair"}
	var result = StructRewrite.rewrite_access(lines, types.type_of, structs, func(p): return names[p], types.annotation)

	for c in [
		["return v.x * v.x", "\treturn v[StructVec.X] * v[StructVec.X] + v[StructVec.Y] * v[StructVec.Y]"],
		["StructFixture.make(3).left", "\treturn StructFixture.make(3)[StructFixture.Pair.LEFT]"],
		['p.right = "changed"', '\tp[StructFixture.Pair.RIGHT] = "changed"'],
		["return p.right", "\treturn p[StructFixture.Pair.RIGHT]"],
		["v.x += 1.0", "\tv[StructVec.X] += 1.0"],
		["total += v.x", "\t\ttotal += v[StructVec.X]"],
		["return self.held.y", "\treturn self.held[StructVec.Y] + held[StructVec.X]"],
		["return vs[0].y", "\treturn vs[0][StructVec.Y]"],
		["var readers", 'var readers = ["é", func(v: StructVec) -> float: return v[StructVec.X], func(w: StructVec) -> float: return w[StructVec.Y]]'],
		["var y := e.y", "\t\tvar y: float = e[StructVec.Y]"],
		["var get_x = func", "\tvar get_x = func(v: StructVec) -> float: return v[StructVec.X]"],
	]:
		var i = _line_of(lines, c[0])
		_check("parser access: " + c[0], result.lines[i] if i > -1 else "<anchor missing>", c[1])
	var flow = StructRewrite.check_flow(lines, types.lookups(), structs)
	_check("parser access: typed routes pass the flow check (%s)" % "; ".join(flow.errors), flow.errors, [])
	_check("parser access: only the get_x.call sink warns", _line_labels(flow.warnings), ["line 61"])


static func _test_flow_with_parser() -> void:
	var structs = _real_structs()
	var lines = _source_lines(UNTYPED)
	var types = StructTypes.new(GDScriptParser, UNTYPED, structs, {})
	var flow = StructRewrite.check_flow(lines, types.lookups(), structs)
	_check("flow: one error per untyped route (%s)" % "; ".join(flow.errors), _line_labels(flow.errors),
		["line 15", "line 16", "line 20", "line 24", "line 32", "line 41", "line 46", "line 60", "line 64", "line 79", "line 84"])
	_check("flow: signal and callable sinks warn (%s)" % "; ".join(flow.warnings), _line_labels(flow.warnings),
		["line 72", "line 73", "line 74"])


## Literals, lambdas and sinks against fake lookups, so each rule is pinned without the parser.
static func _test_literals_and_lambdas() -> void:
	var structs = {P + ".S": _def(["class S:", "\tvar a"], P + ".S")}
	var raw = {"S": P + ".S", "typed": "Array[S]", "loose_list": "Array", "list": "Array[S]"}
	var return_types = {6: "Array[S]", 27: "S"}
	var named = {"untyped_named": [false], "typed_named": [true]}
	var lookups = {
		"type_of": func(expr:String, _line:int, _column:int) -> String: return P + ".S" if expr == "s" else "",
		"raw_type": func(expr:String, _line:int, _column:int) -> String: return raw.get(expr, ""),
		"return_raw": func(line:int, _column:int) -> String: return return_types.get(line, ""),
		"params": func(_callee:String, _line:int, _column:int) -> Variant: return null,
		"lambda_params": func(name:String, _line:int, _column:int) -> Variant: return named.get(name),
		"lambda_body": func(line:int, _column:int) -> bool: return line in [26, 27],
	}

	var lines = PackedStringArray([
		"var a = [s, 1]",                                        # 0 error
		"var b: Array[S] = [s]",                                 # 1 ok
		"typed = [s]",                                           # 2 ok
		"loose_list = [s]",                                      # 3 error
		"var c = x[s]",                                          # 4 subscript
		'var d = {"k": s}',                                      # 5 error
		"return [s]",                                            # 6 ok, typed return
		"var e: Array[S] = [[s]]",                               # 7 error, nested
		"foo(bar, [s])",                                         # 8 error, call argument
		"var f = {s = 1}",                                       # 9 error, dict key
		"if s in [s]: pass",                                     # 10 error, after a keyword
		"enum {A, B}",                                           # 11 not a literal
		"list.map(func(e): return e)",                           # 12 error, untyped element
		"list.reduce(func(acc, e: S): return acc, 0)",           # 13 ok, typed element
		"list.reduce(func(acc, e): return acc, 0)",              # 14 error, untyped element
		"list.sort_custom(func(a: S, b): return true)",          # 15 error, second element untyped
		"list.map(cb)",                                          # 16 warning, not a lambda in scope
		"sig.emit(s)",                                           # 17 warning
		'var named = "func(e: S)"',                              # 18 string
		"func helper(e: S) -> void:",                            # 19 named func, not a lambda
		"var g = {",                                             # 20 multi-line literal...
		'\t"k": s,',                                             # 21 ...error reported where s is
		"}",                                                     # 22
		"list.map(untyped_named)",                               # 23 error, bound lambda untyped
		"list.map(typed_named)",                                 # 24 ok
		"list.map(func(e: S) -> S:",                             # 25 multi-line inline lambda
		"\tvar u = s",                                           # 26 error, body statement
		"\treturn s",                                            # 27 ok, checked against the lambda
		")",                                                     # 28
	])
	var flow = StructRewrite.check_flow(lines, lookups, structs)
	_check("rules: errors (%s)" % "; ".join(flow.errors), _line_labels(flow.errors),
		["line 1", "line 4", "line 6", "line 8", "line 9", "line 10", "line 11", "line 13", "line 15",
		"line 16", "line 22", "line 24", "line 27"])
	_check("rules: warnings (%s)" % "; ".join(flow.warnings), _line_labels(flow.warnings), ["line 17", "line 18"])
	_check("rules: collection element", [StructRewrite._collection_element("Array[S]"),
		StructRewrite._collection_element("Dictionary[String, Outer.S]"), StructRewrite._collection_element("Array")],
		["S", "Outer.S", ""])


static func _line_labels(messages:Array) -> Array:
	return messages.map(func(e): return e.get_slice(":", 0))


# --- harness -----------------------------------------------------------------------------

static func _source_lines(path:String) -> PackedStringArray:
	return FileAccess.get_file_as_string(path).split("\n")


static func _line_of(lines:PackedStringArray, anchor:String) -> int:
	for i in lines.size():
		if lines[i].contains(anchor):
			return i
	return -1


static func _def(lines:Array, class_path:String = P + ".S") -> Dictionary:
	return StructRewrite.parse_def(PackedStringArray(lines), 0, false, class_path)


## The first error, or "" - checked by substring so messages can be reworded around the detail.
static func _errors(lines:Array) -> String:
	var errors = _def(lines).errors
	return errors[0] if not errors.is_empty() else ""


static func _has(errors:Array, text:String) -> bool:
	for e:String in errors:
		if e.contains(text):
			return true
	return false


static func _check(label:String, actual, expected) -> void:
	if expected is String and actual is String and label.begins_with("error:") and not expected.is_empty():
		if actual.contains(expected):
			_passed += 1
		else:
			_failures.append("%s\n          expected to contain: %s\n          actual:   %s" % [label, expected, actual])
		return
	if actual == expected:
		_passed += 1
	else:
		_failures.append("%s\n          expected: %s\n          actual:   %s" % [label, expected, actual])
