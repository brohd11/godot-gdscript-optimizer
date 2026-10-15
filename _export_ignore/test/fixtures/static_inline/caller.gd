extends RefCounted
const Helpers = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/static_inline/helpers.gd")

static func add(value:String, type:String) -> String:
	var result = Helpers.add_type(value, type)
	return result

static func ordinary(value:String, type:String) -> String:
	return Helpers.ordinary_add(value, type)

static func default_value(value:String) -> String:
	return Helpers.add_type(value)

static func shadow(value:String) -> String:
	var Keys = "caller"
	return Helpers.add_type(value, Keys)

static func branch(value:String, include_type:bool) -> String:
	return "[" + Helpers.path(value, include_type) + "]"

static func ordinary_branch(value:String) -> String:
	return "[" + Helpers.ordinary_path(value) + "]"

static func branch_statement(value:String, include_type:bool) -> String:
	var result = Helpers.path(value, include_type)
	return result

static func branch_return(value:String, include_type:bool) -> String:
	return Helpers.path(value, include_type)

static func reference_branch(choose:bool) -> bool:
	var result = Helpers.reference_branch(choose)
	return result != null

static func composed(value:String) -> String:
	return Helpers.composed(value)

static func static_effects() -> Array:
	Helpers.counter = 0
	Helpers.events.clear()
	var write_result = Helpers.write(5)
	var read_result = Helpers.twice(Helpers.read())
	var step_result = Helpers.twice(Helpers.step())
	var ordered_result = Helpers.ordered(Helpers.next("a"), Helpers.next("b"))
	return [write_result, read_result, step_result, ordered_result, Helpers.counter, Helpers.events.duplicate()]

static func storage(value:int) -> Variant:
	var result = Helpers.local_storage(value)
	return result

static func enum_value(value:int) -> int:
	return Helpers.enum_value(value)

static func numeric_call(value:int) -> int:
	Helpers.counter = 0
	return 1 + Helpers.next_plus(value)

static func mutable_default() -> int:
	Helpers.counter = 3
	return Helpers.mutable_default()

static func constant_divisor() -> int:
	return Helpers.divide(1, Helpers.ZERO)

static func default_divisor() -> int:
	return Helpers.divide(1)

static func forced_divisor() -> int:
	return Helpers.forced_divide(1, Helpers.ZERO)

static func forced_literal_divisor() -> int:
	return Helpers.forced_divide(1, 0)
