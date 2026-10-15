extends RefCounted

const External = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/reference_payload.gd")

class Payload:
	extends RefCounted
	var value:int = 7

#! struct
class References:
	var items:Array[int] = [1, 2]
	var map:Dictionary[String, int] = {"a": 3}
	var packed:PackedInt32Array
	var object:Object
	var node:Node
	var payload:Payload
	var callback:Callable
	var event:Signal
	var external:External
	var inner:External.Inner
	func _init(p:Payload = null) -> void:
		payload = p

static func scalar() -> Array:
	var payload := Payload.new()
	var a := References.new(payload)
	var b := References.new()
	a.items.append(4)
	a.map["b"] = 5
	a.packed.append(6)
	a.payload.value += 1
	return [a.items, b.items, a.map, b.map, a.packed, payload.value,
		a.node == null, a.object == null, a.callback.is_null(), a.event.is_null()]

static func reads(record:References) -> Array:
	var items = record.items
	var map = record.map
	var packed = record.packed
	var object = record.object
	var node = record.node
	var payload = record.payload
	var callback = record.callback
	var event = record.event
	return [items, map, packed, object == null, node == null, payload.value, callback.is_null(), event.is_null()]

static func surviving() -> Array:
	return reads(References.new(Payload.new()))

static func cross_file() -> int:
	var record := References.new()
	record.external = External.new()
	record.inner = External.Inner.new()
	return external_reads(record)

static func external_reads(record:References) -> int:
	var a = record.external
	var b = record.inner
	return a.value + b.value

#! struct
class Child:
	var value:int
	func _init(v:int) -> void:
		value = v

#! struct
class Parent:
	var child:Child
	func _init(c:Child) -> void:
		child = c

static func nested() -> int:
	return nested_read(Parent.new(Child.new(17)))

static func nested_read(record:Parent) -> int:
	var child := record.child
	return child.value

#! struct
class ExternalRecord:
	var payload:External.Inner
	func _init(p:External.Inner) -> void:
		payload = p

static func constructor_reference() -> int:
	var record := ExternalRecord.new(External.Inner.new())
	return record.payload.value

static func objects() -> bool:
	var node := Node.new()
	var record := References.new()
	record.node = node
	record.object = RefCounted.new()
	var result := check_objects(record)
	node.free()
	return result

static func check_objects(record:References) -> bool:
	var node = record.node
	var object = record.object
	return is_instance_valid(node) and object is RefCounted
