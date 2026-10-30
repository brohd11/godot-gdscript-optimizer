extends RefCounted

## A tagged func sharing its name with Array.any, so `arr.any(...)` is a by-name candidate.
#! inline
static func any(a:bool, b:bool) -> bool:
	return a or b
