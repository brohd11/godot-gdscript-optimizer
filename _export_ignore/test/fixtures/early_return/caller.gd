extends RefCounted
const Helpers = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/early_return/helpers.gd")
const Events = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/events.gd")
static var order:String = ""

static func classify(value:int) -> int:
	return Helpers.classify(value)

static func assign(value:int) -> Array:
	var result := Helpers.classify(value, 2)
	var original := result
	result = Helpers.classify(result)
	return [original, result, typeof(result)]

static func touch(value:int) -> Array:
	var events:Array = []
	Helpers.noop()
	Helpers.touch(events, value) # retained void comment
	events.append("after")
	return events

static func loops() -> Array:
	var events:Array = []
	var total:int = 0
	for i:int in range(-1, 3):
		var amount := Helpers.classify(i)
		total += amount
		Helpers.touch(events, i)
		events.append("after")
	return [total, events]

static func argument(label:String, value:int) -> int:
	order += label
	return value

static func ordering() -> Array:
	order = ""
	var result := Helpers.ordered(argument("a", -2), argument("b", 4))
	return [result, order, typeof(result)]

static func lifetime(stop:bool) -> Array:
	Events.events.clear()
	var result := Helpers.unused(Events.make(), stop)
	Events.events.append("after")
	return [result, Events.events.duplicate()]

static func lifetime_void(stop:bool) -> Array:
	Events.events.clear()
	Helpers.unused_void(Events.make(), stop)
	Events.events.append("after")
	return Events.events.duplicate()

static func owned(stop:bool) -> Array:
	var events:Array = []
	var result := Helpers.owned(events, stop)
	return [result, events]

static func embedded(value:int) -> bool:
	return false and Helpers.classify(value) > 0

static func rejected(value:int) -> int:
	return Helpers.inner_loop(value) + Helpers.inner_while(value)

static func local_lifetime(stop:bool) -> Array:
	Events.events.clear()
	Helpers.local_lifetime(stop)
	Events.events.append("after")
	return Events.events.duplicate()
