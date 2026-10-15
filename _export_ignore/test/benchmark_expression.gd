extends SceneTree
## Run with -- iterations samples; timings exclude parsing, compilation, and warmup.

const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/expression_inline/predicates.gd"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var iterations:int = int(args[0]) if args.size() > 0 else 200000
	var samples:int = int(args[1]) if args.size() > 1 else 7
	if iterations < 1 or samples < 1:
		quit(1)
		return
	var original = load(FIXTURE)
	var report:Array = []
	for variants in [false, true]:
		var context = Optimizer.Context.new()
		context.aggressive = variants
		var optimizer = Optimizer.new()
		var prepared:Dictionary = optimizer.prepare({FIXTURE: FIXTURE}, context, [Optimizer.InlinePass])
		if not prepared.errors.is_empty():
			quit(1)
			return
		var result:Dictionary = optimizer.apply(FIXTURE, Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
		var script := GDScript.new()
		script.source_code = "\n".join(result.lines)
		if script.reload() != OK:
			quit(1)
			return
		for method:String in ["bench_typed", "bench_variant"]:
			original.call(method, 1000)
			script.call(method, 1000)
			var baseline:Array = []
			var optimized:Array = []
			var checksum:int = original.call(method, iterations)
			for sample in samples:
				# Alternate order to reduce warm-cache and scheduling bias.
				for transformed:bool in ([false, true] if sample % 2 == 0 else [true, false]):
					var target = script if transformed else original
					var start := Time.get_ticks_usec()
					var actual:int = target.call(method, iterations)
					var elapsed := Time.get_ticks_usec() - start
					if actual != checksum:
						printerr("predicate checksum mismatch")
						quit(1)
						return
					(optimized if transformed else baseline).append(elapsed)
			baseline.sort()
			optimized.sort()
			var middle:int = samples >> 1
			report.append({"method": method, "aggressive": variants, "iterations": iterations,
				"samples": samples, "checksum": checksum, "original_us": baseline[middle],
				"optimized_us": optimized[middle], "speedup": float(baseline[middle]) / optimized[middle]})
	print("EXPRESSION_BENCHMARK " + JSON.stringify(report))
	quit()
