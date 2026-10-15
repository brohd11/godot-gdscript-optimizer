extends RefCounted

class Payload:
	extends RefCounted
	var value:int = 4
	func positive() -> bool:
		return value > 0

static var effects:int = 0

#! inline
static func is_gdscript_path(file_path:String) -> bool:
	return file_path.ends_with(".gd") or file_path.contains(".gd.") or file_path.contains(".gd::")

#! inline
static func multiline(file_path:String) -> bool:
	return (
		file_path.begins_with("res://") # Keep comments out of replacement tokens.
		and not file_path.is_empty()
		and (file_path.ends_with('.gd') or file_path.contains("file_path.gd::"))
	)

#! inline
static func within(value:int, low:int, high:int) -> bool:
	return value >= low and value < high

#! inline
static func variant_predicate(value) -> bool:
	return value.ends_with(".gd") or value.contains(".gd::")

#! inline
static func identity(value:Variant) -> Variant:
	return value

#! inline
static func integer_identity(value:int) -> int:
	return value

#! inline
static func positive(value:Payload) -> bool:
	return value.value > 0 and value.positive()

#! inline
static func node_name(value:Node) -> bool:
	return value.is_inside_tree()

static func next_path() -> String:
	effects += 1
	return "res://test.gd"

static func typed(path:String) -> Array:
	var result:Array = []
	if is_gdscript_path(path):
		result.append(true)
	elif multiline(path):
		result.append(2)
	else:
		result.append(false)
	result.append(not is_gdscript_path(path) or multiline(path))
	result.append(is_gdscript_path("literal.gd"))
	var count:int = 0
	while within(count, 0, 3):
		count += 1
	result.append(count)
	return result

static func dynamic(path:Variant) -> bool:
	return false or is_gdscript_path(path) or variant_predicate(path)

static func implicit(path) -> bool:
	if variant_predicate(path):
		return true
	return false

static func unchecked(value:Variant) -> Variant:
	return integer_identity(value)

static func variant_return(value:int) -> Variant:
	return identity(value)

static func reference_check() -> bool:
	var payload:Payload = Payload.new()
	if positive(payload):
		return true
	return false

static func effects_once(enabled:bool) -> bool:
	return enabled and is_gdscript_path(next_path())

static func indexed(paths:Array[String]) -> bool:
	return false or is_gdscript_path(paths[0])

static func known_mismatch(number:float) -> bool:
	return false or within(number, 0, 4)

static func node_check() -> bool:
	var node:Node = Node.new()
	var result:bool = false or node_name(node)
	node.free()
	return result

static func bench_typed(iterations:int) -> int:
	var paths:Array[String] = ["res://test.gd", "script.gd.remap", "script.gd::Inner", "image.png"]
	var total:int = 0
	for index in iterations:
		var path:String = paths[index % paths.size()]
		if is_gdscript_path(path):
			total += 1
	return total

static func bench_variant(iterations:int) -> int:
	var paths:Array[String] = ["res://test.gd", "script.gd.remap", "script.gd::Inner", "image.png"]
	var total:int = 0
	for index in iterations:
		var path:Variant = paths[index % paths.size()]
		if is_gdscript_path(path):
			total += 1
	return total

#! inline
static func named_string(string:int) -> bool:
	return string > 0

#! inline
static func literal_lines(path:String) -> bool:
	return path == """first

last # literal comment
"""

static func literal_check() -> bool:
	var path:String = """first

last # literal comment
"""
	return named_string(1) and literal_lines(path)

#! inline
static func first_positive(values:Array[int]) -> bool:
	return values[0] > 0

static func array_check() -> bool:
	var values:Array[int] = [1]
	return false or first_positive(values)

#! inline
static func dynamic_field(value) -> bool:
	return value.value > 0

static func dynamic_reference_check() -> bool:
	var value:Variant = Payload.new()
	return false or dynamic_field(value)

#! inline
static func implicit_identity(value):
	return value

static func implicit_return_check(value:Variant) -> Variant:
	return implicit_identity(value)

#! inline
static func integer_return(value:Variant) -> int:
	return value

static func unchecked_return(value:Variant) -> Variant:
	return integer_return(value)
