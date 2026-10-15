extends RefCounted
## Reads a struct field without ever naming the struct, so the export has to inject a preload for
## the enum it indexes with.

const StructUser = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_user.gd")


static func origin_x() -> float:
	return StructUser.origin().x
