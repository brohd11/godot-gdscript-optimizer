extends RefCounted

const Collision = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/inline/collision.gd")
var flags:Array = [false, true]

static func tagged(a:bool, b:bool) -> bool:
	return Collision.any(a, b)

static func on_local(values:Array) -> bool:
	var copy:Array = values.duplicate()
	return copy.any(func(v): return v)

static func on_param(values:Array) -> bool:
	return values.any(func(v): return v)

func on_member() -> bool:
	return flags.any(func(v): return v)
