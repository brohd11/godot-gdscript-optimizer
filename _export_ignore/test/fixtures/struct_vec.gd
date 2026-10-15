#! struct

extends RefCounted
## Whole-file `#! struct` fixture: the header tag makes the script itself the struct.

var x: float
var y: float

func _init(px: float, py: float) -> void:
	x = px
	y = py
