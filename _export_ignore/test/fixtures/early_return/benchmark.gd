extends RefCounted

#! inline
static func classify(value:int) -> int:
	if value < 0:
		return 1
	if value == 0:
		return 2
	var adjusted:int = value + 3
	return adjusted * 2

#! inline
static func update(state:Array[int], value:int) -> void:
	if value < 0:
		state[0] += 1
		return
	if value == 0:
		state[0] += 2
		return
	state[0] += (value + 3) * 2

static func values(iterations:int, distribution:int) -> int:
	var total:int = 0
	for i:int in iterations:
		var value:int = distribution if distribution < 2 else i % 3 - 1
		var amount := classify(value)
		total += amount
	return total

static func effects(iterations:int, distribution:int) -> int:
	var state:Array[int] = [0]
	for i:int in iterations:
		var value:int = distribution if distribution < 2 else i % 3 - 1
		update(state, value)
	return state[0]
