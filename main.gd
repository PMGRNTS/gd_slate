# Main.gd
extends Control
class_name AICodeEditor

# State machine for AI operations
enum AIState {
	IDLE,
	WAITING_FOR_INPUT,
	PROCESSING,
	STREAMING,
	ERROR
}

enum EditorMode {
	COMPARE,
	AI
}

# Configuration
const API_URL = "https://api.anthropic.com/v1/messages"
const API_VERSION = "2023-06-01"
const SEARCH_SHORTCUT_KEY = KEY_F
const SYSTEM_PROMPT_SHORTCUT_KEY = KEY_P
const API_KEY_SHORTCUT_KEY = KEY_R

# Material Design color palette
const COLORS = {
	"primary": Color("#699ce8"),
	"primary_dark": Color("#699ce8"),
	"surface": Color("#333b4f"),
	"background": Color("#fafafa"),
	"on_surface": Color("#699ce8"),
	"on_surface_medium": Color("#00000099"),
	"on_primary": Color("#ffffff"),
	"elevation_1": Color("#00000014"),
	"elevation_2": Color("#0000001f"),
	"code_background": Color("#333b4f"),
	"code_text": Color("#ffffff"),
	"ai_mode_background": Color("#2A1B3D"),
	"ai_mode_surface": Color("#352641"),
	"ai_mode_accent": Color("#B4A0E5")
}

# Core components
var request_manager: AIRequestManager
var error_handler: AIErrorHandler
var api_settings: APISettings
var http_request: HTTPRequest

# Syntax highlighters
var left_highlighter: GDScriptHighlighter
var right_highlighter: GDScriptHighlighter

# Editors
var left_editor: CodeEdit
var right_editor: CodeEdit
var active_editor: CodeEdit = null

# UI Elements
var root_container: VBoxContainer
var splitter: HSplitContainer
var view_menu_button: MenuButton
var ai_mode_button: MenuButton
var search_container: PanelContainer
var search_bar: LineEdit
var match_label: Label
var system_prompt_container: PanelContainer
var system_prompt_editor: TextEdit
var status_bar: PanelContainer
var mode_indicator: Label
var file_info: Label
var stats_label: Label

# Timers
var streaming_timer: Timer

# State
var current_mode: EditorMode = EditorMode.COMPARE
var ai_state: AIState = AIState.IDLE
var ai_mode_active: bool = false
var sync_scroll_enabled: bool = false
var is_dragging_window: bool = false
var drag_start_position: Vector2 = Vector2()

# Search state
var current_search_index: int = -1
var search_results: Array = []

# File tracking
var left_file_name: String = "No file"
var right_file_name: String = "No file"

# AI state
var api_key: String = ""
var prompt_history: Array = []
var current_ai_request_id: String = ""

# Commented out - keeping for future use
# var text_animator: JuicyTextAnimator

var default_system_prompt = """You are an AI that analyzes and edits Godot 4.x .gd files. The text you receive as prompts is the exact text as the .gd file to be edited. Expect questions and instructions to be embedded inside these scripts as commented out text.
Your response to these prompts is the edited version of these .gd files. If you need to explain or instruct, you are to type in commented out lines inside the script. You NEVER have a Beginning Part or Header before the script. 
You NEVER explain yourself after the script as a post-script explanation. Every aspect of your response is inside (embedded if you will) the script as commented out lines. You are ALWAYS under the assumption, no, the ASSURANCE, that your output reply text will LITERALLY be the contents of the file if saved. 
So any preamble or post script, if stupidly written, would throw errors in Godot 4."""


func _ready():
	# Initialize error handler
	error_handler = AIErrorHandler.new()
	add_child(error_handler)
	
	# Initialize request manager with error handler
	request_manager = AIRequestManager.new()
	add_child(request_manager)
	request_manager.setup(error_handler)
	request_manager.request_completed.connect(_on_request_completed)
	request_manager.error_occurred.connect(_on_request_error)
	
	# Initialize API settings
	api_settings = APISettings.new()
	api_settings.api_key_saved.connect(_on_api_key_saved)
	add_child(api_settings)
	api_settings.hide()
	
	# Load API key and pass to request manager
	api_key = api_settings.get_api_key()
	request_manager.set_api_key(api_key)
	
	# Create root container
	if not has_node("RootContainer"):
		root_container = VBoxContainer.new()
		root_container.name = "RootContainer"
		root_container.set_anchors_preset(Control.PRESET_FULL_RECT)
		root_container.set_h_size_flags(Control.SIZE_FILL)
		root_container.set_v_size_flags(Control.SIZE_FILL)
		root_container.set_clip_contents(true)
		add_child(root_container)
	else:
		root_container = get_node("RootContainer")
	
	# Apply theme
	var ide_theme = _create_material_theme()
	self.theme = ide_theme
	
	# Create menu bar
	var menu_container = _create_unified_menu_bar()
	root_container.add_child(menu_container)
	
	# Create main editor container
	var main_container = HSplitContainer.new()
	main_container.name = "MainContainer"
	main_container.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	main_container.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	main_container.add_theme_constant_override("separation", 16)
	root_container.add_child(main_container)
	
	# Create editors
	left_editor = _create_styled_editor()
	right_editor = _create_styled_editor()
	main_container.add_child(left_editor)
	main_container.add_child(right_editor)
	
	# Commented out - keeping for future use
	# text_animator = JuicyTextAnimator.new(left_editor)
	# add_child(text_animator)
	
	# Setup features
	_setup_editor_features()
	_setup_input_shortcuts()
	_setup_search_bar()
	_setup_system_prompt_panel()
	_setup_system_prompt_shortcut()
	
	# Initialize streaming timer
	streaming_timer = Timer.new()
	streaming_timer.one_shot = false
	streaming_timer.wait_time = 0.05
	streaming_timer.timeout.connect(_stream_next_chunk)
	add_child(streaming_timer)
	
	# Connect editor signals
	right_editor.gui_input.connect(_handle_editor_input)
	left_editor.text_changed.connect(_on_text_changed)
	right_editor.text_changed.connect(_on_text_changed)
	
	# Create status bar and apply syntax highlighting
	call_deferred("_create_status_bar")
	call_deferred("_refresh_syntax_highlighting")


func _setup_editor_features():
	active_editor = left_editor
	sync_scroll_enabled = true
	_connect_editor_signals()
	
	left_editor.focus_entered.connect(_on_editor_focus_entered.bind(left_editor))
	right_editor.focus_entered.connect(_on_editor_focus_entered.bind(right_editor))


