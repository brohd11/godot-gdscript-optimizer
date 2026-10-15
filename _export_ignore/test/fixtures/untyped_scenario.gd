extends RefCounted
## Every way a struct loses its static type. The export has to refuse each one: once the struct is an
## Array, a field read through any of these compiles and only breaks at runtime.

const StructVec = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_vec.gd")

signal changed(value)

var loose
var cb: Callable
var some_callable: Callable


static func untyped_local():
	var u = StructVec.new(1.0, 2.0)
	return u


func untyped_member() -> void:
	loose = StructVec.new(1.0, 2.0)


static func untyped_return():
	return StructVec.new(1.0, 2.0)


static func untyped_param(p) -> void:
	print(p)


static func call_untyped() -> void:
	untyped_param(StructVec.new(1.0, 2.0))


static func typed_ok(p: StructVec) -> StructVec:
	var kept: StructVec = p
	return kept


static func literal_row(v: StructVec) -> void:
	var row = [v, 1]
	print(row)


static func literal_dict(v: StructVec) -> Dictionary:
	return {"v": v}


static func literal_typed_ok(v: StructVec) -> Array[StructVec]:
	var ok: Array[StructVec] = [v]
	ok.append(v)
	return [v]


static func takes(list: Array) -> void:
	print(list)


static func literal_arg(v: StructVec) -> void:
	takes([v])


static func lambda_untyped(vs: Array[StructVec]) -> Array:
	return vs.map(func(e): return e)


static func lambda_typed(vs: Array[StructVec]) -> Array:
	return vs.map(func(e: StructVec): return e.x)


func sinks(v: StructVec, vs: Array[StructVec]) -> void:
	vs.map(some_callable)
	changed.emit(v)
	cb.call(v)


static func named_untyped(vs: Array[StructVec]) -> Array:
	var ident = func(e): return e
	return vs.map(ident)


static func body_untyped(vs: Array[StructVec]) -> Array:
	return vs.map(func(e: StructVec) -> StructVec:
		var u = e
		return u
	)


static func lambda_return():
	var mk = func() -> StructVec:
		return StructVec.new(1.0, 2.0)
	return mk
