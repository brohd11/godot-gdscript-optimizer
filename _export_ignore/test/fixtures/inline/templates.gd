extends RefCounted
const Record = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/reference.gd")
const DEFAULT_AMOUNT = 3

#! inline
static func choose(label:String, rect:Rect2) -> float:
	if label == "x":
		return rect.position.x
	elif label == "y":
		return rect.position.y
	else:
		if rect.size.x > 0:
			return rect.size.x
		else:
			return rect.size.y

#! inline
static func twice(value:float) -> float:
	return value + value

#! inline
static func bump(record:Record, rect:Rect2, amount:int = DEFAULT_AMOUNT) -> int:
	record.amount += amount
	rect.position.x = 9
	return record.amount + int(rect.position.x)

#! inline
static func rebind(record:Record, other:Record) -> Record:
	record = other
	return record

#! inline
static func dictionary_value(values:Dictionary, key:String = "value") -> float:
	return values[key] + values[key]

#! inline
static func array_value(values:Array[int], amount:int = 1) -> int:
	values[0] += amount
	return values[0]

#! inline
static func nullable(record:Record = null) -> bool:
	return record == null

#! inline
static func executable(value:int = randi()) -> int:
	return value + 1

#! inline
static func mutable_default(values:Array = []) -> int:
	return values.size()

const Events = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/events.gd")
#! inline
static func ordering(value:float, other:float) -> float:
	return value + value + other
#! inline
static func unused(value:RefCounted) -> int:
	return 2
#! inline
static func read_property(value:Events) -> float:
	return value.value
#! inline
static func converted(value:float = 1) -> float:
	return value / 2
#! inline
static func vector_default(value:Vector2 = Vector2(2, 3)) -> float:
	return value.x + value.y

const Defaults = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/defaults.gd")
#! inline
static func constant_default(value:int = Defaults.AMOUNT) -> int:
	return value + 1
#! inline
static func changing_default(value:int = Defaults.changing) -> int:
	return value + 1
#! inline
static func reference_count(value:RefCounted) -> int:
	return value.get_reference_count()
#! inline
static func dictionary_keys(value:int) -> Dictionary:
	return {value: value, "other": value}

#! inline
static func divide(value:int, divisor:int) -> int:
	return value / divisor
