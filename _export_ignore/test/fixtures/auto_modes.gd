extends RefCounted

class Automatic:
	var value:int
	func _init(input:int = 3) -> void:
		value = input

#! struct
class Tagged:
	var value:int = 4

#! struct; off
#! struct
class Excluded:
	var value:int = 5

class RefFields:
	var items:Array[int] = [6]

class VariantFields:
	var value = 7

class Behavioral:
	var value:int = 8
	func read() -> int:
		return value

class Reflected:
	var value:int = 9

static var effects:int = 0

static func automatic(value:int) -> int:
	return value + 1

#! inline
static func tagged(value:int) -> int:
	return value + 2

#! inline; off
#! inline
static func excluded(value:int) -> int:
	return value + 3

static func branch(value:int) -> int:
	if value < 0:
		return -1
	if value == 0:
		return 0
	return value + 4

static func dynamic(value:Variant) -> Variant:
	return value

static func twice(value:int) -> int:
	return value + value

#! inline; substitute
static func explicit_twice(value:int) -> int:
	return value + value

static func next() -> int:
	effects += 1
	return effects

static func values(input:int) -> Array:
	var a := Automatic.new(input)
	var b := Tagged.new()
	var c := Excluded.new()
	var d := RefFields.new()
	var e := VariantFields.new()
	var f := Behavioral.new()
	var g := Reflected.new()
	var result := branch(input)
	return [a.value, b.value, c.value, d.items[0], e.value, f.read(), g.get("value"), automatic(input), tagged(input), excluded(input), result]

static func effectful() -> int:
	effects = 0
	var result := twice(next())
	return result

static func forced() -> int:
	effects = 0
	return explicit_twice(next())

static func dynamic_call(value:Variant) -> Variant:
	return dynamic(value)

class Identity:
	var value:int = 1

class Escaping:
	var value:int = 2

static func identity_check() -> bool:
	var a := Identity.new()
	var b := Identity.new()
	return a == b

static func consume(value):
	return value.value

static func escape_check() -> int:
	var value := Escaping.new()
	return consume(value)

static func with_receiver(value:Behavioral, result:int) -> int:
	return value.value + result

#! inline; substitute
static func explicit_receiver(value:Behavioral, result:int) -> int:
	return value.value + result

static func receiver_check() -> Array:
	var value := Behavioral.new()
	var ordinary := with_receiver(value, value.read())
	var explicit := explicit_receiver(value, value.read())
	return [ordinary, explicit]

class Nullable:
	var value:int = 10

static var nullable:Nullable = null

static func nullable_check() -> bool:
	nullable = Nullable.new()
	nullable = null
	return nullable == null

class BaseData:
	var value:int = 11

class Derived extends BaseData:
	pass

class FactoryData:
	var value:int = 12

class ObjectArgument:
	var value:int = 13

class NullArgument:
	var value:int = 14

static func object_sink(value:Object) -> int:
	return value.get("value")

static func nullable_sink(value:NullArgument) -> bool:
	return value == null

static func usage_checks() -> Array:
	var derived := Derived.new()
	var factory = FactoryData
	var item = factory.new()
	var object := ObjectArgument.new()
	return [derived.value, item.value, object_sink(object), nullable_sink(null)]

class ContainerEscape:
	var value:int = 15

static func untyped_rows(rows) -> int:
	return rows[0].value

static func container_check() -> int:
	var rows:Array[ContainerEscape] = [ContainerEscape.new()]
	return untyped_rows(rows)
