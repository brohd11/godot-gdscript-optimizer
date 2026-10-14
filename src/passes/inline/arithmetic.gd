extends RefCounted
## A deliberately small expression grammar: no calls, member access, or implicit conversions.

var _tokens:Array = []
var _index:int
var _parameters:Dictionary
var _error:String


func analyze(source:String, parameters:Dictionary) -> Dictionary:
	_tokens = []
	_index = 0
	_parameters = parameters
	_error = ""
	var regex := RegEx.new()
	regex.compile(r"\s*(?:(?<number>(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)|(?<name>[A-Za-z_][A-Za-z_0-9]*)|(?<operator>[()+*/%\-]))")
	var offset := 0
	while offset < source.length():
		if source.substr(offset).strip_edges().is_empty():
			break
		var found := regex.search(source, offset)
		if found == null or found.get_start() != offset:
			return {"error": "unsupported arithmetic expression"}
		var number := found.get_string("number")
		var name := found.get_string("name")
		_tokens.append({"text": number if number != "" else (name if name != "" else found.get_string("operator")),
			"number": number != "", "name": name != ""})
		offset = found.get_end()
	var result := _binary(0)
	if _index != _tokens.size() or _tokens.is_empty():
		_error = "unsupported arithmetic expression"
	return {"error": _error, "type": result.type, "tokens": _tokens.duplicate(), "known": result.known, "value": result.value}


static func render(tokens:Array, bindings:Dictionary) -> String:
	var parts := PackedStringArray()
	for token:Dictionary in tokens:
		parts.append("(" + bindings[token.text] + ")" if token.name else token.text)
	return "(" + " ".join(parts) + ")"


func _binary(minimum:int) -> Dictionary:
	var left := _primary()
	while _index < _tokens.size():
		var op:String = _tokens[_index].text
		var priority := 1 if op in ["+", "-"] else (2 if op in ["*", "/", "%"] else -1)
		if priority < minimum:
			break
		_index += 1
		var right := _binary(priority + 1)
		var type:String = "float" if "float" in [left.type, right.type] else "int"
		if op == "%" and type != "int":
			_error = "remainder requires integers"
		if op in ["/", "%"] and right.known and right.value == 0:
			_error = "constant zero divisor"
		var value:Variant = 0
		var known:bool = left.known and right.known and _error.is_empty()
		if known:
			match op:
				"+": value = left.value + right.value
				"-": value = left.value - right.value
				"*": value = left.value * right.value
				"/": value = left.value / right.value
				"%": value = left.value % right.value
		left = {"type": type, "known": known, "value": value}
	return left


func _primary() -> Dictionary:
	var unknown := {"type": "int", "known": false, "value": 0}
	if _index >= _tokens.size():
		_error = "missing arithmetic operand"
		return unknown
	var token:Dictionary = _tokens[_index]
	_index += 1
	if token.text in ["+", "-"]:
		var value := _primary()
		if token.text == "-" and value.known:
			value.value = -value.value
		return value
	if token.text == "(":
		var value := _binary(0)
		if _index >= _tokens.size() or _tokens[_index].text != ")":
			_error = "unbalanced arithmetic expression"
		else:
			_index += 1
		return value
	if token.number:
		var floating:bool = "." in token.text or "e" in token.text.to_lower()
		return {"type": "float" if floating else "int", "known": true,
			"value": token.text.to_float() if floating else token.text.to_int()}
	if token.name and _parameters.get(token.text, "") in ["int", "float"]:
		unknown.type = _parameters[token.text]
		return unknown
	_error = "only numeric parameters and literals are supported"
	return unknown
