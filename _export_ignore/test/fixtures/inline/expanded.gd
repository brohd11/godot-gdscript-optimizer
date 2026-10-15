extends RefCounted

const Math = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/math.gd")
static var events:String = ""

#! inline
static func vector(value:Vector2, scale:float) -> float:
	var scaled := value * scale
	scaled += Vector2.ONE
	return scaled.length_squared()

#! inline
static func compute(value:int, unused:int) -> float:
	value += 2
	var result:int = value * value
	return result

#! inline
static func strings(value:String, suffix:String) -> String:
	var combined := value + suffix
	return combined.to_upper()

#! inline
static func components(x:Vector2, y:float) -> float:
	return x.x + y

static func argument(label:String, value:int) -> int:
	events += label
	return value

static func order() -> float:
	var result := compute(argument("a", 3), argument("b", 9))
	return result

static func values() -> float:
	var value := Vector2(2, 3)
	var scaled := 99
	var result := vector(value + Vector2.ONE, 2)
	result = vector(value, 3.0)
	return result + scaled

static func numeric_conversion(value:float) -> float:
	return compute(value, 2)

static func text() -> String:
	return strings("x", "y")

static func fields() -> float:
	return components(Vector2(3, 4), 5.0)

static func bound(value:int) -> int:
	return Math.affine(value + 1, 3)

static func skipped(value:Vector2) -> bool:
	return false and vector(value, 2.0) > 0.0

static func embedded(value:Vector2) -> float:
	return 1.0 + vector(value, 2.0)

#! inline
static func absolute(value:float) -> float:
	var result := absf(value)
	return result

#! inline
static func collections(value:Array) -> int:
	return value.size()

#! inline
static func branches(value:int) -> int:
	if value > 0:
		return value
	return 0

#! inline
static func external(value:int) -> int:
	return Math.affine(value, 3)

#! inline
static func array_temporary(value:String) -> int:
	return value.split(",").size()

#! inline
static func unsupported_local(value:int) -> int:
	var copy = value
	return copy

static func dynamic_argument(value:int) -> float:
	var dynamic = value
	return compute(dynamic, 2)

static func in_loop() -> float:
	var total:float = 0.0
	for index:int in 3:
		var value := compute(index, 1)
		total += value
	return total

#! inline
static func matching(value:String, pattern:String) -> bool:
	return value.match(pattern)

static func match_text() -> bool:
	return matching("abc", "a*")
