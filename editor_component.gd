# EditorComponent.gd
class_name EditorComponent
extends VBoxContainer

signal text_changed()
signal editor_focus_changed(editor: CodeEdit)

var left_editor: CodeEdit
var right_editor: CodeEdit
var sync_scroll_enabled := true
var active_editor: CodeEdit = null

const COLORS = {
	"code_background": Color("#333b4f"),
	"code_text": Color("#ffffff")
}

func setup_editors() -> void:
	left_editor = _create_styled_editor()
	right_editor = _create_styled_editor()
	add_child(left_editor)
	add_child(right_editor)
	_connect_editor_signals()

func _create_styled_editor() -> CodeEdit:
	var editor = CodeEdit.new()
	editor.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	editor.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	
	var editor_style = StyleBoxFlat.new()
	editor_style.bg_color = COLORS.code_background
	editor.add_theme_stylebox_override("normal", editor_style)
	editor.add_theme_color_override("font_color", COLORS.code_text)
	
	editor.gutters_draw_line_numbers = true
	editor.text_changed.connect(_on_text_changed)
	editor.focus_entered.connect(_on_editor_focus_entered.bind(editor))
	return editor

func _connect_editor_signals() -> void:
	left_editor.get_v_scroll_bar().value_changed.connect(_on_editor_scroll.bind(left_editor))
	right_editor.get_v_scroll_bar().value_changed.connect(_on_editor_scroll.bind(right_editor))

func _on_editor_scroll(value: float, source_editor: CodeEdit) -> void:
	if not sync_scroll_enabled: return
	var target_editor = right_editor if source_editor == left_editor else left_editor
	target_editor.get_v_scroll_bar().value = value

func _on_editor_focus_entered(editor: CodeEdit) -> void:
	active_editor = editor
	editor_focus_changed.emit(editor)

func _on_text_changed() -> void:
	text_changed.emit()
