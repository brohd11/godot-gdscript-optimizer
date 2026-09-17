extends RefCounted
## Mark completed edits at logical statement boundaries, never inside a string or expression.

const Scanner = preload("res://addons/addon_lib/tag_parser/scanner.gd")

static func annotate(lines:Array, events:Array) -> Array:
	var starts:Array = []
	var state := {"quote": "", "depth": 0, "cont": false}
	var start := 0
	for i in lines.size():
		if not state.cont:
			start = i
		starts.append(start)
		Scanner.scan_code(lines[i], state)
	var markers:Dictionary = {}
	for event:Dictionary in events:
		if event.line < 0 or event.line >= lines.size():
			continue
		var at:int = starts[event.line]
		var details:Array = []
		for key:String in event.details:
			details.append(key + "=" + JSON.stringify(event.details[key]))
		var line:String = lines[at]
		var indent := line.substr(0, line.length() - line.strip_edges(true, false).length())
		markers.get_or_add(at, []).append(indent + "# optimizer-" + event.kind + "; " + " ".join(details))
	var out:Array = []
	for i in lines.size():
		out.append_array(markers.get(i, []))
		out.append(lines[i])
	return out
