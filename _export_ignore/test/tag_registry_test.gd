extends RefCounted

const Legacy = preload("res://addons/_lib/gdscript_optimizer/src/tag_registry.gd")
const Shared = preload("res://addons/_lib/editor_parser/src/tag/registry.gd")

static func run_tests() -> Dictionary:
	var source := PackedStringArray(["#! struct", "class Value:", "\tvar x:int"])
	var actual := Legacy.scan_lines(source, "res://sample.gd")
	var expected := Shared.scan_lines(source, "res://sample.gd")
	var registry = Legacy.new()
	registry.replace_source("res://sample.gd", source)
	var ok:bool = actual == expected and registry.has_tag("res://sample.gd.Value", "struct")
	return {"result": 0 if ok else 1, "output": ["tag_registry compatibility: " + ("PASS" if ok else "FAIL")]}