func _connect_editor_signals():
	left_editor.get_v_scroll_bar().value_changed.connect(_on_editor_scroll.bind(left_editor))
	right_editor.get_v_scroll_bar().value_changed.connect(_on_editor_scroll.bind(right_editor))


func _disconnect_editor_signals():
	var left_scroll = left_editor.get_v_scroll_bar()
	var right_scroll = right_editor.get_v_scroll_bar()
	
	if left_scroll.value_changed.is_connected(_on_editor_scroll):
		left_scroll.value_changed.disconnect(_on_editor_scroll)
	
	if right_scroll.value_changed.is_connected(_on_editor_scroll):
		right_scroll.value_changed.disconnect(_on_editor_scroll)


func _on_editor_scroll(value: float, source_editor: CodeEdit):
	if not sync_scroll_enabled:
		return
	
	var target_editor = right_editor if source_editor == left_editor else left_editor
	target_editor.get_v_scroll_bar().value = value


func _on_editor_focus_entered(editor: CodeEdit):
	active_editor = editor


func _setup_input_shortcuts():
	if InputMap.has_action("toggle_search"):
		InputMap.erase_action("toggle_search")
	
	InputMap.add_action("toggle_search")
	var search_event = InputEventKey.new()
	search_event.keycode = SEARCH_SHORTCUT_KEY
	search_event.ctrl_pressed = true
	InputMap.action_add_event("toggle_search", search_event)


func _unhandled_input(event):
	if event.is_action_pressed("toggle_search"):
		_toggle_search()
		get_viewport().set_input_as_handled()
	elif search_container and search_container.visible:
		if event is InputEventKey and event.pressed:
			match event.keycode:
				KEY_ESCAPE:
					_toggle_search()
					get_viewport().set_input_as_handled()
				KEY_ENTER:
					if event.shift_pressed:
						_find_previous()
					else:
						_find_next()
					get_viewport().set_input_as_handled()
	
	if event.is_action_pressed("toggle_system_prompt"):
		_toggle_system_prompt()
		get_viewport().set_input_as_handled()
	
	if event is InputEventKey and event.pressed and event.keycode == KEY_R and event.ctrl_pressed:
		api_settings.popup_centered()
		get_viewport().set_input_as_handled()
	
	if event is InputEventKey and event.pressed:
		# Clear editors (Ctrl+Shift+N)
		if event.keycode == KEY_N and event.ctrl_pressed and event.shift_pressed:
			_clear_both_editors()
			get_viewport().set_input_as_handled()
		
		# Quick save (Ctrl+S)
		elif event.keycode == KEY_S and event.ctrl_pressed:
			_quick_save_active_editor()
			get_viewport().set_input_as_handled()
		
		# Toggle word wrap (Ctrl+W)
		elif event.keycode == KEY_W and event.ctrl_pressed:
			_toggle_word_wrap()
			get_viewport().set_input_as_handled()
		
		# Open file (Ctrl+O)
		elif event.keycode == KEY_O and event.ctrl_pressed:
			if active_editor:
				_open_file(active_editor)
			get_viewport().set_input_as_handled()
		
		# Toggle AI mode (Ctrl+Shift+A)
		elif event.keycode == KEY_A and event.ctrl_pressed and event.shift_pressed:
			toggle_ai_mode()
			get_viewport().set_input_as_handled()
	
	# Sync scrolling
	if sync_scroll_enabled and active_editor:
		var target_editor = right_editor if active_editor == left_editor else left_editor
		
		if event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down") or \
		   event.is_action_pressed("ui_page_up") or event.is_action_pressed("ui_page_down"):
			await get_tree().process_frame
			target_editor.set_v_scroll(active_editor.get_v_scroll())
			get_viewport().set_input_as_handled()


func _clear_both_editors():
	left_editor.text = ""
	right_editor.text = ""
	left_file_name = "No file"
	right_file_name = "No file"
	_update_status_info()


func _quick_save_active_editor():
	if not active_editor:
		return
	
	var file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Save File"
	file_dialog.add_filter("*.gd ; GDScript files")
	file_dialog.add_filter("*.txt ; Text files")
	file_dialog.add_filter("* ; All files")
	
	add_child(file_dialog)
	file_dialog.popup_centered(Vector2(600, 400))
	
	file_dialog.file_selected.connect(
		func(path):
			var file = FileAccess.open(path, FileAccess.WRITE)
			if file:
				file.store_string(active_editor.text)
				if active_editor == left_editor:
					left_file_name = path.get_file()
				else:
					right_file_name = path.get_file()
				_update_status_info()
			file_dialog.queue_free()
	)


func _toggle_word_wrap():
	if not view_menu_button or not is_instance_valid(view_menu_button):
		return
	
	var popup = view_menu_button.get_popup()
	var current_wrap = popup.is_item_checked(1)
	popup.set_item_checked(1, !current_wrap)
	
	var wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if !current_wrap else TextEdit.LINE_WRAPPING_NONE
	if left_editor:
		left_editor.wrap_mode = wrap_mode
	if right_editor:
		right_editor.wrap_mode = wrap_mode


# =============================================================================
# THEME AND UI CREATION
# =============================================================================

func _create_material_theme() -> Theme:
	var theme = Theme.new()
	
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = COLORS.surface
	panel_style.corner_radius_top_left = 8
	panel_style.corner_radius_top_right = 8
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.shadow_color = COLORS.elevation_1
	panel_style.shadow_size = 4
	panel_style.shadow_offset = Vector2(0, 2)
	
	var button_normal = StyleBoxFlat.new()
	button_normal.bg_color = COLORS.primary
	button_normal.corner_radius_top_left = 4
	button_normal.corner_radius_top_right = 4
	button_normal.corner_radius_bottom_left = 4
	button_normal.corner_radius_bottom_right = 4
	
	var button_hover = button_normal.duplicate()
	button_hover.bg_color = COLORS.primary_dark
	
	var button_pressed = button_hover.duplicate()
	button_pressed.shadow_size = 0
	
	theme.set_stylebox("panel", "Panel", panel_style)
	theme.set_stylebox("normal", "Button", button_normal)
	theme.set_stylebox("hover", "Button", button_hover)
	theme.set_stylebox("pressed", "Button", button_pressed)
	theme.set_color("font_color", "Label", COLORS.on_surface)
	theme.set_color("font_color", "Button", COLORS.on_primary)
	
	return theme


