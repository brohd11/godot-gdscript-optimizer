extends RefCounted
## `#! struct` phase 2 fixture: field access through each typed route the exporter has to resolve.

const StructVec = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_vec.gd")
const StructFixture = preload("res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/struct_fixture.gd")

var held: StructVec
## Two lambdas on one line, after a non-ASCII string: each read resolves by its own column.
var readers = ["é", func(v: StructVec) -> float: return v.x, func(w: StructVec) -> float: return w.y]


static func length_sq(v: StructVec) -> float:
	return v.x * v.x + v.y * v.y


static func from_return() -> int:
	return StructFixture.make(3).left


static func local_typed() -> String:
	var p: StructFixture.Pair = StructFixture.Pair.new(1)
	p.right = "changed"
	return p.right


static func local_inferred() -> float:
	var v := StructVec.new(1.0, 2.0)
	v.x += 1.0
	return v.x


static func loop_sum(vs: Array[StructVec]) -> float:
	var total := 0.0
	for v in vs:
		total += v.x
	return total


func member() -> float:
	held = StructVec.new(3.0, 4.0)
	return self.held.y + held.x


static func indexed(vs: Array[StructVec]) -> float:
	return vs[0].y


## A literal holding structs is fine when it lands in a typed collection.
static func typed_list(a: StructVec, b: StructVec) -> float:
	var list: Array[StructVec] = [a, b]
	return list[1].y


## Reads inside a multi-line inline lambda and a var-bound one-liner.
static func lambda_sum(vs: Array[StructVec]) -> float:
	var ys := vs.map(func(e: StructVec) -> float:
		var y := e.y
		return y
	)
	var get_x = func(v: StructVec) -> float: return v.x
	return get_x.call(vs[0]) + ys[1]
