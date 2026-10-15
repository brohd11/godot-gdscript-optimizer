extends RefCounted
const Helpers = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/templates.gd")
const Record = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/reference.gd")
const DEFAULT_AMOUNT = 99

static func branch(label:String) -> float:
	var rect := Rect2(2, 3, 4, 5)
	return Helpers.choose(label, rect)

static func lookup() -> float:
	var values:Dictionary = {"value": 2.5}
	return Helpers.twice(values["value"])

static func mixed() -> int:
	var record := Record.new()
	var rect := Rect2(2, 3, 4, 5)
	var value := Helpers.bump(record, rect)
	return value + record.amount + int(rect.position.x)

static func reference_rebind() -> bool:
	var first := Record.new()
	var second := Record.new()
	var value := Helpers.rebind(first, second)
	return first != second and value == second

static func containers() -> float:
	var values:Dictionary = {"value": 2.5}
	var array:Array[int] = [2]
	var total := Helpers.dictionary_value(values)
	var changed := Helpers.array_value(array)
	return total + changed + array[0]

static func defaults() -> bool:
	return Helpers.nullable()

static func supplied() -> int:
	return Helpers.executable(2)

static func deferred() -> int:
	return Helpers.executable()

const Events = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/events.gd")
static func ordering() -> Array:
	Events.events.clear()
	var values:Dictionary = {"value": 2.5}
	var result := Helpers.ordering(values.value, Events.change(values))
	return [result, Events.events.duplicate()]
static func lifetime() -> Array:
	Events.events.clear()
	var result := Helpers.unused(Events.make())
	Events.events.append("after")
	return [result, Events.events.duplicate()]
static func getter() -> Array:
	Events.events.clear()
	var object := Events.new()
	var result := Helpers.twice(object.value)
	return [result, Events.events.duplicate()]
static func reference_getter() -> Array:
	Events.events.clear()
	var object := Events.new()
	var result := Helpers.read_property(object)
	return [result, Events.events.duplicate()]
static func converted() -> float:
	return Helpers.converted()
static func vector_default() -> float:
	return Helpers.vector_default()
static func mutable_supplied() -> int:
	var values:Array = [1, 2]
	return Helpers.mutable_default(values)
static func mutable_deferred() -> int:
	return Helpers.mutable_default()

static func constant_default() -> int:
	return Helpers.constant_default()
static func changing_default() -> int:
	return Helpers.changing_default()
static func reference_count() -> int:
	var object := Record.new()
	return Helpers.reference_count(object)
static func dictionary_keys() -> Dictionary:
	return Helpers.dictionary_keys(3)

static func constant_zero_division() -> int:
	return Helpers.divide(1, 0)
