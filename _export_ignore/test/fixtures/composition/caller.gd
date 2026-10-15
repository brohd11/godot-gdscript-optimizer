extends RefCounted
const Helpers = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/composition/helpers.gd")
static var events:String = ""

static func probe(label:String, value:bool) -> bool:
	events += label
	return value

static func number(label:String, value:int) -> int:
	events += label
	return value

static func lazy() -> bool:
	return Helpers.both(probe("a", false), probe("b", true))

static func repeated() -> bool:
	return Helpers.repeated(probe("a", false))

static func reversed() -> bool:
	return Helpers.reversed(probe("a", true), probe("b", true))

static func dropped() -> bool:
	return Helpers.first(probe("a", true), probe("b", true))

static func ordinary() -> bool:
	return false or Helpers.safe_both(probe("a", false), probe("b", true))

static func all_variadic() -> bool:
	return false or Helpers.all_values(probe("a", true), probe("b", false), probe("c", true))

static func any_variadic() -> bool:
	return false or Helpers.any_values(probe("a", false), probe("b", true), probe("c", true))

static func safe_variadic() -> bool:
	return false or Helpers.safe_all(probe("a", false), probe("b", true))

static func pure_variadic(path:String) -> bool:
	return Helpers.safe_all(path.begins_with("res://"), path.ends_with(".gd"))

static func empty() -> bool:
	return Helpers.all_values() and not Helpers.any_values()

static func packed() -> Array:
	return Helpers.packed(number("a", 3), number("b", 4), number("c", 5))

static func defaults() -> Array:
	return Helpers.packed()

static func no_tail() -> Array:
	return Helpers.packed(2)

static func nested(value:int) -> int:
	return Helpers.chained(Helpers.twice(value))

static func template_nested(value:int) -> int:
	return Helpers.templated(Helpers.chained(value))

static func policy_boundary() -> bool:
	return Helpers.safe_both(Helpers.repeated(probe("a", false)), probe("b", true))

static func untouched_definition(value:int) -> int:
	return Helpers.cycle_a(value)

static func zero_divisor() -> bool:
	return false or Helpers.divides(number("a", 1), 0)
