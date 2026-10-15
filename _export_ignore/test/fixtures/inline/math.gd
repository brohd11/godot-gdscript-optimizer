extends RefCounted

#! inline
static func affine(value:int, scale:int) -> int:
	return value * scale + value - 3

#! inline
static func fraction(value:float) -> float:
	return -(value + 1.5) / 2.0

#! inline
static func nested(value:int) -> int:
	return affine(value, 2)

#! inline
static func defaulted(value:int = 1) -> int:
	return value + 1

#! inline
static func converted(value:int) -> float:
	return value + 1

#! inline
func instance_only(value:int) -> int:
	return value + 1

static func same(value:int) -> int:
	return 2 * affine(value, 3) + affine(-2, 4)

#! inline
static func divide(value:int, divisor:int) -> int:
	return value / divisor

#! inline
static func multi(value:int) -> int:
	var copy:int = value
	return copy

#! inline
static func recursive(value:int) -> int:
	return recursive(value)