func _create_unified_menu_bar() -> PanelContainer:
	var menu_container = PanelContainer.new()
	
	var style_box = StyleBoxFlat.new()
	style_box.bg_color = COLORS.surface
	style_box.shadow_color = COLORS.elevation_1
	style_box.shadow_size = 2
	style_box.shadow_offset = Vector2(0, 2)
	menu_container.add_theme_stylebox_override("panel", style_box)
	
	var h_container = HBoxContainer.new()
	menu_container.add_child(h_container)
	
	# Left section
	var left_section = HBoxContainer.new()
	left_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_container.add_child(left_section)
	
	var app_name = Label.new()
	app_name.text = "GD Slate"
	app_name.add_theme_color_override("font_color", COLORS.on_surface)
	left_section.add_child(app_name)
	
	var separator = VSeparator.new()
	left_section.add_child(separator)
	
	_add_file_menu(left_section)
	_add_view_menu(left_section)
	_add_edit_menu(left_section)
	_add_ai_mode_button(left_section)
	
	# Right section - window controls
	var right_section = HBoxContainer.new()
	right_section.add_theme_constant_override("separation", 8)
	h_container.add_child(right_section)
	
	var minimize_btn = _create_window_button("─", func(): get_window().mode = Window.MODE_MINIMIZED)
	var maximize_btn = _create_window_button("□", func():
		if get_window().mode == Window.MODE_MAXIMIZED:
			get_window().mode = Window.MODE_WINDOWED
		else:
			get_window().mode = Window.MODE_MAXIMIZED
	)
	var close_btn = _create_window_button("×", func(): get_tree().quit())
	
	right_section.add_child(minimize_btn)
	right_section.add_child(maximize_btn)
	right_section.add_child(close_btn)
	
	menu_container.gui_input.connect(_on_title_bar_gui_input)
	
	return menu_container


func _create_window_button(text: String, callback: Callable) -> Button:
	var button = Button.new()
	button.text = text
	button.flat = true
	button.custom_minimum_size = Vector2(24, 24)
	button.pressed.connect(callback)
	return button


func _add_file_menu(parent: Control):
	var menu_button = MenuButton.new()
	menu_button.text = "File"
	menu_button.flat = true
	parent.add_child(menu_button)
	
	var popup = menu_button.get_popup()
	_style_popup_menu(popup)
	
	popup.add_item("New", 10)
	popup.add_item("Open Left", 0)
	popup.add_item("Open Right", 1)
	popup.add_separator()
	popup.add_item("Save", 11)
	popup.add_item("Save As...", 12)
	popup.add_separator()
	popup.add_item("Exit", 2)
	
	popup.id_pressed.connect(_on_file_menu_pressed)


func _add_view_menu(parent: Control):
	view_menu_button = MenuButton.new()
	view_menu_button.text = "View"
	view_menu_button.flat = true
	parent.add_child(view_menu_button)
	
	var popup = view_menu_button.get_popup()
	_style_popup_menu(popup)
	
	popup.add_check_item("Show Line Numbers", 0)
	popup.add_check_item("Word Wrap", 1)
	popup.add_check_item("Dark Theme", 2)
	popup.add_separator()
	popup.add_check_item("Sync Scrolling", 3)
	
	popup.set_item_checked(0, true)
	popup.set_item_checked(2, true)
	popup.set_item_checked(3, true)
	
	popup.id_pressed.connect(_on_view_menu_pressed)


func _add_edit_menu(parent: Control):
	var menu_button = MenuButton.new()
	menu_button.text = "Edit"
	menu_button.flat = true
	parent.add_child(menu_button)
	
	var popup = menu_button.get_popup()
	_style_popup_menu(popup)
	
	popup.add_item("Undo", 0)
	popup.add_item("Redo", 1)
	popup.add_separator()
	popup.add_item("Cut", 2)
	popup.add_item("Copy", 3)
	popup.add_item("Paste", 4)
	popup.add_separator()
	popup.add_item("Find", 5)
	popup.add_item("Replace", 6)


func _add_ai_mode_button(parent: Control):
	ai_mode_button = MenuButton.new()
	ai_mode_button.text = "✦"
	ai_mode_button.flat = true
	ai_mode_button.tooltip_text = "Toggle AI Analysis Mode"
	
	var font = SystemFont.new()
	font.font_names = ["Sans-serif"]
	ai_mode_button.add_theme_font_override("font", font)
	ai_mode_button.add_theme_font_size_override("font_size", 20)
	ai_mode_button.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	parent.add_child(ai_mode_button)
	
	var popup = ai_mode_button.get_popup()
	_style_popup_menu(popup)
	popup.add_item("Toggle AI Mode", 0)
	popup.add_separator()
	popup.add_item("API Key", 1)
	
	popup.id_pressed.connect(_on_ai_mode_pressed)


func _style_popup_menu(popup: PopupMenu):
	popup.add_theme_color_override("font_color", COLORS.on_surface)
	
	var popup_style = StyleBoxFlat.new()
	popup_style.bg_color = COLORS.surface
	popup_style.corner_radius_top_left = 4
	popup_style.corner_radius_top_right = 4
	popup_style.corner_radius_bottom_left = 4
	popup_style.corner_radius_bottom_right = 4
	popup_style.shadow_color = COLORS.elevation_2
	popup_style.shadow_size = 6
	popup_style.shadow_offset = Vector2(0, 4)
	popup.add_theme_stylebox_override("panel", popup_style)


func _on_title_bar_gui_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_dragging_window = event.pressed
			drag_start_position = event.global_position
	elif event is InputEventMouseMotion and is_dragging_window:
		var delta = event.global_position - drag_start_position
		drag_start_position = event.global_position
		if get_window().mode == Window.MODE_WINDOWED:
			get_window().position += Vector2i(delta)


func _on_file_menu_pressed(id: int):
	match id:
		0:
			_open_file(left_editor)
		1:
			_open_file(right_editor)
		2:
			get_tree().quit()


func _on_view_menu_pressed(id: int):
	var popup = view_menu_button.get_popup()
	
	match id:
		0:  # Show Line Numbers
			var show_lines = !popup.is_item_checked(0)
			popup.set_item_checked(0, show_lines)
			left_editor.gutters_draw_line_numbers = show_lines
			right_editor.gutters_draw_line_numbers = show_lines
		
		1:  # Word Wrap
			var wrap_enabled = !popup.is_item_checked(1)
			popup.set_item_checked(1, wrap_enabled)
			left_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if wrap_enabled else TextEdit.LINE_WRAPPING_NONE
			right_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if wrap_enabled else TextEdit.LINE_WRAPPING_NONE
		
		2:  # Dark Theme
			var dark_theme = !popup.is_item_checked(2)
			popup.set_item_checked(2, dark_theme)
			_apply_theme(dark_theme)
		
		3:  # Sync Scrolling
			sync_scroll_enabled = !popup.is_item_checked(3)
			popup.set_item_checked(3, sync_scroll_enabled)
			if sync_scroll_enabled:
				_connect_editor_signals()
			else:
				_disconnect_editor_signals()


