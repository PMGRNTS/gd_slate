# gdscript_highlighter.gd
class_name GDScriptHighlighter
extends SyntaxHighlighter

# Theme presets
const DARK_THEME = {
	"symbol": Color("#abc9ff"),
	"keyword": Color("#ff7085"),
	"control_flow": Color("#ff8ccc"),
	"base_type": Color("#42ffc2"),
	"engine_type": Color("#8fffdb"),
	"user_type": Color("#c7ffed"),
	"comment": Color("#676767"),
	"doc_comment": Color("#99b3cc"),
	"string": Color("#ffeda1"),
	"number": Color("#b5cea8"),
	"function_def": Color("#66e6ff"),
	"function_call": Color("#57b3ff"),
	"node_path": Color("#63c259"),
	"annotation": Color("#ffb373"),
	"default": Color("#ffffff")
}

const LIGHT_THEME = {
	"symbol": Color("#0066cc"),
	"keyword": Color("#d73a49"),
	"control_flow": Color("#b31d28"),
	"base_type": Color("#22863a"),
	"engine_type": Color("#005cc5"),
	"user_type": Color("#6f42c1"),
	"comment": Color("#6a737d"),
	"doc_comment": Color("#6a737d"),
	"string": Color("#032f62"),
	"number": Color("#005cc5"),
	"function_def": Color("#6f42c1"),
	"function_call": Color("#005cc5"),
	"node_path": Color("#22863a"),
	"annotation": Color("#e36209"),
	"default": Color("#24292e")
}

var colors: Dictionary = DARK_THEME
var _regex_cache: Dictionary = {}
var _is_initialized: bool = false

# Keyword sets
const KEYWORDS = [
	"func", "class", "class_name", "extends", "signal", "enum", "static",
	"var", "const", "self", "super", "null", "true", "false",
	"and", "or", "not", "in", "is", "as", "await", "yield"
]

const CONTROL_FLOW = [
	"if", "elif", "else", "for", "while", "match", "when",
	"break", "continue", "pass", "return"
]

const BASE_TYPES = [
	"bool", "int", "float", "String", "StringName", "Array",
	"Dictionary", "Variant", "void", "Callable", "Signal"
]

const ENGINE_TYPES = [
	"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i",
	"Rect2", "Rect2i", "Transform2D", "Transform3D", "Basis", "Quaternion",
	"Color", "NodePath", "RID", "Object", "Node", "Node2D", "Node3D",
	"Control", "Resource", "RefCounted", "PackedScene", "Texture2D",
	"Timer", "HTTPRequest", "FileAccess", "DirAccess", "Input", "OS", "Time",
	"Engine", "ProjectSettings", "ResourceLoader", "ClassDB",
	"Tween", "SceneTree", "Viewport", "Window", "CodeEdit", "TextEdit",
	"Label", "Button", "LineEdit", "PanelContainer", "VBoxContainer",
	"HBoxContainer", "HSplitContainer", "MenuButton", "PopupMenu",
	"StyleBoxFlat", "Theme", "Font", "SystemFont"
]


func _init():
	# Parameterless constructor - call setup() after creation
	pass


func setup(dark_mode: bool = true) -> GDScriptHighlighter:
	colors = DARK_THEME if dark_mode else LIGHT_THEME
	_compile_regex_patterns()
	_is_initialized = true
	return self


func set_dark_mode(enabled: bool) -> void:
	colors = DARK_THEME if enabled else LIGHT_THEME


func _compile_regex_patterns() -> void:
	_regex_cache["doc_comment"] = _create_regex("##.*$")
	_regex_cache["comment"] = _create_regex("#.*$")
	_regex_cache["triple_string_double"] = _create_regex("\"\"\"[\\s\\S]*?\"\"\"")
	_regex_cache["triple_string_single"] = _create_regex("'''[\\s\\S]*?'''")
	_regex_cache["double_string"] = _create_regex("\"(?:[^\"\\\\]|\\\\.)*\"")
	_regex_cache["single_string"] = _create_regex("'(?:[^'\\\\]|\\\\.)*'")
	_regex_cache["annotation"] = _create_regex("@\\w+")
	_regex_cache["node_path"] = _create_regex("[$%][\\w/]+")
	_regex_cache["hex_number"] = _create_regex("\\b0x[0-9a-fA-F]+\\b")
	_regex_cache["bin_number"] = _create_regex("\\b0b[01]+\\b")
	_regex_cache["float_number"] = _create_regex("\\b\\d+\\.\\d+(?:e[+-]?\\d+)?\\b")
	_regex_cache["int_number"] = _create_regex("\\b\\d+\\b")
	_regex_cache["function_def"] = _create_regex("(?<=func )\\w+")
	_regex_cache["identifier"] = _create_regex("\\b[a-zA-Z_][a-zA-Z0-9_]*\\b")


