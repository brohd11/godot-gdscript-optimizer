extends RefCounted
const Helpers = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/substitute/helpers.gd")
const Record = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/substitute/record.gd")
static var events:Array = []
static var seed:String = "outer"

static func existing(current:String) -> String:
	var record := Record.new()
	current = Helpers.path(current, record)
	return current

static func dynamic_existing() -> String:
	var current = ""
	var record = Record.new()
	current = Helpers.path(current, record)
	return current

static func declarations() -> Array:
	var record := Record.new()
	var dynamic = Helpers.path("", record)
	var inferred := Helpers.path("", record)
	var typed:String = Helpers.path("", record)
	dynamic = 7
	return [dynamic, inferred, typed]

static func ordinary_declarations(choose:bool) -> Array:
	var dynamic = Helpers.choice("chosen", choose)
	var inferred := Helpers.choice("chosen", choose)
	var typed:String = Helpers.choice("chosen", choose)
	var converted = Helpers.converted(2.75, choose)
	var converted_float:float = Helpers.converted(2.75, choose)
	dynamic = 7
	return [dynamic, inferred, typed, converted, typeof(converted), converted_float]

static func shadowed_initializer() -> String:
	var seed = Helpers.path(seed, Record.new())
	return seed

static func ordinary_alias() -> String:
	var record := Record.new()
	var current:String = ""
	current = Helpers.ordinary_path(current, record)
	return current

static func shadowed_alias() -> String:
	var record := Record.new()
	var Record:int = 7
	var current:String = ""
	current = Helpers.ordinary_path(current, record)
	return current + str(Record)

static func rebinding() -> Array:
	var value:int = 3
	var vector := Vector2(1, 2)
	var changed := Helpers.rebound(value)
	var moved := Helpers.mutated(vector)
	return [value, changed, vector, moved]

static func probe(label:String) -> int:
	events.append(label)
	return events.size()

static func repeated() -> Array:
	events.clear()
	var result:int = 0
	result = Helpers.repeated(probe("first"), probe("unused"), true)
	return [result, events.duplicate()]

static func reordered() -> Array:
	events.clear()
	var result:int = 0
	result = Helpers.reordered(probe("first"), probe("second"), true)
	return [result, events.duplicate()]

static func reference_counts() -> Array:
	var record := Record.new()
	var before:int = record.get_reference_count()
	var expanded:int = 0
	expanded = Helpers.references(record)
	var direct:int = Helpers.direct_references(record)
	return [before, expanded, direct]

static func variants() -> Array:
	var value = "variant"
	var direct = Helpers.identity(value)
	var branch = Helpers.variant_branch(value, true)
	return [direct, branch]

static func conversions() -> Array:
	var value:float = 2.75
	var ordinary:float = 0.0
	ordinary = Helpers.converted(value, true)
	var forced:float = 0.0
	forced = Helpers.unchecked(value, true)
	return [ordinary, forced]

static func nested(first:bool, second:bool) -> int:
	var value:int = 4
	value = Helpers.nested(value, first, second)
	return value

static func native() -> String:
	var node := Helpers.SceneNode.new()
	node.name = "native"
	var value:String = ""
	value = Helpers.native(node, true)
	var script_name:StringName = &""
	script_name = Helpers.script_native(node, true)
	node.free()
	return value + script_name

static func local_reference() -> String:
	var value:String = ""
	value = Helpers.local_reference(true)
	return value