func _on_ai_mode_pressed(id: int):
	match id:
		0:
			toggle_ai_mode()
		1:
			api_settings.popup_centered()


func _open_file(editor: CodeEdit):
	var file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Select a File"
	
	file_dialog.add_filter("*.gd ; GDScript files")
	file_dialog.add_filter("*.cs ; C# files")
	file_dialog.add_filter("*.js ; JavaScript files")
	file_dialog.add_filter("*.ts ; TypeScript files")
	file_dialog.add_filter("*.py ; Python files")
	file_dialog.add_filter("*.cpp,*.hpp,*.c,*.h ; C/C++ files")
	file_dialog.add_filter("*.txt ; Text files")
	file_dialog.add_filter("*.md ; Markdown files")
	file_dialog.add_filter("*.json ; JSON files")
	file_dialog.add_filter("*.xml ; XML files")
	file_dialog.add_filter("* ; All files")
	
	add_child(file_dialog)
	file_dialog.popup_centered(Vector2(800, 600))
	
	file_dialog.file_selected.connect(
		func(path):
			_load_file_safely(path, editor)
			file_dialog.queue_free()
	)


func _load_file_safely(file_path: String, editor: CodeEdit):
	if not FileAccess.file_exists(file_path):
		_show_error_message("File not found: " + file_path)
		return
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if not file:
		_show_error_message("Cannot open file: " + file_path + "\nCheck file permissions.")
		return
	
	var file_content = file.get_as_text()
	var error = file.get_error()
	
	if error != OK:
		_show_error_message("Error reading file: " + file_path + "\nError code: " + str(error))
		return
	
	editor.text = file_content
	
	var file_name = file_path.get_file()
	if editor == left_editor:
		left_file_name = file_name
	else:
		right_file_name = file_name
	
	call_deferred("_refresh_syntax_highlighting")
	_update_status_info()


func _show_error_message(message: String):
	var dialog = AcceptDialog.new()
	dialog.title = "Error"
	
	var label = Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog.add_child(label)
	
	add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(func(): dialog.queue_free())


# =============================================================================
# EDITOR CREATION AND SYNTAX HIGHLIGHTING
# =============================================================================

func _create_styled_editor() -> CodeEdit:
	var editor = CodeEdit.new()
	editor.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	editor.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	
	# Background style
	var editor_style = StyleBoxFlat.new()
	editor_style.bg_color = COLORS.code_background
	editor_style.corner_radius_top_left = 4
	editor_style.corner_radius_top_right = 4
	editor_style.corner_radius_bottom_left = 4
	editor_style.corner_radius_bottom_right = 4
	editor_style.content_margin_left = 8
	editor_style.content_margin_right = 8
	editor_style.content_margin_top = 8
	editor_style.content_margin_bottom = 8
	editor.add_theme_stylebox_override("normal", editor_style)
	
	# Text colors
	editor.add_theme_color_override("font_color", COLORS.code_text)
	editor.add_theme_color_override("font_selected_color", COLORS.code_text)
	editor.add_theme_color_override("caret_color", COLORS.code_text)
	editor.add_theme_color_override("selection_color", Color(0.2, 0.4, 0.8, 0.3))
	editor.add_theme_color_override("line_number_color", Color(1.0, 1.0, 1.0, 0.5))
	editor.add_theme_color_override("current_line_color", Color(1.0, 1.0, 1.0, 0.05))
	
	# Editor settings
	editor.gutters_draw_line_numbers = true
	editor.minimap_draw = false
	editor.highlight_current_line = true
	editor.add_theme_constant_override("line_spacing", 4)
	
	return editor


func _refresh_syntax_highlighting() -> void:
	var is_dark = true
	if is_instance_valid(view_menu_button):
		is_dark = view_menu_button.get_popup().is_item_checked(2)
	
	# Create highlighters with setup() instead of constructor params
	if not left_highlighter:
		left_highlighter = GDScriptHighlighter.new()
		left_highlighter.setup(is_dark)
	else:
		left_highlighter.set_dark_mode(is_dark)
	
	if not right_highlighter:
		right_highlighter = GDScriptHighlighter.new()
		right_highlighter.setup(is_dark)
	else:
		right_highlighter.set_dark_mode(is_dark)
	
	# Apply to editors
	left_editor.syntax_highlighter = left_highlighter
	right_editor.syntax_highlighter = right_highlighter
	
	# Update background colors
	var bg_color = COLORS.code_background if is_dark else Color("#ffffff")
	var text_color = COLORS.code_text if is_dark else Color("#24292e")
	
	for editor in [left_editor, right_editor]:
		var style = editor.get_theme_stylebox("normal").duplicate()
		style.bg_color = bg_color
		editor.add_theme_stylebox_override("normal", style)
		editor.add_theme_color_override("font_color", text_color)
		editor.add_theme_color_override("caret_color", text_color)
		editor.add_theme_color_override("line_number_color", Color(text_color.r, text_color.g, text_color.b, 0.5))
		editor.queue_redraw()

func _apply_theme(dark_theme: bool):
	_refresh_syntax_highlighting()


# =============================================================================
# AI MODE
# =============================================================================

func toggle_ai_mode():
	_cleanup_resources()
	
	ai_mode_active = !ai_mode_active
	current_mode = EditorMode.AI if ai_mode_active else EditorMode.COMPARE
	ai_state = AIState.WAITING_FOR_INPUT if ai_mode_active else AIState.IDLE
	
	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	
	if ai_mode_active:
		_transition_to_ai_mode(tween)
		_configure_editors_for_ai_mode()
	else:
		_transition_to_normal_mode(tween)
		_configure_editors_for_compare_mode()
	
	_update_status_info()
	
	if is_instance_valid(ai_mode_button):
		ai_mode_button.add_theme_color_override(
			"font_color",
			COLORS.ai_mode_accent if ai_mode_active else COLORS.on_surface
		)


func _configure_editors_for_ai_mode():
	right_editor.placeholder_text = "# Enter your code and questions here...\n# Press Enter to submit, Shift+Enter for new line"
	right_editor.editable = true
	left_editor.editable = false
	
	_update_editor_labels("AI Output", "Code Input")
	_disconnect_editor_signals()


