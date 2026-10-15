extends RefCounted

#! inline
static func twice(value:int) -> int:
	return value * 2

#! inline
static func chained(value:int) -> int:
	return twice(twice(value))

#! inline
static func templated(value:int) -> int:
	var result:int = chained(value)
	return result + 1

#! inline; substitute
static func both(a:bool, b:bool) -> bool:
	return a and b

#! inline; substitute
static func repeated(a:bool) -> bool:
	return a or a

#! inline; substitute
static func reversed(a:bool, b:bool) -> bool:
	return b and a

#! inline; substitute
static func first(a:bool, _unused:bool) -> bool:
	return a

#! inline
static func safe_both(a:bool, b:bool) -> bool:
	return a and b

#! inline; substitute
static func all_values(...values:Array) -> bool:
	for value in values:
		if not value:
			return false
	return true

#! inline; substitute
static func any_values(...values) -> bool:
	for value in values:
		if value:
			return true
	return false

#! inline
static func safe_all(...values:Array) -> bool:
	for value in values:
		if not value:
			return false
	return true

#! inline
static func packed(prefix:int = 7, ...values:Array) -> Array:
	var result:Array = values
	result.append(prefix)
	return result

#! inline
static func cycle_a(value:int) -> int:
	return cycle_b(value)

#! inline
static func cycle_b(value:int) -> int:
	return cycle_a(value)

#! inline; misspelled
static func invalid(value:int) -> int:
	return value

#! inline; substitute
static func divides(value:int, divisor:int) -> bool:
	return value / divisor > 0
