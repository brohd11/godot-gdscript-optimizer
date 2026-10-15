extends SceneTree

func _init() -> void:
	var failures = 0
	var suites := ["auto_modes", "tag_registry", "struct", "optimizer", "inline", "expression_inline", "composition", "early_return", "expanded_inline", "template_inline", "substitute", "static_inline", "struct_optimization", "struct_references"]
	if not OS.get_cmdline_user_args().is_empty():
		suites = Array(OS.get_cmdline_user_args())
	for name in suites:
		var suite = load("res://addons/_lib/gdscript_optimizer/_export_ignore/test/%s_test.gd" % name)
		if suite == null or not suite.has_method("run_tests"):
			failures += 1
			continue
		var result:Dictionary = suite.run_tests()
		failures += result.result
		print("\n".join(result.output))
	quit(0 if failures == 0 else 1)