func _configure_editors_for_compare_mode():
	right_editor.placeholder_text = ""
	right_editor.editable = true
	left_editor.editable = true
	
	_update_editor_labels("Left Editor", "Right Editor")
	
	if sync_scroll_enabled:
		_connect_editor_signals()


func _transition_to_ai_mode(tween: Tween):
	for editor in [left_editor, right_editor]:
		var style = editor.get_theme_stylebox("normal").duplicate()
		tween.parallel().tween_method(
			func(color):
				style.bg_color = color
				editor.add_theme_stylebox_override("normal", style),
			style.bg_color,
			COLORS.ai_mode_background,
			0.5
		)
	
	var menu_container = root_container.get_child(0)
	var menu_style = menu_container.get_theme_stylebox("panel").duplicate()
	tween.parallel().tween_method(
		func(color):
			menu_style.bg_color = color
			menu_container.add_theme_stylebox_override("panel", menu_style),
		menu_style.bg_color,
		COLORS.ai_mode_surface,
		0.5
	)
	
	for menu_button in _get_all_menu_buttons():
		var popup = menu_button.get_popup()
		var popup_style = popup.get_theme_stylebox("panel").duplicate()
		tween.parallel().tween_method(
			func(color):
				popup_style.bg_color = color
				popup.add_theme_stylebox_override("panel", popup_style),
			popup_style.bg_color,
			COLORS.ai_mode_surface,
			0.5
		)
		popup.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	if search_container:
		var search_style = search_container.get_theme_stylebox("panel").duplicate()
		tween.parallel().tween_method(
			func(color):
				search_style.bg_color = color
				search_container.add_theme_stylebox_override("panel", search_style),
			search_style.bg_color,
			COLORS.ai_mode_surface,
			0.5
		)
		
		var search_input_style = search_bar.get_theme_stylebox("normal").duplicate()
		tween.parallel().tween_method(
			func(color):
				search_input_style.bg_color = color
				search_bar.add_theme_stylebox_override("normal", search_input_style),
			search_input_style.bg_color,
			COLORS.ai_mode_background,
			0.5
		)
		search_bar.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	if status_bar:
		var status_style = status_bar.get_theme_stylebox("panel").duplicate()
		tween.parallel().tween_method(
			func(color):
				status_style.bg_color = color
				status_bar.add_theme_stylebox_override("panel", status_style),
			status_style.bg_color,
			COLORS.ai_mode_surface.darkened(0.1),
			0.5
		)
		
		if stats_label:
			stats_label.add_theme_color_override("font_color", COLORS.ai_mode_accent)
		if file_info:
			file_info.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	ai_mode_button.add_theme_color_override("font_color", COLORS.ai_mode_accent)


func _transition_to_normal_mode(tween: Tween):
	for editor in [left_editor, right_editor]:
		var style = editor.get_theme_stylebox("normal").duplicate()
		tween.parallel().tween_method(
			func(color):
				style.bg_color = color
				editor.add_theme_stylebox_override("normal", style),
			style.bg_color,
			COLORS.code_background,
			0.5
		)
	
	var menu_container = root_container.get_child(0)
	var menu_style = menu_container.get_theme_stylebox("panel").duplicate()
	tween.parallel().tween_method(
		func(color):
			menu_style.bg_color = color
			menu_container.add_theme_stylebox_override("panel", menu_style),
		menu_style.bg_color,
		COLORS.surface,
		0.5
	)
	
	for menu_button in _get_all_menu_buttons():
		var popup = menu_button.get_popup()
		var popup_style = popup.get_theme_stylebox("panel").duplicate()
		tween.parallel().tween_method(
			func(color):
				popup_style.bg_color = color
				popup.add_theme_stylebox_override("panel", popup_style),
			popup_style.bg_color,
			COLORS.surface,
			0.5
		)
		popup.add_theme_color_override("font_color", COLORS.on_surface)
	
	if search_container:
		var search_style = search_container.get_theme_stylebox("panel").duplicate()
		tween.parallel().tween_method(
			func(color):
				search_style.bg_color = color
				search_container.add_theme_stylebox_override("panel", search_style),
			search_style.bg_color,
			COLORS.surface,
			0.5
		)
		
		var search_input_style = search_bar.get_theme_stylebox("normal").duplicate()
		tween.parallel().tween_method(
			func(color):
				search_input_style.bg_color = color
				search_bar.add_theme_stylebox_override("normal", search_input_style),
			search_input_style.bg_color,
			COLORS.code_background,
			0.5
		)
		search_bar.add_theme_color_override("font_color", COLORS.code_text)
	
	if status_bar:
		var status_style = status_bar.get_theme_stylebox("panel").duplicate()
		tween.parallel().tween_method(
			func(color):
				status_style.bg_color = color
				status_bar.add_theme_stylebox_override("panel", status_style),
			status_style.bg_color,
			COLORS.surface.darkened(0.1),
			0.5
		)
		
		if stats_label:
			stats_label.add_theme_color_override("font_color", COLORS.on_surface)
		if file_info:
			file_info.add_theme_color_override("font_color", COLORS.on_surface)
	
	ai_mode_button.add_theme_color_override("font_color", COLORS.on_surface)


func _get_all_menu_buttons() -> Array:
	var menu_buttons = []
	var menu_container = _get_menu_container()
	if menu_container:
		_find_menu_buttons_recursive(menu_container, menu_buttons)
	return menu_buttons


func _find_menu_buttons_recursive(node: Node, buttons: Array) -> void:
	if node is MenuButton:
		buttons.append(node)
	for child in node.get_children():
		_find_menu_buttons_recursive(child, buttons)


func _get_menu_container() -> PanelContainer:
	if not root_container or root_container.get_child_count() == 0:
		return null
	
	var first_child = root_container.get_child(0)
	if first_child is PanelContainer:
		return first_child
	return null


# =============================================================================
# SEARCH FUNCTIONALITY
# =============================================================================

