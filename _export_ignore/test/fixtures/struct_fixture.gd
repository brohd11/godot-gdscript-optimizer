extends RefCounted
## `#! struct` fixture: an inner struct exports as an enum plus create(), and its constructor and
## type hints in this file become array literals and Array. No field access - that is phase 2.

#! struct
class Pair:
	var left: int
	var right := "r"

	func _init(l: int) -> void:
		left = l


static func make(v: int) -> Pair:
	return Pair.new(v)
