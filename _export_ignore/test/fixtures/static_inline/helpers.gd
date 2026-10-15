extends RefCounted
const Keys = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/static_inline/keys.gd")
const DEFAULT_TYPE = "String"
const ZERO = 0
static var counter:int = 0
static var events:Array = []
enum Mode { FIRST = 2, SECOND = 5 }

class Nested:
	const LABEL = "nested"

#! inline; substitute
static func add_type(value:String, type:String = DEFAULT_TYPE) -> String:
	return value + Keys.TYPE_DELIM + type

#! inline
static func ordinary_add(value:String, type:String) -> String:
	return value + Keys.TYPE_DELIM + type

#! inline
static func enum_value(value:int) -> int:
	return value + Mode.SECOND

#! inline
static func next_plus(value:int) -> int:
	return next() + value

#! inline
static func mutable_default(value:int = counter) -> int:
	return value + next() + value

#! inline
static func divide(value:int, divisor:int = ZERO) -> int:
	return value / divisor

#! inline; substitute
static func forced_divide(value:int, divisor:int) -> int:
	return value / divisor

#! inline; substitute
static func path(value:String, include_type:bool = false) -> String:
	if value.is_empty():
		return "empty"
	if include_type:
		return value.trim_prefix("res://").trim_suffix(".gd")
	elif value.contains(Keys.TYPE_DELIM):
		return value.get_slice(Keys.TYPE_DELIM, 0)
	else:
		return value + &"!"

#! inline
static func ordinary_path(value:String) -> String:
	if value.is_empty():
		return "empty"
	return value + Keys.TYPE_DELIM

static func next(label:String = "next") -> int:
	events.append(label)
	counter += 1
	return counter

#! inline
static func read() -> int:
	return counter

#! inline
static func step() -> int:
	return next()

#! inline
static func twice(value:int) -> int:
	return value + value

#! inline
static func ordered(first:int, second:int) -> int:
	return second + next() + first

#! inline
static func write(amount:int) -> int:
	counter += amount
	return counter

#! inline; substitute
static func composed(value:String) -> String:
	return add_type(path(value), Nested.LABEL)

#! inline; substitute
static func local_storage(value:int) -> Variant:
	var local:Array = [value]
	if value > 0:
		return local
	else:
		return []

#! inline
static func reference_branch(choose:bool) -> RefCounted:
	if choose:
		return RefCounted.new()
	else:
		return null

static func local_use(value:String) -> String:
	return add_type(value, "local")

static func local_shadow(value:String) -> String:
	var Keys = "shadow"
	return add_type(value, Keys)