func _setup_search_bar():
	search_container = PanelContainer.new()
	search_container.name = "SearchContainer"
	search_container.set_anchors_preset(Control.PRESET_TOP_WIDE)
	search_container.position.y = -50
	search_container.custom_minimum_size.y = 50
	
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = COLORS.surface
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.shadow_color = COLORS.elevation_2
	panel_style.shadow_size = 4
	panel_style.shadow_offset = Vector2(0, 2)
	search_container.add_theme_stylebox_override("panel", panel_style)
	
	var main_container = root_container.get_node("MainContainer")
	main_container.add_child(search_container)
	
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	search_container.add_child(margin)
	
	var h_box = HBoxContainer.new()
	h_box.add_theme_constant_override("separation", 8)
	margin.add_child(h_box)
	
	search_bar = LineEdit.new()
	search_bar.placeholder_text = "Search text..."
	search_bar.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	
	var search_style = StyleBoxFlat.new()
	search_style.bg_color = COLORS.code_background
	search_style.corner_radius_top_left = 4
	search_style.corner_radius_top_right = 4
	search_style.corner_radius_bottom_left = 4
	search_style.corner_radius_bottom_right = 4
	search_style.content_margin_left = 8
	search_style.content_margin_right = 8
	search_bar.add_theme_stylebox_override("normal", search_style)
	search_bar.add_theme_color_override("font_color", COLORS.code_text)
	
	search_bar.text_changed.connect(_on_search_text_changed)
	search_bar.text_submitted.connect(_on_search_submitted)
	h_box.add_child(search_bar)
	
	match_label = Label.new()
	match_label.name = "MatchLabel"
	match_label.text = "No matches"
	match_label.add_theme_color_override("font_color", COLORS.on_surface)
	match_label.custom_minimum_size.x = 100
	h_box.add_child(match_label)
	
	var prev_button = Button.new()
	prev_button.text = "◀"
	prev_button.tooltip_text = "Previous match (Shift+Enter)"
	prev_button.custom_minimum_size.x = 40
	prev_button.pressed.connect(_find_previous)
	h_box.add_child(prev_button)
	
	var next_button = Button.new()
	next_button.text = "▶"
	next_button.tooltip_text = "Next match (Enter)"
	next_button.custom_minimum_size.x = 40
	next_button.pressed.connect(_find_next)
	h_box.add_child(next_button)
	
	var close_button = Button.new()
	close_button.text = "×"
	close_button.tooltip_text = "Close search (Esc)"
	close_button.custom_minimum_size = Vector2(24, 24)
	close_button.pressed.connect(_toggle_search)
	h_box.add_child(close_button)
	
	search_container.hide()


func _toggle_search():
	if search_container.visible:
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.parallel().tween_property(search_container, "position:y", -50, 0.3)
		tween.parallel().tween_property(search_container, "modulate:a", 0.0, 0.3)
		await tween.finished
		search_container.visible = false
		if active_editor:
			active_editor.grab_focus()
	else:
		search_container.visible = true
		search_container.modulate.a = 0.0
		search_container.position.y = -50
		
		if left_editor.has_focus():
			active_editor = left_editor
		elif right_editor.has_focus():
			active_editor = right_editor
		else:
			active_editor = left_editor
		
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.parallel().tween_property(search_container, "position:y", 0, 0.3)
		tween.parallel().tween_property(search_container, "modulate:a", 1.0, 0.3)
		
		search_bar.clear()
		search_bar.grab_focus()


func _on_search_text_changed(new_text: String):
	if not active_editor:
		return
	
	_clear_search_highlights()
	search_results.clear()
	current_search_index = -1
	
	if new_text.is_empty():
		_update_match_count()
		return
	
	var text = active_editor.text
	var position = 0
	
	while true:
		position = text.find(new_text, position)
		if position == -1:
			break
		search_results.append(position)
		position += 1
	
	if not search_results.is_empty():
		current_search_index = 0
		_highlight_current_result()
	
	_update_match_count()


func _find_next():
	if search_results.is_empty():
		return
	current_search_index = (current_search_index + 1) % search_results.size()
	_highlight_current_result()


func _find_previous():
	if search_results.is_empty():
		return
	current_search_index = (current_search_index - 1 + search_results.size()) % search_results.size()
	_highlight_current_result()


func _highlight_current_result():
	if not active_editor or current_search_index < 0:
		return
	
	var position = search_results[current_search_index]
	var search_text = search_bar.text
	
	var line = 0
	var current_pos = 0
	var text = active_editor.text
	
	while current_pos < position:
		var newline_pos = text.find("\n", current_pos)
		if newline_pos == -1 or newline_pos >= position:
			break
		line += 1
		current_pos = newline_pos + 1
	
	var column = position - current_pos
	
	active_editor.set_caret_line(line)
	active_editor.set_caret_column(column)
	active_editor.select(line, column, line, column + search_text.length())
	
	_update_match_count()


func _on_search_submitted(_text: String):
	_find_next()


func _clear_search_highlights():
	if active_editor:
		active_editor.select(0, 0, 0, 0)


func _update_match_count():
	if match_label:
		if search_results.is_empty():
			match_label.text = "No matches"
		else:
			match_label.text = "%d/%d matches" % [current_search_index + 1, search_results.size()]


# =============================================================================
# SYSTEM PROMPT
# =============================================================================

func _setup_system_prompt_shortcut():
	if InputMap.has_action("toggle_system_prompt"):
		InputMap.erase_action("toggle_system_prompt")
	
	InputMap.add_action("toggle_system_prompt")
	var prompt_event = InputEventKey.new()
	prompt_event.keycode = SYSTEM_PROMPT_SHORTCUT_KEY
	prompt_event.ctrl_pressed = true
	prompt_event.alt_pressed = true
	InputMap.action_add_event("toggle_system_prompt", prompt_event)


