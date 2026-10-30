extends RefCounted

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/"
static var _failures:Array = []
static var _passed:int = 0


static func run_tests() -> Dictionary:
	_failures = []
	_passed = 0
	_test_arithmetic()
	_test_name_collision()
	var sources:Dictionary = {}
	for name:String in ["math", "caller"]:
		var path := BASE + name + ".gd"
		sources[path] = path
	var optimizer = Optimizer.new()
	var result = optimizer.prepare(sources, Optimizer.Context.new(), [Optimizer.InlinePass])
	_check("prepare", result.errors, [])
	_check("unsupported definitions diagnosed", result.warnings.size(), 2)
	for path:String in sources:
		var source := FileAccess.get_file_as_string(path)
		var lines := Array(source.split("\n"))
		var edited := optimizer.apply(path, lines)
		_check("apply " + path, edited.errors, [])
		_check("source immutable", "\n".join(lines), source)
		var text := "\n".join(edited.lines)
		_check("supported sites " + path, edited.stats.inline_calls, 2 if path.ends_with("math.gd") else 10)
		var transformed := GDScript.new()
		transformed.source_code = text
		var compiled := transformed.reload()
		_check("optimized compilation", compiled, OK)
		if compiled != OK:
			continue
		var original = load(path)
		if path.ends_with("math.gd"):
			_check("definition preserved", text.contains("return value * scale + value - 3"), true)
			_check("nested definition preserved", text.contains("return affine(value, 2)"), true)
			for value:int in [-10, 0, 7]:
				_check("same script equivalence", transformed.same(value), original.same(value))
		else:
			_check("skipped sites diagnosed", edited.warnings.size(), edited.stats.inline_skipped)
			_check("zero divisor stays runtime expression", text.contains("_divisor:int = 0"), true)
			_check("conversion expanded", text.contains("return Math.fraction(value)"), false)
			_check("direct path retained", edited.stats.inline_direct_calls, 7)
			_check("expanded path counted", edited.stats.inline_expanded_calls, 3)
			_check("nested calls expanded", text.contains("Math.affine(Math.affine(value, 2), 3)"), false)
			_check("shadowed alias preserved", text.contains("return Math.affine(value, 3)"), true)
			for value:int in [-10, 0, 7]:
				_check("cross script equivalence", transformed.cross(value), original.cross(value))
				_check("float equivalence", transformed.floating(float(value)), original.floating(float(value)))
				_check("integer division", transformed.integer_division(value), original.integer_division(value))
				_check("inferred local", transformed.inferred(value), original.inferred(value))
				_check("mutable alias", transformed.mutable_alias(value), original.mutable_alias(value))
			_check("typed loop", transformed.loop(), original.loop())
			var before:int = load(BASE + "caller.gd").effects
			_check("side-effect result", transformed.side_effect(), original.side_effect())
			_check("side-effect once per call", load(BASE + "caller.gd").effects - before, 1)
			_check("side-effect once in rewritten script", transformed.effects, 1)
			_check("strings preserved", transformed.text(), original.text())
	var output:Array = ["inline: %d passed, %d failed" % [_passed, _failures.size()]]
	output.append_array(_failures)
	return {"result": _failures.size(), "output": output}


## `.any(...)` on a local, param or member is Array.any, not the tagged `any`: skipped silently,
## while the real tagged call still inlines.
static func _test_name_collision() -> void:
	var sources:Dictionary = {}
	for name:String in ["collision", "collision_caller"]:
		sources[BASE + name + ".gd"] = BASE + name + ".gd"
	var optimizer = Optimizer.new()
	var prepared = optimizer.prepare(sources, Optimizer.Context.new(), [Optimizer.InlinePass])
	_check("collision prepare", prepared.errors, [])
	var path := BASE + "collision_caller.gd"
	var edited := optimizer.apply(path, Array(FileAccess.get_file_as_string(path).split("\n")))
	_check("collision apply", edited.errors, [])
	_check("collision no warnings", edited.warnings, [])
	_check("collision not counted as skipped", edited.stats.inline_skipped, 0)
	_check("collision tagged call inlined", edited.stats.inline_calls, 1)
	var text := "\n".join(edited.lines)
	_check("collision Array.any kept", text.count(".any(func(v)"), 3)
	_check("collision tagged call rewritten", text.contains("Collision.any("), false)


static func _test_arithmetic() -> void:
	var arithmetic = Optimizer.InlinePass.Arithmetic.new()
	for expression:String in ["a + b * 2", "-(a + b) % 3", "a / 2", "a - -b"]:
		var parsed:Dictionary = arithmetic.analyze(expression, {"a": "int", "b": "int"})
		_check("numeric grammar " + expression, parsed.error, "")
		_check("integer result " + expression, parsed.type, "int")
	for expression:String in ["a.foo", "abs(a)", "a ** b", "a +", "(a", "a if b else 0", "a / (2 - 2)"]:
		_check("reject expression " + expression, arithmetic.analyze(expression, {"a": "int", "b": "int"}).error.is_empty(), false)
	_check("mixed arithmetic", arithmetic.analyze("a * 0.5", {"a": "int"}).type, "float")


static func _check(label:String, actual:Variant, expected:Variant) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failures.append("FAIL %s: expected %s, got %s" % [label, expected, actual])
