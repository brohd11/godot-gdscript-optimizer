extends RefCounted
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/auto_modes.gd"

static func run_tests() -> Dictionary:
	var failures:Array = []
	var source := FileAccess.get_file_as_string(FIXTURE)
	var original = load(FIXTURE)
	for struct_mode:String in Optimizer.Config.MODES:
		for inline_mode:String in Optimizer.Config.MODES:
			for aggressive:bool in [false, true]:
				var context = Optimizer.Context.new()
				context.configure({"struct_mode": struct_mode, "inline_mode": inline_mode, "aggressive": aggressive})
				var optimizer = Optimizer.new()
				var prepared := optimizer.prepare({FIXTURE: FIXTURE}, context, [Optimizer.StructPass, Optimizer.InlinePass])
				var result := optimizer.apply(FIXTURE, Array(source.split("\n")))
				var label := "%s/%s aggressive=%s" % [struct_mode, inline_mode, aggressive]
				if not prepared.errors.is_empty() or not result.errors.is_empty():
					failures.append(label + ": " + str(prepared) + str(result.errors))
					continue
				var text := "\n".join(result.lines)
				var script := GDScript.new()
				script.source_code = text
				if script.reload() != OK:
					failures.append(label + ": compile failed\n" + text)
					continue
				for input:int in [-2, 0, 3]:
					if script.values(input) != original.values(input) or script.usage_checks() != [11, 12, 13, true]:
						failures.append(label + ": values changed")
				if script.container_check() != 15 or not script.nullable_check() or script.identity_check() or script.escape_check() != 2 or script.receiver_check() != [16, 16]:
					failures.append(label + ": identity, escape, or receiver behavior changed")
				if not text.contains("Nullable.new()") or not text.contains("Identity.new()") or not text.contains("Escaping.new()"):
					failures.append(label + ": observable object identity or untyped escape was lowered")
				if not text.contains("with_receiver(value, value.read())") or text.contains("explicit_receiver(value, value.read())") != (inline_mode == "off"):
					failures.append(label + ": receiver argument permission was not enforced")
				if script.effectful() != 2 or script.effects != 1:
					failures.append(label + ": unproven argument was duplicated")
				if script.forced() != (2 if inline_mode == "off" else 3):
					failures.append(label + ": explicit substitute permission missing")
				var body := text.split("static func values(")[1].split("\nstatic func")[0]
				for name:String in ["Excluded.new()", "Behavioral.new()", "Reflected.new()", "excluded(input)"]:
					if not body.contains(name):
						failures.append(label + ": excluded or unsupported candidate changed: " + name)
				if body.contains("automatic(input)") != (inline_mode != "auto") or body.contains("tagged(input)") != (inline_mode == "off"):
					failures.append(label + ": inline selection wrong")
				if body.contains("Automatic.new(input)") != (struct_mode != "auto") or body.contains("Tagged.new()") != (struct_mode == "off"):
					failures.append(label + ": struct selection wrong")
				if body.contains("RefFields.new()") != (struct_mode != "auto" or not aggressive) or body.contains("VariantFields.new()") != (struct_mode != "auto" or not aggressive):
					failures.append(label + ": reference/Variant struct policy wrong")
				if text.contains(" else "):
					failures.append(label + ": generated ternary")
				if aggressive and inline_mode == "auto" and not text.contains("twice(next())"):
					failures.append(label + ": nested argument lost its effect provenance")
				var again := optimizer.apply(FIXTURE, Array(source.split("\n")))
				if again.lines != result.lines or again.stats != result.stats:
					failures.append(label + ": replay is not deterministic")
	return {"result": failures.size(), "output": ["auto modes: %d failures" % failures.size()] + failures}
