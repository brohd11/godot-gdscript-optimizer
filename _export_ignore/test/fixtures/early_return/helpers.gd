extends RefCounted

#! inline
static func classify(value:int, offset:int = 3) -> int:
	if value < 0:
		return -1
	value += offset
	if value < 5:
		if value == 3:
			return 10
		elif value == 4:
			return 20
	else:
		value *= 2
	return value + 1

#! inline
static func touch(events:Array, value:int) -> void:
	if value < 0:
		events.append("early")
		return
	if value == 0:
		pass
	else:
		events.append(value)
	events.append("end")

#! inline
static func unused(value:RefCounted, stop:bool) -> int:
	if stop:
		return 7
	return 9

#! inline
static func unused_void(value:RefCounted, stop:bool) -> void:
	if stop:
		return
	pass

#! inline
static func ordered(value:float, unused:int) -> float:
	if value < 0.0:
		return value
	return value + 0.5

#! inline
static func owned(events:Array, stop:bool) -> int:
	var local:RefCounted = RefCounted.new()
	if stop:
		events.append(local.get_reference_count())
		return 1
	return local.get_reference_count()

#! inline
static func inner_loop(value:int) -> int:
	for i in value:
		if i > 0:
			return i
	return -1

#! inline
static func inner_while(value:int) -> int:
	while value > 0:
		return value
	return -1

const Events = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/events.gd")

#! inline
static func local_lifetime(stop:bool) -> void:
	var local:Events = Events.new()
	if stop:
		return
	local.get_reference_count()

#! inline
static func noop() -> void:
	pass
