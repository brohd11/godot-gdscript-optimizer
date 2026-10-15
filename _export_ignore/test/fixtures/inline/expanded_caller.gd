extends RefCounted

const E = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/expanded.gd")

class Probe:
	var reads:int = 0
	var value:float:
		get:
			reads += 1
			return 3.5

static func absf(_value:float) -> float:
	return 99.0

static func shadowed() -> float:
	return E.absolute(-4.0)

static func cross() -> float:
	var result:float = E.vector(Vector2(2, 3), 2.0) # retained comment
	return result

static func getter() -> float:
	var probe := Probe.new()
	var value := E.compute(probe.value, 1)
	return value + probe.reads
