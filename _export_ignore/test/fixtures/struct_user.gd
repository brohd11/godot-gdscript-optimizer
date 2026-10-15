extends RefCounted
## Uses both struct fixtures from another file, through a const preload and an inner class path.

const StructVec = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_vec.gd")
const StructFixture = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_fixture.gd")


static func origin() -> StructVec:
	return StructVec.new(0.0, 0.0)


static func passthrough(pair: StructFixture.Pair) -> StructFixture.Pair:
	return pair


static func new_pair() -> StructFixture.Pair:
	var next: StructFixture.Pair = StructFixture.Pair.new(1)
	return next
