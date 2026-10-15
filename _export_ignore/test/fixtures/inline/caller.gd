extends RefCounted

const Math = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/math.gd")
static var effects:int = 0

class Other:
	static func affine(a:int, b:int) -> int:
		return a - b

static func cross(value:int) -> int:
	var local:int = value + 1
	return 2 * Math.affine(local, 3)

static func floating(value:float) -> float:
	return Math.fraction(value) * 3.0

static func skipped(value:int) -> int:
	var dynamic = value
	return Math.affine(dynamic, 2) + Math.affine(abs(value), 2) + Math.affine(1.5, 2)

static func nested_call(value:int) -> int:
	return Math.affine(Math.affine(value, 2), 3)

static func shadow(value:int) -> int:
	var Math = Other
	return Math.affine(value, 3)

static func text() -> String:
	# Math.affine(1, 2)
	return "Math.affine(1, 2)"

static func effect() -> int:
	effects += 1
	return 7

static func side_effect() -> int:
	return Math.affine(effect(), 3)

static func mutable_alias(value:int) -> int:
	var alias = Math
	alias = Other
	return alias.affine(value, 3)

static func conversion(value:int) -> float:
	return Math.fraction(value)

static func integer_division(value:int) -> int:
	return Math.divide(value, 2)

static func zero_division(value:int) -> int:
	return Math.divide(value, 0)

static func inferred(value:int) -> int:
	var local := value + 1
	return Math.affine(local, 3)

static func loop() -> int:
	var result:int = 0
	for index:int in 7:
		result += Math.affine(index, 3)
	return result
