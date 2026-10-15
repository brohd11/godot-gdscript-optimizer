extends SceneTree
## Timings exclude optimization, compilation, and warmup; counters validate each evaluation policy.
const Optimizer = preload("res://addons/_lib/gdscript_optimizer/src/optimizer.gd")
const BASE = "res://addons/_lib/gdscript_optimizer/_export_ignore/test/fixtures/composition/"

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var iterations:int = int(args[0]) if args.size() > 0 else 100000
	var samples:int = int(args[1]) if args.size() > 1 else 7
	if iterations < 1 or samples < 1:
		quit(1)
		return
	var path := BASE + "benchmark.gd"
	var optimizer = Optimizer.new()
	var prepared:Dictionary = optimizer.prepare({path: path, BASE + "helpers.gd": BASE + "helpers.gd"}, Optimizer.Context.new(), [Optimizer.InlinePass])
	if not prepared.errors.is_empty():
		quit(1)
		return
	var result:Dictionary = optimizer.apply(path, Array(FileAccess.get_file_as_string(path).split("\n")))
	var original = load(path)
	var transformed := GDScript.new()
	transformed.source_code = "\n".join(result.lines)
	if transformed.reload() != OK:
		quit(1)
		return
	var report:Array = []
	for method:String in ["ordinary", "substituted"]:
		original.call(method, 1000)
		transformed.call(method, 1000)
		var before:Array = []
		var after:Array = []
		var true_count:int = (iterations + 1) >> 1
		for sample in samples:
			for optimized:bool in ([false, true] if sample % 2 == 0 else [true, false]):
				var target = transformed if optimized else original
				var start := Time.get_ticks_usec()
				var actual:Array = target.call(method, iterations)
				var elapsed := Time.get_ticks_usec() - start
				var expected_calls:int = (iterations + true_count if optimized else 2 * iterations) if method == "substituted" else 0
				if actual != [true_count, expected_calls]:
					printerr("COMPOSITION_BENCHMARK_FAILED ", method, " ", actual)
					quit(1)
					return
				(after if optimized else before).append(elapsed)
		before.sort()
		after.sort()
		var middle:int = samples >> 1
		report.append({"method": method, "iterations": iterations, "samples": samples,
			"original_us": before[middle], "optimized_us": after[middle], "speedup": float(before[middle]) / after[middle]})
	print("COMPOSITION_BENCHMARK ", JSON.stringify(report))
	quit()