func _setup_system_prompt_panel():
	system_prompt_container = PanelContainer.new()
	system_prompt_container.name = "SystemPromptContainer"
	system_prompt_container.set_anchors_preset(Control.PRESET_TOP_WIDE)
	system_prompt_container.position.y = -300
	system_prompt_container.custom_minimum_size.y = 300
	
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = COLORS.surface
	panel_style.corner_radius_bottom_left = 12
	panel_style.corner_radius_bottom_right = 12
	panel_style.shadow_color = COLORS.elevation_2
	panel_style.shadow_size = 8
	panel_style.shadow_offset = Vector2(0, 4)
	system_prompt_container.add_theme_stylebox_override("panel", panel_style)
	
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	system_prompt_container.add_child(margin)
	
	var v_box = VBoxContainer.new()
	v_box.add_theme_constant_override("separation", 12)
	margin.add_child(v_box)
	
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	v_box.add_child(header)
	
	var title = Label.new()
	title.text = "System Prompt"
	title.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	title.add_theme_font_size_override("font_size", 18)
	header.add_child(title)
	
	var spacer = Control.new()
	spacer.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	header.add_child(spacer)
	
	var save_button = Button.new()
	save_button.text = "Save"
	save_button.custom_minimum_size.x = 80
	save_button.pressed.connect(_save_system_prompt)
	header.add_child(save_button)
	
	var close_button = Button.new()
	close_button.text = "×"
	close_button.custom_minimum_size = Vector2(24, 24)
	close_button.pressed.connect(_toggle_system_prompt)
	header.add_child(close_button)
	
	system_prompt_editor = TextEdit.new()
	system_prompt_editor.text = default_system_prompt
	system_prompt_editor.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	system_prompt_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	
	var editor_style = StyleBoxFlat.new()
	editor_style.bg_color = COLORS.code_background
	editor_style.corner_radius_top_left = 4
	editor_style.corner_radius_top_right = 4
	editor_style.corner_radius_bottom_left = 4
	editor_style.corner_radius_bottom_right = 4
	editor_style.content_margin_left = 8
	editor_style.content_margin_right = 8
	editor_style.content_margin_top = 8
	editor_style.content_margin_bottom = 8
	
	system_prompt_editor.add_theme_stylebox_override("normal", editor_style)
	system_prompt_editor.add_theme_color_override("font_color", COLORS.code_text)
	v_box.add_child(system_prompt_editor)
	
	root_container.add_child(system_prompt_container)
	system_prompt_container.hide()


func _toggle_system_prompt():
	if system_prompt_container.visible:
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.parallel().tween_property(system_prompt_container, "position:y", -300, 0.3)
		tween.parallel().tween_property(system_prompt_container, "modulate:a", 0.0, 0.3)
		await tween.finished
		system_prompt_container.hide()
		if active_editor:
			active_editor.grab_focus()
	else:
		system_prompt_container.show()
		system_prompt_container.modulate.a = 0.0
		system_prompt_container.position.y = -300
		
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		tween.parallel().tween_property(system_prompt_container, "position:y", 0, 0.3)
		tween.parallel().tween_property(system_prompt_container, "modulate:a", 1.0, 0.3)
		
		system_prompt_editor.grab_focus()


func _save_system_prompt():
	_toggle_system_prompt()


func _on_api_key_saved(new_key: String) -> void:
	api_key = new_key
	request_manager.set_api_key(new_key)
	
	if ai_state == AIState.ERROR:
		ai_state = AIState.WAITING_FOR_INPUT
		var indicator = left_editor.get_node_or_null("ProcessingIndicator")
		if indicator:
			indicator.queue_free()


# =============================================================================
# AI REQUEST HANDLING
# =============================================================================

func _handle_editor_input(event: InputEvent) -> void:
	if current_mode != EditorMode.AI:
		return
	
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER:
			if event.shift_pressed:
				_handle_shift_enter()
			else:
				_submit_ai_prompt()
			get_viewport().set_input_as_handled()


func _handle_shift_enter() -> void:
	if not is_instance_valid(right_editor):
		return
	
	var current_line = right_editor.get_caret_line()
	var current_column = right_editor.get_caret_column()
	var line_text = right_editor.get_line(current_line)
	
	var text_before = line_text.substr(0, current_column)
	var text_after = line_text.substr(current_column)
	
	var indentation = ""
	var i = 0
	while i < text_before.length() and text_before[i] == "\t":
		indentation += "\t"
		i += 1
	
	right_editor.begin_complex_operation()
	right_editor.set_line(current_line, text_before)
	right_editor.insert_text_at_caret("\n" + indentation + text_after)
	right_editor.end_complex_operation()
	
	right_editor.set_caret_line(current_line + 1)
	right_editor.set_caret_column(indentation.length())


func _submit_ai_prompt() -> void:
	if ai_state == AIState.PROCESSING or ai_state == AIState.STREAMING:
		return
	if right_editor.text.strip_edges().is_empty():
		return
	
	if api_key.is_empty():
		_show_api_key_dialog()
		return
	
	ai_state = AIState.PROCESSING
	left_editor.text = ""
	
	error_handler.log_debug("Submitting AI prompt", {
		"text_length": str(right_editor.text.length())
	})
	
	_show_processing_indicator()
	prompt_history.append(right_editor.text)
	request_manager.queue_request(right_editor.text, system_prompt_editor.text)


func _show_processing_indicator() -> void:
	var existing_indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if existing_indicator:
		existing_indicator.queue_free()
	
	var container = HBoxContainer.new()
	container.name = "ProcessingIndicator"
	container.position = Vector2(10, 10)
	container.custom_minimum_size = Vector2(0, 30)
	
	var spinner_label = Label.new()
	spinner_label.text = "⟳"
	spinner_label.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(10, 0)
	
	var loading_label = Label.new()
	loading_label.text = "Processing..."
	loading_label.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	container.add_child(spinner_label)
	container.add_child(spacer)
	container.add_child(loading_label)
	
	left_editor.add_child(container)
	
	var tween = create_tween()
	tween.set_loops()
	tween.tween_property(spinner_label, "rotation", TAU, 1.0)


func _on_request_completed(response: String) -> void:
	if ai_state == AIState.PROCESSING:
		ai_state = AIState.STREAMING
		var indicator = left_editor.get_node_or_null("ProcessingIndicator")
		if indicator:
			indicator.hide()
	
	left_editor.text += response
	left_editor.set_caret_line(left_editor.get_line_count() - 1)
	left_editor.set_caret_column(left_editor.get_line(left_editor.get_line_count() - 1).length())
	left_editor.queue_redraw()


func _on_request_error(error_message: String) -> void:
	ai_state = AIState.ERROR
	
	var user_friendly_message = error_message
	
	if "api" in error_message.to_lower() and "key" in error_message.to_lower():
		user_friendly_message = """# API Key Issue
# Your API key may be missing or invalid.
# Click the ✦ button in the menu bar, then select "API Key" to update it.
# 
# Original error: """ + error_message
	elif "rate" in error_message.to_lower() and "limit" in error_message.to_lower():
		user_friendly_message = """# Rate Limit Reached
# You've made too many requests too quickly.
# Please wait a moment before trying again.
# 
# Original error: """ + error_message
	elif "network" in error_message.to_lower():
		user_friendly_message = """# Network Error
# Please check your internet connection and try again.
# 
# Original error: """ + error_message
	else:
		user_friendly_message = "# Error: " + error_message
	
	left_editor.text = user_friendly_message
	
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.queue_free()


func _stream_next_chunk() -> void:
	# Placeholder for streaming implementation
	pass


func _on_stream_complete() -> void:
	ai_state = AIState.IDLE
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.queue_free()


