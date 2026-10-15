extends RefCounted
const Helpers = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/composition/helpers.gd")
static var calls:int = 0

static func check(value:bool) -> bool:
	calls += 1
	return value

static func ordinary(iterations:int) -> Array:
	calls = 0
	var total:int = 0
	for index in iterations:
		var a:bool = index % 2 == 0
		var b:bool = true
		if Helpers.safe_all(a, b):
			total += 1
	return [total, calls]

static func substituted(iterations:int) -> Array:
	calls = 0
	var total:int = 0
	for index in iterations:
		var a:bool = index % 2 == 0
		if Helpers.all_values(check(a), check(true)):
			total += 1
	return [total, calls]
