extends SceneTree
## Run with -- iterations samples; timings exclude optimization, compilation, and warmup.
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const FIXTURE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/early_return/benchmark.gd"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var iterations:int = int(args[0]) if args.size() > 0 else 200000
	var samples:int = int(args[1]) if args.size() > 1 else 7
	if iterations < 1 or samples < 1:
		quit(1)
		return
	var optimizer = Optimizer.new()
	var prepared:Dictionary = optimizer.prepare({FIXTURE: FIXTURE}, Optimizer.Context.new(), [Optimizer.InlinePass])
	var result:Dictionary = optimizer.apply(FIXTURE, Array(FileAccess.get_file_as_string(FIXTURE).split("\n")))
	var transformed := GDScript.new()
	transformed.source_code = "\n".join(result.lines)
	if not prepared.errors.is_empty() or (prepared.warnings.size() != 1 or not str(prepared.warnings).contains("limited to void")) or not result.errors.is_empty() or result.stats.inline_early_return_calls != 1 or transformed.reload() != OK:
		printerr("EARLY_RETURN_BENCHMARK_SETUP_FAILED ", prepared, result)
		quit(1)
		return
	var original = load(FIXTURE)
	var report:Array = []
	for method:String in ["values", "effects"]:
		for distribution:int in [-1, 0, 1, 2]:
			original.call(method, 1000, distribution)
			transformed.call(method, 1000, distribution)
			var before:Array = []
			var after:Array = []
			var checksum:int = iterations * ([1, 2, 8][distribution + 1] if distribution < 2 else 0)
			if distribution == 2:
				checksum = (iterations / 3) * 11 + ([0, 1, 3][iterations % 3])
			for sample in samples:
				for optimized:bool in ([false, true] if sample % 2 == 0 else [true, false]):
					var target = transformed if optimized else original
					var start := Time.get_ticks_usec()
					var actual:int = target.call(method, iterations, distribution)
					var elapsed := Time.get_ticks_usec() - start
					if actual != checksum:
						printerr("EARLY_RETURN_BENCHMARK_CHECKSUM_FAILED ", method, actual, checksum)
						quit(1)
						return
					(after if optimized else before).append(elapsed)
			before.sort()
			after.sort()
			var middle:int = samples >> 1
			report.append({"method": method, "inlined": method == "effects", "distribution": ["first_guard", "second_guard", "fallthrough", "mixed"][distribution + 1],
				"iterations": iterations, "samples": samples, "checksum": checksum,
				"original_us": before[middle], "optimized_us": after[middle], "speedup": float(before[middle]) / after[middle]})
	print("EARLY_RETURN_BENCHMARK ", JSON.stringify(report))
	quit()