func _show_api_key_dialog() -> void:
	if not api_settings:
		return
	if api_settings.visible:
		return
	api_settings.popup_centered()
	api_settings.grab_focus()


# =============================================================================
# DIFF COMPARISON
# =============================================================================

func _on_text_changed() -> void:
	if current_mode == EditorMode.COMPARE:
		_highlight_differences()


func _highlight_differences():
	var left_lines = left_editor.text.split("\n")
	var right_lines = right_editor.text.split("\n")
	
	var deletion_color = Color(1, 0.8, 0.8, 0.3)
	var addition_color = Color(0.8, 1, 0.8, 0.3)
	var modification_color = Color(0.95, 0.95, 0.8, 0.3)
	
	for i in range(left_editor.get_line_count()):
		left_editor.set_line_background_color(i, Color.TRANSPARENT)
	for i in range(right_editor.get_line_count()):
		right_editor.set_line_background_color(i, Color.TRANSPARENT)
	
	var max_lines = max(left_lines.size(), right_lines.size())
	
	for i in range(max_lines):
		var left_line = left_lines[i] if i < left_lines.size() else ""
		var right_line = right_lines[i] if i < right_lines.size() else ""
		
		if left_line != right_line:
			if i < left_lines.size() and i < right_lines.size():
				left_editor.set_line_background_color(i, modification_color)
				right_editor.set_line_background_color(i, modification_color)
			elif i < left_lines.size():
				left_editor.set_line_background_color(i, deletion_color)
			else:
				right_editor.set_line_background_color(i, addition_color)
	
	var stats = _count_differences()
	_update_status_bar(stats)


func _count_differences() -> Dictionary:
	var left_lines = left_editor.text.split("\n")
	var right_lines = right_editor.text.split("\n")
	
	var stats = {
		"modifications": 0,
		"additions": 0,
		"deletions": 0,
		"total": 0
	}
	
	var max_lines = max(left_lines.size(), right_lines.size())
	
	for i in range(max_lines):
		var left_line = left_lines[i] if i < left_lines.size() else ""
		var right_line = right_lines[i] if i < right_lines.size() else ""
		
		if left_line != right_line:
			if i < left_lines.size() and i < right_lines.size():
				stats.modifications += 1
			elif i < left_lines.size():
				stats.deletions += 1
			else:
				stats.additions += 1
	
	stats.total = stats.modifications + stats.additions + stats.deletions
	return stats


# =============================================================================
# STATUS BAR
# =============================================================================

func _create_status_bar() -> void:
	var existing_status_bar = root_container.get_node_or_null("StatusBar")
	if existing_status_bar:
		existing_status_bar.queue_free()
	
	status_bar = PanelContainer.new()
	status_bar.name = "StatusBar"
	status_bar.set_h_size_flags(Control.SIZE_FILL)
	status_bar.custom_minimum_size.y = 24
	
	var style = StyleBoxFlat.new()
	style.bg_color = COLORS.surface.darkened(0.1)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	status_bar.add_theme_stylebox_override("panel", style)
	
	var h_box = HBoxContainer.new()
	h_box.set_h_size_flags(Control.SIZE_FILL)
	h_box.set_v_size_flags(Control.SIZE_FILL)
	status_bar.add_child(h_box)
	
	mode_indicator = Label.new()
	mode_indicator.name = "ModeIndicator"
	mode_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	mode_indicator.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mode_indicator.add_theme_font_size_override("font_size", 12)
	mode_indicator.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	mode_indicator.text = "○ Compare Mode"
	h_box.add_child(mode_indicator)
	
	var separator1 = VSeparator.new()
	separator1.custom_minimum_size.x = 8
	h_box.add_child(separator1)
	
	stats_label = Label.new()
	stats_label.name = "StatsLabel"
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	stats_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stats_label.add_theme_font_size_override("font_size", 12)
	stats_label.text = "No diffs"
	h_box.add_child(stats_label)
	
	var spacer = Control.new()
	spacer.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	h_box.add_child(spacer)
	
	file_info = Label.new()
	file_info.name = "FileInfo"
	file_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	file_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	file_info.add_theme_font_size_override("font_size", 12)
	file_info.text = "No file | No file"
	h_box.add_child(file_info)
	
	if root_container and is_instance_valid(root_container):
		root_container.add_child(status_bar)
		root_container.move_child(status_bar, root_container.get_child_count() - 1)
		_update_status_info()


func _update_status_info() -> void:
	if not is_instance_valid(status_bar) or not is_instance_valid(mode_indicator) or \
	   not is_instance_valid(stats_label) or not is_instance_valid(file_info):
		return
	
	var mode_text = "● AI Mode" if ai_mode_active else "○ Compare Mode"
	mode_indicator.text = mode_text
	mode_indicator.add_theme_color_override(
		"font_color",
		COLORS.ai_mode_accent if ai_mode_active else COLORS.on_surface
	)
	
	file_info.text = "%s | %s" % [left_file_name, right_file_name]
	
	mode_indicator.show()
	stats_label.show()
	file_info.show()


func _update_status_bar(stats: Dictionary):
	if not stats_label:
		return
	
	if stats.total > 0:
		stats_label.text = str(stats.total) + " diff" + ("s" if stats.total != 1 else "")
	else:
		stats_label.text = "No diffs"


func _update_editor_labels(left_label: String, right_label: String):
	var left_header = left_editor.get_node_or_null("Header")
	var right_header = right_editor.get_node_or_null("Header")
	
	if not left_header:
		left_header = Label.new()
		left_header.name = "Header"
		left_header.add_theme_font_size_override("font_size", 14)
		left_editor.add_child(left_header)
		left_header.position = Vector2(10, -25)
	
	if not right_header:
		right_header = Label.new()
		right_header.name = "Header"
		right_header.add_theme_font_size_override("font_size", 14)
		right_editor.add_child(right_header)
		right_header.position = Vector2(10, -25)
	
	left_header.text = left_label
	right_header.text = right_label


# =============================================================================
# CLEANUP
# =============================================================================

func _cleanup_resources():
	if streaming_timer and is_instance_valid(streaming_timer):
		streaming_timer.stop()
	
	if request_manager and is_instance_valid(request_manager):
		request_manager._current_request.clear()
	
	for editor in [left_editor, right_editor]:
		if is_instance_valid(editor):
			var indicator = editor.get_node_or_null("ProcessingIndicator")
			if indicator:
				indicator.queue_free()
	
	ai_state = AIState.IDLE
