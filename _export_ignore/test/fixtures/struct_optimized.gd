extends RefCounted

#! struct
class Point:
	var x: float
	var y := 2
	func _init(a: float, b: int = 2) -> void:
		x = a
		y = b

#! struct
class Values:
	var enabled := true
	var integer: int
	var real: float
	var text := "hello"
	var name: StringName
	var path: NodePath
	var v2: Vector2 = Vector2.ZERO
	var v2i: Vector2i
	var v3: Vector3
	var v3i: Vector3i
	var v4: Vector4
	var v4i: Vector4i
	var rect: Rect2
	var recti: Rect2i
	var t2: Transform2D
	var t3: Transform3D
	var plane: Plane
	var quaternion: Quaternion
	var box: AABB
	var basis: Basis
	var projection: Projection
	var color: Color = Color.WHITE
	var handle: RID

#! struct
class Reference:
	var items: Array = []

#! struct
class Dynamic:
	var item = 1

#! struct
class Reordered:
	var first: int
	var second: int
	func _init(b: int, a: int) -> void:
		first = a
		second = b

static var events: Array = []

static func local_loop() -> float:
	var total := 0.0
	for i in 5:
		var point := Point.new(i)
		if i % 2 == 0:
			point.x += 3
		else:
			point.y = 4
		total += point.x + point.y
	return total

static func values() -> Array:
	var data := Values.new()
	data.v2.x = 4.0
	data.v3.z += 5.0
	data.text += "!"
	return [data.enabled, data.integer, data.real, data.text, data.name, data.path,
		data.v2, data.v2i, data.v3, data.v3i, data.v4, data.v4i, data.rect, data.recti,
		data.t2, data.t3, data.plane, data.quaternion, data.box, data.basis,
		data.projection, data.color, data.handle]

static func next(value: int) -> int:
	events.append(value)
	return value

static func ordering() -> Array:
	events.clear()
	var point := Reordered.new(next(7), next(8))
	return [point.first, point.second, events.duplicate()]

static func alias() -> float:
	var point := Point.new(3.0)
	var other: Point = point
	other.x = 7.0
	return point.x

static func captured() -> float:
	var point := Point.new(3.0)
	var read: Callable = func() -> float: return point.x
	point.x = 8.0
	return read.call()

static func references() -> Array:
	var record := Reference.new()
	record.items.append(7)
	return record.items

static func dynamic() -> String:
	var record := Dynamic.new()
	record.item = "changed"
	return record.item

static func consume(value: float) -> float:
	return value * 2.0

static func arithmetic(point: Point) -> float:
	return point.x * 2.0 + point.y

static func call_read(point: Point) -> float:
	return consume(point.x)

static func engine_read(point: Point) -> float:
	return Vector2.ONE.dot(Vector2(point.x, point.x))

static func conditional(point: Point, enabled: bool) -> bool:
	return enabled and point.x > 2.0

static func conditional_null() -> bool:
	return conditional(Point.new(0.0), false)

static func mutate(point: Point) -> float:
	point.x = 9.0
	return 1.0

static func effectful(point: Point) -> float:
	return mutate(point) + point.x

static func writes(point: Point) -> float:
	point.x += 2.0
	var direct: float = point.x
	var inferred := point.x
	return direct + inferred + (point.x as float)

#! inline
static func helper(point: Point) -> float:
	return point.x * 3.0

static func combined() -> float:
	var point := Point.new(2.0)
	var result := helper(point)
	return result

static func reads() -> Array:
	var point := Point.new(3.0)
	return [arithmetic(point), call_read(point), engine_read(point), conditional(point, true),
		effectful(point), writes(point)]

static func shadowing() -> float:
	var total := 0.0
	if true:
		var point := Point.new(1.0)
		total += point.x
	if true:
		var point := Point.new(4.0)
		total += point.x
	return total

static func chained_constructors() -> float:
	var first := Point.new(3.0)
	var second := Point.new(first.x + 1.0)
	return second.x + first.x

static func skipped_branches(point: Point) -> Array:
	events.clear()
	var result := false and next(int(point.x)) > 0
	var alternative: float = point.x if true else next(10)
	return [result, alternative, events.duplicate()]

static func branch_checks() -> Array:
	return skipped_branches(Point.new(4.0))

static func reassignment() -> float:
	var point := Point.new(3.0)
	point = Point.new(8.0)
	return point.x

static func collision() -> float:
	var _struct_opt_read_0_0 := 5.0
	var point := Point.new(2.0)
	return point.x + _struct_opt_read_0_0

static func inline_statements(point: Point) -> float:
	var before: float = point.x; point.x = 9.0
	var change: Callable = func(): point.x = 10.0
	change.call()
	match point.y:
		2: return before + point.x
		_: return 0.0

static func statement_checks() -> float:
	return inline_statements(Point.new(3.0))

static func cast_wrappers(point: Point) -> float:
	return ((point.x) as float) + (consume(point.x) as float)

static func cast_checks() -> float:
	return cast_wrappers(Point.new(3.0))

static func named_value(label: String, value: float) -> float:
	return value if label == "point.x" else -100.0

static func literal_spelling() -> float:
	var point := Point.new(3.0)
	var otherpoint := Point.new(5.0)
	var second := Point.new(named_value("point.x", otherpoint.x + point.x))
	return second.x
