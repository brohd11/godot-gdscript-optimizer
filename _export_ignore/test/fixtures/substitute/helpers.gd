extends RefCounted
const Record = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/substitute/record.gd")
const SceneNode = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/substitute/node.gd")

#! inline; substitute
static func path(current:String, record:Record) -> String:
	if current != "":
		return current
	else:
		return record.get_path()

#! inline
static func ordinary_path(current:String, record:Record) -> String:
	if current != "":
		return current
	else:
		return record.get_path()

#! inline
static func choice(value:String, choose:bool) -> String:
	if choose:
		return value
	else:
		return "fallback"

#! inline; substitute
static func identity(value:Variant) -> Variant:
	return value

#! inline; substitute
static func references(value:RefCounted) -> int:
	if value != null:
		return value.get_reference_count()
	else:
		return 0

#! inline; substitute
static func direct_references(value:RefCounted) -> int:
	return value.get_reference_count()

#! inline; substitute
static func rebound(value:int) -> int:
	value += 2
	return value

#! inline; substitute
static func mutated(value:Vector2) -> Vector2:
	value.x += 2.0
	return value

#! inline; substitute
static func repeated(first:int, _unused:int, choose:bool) -> int:
	if choose:
		return first + first
	else:
		return 0

#! inline; substitute
static func reordered(first:int, second:int, choose:bool) -> int:
	if choose:
		return second + first
	else:
		return first

#! inline
static func converted(value:float, choose:bool) -> int:
	if choose:
		return value
	else:
		return 0

#! inline; substitute
static func unchecked(value:float, choose:bool) -> int:
	if choose:
		return value
	else:
		return 0

#! inline; substitute
static func variant_branch(value:Variant, choose:bool) -> Variant:
	if choose:
		return value
	else:
		return null

#! inline; substitute
static func nested(value:int, first:bool, second:bool) -> int:
	if first:
		if second:
			return value + 1
		else:
			return value + 2
	else:
		return value + 3

#! inline; substitute
static func native(value:Node, choose:bool) -> String:
	var label = str(value.name)
	if choose:
		return label
	else:
		return ""

#! inline
static func local_reference(choose:bool) -> String:
	var record := Record.new()
	if choose:
		return record.get_path()
	else:
		return ""

#! inline; substitute
static func script_native(value:SceneNode, choose:bool) -> StringName:
	if choose:
		return value.name
	else:
		return &""