func _create_regex(pattern: String) -> RegEx:
	var regex = RegEx.new()
	var err = regex.compile(pattern)
	if err != OK:
		push_error("GDScriptHighlighter: Failed to compile regex: " + pattern)
		return null
	return regex


func _get_line_syntax_highlighting(line: int) -> Dictionary:
	if not _is_initialized:
		setup(true)
	
	var text_edit = get_text_edit()
	if not text_edit:
		return {}
	
	var text = text_edit.get_line(line)
	if text.is_empty():
		return {}
	
	var result: Dictionary = {}
	var colored: Array[bool] = []
	colored.resize(text.length())
	colored.fill(false)
	
	# Order matters — higher precedence first
	
	# 1. Doc comments (##)
	_highlight_regex(text, "doc_comment", "doc_comment", result, colored)
	
	# 2. Regular comments (#)
	_highlight_regex(text, "comment", "comment", result, colored)
	
	# 3. Strings (check triple-quoted first)
	_highlight_regex(text, "triple_string_double", "string", result, colored)
	_highlight_regex(text, "triple_string_single", "string", result, colored)
	_highlight_regex(text, "double_string", "string", result, colored)
	_highlight_regex(text, "single_string", "string", result, colored)
	
	# 4. Annotations (@export, @onready, etc.)
	_highlight_regex(text, "annotation", "annotation", result, colored)
	
	# 5. Node paths ($Node, %UniqueNode)
	_highlight_regex(text, "node_path", "node_path", result, colored)
	
	# 6. Numbers (order: hex, bin, float, int)
	_highlight_regex(text, "hex_number", "number", result, colored)
	_highlight_regex(text, "bin_number", "number", result, colored)
	_highlight_regex(text, "float_number", "number", result, colored)
	_highlight_regex(text, "int_number", "number", result, colored)
	
	# 7. Function definitions
	_highlight_regex(text, "function_def", "function_def", result, colored)
	
	# 8. Identifiers (keywords, types, function calls)
	_highlight_identifiers(text, result, colored)
	
	return result


func _highlight_regex(text: String, regex_key: String, color_key: String, result: Dictionary, colored: Array[bool]) -> void:
	var regex: RegEx = _regex_cache.get(regex_key)
	if not regex:
		return
	
	for regex_match in regex.search_all(text):
		var start = regex_match.get_start()
		var end = regex_match.get_end()
		
		if _is_range_colored(colored, start, end):
			continue
		
		result[start] = {"color": colors[color_key]}
		result[end] = {"color": colors["default"]}
		_mark_range_colored(colored, start, end)


func _highlight_identifiers(text: String, result: Dictionary, colored: Array[bool]) -> void:
	var regex: RegEx = _regex_cache.get("identifier")
	if not regex:
		return
	
	for regex_match in regex.search_all(text):
		var start = regex_match.get_start()
		var end = regex_match.get_end()
		var word = regex_match.get_string()
		
		if _is_range_colored(colored, start, end):
			continue
		
		var color_key = _classify_identifier(word, text, end)
		if color_key.is_empty():
			continue
		
		result[start] = {"color": colors[color_key]}
		result[end] = {"color": colors["default"]}
		_mark_range_colored(colored, start, end)


func _classify_identifier(word: String, line: String, end_pos: int) -> String:
	if word in KEYWORDS:
		return "keyword"
	if word in CONTROL_FLOW:
		return "control_flow"
	if word in BASE_TYPES:
		return "base_type"
	if word in ENGINE_TYPES:
		return "engine_type"
	
	# Function call check (followed by parenthesis)
	var rest = line.substr(end_pos).strip_edges()
	if rest.begins_with("("):
		return "function_call"
	
	# PascalCase = likely a type
	if word.length() > 1 and word[0] == word[0].to_upper() and word[0] != "_":
		var has_lower = false
		for c in word:
			if c == c.to_lower() and c != "_":
				has_lower = true
				break
		if has_lower:
			return "user_type"
	
	return ""


func _is_range_colored(colored: Array[bool], start: int, end: int) -> bool:
	for i in range(start, mini(end, colored.size())):
		if colored[i]:
			return true
	return false


func _mark_range_colored(colored: Array[bool], start: int, end: int) -> void:
	for i in range(start, mini(end, colored.size())):
		colored[i] = true
