# Main.gd
extends Control
class_name AICodeEditor

# Add HTTPRequest node for API calls
var http_request: HTTPRequest

# Configuration for API
const API_URL = "https://api.anthropic.com/v1/messages"
const API_VERSION = "2023-06-01"

var api_key: String

var request_manager: AIRequestManager
var error_handler: AIErrorHandler


var system_prompt_container: PanelContainer
var system_prompt_editor: TextEdit
var default_system_prompt = """You are an AI that analyzes and edits Godot 4.x .gd files. The text you receive as prompts is the exact text as the .gd file to be edited. Expect questions and instructions to be embedded inside these scripts as commented out text.
Your response to these prompts is the edited version of these .gd files. If you need to explain or instruct, you are to type in commented out lines inside the script. You NEVER have a Beginning Part or Header before the script. 
You NEVER explain yourself after the script as a post-script explanation. Every aspect of your response is inside (embedded if you will) the script as commented out lines. You are ALWAYS under the assumption, no, the ASSURANCE, that your output reply text will LITERALLY be the contents of the file if saved. 
So any preamble or post script, if stupidly written, would throw errors in Godot 4."""

var is_processing_ai: bool = false
var prompt_history: Array = []
var current_ai_request_id: String = ""

# Let's add an enum to track our editor states
enum EditorMode {
	COMPARE,  # Normal comparison mode
	AI        # AI analysis mode
}

var current_mode: EditorMode = EditorMode.COMPARE

var left_editor: CodeEdit
var right_editor: CodeEdit
var splitter: HSplitContainer
var is_dragging_window = false
var drag_start_position = Vector2()
var sync_scroll_enabled = false
var search_bar: LineEdit
var search_container: PanelContainer
var current_search_index = -1
var search_results = []
var active_editor: CodeEdit = null
var view_menu_button: MenuButton
var root_container: VBoxContainer 
var ai_mode_active: bool = false
var ai_mode_button: MenuButton
var original_background_color: Color
var ai_background_color: Color = Color("2A1B3D")  # Deep purple for AI mode
var is_shift_pressed: bool = false  # To handle Shift+Enter for new lines
var is_streaming_response: bool = false
var current_streaming_text: String = ""
var streaming_timer: Timer
var is_streaming: bool = false
var stream_delay: float = 0.03 # 30ms between characters
var stream_timer: Timer
var mode_indicator: Label
var file_info: Label
var stats_label: Label
var status_bar: PanelContainer
var left_file_name: String = "No file"
var right_file_name: String = "No file"
var match_label: Label
var api_settings: APISettings
var text_animator: JuicyTextAnimator
var typing_speed: float = 0.002  # Seconds per character
var current_typing_text: String = ""
var is_typing: bool = false
var _left_scroll_callable: Callable
var _right_scroll_callable: Callable

# Material Design color palette
const COLORS = {
	"primary": Color("#699ce8"),        # Blue 500 2196f3
	"primary_dark": Color("#699ce8"),   # Blue 700 1976d2
	"surface": Color("#333b4f"),        # Surface color 1e2b2f
	"background": Color("#fafafa"),     # Background color
	"on_surface": Color("#699ce8"),     # Text on surface
	"on_surface_medium": Color("#00000099"),  # Medium emphasis text
	"on_primary": Color("#ffffff"),     # Text on primary color
	"elevation_1": Color("#00000014"),  # 8% shadow
	"elevation_2": Color("#0000001f"),  # 12% shadow
	"code_background": Color("#333b4f"), # Code editor background 333b4f 263238
	"code_text": Color("#ffffff"),      # Code editor text
	"ai_mode_background": Color("#2A1B3D"),  # Deep purple for AI mode
	"ai_mode_surface": Color("#352641"),     # Lighter purple for surfaces in AI mode
	"ai_mode_accent": Color("#B4A0E5")       # Light purple for accents
}
const SEARCH_SHORTCUT_KEY = KEY_F
const SYSTEM_PROMPT_SHORTCUT_KEY = KEY_P
const API_KEY_SHORTCUT_KEY = KEY_R



func _ready():
	# 1. Core systems first
	error_handler = AIErrorHandler.new()
	add_child(error_handler)
	
	request_manager = AIRequestManager.new()
	add_child(request_manager)
	request_manager.setup(error_handler)
	request_manager.request_completed.connect(_on_request_completed)
	request_manager.error_occurred.connect(_on_request_error)
	
	# 2. API settings (invisible, but needed early)
	api_settings = APISettings.new()
	api_settings.api_key_saved.connect(_on_api_key_saved)
	add_child(api_settings)
	api_settings.hide()
	api_key = api_settings.get_api_key()
	request_manager.set_api_key(api_key)
	
	# 3. UI structure
	_setup_root_container()
	self.theme = _create_material_theme()
	
	var menu_container := _create_unified_menu_bar()
	root_container.add_child(menu_container)
	
	var main_container := HSplitContainer.new()
	main_container.name = "MainContainer"
	main_container.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	main_container.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	main_container.add_theme_constant_override("separation", 16)
	root_container.add_child(main_container)
	
	# 4. Editors
	left_editor = _create_styled_editor()
	right_editor = _create_styled_editor()
	main_container.add_child(left_editor)
	main_container.add_child(right_editor)
	
	# 5. Editor features (after editors exist)
	_setup_editor_features()
	_setup_search_bar()
	_setup_system_prompt_panel()
	
	# 6. Input handling
	_setup_input_shortcuts()
	_setup_system_prompt_shortcut()
	
	# 7. Timers
	streaming_timer = Timer.new()
	streaming_timer.one_shot = false
	streaming_timer.wait_time = 0.05
	streaming_timer.timeout.connect(_stream_next_chunk)
	add_child(streaming_timer)
	
	# 8. Final editor signal connections
	right_editor.gui_input.connect(_handle_editor_input)
	left_editor.text_changed.connect(_on_text_changed)
	right_editor.text_changed.connect(_on_text_changed)
	
	# 9. Deferred setup (needs full scene tree)
	call_deferred("_create_status_bar")
	call_deferred("_refresh_syntax_highlighting")
	
# Comment out until we implement animated streaming
# text_animator = JuicyTextAnimator.new(left_editor)
# add_child(text_animator)


func _setup_root_container():
	if has_node("RootContainer"):
		root_container = get_node("RootContainer")
	else:
		root_container = VBoxContainer.new()
		root_container.name = "RootContainer"
		root_container.set_anchors_preset(Control.PRESET_FULL_RECT)
		root_container.set_h_size_flags(Control.SIZE_FILL)
		root_container.set_v_size_flags(Control.SIZE_FILL)
		root_container.set_clip_contents(true)
		add_child(root_container)

func _setup_editor_features():
	# Initialize the active editor
	active_editor = left_editor
	
	# Set up scroll synchronization
	sync_scroll_enabled = true
	_connect_editor_signals()
	
	# Connect focus signals
	left_editor.focus_entered.connect(_on_editor_focus_entered.bind(left_editor))
	right_editor.focus_entered.connect(_on_editor_focus_entered.bind(right_editor))



func _connect_editor_signals():
	# Create and store the bound callables
	_left_scroll_callable = _on_editor_scroll.bind(left_editor)
	_right_scroll_callable = _on_editor_scroll.bind(right_editor)
	
	var left_scroll := left_editor.get_v_scroll_bar()
	var right_scroll := right_editor.get_v_scroll_bar()
	
	if not left_scroll.value_changed.is_connected(_left_scroll_callable):
		left_scroll.value_changed.connect(_left_scroll_callable)
	if not right_scroll.value_changed.is_connected(_right_scroll_callable):
		right_scroll.value_changed.connect(_right_scroll_callable)

func _disconnect_editor_signals():
	var left_scroll := left_editor.get_v_scroll_bar()
	var right_scroll := right_editor.get_v_scroll_bar()
	
	if _left_scroll_callable.is_valid() and left_scroll.value_changed.is_connected(_left_scroll_callable):
		left_scroll.value_changed.disconnect(_left_scroll_callable)
	if _right_scroll_callable.is_valid() and right_scroll.value_changed.is_connected(_right_scroll_callable):
		right_scroll.value_changed.disconnect(_right_scroll_callable)



func _on_editor_scroll(value: float, source_editor: CodeEdit):
	if not sync_scroll_enabled:
		return
	
	var target_editor = right_editor if source_editor == left_editor else left_editor
	target_editor.get_v_scroll_bar().value = value



func _on_editor_focus_entered(editor: CodeEdit):
	active_editor = editor



func _ensure_visible_lines_match():
	if not sync_scroll_enabled or not active_editor:
		return
	
	var target_editor = right_editor if active_editor == left_editor else left_editor
	var visible_lines = active_editor.get_visible_line_count()
	target_editor.set_v_scroll(active_editor.get_v_scroll())



func _setup_input_shortcuts():
	# Remove any existing shortcuts to prevent duplicates
	if InputMap.has_action("toggle_search"):
		InputMap.erase_action("toggle_search")
	
	# Create the search shortcut
	InputMap.add_action("toggle_search")
	
	# Create and configure the keyboard event
	var search_event = InputEventKey.new()
	search_event.keycode = SEARCH_SHORTCUT_KEY
	search_event.ctrl_pressed = true
	
	# Add the event to our action
	InputMap.action_add_event("toggle_search", search_event)



func _unhandled_input(event):
	if event.is_action_pressed("toggle_search"):
		print("Search shortcut detected")
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
	
	# System prompt toggle
	if event.is_action_pressed("toggle_system_prompt"):
		_toggle_system_prompt()
		get_viewport().set_input_as_handled()
	
	# API settings shortcut
	if event is InputEventKey and event.pressed and event.keycode == KEY_R and event.ctrl_pressed:
		api_settings.popup_centered()
		get_viewport().set_input_as_handled()
	
	# DIRECT KEYBOARD HANDLING - no InputMap needed
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
		
		# Open file in active editor (Ctrl+O)
		elif event.keycode == KEY_O and event.ctrl_pressed:
			if active_editor:
				_open_file(active_editor)
			get_viewport().set_input_as_handled()
		
		# Toggle AI mode (Ctrl+Shift+A)
		elif event.keycode == KEY_A and event.ctrl_pressed and event.shift_pressed:
			toggle_ai_mode()
			get_viewport().set_input_as_handled()
	
	# Handle sync scrolling
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
		print("No active editor to save")
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
				print("Saved file: ", path)
				# Update filename
				if active_editor == left_editor:
					left_file_name = path.get_file()
				else:
					right_file_name = path.get_file()
				_update_status_info()
			file_dialog.queue_free()
	)

func _toggle_word_wrap():
	if not view_menu_button or not is_instance_valid(view_menu_button):
		print("View menu button not available")
		return
		
	var popup = view_menu_button.get_popup()
	var current_wrap = popup.is_item_checked(1)
	popup.set_item_checked(1, !current_wrap)
	
	# Apply word wrap to both editors
	var wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY if !current_wrap else TextEdit.LINE_WRAPPING_NONE
	if left_editor:
		left_editor.wrap_mode = wrap_mode
	if right_editor:
		right_editor.wrap_mode = wrap_mode
	
	print("Word wrap toggled: ", !current_wrap)
	



func _create_material_theme() -> Theme:
	var theme = Theme.new()

	# Create base styles for different components
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
	
	# Apply styles to theme
	theme.set_stylebox("panel", "Panel", panel_style)
	theme.set_stylebox("normal", "Button", button_normal)
	theme.set_stylebox("hover", "Button", button_hover)
	theme.set_stylebox("pressed", "Button", button_pressed)
	
	# Set up colors
	theme.set_color("font_color", "Label", COLORS.on_surface)
	theme.set_color("font_color", "Button", COLORS.on_primary)
	
	return theme



func _create_unified_menu_bar() -> PanelContainer:
	var menu_container = PanelContainer.new()
	
	# Style the menu container
	var style_box = StyleBoxFlat.new()
	style_box.bg_color = COLORS.surface
	style_box.shadow_color = COLORS.elevation_1
	style_box.shadow_size = 2
	style_box.shadow_offset = Vector2(0, 2)
	menu_container.add_theme_stylebox_override("panel", style_box)
	
	# Create a horizontal container for all menu items
	var h_container = HBoxContainer.new()
	menu_container.add_child(h_container)
	
	# Left side: Application name and menus
	var left_section = HBoxContainer.new()
	left_section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h_container.add_child(left_section)
	
	# App name
	var app_name = Label.new()
	app_name.text = "GD Slate"
	app_name.add_theme_color_override("font_color", COLORS.on_surface)
	left_section.add_child(app_name)
	
	# Add a small separator
	var separator = VSeparator.new()
	left_section.add_child(separator)
	
	# Create menu buttons with popups
	_add_file_menu(left_section)
	_add_view_menu(left_section)
	_add_edit_menu(left_section)
	_add_ai_mode_button(left_section)
	
	# Right side: Window controls
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
	
	# Make the entire menu bar draggable
	menu_container.gui_input.connect(_on_title_bar_gui_input)
	
	return menu_container



func _create_window_button(text: String, callback: Callable) -> Button:
	var button = Button.new()
	button.text = text
	button.flat = true
	button.custom_minimum_size = Vector2(24, 24)  # Smaller size for more compact layout
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


##Creates File drop down
func _create_menu_container() -> PanelContainer:
	var menu_container = PanelContainer.new()
	
	# Create Material-style menu bar background
	var style_box = StyleBoxFlat.new()
	style_box.bg_color = COLORS.surface
	style_box.shadow_color = COLORS.elevation_1
	style_box.shadow_size = 2
	style_box.shadow_offset = Vector2(0, 2)
	menu_container.add_theme_stylebox_override("panel", style_box)
	
	var menu_bar = MenuBar.new()
	menu_container.add_child(menu_bar)
	
	var file_menu = PopupMenu.new()
	file_menu.add_theme_color_override("font_color", COLORS.on_surface)
	
	# Style the popup menu
	var popup_style = StyleBoxFlat.new()
	popup_style.bg_color = COLORS.surface
	popup_style.corner_radius_top_left = 4
	popup_style.corner_radius_top_right = 4
	popup_style.corner_radius_bottom_left = 4
	popup_style.corner_radius_bottom_right = 4
	popup_style.shadow_color = COLORS.elevation_2
	popup_style.shadow_size = 6
	popup_style.shadow_offset = Vector2(0, 4)
	file_menu.add_theme_stylebox_override("panel", popup_style)
	
	file_menu.add_item("Open Left", 0)
	file_menu.add_item("Open Right", 1)
	file_menu.add_separator()
	file_menu.add_item("Exit", 2)
	
	menu_bar.add_child(file_menu)
	menu_bar.set_menu_title(0, "File")
	file_menu.id_pressed.connect(_on_file_menu_pressed)
	
	return menu_container



func _setup_enhanced_shortcuts():
	# Add more useful keyboard shortcuts for power users
	
	# Clear editors shortcut (Ctrl+Shift+N)
	if not InputMap.has_action("clear_editors"):
		InputMap.add_action("clear_editors")
		var clear_event = InputEventKey.new()
		clear_event.keycode = KEY_N
		clear_event.ctrl_pressed = true
		clear_event.shift_pressed = true
		InputMap.action_add_event("clear_editors", clear_event)
	
	# Quick save shortcut (Ctrl+S)
	if not InputMap.has_action("quick_save"):
		InputMap.add_action("quick_save")
		var save_event = InputEventKey.new()
		save_event.keycode = KEY_S
		save_event.ctrl_pressed = true
		InputMap.action_add_event("quick_save", save_event)
	
	# Toggle word wrap (Ctrl+W)
	if not InputMap.has_action("toggle_word_wrap"):
		InputMap.add_action("toggle_word_wrap")
		var wrap_event = InputEventKey.new()
		wrap_event.keycode = KEY_W
		wrap_event.ctrl_pressed = true
		InputMap.action_add_event("toggle_word_wrap", wrap_event)











###########################
##TITLE BAR FUNCTIONALITY##
func _on_title_bar_gui_input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_dragging_window = event.pressed
			drag_start_position = event.global_position
	elif event is InputEventMouseMotion and is_dragging_window:
		var delta = event.global_position - drag_start_position
		drag_start_position = event.global_position
		
		# Only move the window if we're not maximized
		if get_window().mode == Window.MODE_WINDOWED:
			get_window().position += Vector2i(delta)



func _on_file_menu_pressed(id: int):
	match id:
		0: # Open Left
			_open_file(left_editor)
		1: # Open Right
			_open_file(right_editor)
		2: # Exit
			get_tree().quit()



func _open_file(editor: CodeEdit):
	var file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Select a File"
	
	# Enhanced file filters for better developer experience
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
	file_dialog.popup_centered(Vector2(800, 600))  # Larger dialog for better UX
	
	# Enhanced file handling with proper error checking
	file_dialog.file_selected.connect(
		func(path):
			_load_file_safely(path, editor)
			file_dialog.queue_free()
	)



func _load_file_safely(file_path: String, editor: CodeEdit):
	# Enhanced file loading with comprehensive error handling
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
		
	# Successfully loaded file
	editor.text = file_content
	
	# Update the appropriate file name
	var file_name = file_path.get_file()
	if editor == left_editor:
		left_file_name = file_name
	else:
		right_file_name = file_name
	
	# Refresh syntax highlighting for the new content
	call_deferred("_refresh_syntax_highlighting")
	
	# Update the status bar
	_update_status_info()
	
	print("Successfully loaded file: ", file_name, " (", file_content.length(), " characters)")



func _show_error_message(message: String):
	# Helper function to show error messages to the user
	var dialog = AcceptDialog.new()
	dialog.title = "Error"
	
	var label = Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dialog.add_child(label)
	
	add_child(dialog)
	dialog.popup_centered()
	
	# Auto-cleanup after user closes the dialog
	dialog.confirmed.connect(func(): dialog.queue_free())



func _add_view_menu(parent: Control):
	# Create the menu button and store it in our class variable
	view_menu_button = MenuButton.new()
	view_menu_button.text = "View"
	view_menu_button.flat = true
	parent.add_child(view_menu_button)
	
	# Get and configure the popup menu
	var popup = view_menu_button.get_popup()
	_style_popup_menu(popup)
	
	# Add menu items
	popup.add_check_item("Show Line Numbers", 0)
	popup.add_check_item("Word Wrap", 1)
	popup.add_check_item("Dark Theme", 2)
	popup.add_separator()
	popup.add_check_item("Sync Scrolling", 3)
	
	# Set initial states
	popup.set_item_checked(0, true)  # Line numbers enabled by default
	popup.set_item_checked(2, true)  # Dark theme enabled by default
	popup.set_item_checked(3, true)  # Sync scrolling enabled by default
	
	# Connect the menu signal to our handler
	popup.id_pressed.connect(_on_view_menu_pressed)



func _add_ai_mode_button(parent: Control):
	# Create the AI mode toggle button
	ai_mode_button = MenuButton.new()
	ai_mode_button.text = "✦"  # Star symbol for AI mode
	ai_mode_button.flat = true
	ai_mode_button.tooltip_text = "Toggle AI Analysis Mode"
	
	# Style the button
	var font = SystemFont.new()
	font.font_names = ["Sans-serif"]
	#font.font_style = SystemFont.STYLE_BOLD
	ai_mode_button.add_theme_font_override("font", font)
	ai_mode_button.add_theme_font_size_override("font_size", 20)
	ai_mode_button.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	parent.add_child(ai_mode_button)
	
	# Create popup menu for AI mode
	var popup = ai_mode_button.get_popup()
	_style_popup_menu(popup)
	popup.add_item("Toggle AI Mode", 0)
	popup.add_separator()
	popup.add_item("API Key", 1)  # Add new menu item
	
	# Connect the popup menu
	popup.id_pressed.connect(_on_ai_mode_pressed)



func _on_ai_mode_pressed(id: int):
	match id:
		0:  # Toggle AI Mode
			toggle_ai_mode()
		1:  # API Key Settings
			api_settings.popup_centered()



func _on_view_menu_pressed(id: int):
	# Now we can safely access the popup through our stored menu button
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






###########
##AI MODE##
func toggle_ai_mode():
	if not is_instance_valid(left_editor) or not is_instance_valid(right_editor):
		push_error("Editors not initialized")
		return
	
	_cleanup_resources()
	
	ai_mode_active = !ai_mode_active
	current_mode = EditorMode.AI if ai_mode_active else EditorMode.COMPARE
	
	
	# Reset typing state when toggling modes
	is_typing = false
	current_typing_text = ""
	
	# Create a tween for smooth transitions
	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	
	if ai_mode_active:
		_transition_to_ai_mode(tween)
		_configure_editors_for_ai_mode()
	else:
		_transition_to_normal_mode(tween)
		_configure_editors_for_compare_mode()
	
	# Ensure we update the status bar
	_update_status_info()
	
	# Update the AI mode button appearance
	if is_instance_valid(ai_mode_button):
		ai_mode_button.add_theme_color_override(
			"font_color",
			COLORS.ai_mode_accent if ai_mode_active else COLORS.on_surface
		)



func _configure_editors_for_ai_mode():
	# Configure right editor as input
	right_editor.placeholder_text = "# Enter your code and questions here...\n# Example:\n# How can this code be optimized?\n\nfunc _ready():\n    pass"
	
	# Use our existing syntax highlighter
	var input_highlighter = CodeHighlighter.new()
	_configure_syntax_highlighting(input_highlighter)
	right_editor.syntax_highlighter = input_highlighter
	
	# Configure left editor as output
	left_editor.editable = false  # Make it read-only for AI output
	
	# Create another instance for the output editor
	var output_highlighter = CodeHighlighter.new()
	_configure_syntax_highlighting(output_highlighter)
	left_editor.syntax_highlighter = output_highlighter
	
	# Add processing indicator
	_create_processing_indicator()
	
	# Update editor labels
	_update_editor_labels("AI Output", "Code Input")
	
	# Disconnect scroll sync in AI mode
	_disconnect_editor_signals()
	
	is_typing = false
	current_typing_text = ""



func _configure_editors_for_compare_mode():
	# Reset editor configurations
	right_editor.placeholder_text = ""
	right_editor.editable = true
	left_editor.editable = true
	
	# Reset syntax highlighting
	var left_highlighter = CodeHighlighter.new()
	_configure_syntax_highlighting(left_highlighter)
	left_editor.syntax_highlighter = left_highlighter
	
	var right_highlighter = CodeHighlighter.new()
	_configure_syntax_highlighting(right_highlighter)
	right_editor.syntax_highlighter = right_highlighter
	
	# Remove processing indicator
	if is_processing_ai:
		_remove_processing_indicator()
	
	# Update editor labels
	_update_editor_labels("Left Editor", "Right Editor")
	
	# Reconnect scroll sync if it was enabled
	if sync_scroll_enabled:
		_connect_editor_signals()
	is_typing = false
	current_typing_text = ""



func _transition_to_ai_mode(tween: Tween):
	# Transition background color of editors
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
	
	# Transition menu bar color
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
	
	# Update all popup menus
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
		
		# Update popup text color
		popup.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	# Transition search bar
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
		
		# Update search bar input field
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
	
	# Transition status bar
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
		
		# Update status bar text colors
		if stats_label:
			stats_label.add_theme_color_override("font_color", COLORS.ai_mode_accent)
		if file_info:
			file_info.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	# Update button color
	ai_mode_button.add_theme_color_override("font_color", COLORS.ai_mode_accent)




func _transition_to_normal_mode(tween: Tween):
	# Transition background color of editors back to normal
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
	
	# Transition menu bar color back to normal
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
	
	# Update all popup menus
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
		
		# Reset popup text color
		popup.add_theme_color_override("font_color", COLORS.on_surface)
	
	# Transition search bar back to normal
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
		
		# Reset search bar input field
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
	
	# Transition status bar back to normal
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
		
		# Reset status bar text colors
		if stats_label:
			stats_label.add_theme_color_override("font_color", COLORS.on_surface)
		if file_info:
			file_info.add_theme_color_override("font_color", COLORS.on_surface)
	
	# Update button color back to normal
	ai_mode_button.add_theme_color_override("font_color", COLORS.on_surface)



func _get_all_menu_buttons() -> Array:
	var menu_buttons = []
	
	# Get the menu container first
	var menu_container = _get_menu_container()
	if not menu_container:
		push_warning("Menu container not found when searching for menu buttons")
		return menu_buttons
	
	# Search through all children recursively to find MenuButtons
	# This is more reliable than assuming a specific hierarchy
	_find_menu_buttons_recursive(menu_container, menu_buttons)
	
	return menu_buttons



func _find_menu_buttons_recursive(node: Node, buttons: Array) -> void:
	# Check if this node is a MenuButton
	if node is MenuButton:
		buttons.append(node)
	
	# Recursively check all children
	for child in node.get_children():
		_find_menu_buttons_recursive(child, buttons)



func _get_menu_container() -> PanelContainer:
	# Safety check for root_container
	if not root_container:
		push_warning("root_container is null")
		return null
	
	# Make sure we have children
	if root_container.get_child_count() == 0:
		push_warning("root_container has no children")
		return null
	
	# Get the first child, which should be our menu container
	var first_child = root_container.get_child(0)
	if first_child is PanelContainer:
		return first_child
	
	push_warning("First child is not a PanelContainer as expected")
	return null




func _handle_editor_scroll(event: InputEvent, source_editor: CodeEdit):
	if not sync_scroll_enabled:
		return
		
	# Check for scroll wheel events
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var target_editor = right_editor if source_editor == left_editor else left_editor
			
			# Get the scroll offset
			var scroll_offset = source_editor.get_v_scroll()
			
			# Apply the scroll offset to the target editor
			target_editor.set_v_scroll(scroll_offset)
			
			# Mark the event as handled
			get_viewport().set_input_as_handled()














########################
##SEARCH FUNCTIONALITY##
func _setup_search_bar():
	# Create a container that will sit between the editors
	search_container = PanelContainer.new()
	search_container.name = "SearchContainer"
	
	# Position it at the top of the editors
	search_container.set_anchors_preset(Control.PRESET_TOP_WIDE)
	search_container.position.y = -50  # Start above the visible area
	search_container.custom_minimum_size.y = 50
	
	# Style the container with Material Design
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = COLORS.surface
	panel_style.corner_radius_bottom_left = 8
	panel_style.corner_radius_bottom_right = 8
	panel_style.shadow_color = COLORS.elevation_2
	panel_style.shadow_size = 4
	panel_style.shadow_offset = Vector2(0, 2)
	search_container.add_theme_stylebox_override("panel", panel_style)
	
	# Add it to the main container after the menu bar
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
	
	# Search input field with improved styling
	search_bar = LineEdit.new()
	search_bar.placeholder_text = "Search text..."
	search_bar.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	
	# Style the search input
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
	
	# Connect search bar signals
	search_bar.text_changed.connect(_on_search_text_changed)
	search_bar.text_submitted.connect(_on_search_submitted)
	h_box.add_child(search_bar)
	
	# Add match count label
	match_label = Label.new()
	match_label.name = "MatchLabel"
	match_label.text = "No matches"
	match_label.add_theme_color_override("font_color", COLORS.on_surface)
	match_label.custom_minimum_size.x = 100
	h_box.add_child(match_label)
	
	# Navigation buttons with improved styling
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
	
	# Close button
	var close_button = Button.new()
	close_button.text = "×"
	close_button.tooltip_text = "Close search (Esc)"
	close_button.custom_minimum_size = Vector2(24, 24)
	close_button.pressed.connect(_toggle_search)
	h_box.add_child(close_button)
	
	# Initially hide the search container
	search_container.hide()



func _toggle_search():
	if search_container.visible:
		# Animate the search bar sliding up
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		
		# Animate position and opacity
		tween.parallel().tween_property(search_container, "position:y", -50, 0.3)
		tween.parallel().tween_property(search_container, "modulate:a", 0.0, 0.3)
		
		# Hide the container when animation completes
		await tween.finished
		search_container.visible = false
		
		# Return focus to the active editor
		if active_editor:
			active_editor.grab_focus()
	else:
		# Show container before animation
		search_container.visible = true
		search_container.modulate.a = 0.0
		search_container.position.y = -50
		
		# Store active editor
		if left_editor.has_focus():
			active_editor = left_editor
		elif right_editor.has_focus():
			active_editor = right_editor
		else:
			active_editor = left_editor
		
		# Animate the search bar sliding down
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		
		# Animate position and opacity
		tween.parallel().tween_property(search_container, "position:y", 0, 0.3)
		tween.parallel().tween_property(search_container, "modulate:a", 1.0, 0.3)
		
		# Clear and focus the search bar
		search_bar.clear()
		search_bar.grab_focus()



func _on_search_text_changed(new_text: String):
	if not active_editor:
		return
		
	# Clear previous highlights
	_clear_search_highlights()
	
	search_results.clear()
	current_search_index = -1
	
	if new_text.is_empty():
		_update_match_count()
		return
	
	var text = active_editor.text
	var position = 0
	
	# Find all occurrences
	while true:
		position = text.find(new_text, position)
		if position == -1:
			break
		search_results.append(position)
		position += 1
	
	if not search_results.is_empty():
		current_search_index = 0
		_highlight_all_matches()
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
	
	# Calculate line and column for the current match
	var line = 0
	var current_pos = 0
	var text = active_editor.text
	
	# Find the line number by counting newlines
	while current_pos < position:
		var newline_pos = text.find("\n", current_pos)
		if newline_pos == -1 or newline_pos >= position:
			break
		line += 1
		current_pos = newline_pos + 1
	
	# Calculate the column
	var column = position - current_pos
	
	# Make sure we can see the text by setting the caret position
	# This will automatically scroll the view to show the caret
	active_editor.set_caret_line(line)
	active_editor.set_caret_column(column)
	
	# Now select the text
	active_editor.select(line, column, line, column + search_text.length())
	
	# Update the match count display
	_update_match_count()



func _on_search_submitted(_text: String):
	_find_next()



func _highlight_all_matches():
	var search_text = search_bar.text
	if search_text.is_empty():
		return
	
	for position in search_results:
		_highlight_match(position, search_text.length(), false)



func _highlight_match(position: int, length: int, is_current: bool = false):
	var text = active_editor.text
	var line = 0
	var current_pos = 0
	
	# Find the line number
	while current_pos < position:
		var newline_pos = text.find("\n", current_pos)
		if newline_pos == -1 or newline_pos >= position:
			break
		line += 1
		current_pos = newline_pos + 1
	
	# Calculate column start and end
	var column_start = position - current_pos
	var column_end = column_start + length
	
	# For the current match, we use select() to highlight it
	# CodeEdit only supports one selection at a time
	if is_current:
		active_editor.select(line, column_start, line, column_end)
		
		# Also set the caret position to make it visible
		active_editor.set_caret_line(line)
		active_editor.set_caret_column(column_end)
	
	# For non-current matches, we unfortunately cannot highlight them
	# as CodeEdit doesn't support multiple selections or custom text highlighting
	# We could potentially implement this using syntax highlighting or custom drawing
	# but that would be more complex and require additional setup



func _clear_search_highlights():
	if active_editor:
		# Simply selecting an empty range effectively clears the selection
		active_editor.select(0, 0, 0, 0)



func _update_match_count():
	if match_label:  # Check if the label exists
		if search_results.is_empty():
			match_label.text = "No matches"
		else:
			match_label.text = "%d/%d matches" % [current_search_index + 1, search_results.size()]



func _update_selection_colors():
	# Set selection colors
	active_editor.add_theme_color_override("selection_color", Color(0.4, 0.6, 0.8, 0.3))  # Light blue
	active_editor.add_theme_color_override("font_selected_color", COLORS.code_text)












###############################
##AI SETUP AND SYSTEM PROMPT ##
func _setup_system_prompt_shortcut():
	# Remove any existing shortcuts to prevent duplicates
	if InputMap.has_action("toggle_system_prompt"):
		InputMap.erase_action("toggle_system_prompt")
	
	# Create the system prompt shortcut
	InputMap.add_action("toggle_system_prompt")
	
	# Create and configure the keyboard event
	var prompt_event = InputEventKey.new()
	prompt_event.keycode = SYSTEM_PROMPT_SHORTCUT_KEY
	prompt_event.ctrl_pressed = true
	prompt_event.alt_pressed = true
	
	# Add the event to our action
	InputMap.action_add_event("toggle_system_prompt", prompt_event)



func _setup_system_prompt_panel():
	# Create the main container for the system prompt
	system_prompt_container = PanelContainer.new()
	system_prompt_container.name = "SystemPromptContainer"
	
	# Position it at the top of the window
	system_prompt_container.set_anchors_preset(Control.PRESET_TOP_WIDE)
	system_prompt_container.position.y = -300  # Start above the visible area
	system_prompt_container.custom_minimum_size.y = 300
	
	# Create a stylish background for the prompt panel
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = COLORS.surface
	panel_style.corner_radius_bottom_left = 12
	panel_style.corner_radius_bottom_right = 12
	panel_style.shadow_color = COLORS.elevation_2
	panel_style.shadow_size = 8
	panel_style.shadow_offset = Vector2(0, 4)
	system_prompt_container.add_theme_stylebox_override("panel", panel_style)
	
	# Create a margin container for padding
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	system_prompt_container.add_child(margin)
	
	# Create a vertical layout for the content
	var v_box = VBoxContainer.new()
	v_box.add_theme_constant_override("separation", 12)
	margin.add_child(v_box)
	
	# Add a header
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	v_box.add_child(header)
	
	# Add the title
	var title = Label.new()
	title.text = "System Prompt"
	title.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	title.add_theme_font_size_override("font_size", 18)
	header.add_child(title)
	
	# Add a spacer
	var spacer = Control.new()
	spacer.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	header.add_child(spacer)
	
	# Add save and close buttons
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
	
	# Create the system prompt editor
	system_prompt_editor = TextEdit.new()
	system_prompt_editor.text = default_system_prompt
	system_prompt_editor.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	system_prompt_editor.syntax_highlighter = null  # Disable syntax highlighting for prompt
	system_prompt_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	
	# Style the editor
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
	
	# Add the container to our root
	root_container.add_child(system_prompt_container)
	
	# Initially hide the system prompt container
	system_prompt_container.hide()



func _toggle_system_prompt():
	if system_prompt_container.visible:
		# Animate the prompt panel sliding up
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		
		# Animate position and opacity
		tween.parallel().tween_property(system_prompt_container, "position:y", -300, 0.3)
		tween.parallel().tween_property(system_prompt_container, "modulate:a", 0.0, 0.3)
		
		# Hide the container when animation completes
		await tween.finished
		system_prompt_container.hide()
		
		# Return focus to the active editor
		if active_editor:
			active_editor.grab_focus()
	else:
		# Show container before animation
		system_prompt_container.show()
		system_prompt_container.modulate.a = 0.0
		system_prompt_container.position.y = -300
		
		# Animate the prompt panel sliding down
		var tween = create_tween()
		tween.set_ease(Tween.EASE_OUT)
		tween.set_trans(Tween.TRANS_CUBIC)
		
		# Animate position and opacity
		tween.parallel().tween_property(system_prompt_container, "position:y", 0, 0.3)
		tween.parallel().tween_property(system_prompt_container, "modulate:a", 1.0, 0.3)
		
		# Focus the prompt editor
		system_prompt_editor.grab_focus()



func _save_system_prompt():
	# Here we would typically save the prompt to some persistent storage
	# For now, we'll just close the panel
	_toggle_system_prompt()




func _load_api_key() -> void:
	## In a real application, you'd want to use secure storage
	## For now, we'll try to load from a config file
	#if FileAccess.file_exists("user://api_config.save"):
		#var file = FileAccess.open("user://api_config.save", FileAccess.READ)
		#api_key = file.get_line()
	pass



#func _save_api_key(new_key: String) -> void:
	#api_key = new_key
	#var file = FileAccess.open("user://api_config.save", FileAccess.WRITE)
	#file.store_line(api_key)



func _on_api_key_saved(new_key: String) -> void:
	api_key = new_key
	request_manager.set_api_key(new_key)  # Update request manager's API key
	# Check if we were in the middle of an AI request
	if is_processing_ai:
		error_handler.log_debug("Retrying AI request with new API key")
		# Reset processing state so we can retry
		is_processing_ai = false
		var indicator = left_editor.get_node_or_null("ProcessingIndicator")
		if indicator:
			indicator.queue_free()
		# Retry the request
		_process_ai_request()














#############################
##AI RESPONSE FUNCTIONALITY##
func _process_ai_request() -> void:
	if is_processing_ai:
		return
	
	if api_key.is_empty():
		error_handler.log_debug("No API key found, showing settings dialog")
		_show_api_key_dialog()
		return
	
	error_handler.log_debug("Submitting AI prompt", {
		"text_length": str(right_editor.text.length()),
		"has_system_prompt": str(not system_prompt_editor.text.is_empty()),
		"has_api_key": str(not api_key.is_empty())
	})
	
	is_processing_ai = true
	is_streaming_response = false  # Reset streaming state
	left_editor.text = ""  # Clear previous response
	_show_processing_indicator()
	prompt_history.append(right_editor.text)
	request_manager.queue_request(right_editor.text, system_prompt_editor.text)


func _on_api_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	is_processing_ai = false
	
	# Hide processing indicator
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.hide()
	
	if result != HTTPRequest.RESULT_SUCCESS:
		_handle_api_error("Request failed with result: " + str(result))
		return
	
	if response_code != 200:
		_handle_api_error("API returned error code: " + str(response_code))
		return
	
	# Parse the response
	var json = JSON.new()
	var parse_result = json.parse(body.get_string_from_utf8())
	if parse_result != OK:
		_handle_api_error("Failed to parse response")
		return
	
	var response_data = json.get_data()
	if not response_data.has("content"):
		_handle_api_error("Invalid response format")
		return
	
	# Update the output editor with the response
	left_editor.text = response_data["content"][0]["text"]



func _handle_api_error(error_message: String) -> void:
	is_processing_ai = false
	
	# Hide processing indicator
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.hide()
	
	# Show error in output editor
	left_editor.text = "# Error occurred:\n# " + error_message



func _on_request_completed(response: String) -> void:
	# Enhanced response handling with better state management
	error_handler.log_debug("Received response chunk", {"chunk_length": str(response.length())})
	
	# Initialize streaming if this is the first chunk
	if not is_streaming_response:
		left_editor.text = ""  # Clear on first chunk
		is_streaming_response = true
		
		# Hide the processing indicator since we're getting real data
		var indicator = left_editor.get_node_or_null("ProcessingIndicator")
		if indicator:
			indicator.hide()
	
	# Add the chunk to the editor
	left_editor.text += response
	
	# Keep the cursor at the end for live updating effect
	left_editor.set_caret_line(left_editor.get_line_count() - 1)
	left_editor.set_caret_column(left_editor.get_line(left_editor.get_line_count() - 1).length())
	
	# Force a redraw to ensure the text appears immediately
	left_editor.queue_redraw()


func _on_request_error(error_message: String) -> void:
	# Enhanced error handling with better recovery options
	is_streaming_response = false
	is_processing_ai = false
	
	# Provide more helpful error messages based on error type
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
# If the problem persists, the Claude API might be temporarily unavailable.
# 
# Original error: """ + error_message
	else:
		user_friendly_message = "# Error: " + error_message
	
	left_editor.text = user_friendly_message
	
	# Clean up any processing indicators
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.queue_free()



func _on_error_occurred(message: String, level: int) -> void:
	if left_editor:
		# Only update the UI for warnings and errors, not for debug/info messages.
		var error_prefix = ""
		match level:
			AIErrorHandler.ErrorLevel.WARNING:
				error_prefix = "# Warning: "
			AIErrorHandler.ErrorLevel.ERROR:
				error_prefix = "# Error: "
			AIErrorHandler.ErrorLevel.CRITICAL:
				error_prefix = "# Critical Error: "
			AIErrorHandler.ErrorLevel.INFO:
				# Do not overwrite streaming text on info messages.
				return
			_:
				error_prefix = "# "
		if not is_streaming_response:
			left_editor.text = error_prefix + message
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.hide()
	is_processing_ai = false



func _handle_editor_input(event: InputEvent) -> void:
	if current_mode != EditorMode.AI:
		return
		
	if event is InputEventKey:
		# Store the shift state explicitly
		is_shift_pressed = event.shift_pressed
		
		if event.keycode == KEY_ENTER and event.pressed:
			if event.shift_pressed:
				# Handle Shift+Enter for new line
				_handle_shift_enter()
				get_viewport().set_input_as_handled()
			else:
				# Normal Enter for submitting prompt
				error_handler.handle_error("debug", {"message": "Enter key pressed", "details": "Submitting AI prompt"})
				get_viewport().set_input_as_handled()
				_submit_ai_prompt()



func _submit_ai_prompt() -> void:
	if is_processing_ai or right_editor.text.strip_edges().is_empty():
		return
	
	# Reset typing state
	is_typing = false
	current_typing_text = ""
	left_editor.text = ""  # Clear previous response
	
	error_handler.log_debug("Submitting AI prompt", {
		"text_length": str(right_editor.text.length()),
		"has_system_prompt": str(not system_prompt_editor.text.is_empty())
	})
	is_processing_ai = true
	is_streaming_response = false
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
	
	left_editor.text = ""
	left_editor.add_child(container)
	
	var tween = create_tween()
	tween.set_loops()
	tween.tween_property(spinner_label, "rotation", TAU, 1.0)



func _handle_ai_response(response: String):
	# Update the output editor with the response
	left_editor.text = response
	
	# Hide processing indicator
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.hide()
	
	is_processing_ai = false



func _stream_response(complete_response: String) -> void:
	is_streaming_response = true
	current_streaming_text = complete_response
	left_editor.text = ""  # Clear the editor
	streaming_timer.start()



func _stream_next_chunk() -> void:
	if not is_streaming_response or current_streaming_text.is_empty():
		streaming_timer.stop()
		is_streaming_response = false
		_on_stream_complete()
		return
		
	# Take the next chunk
	var chunk_size = 1  # Process one character at a time
	var chunk = current_streaming_text.substr(0, chunk_size)
	current_streaming_text = current_streaming_text.substr(chunk_size)
	
	# Insert at current caret position
	left_editor.set_caret_line(left_editor.get_line_count() - 1)
	left_editor.set_caret_column(left_editor.get_line(left_editor.get_line_count() - 1).length())
	left_editor.insert_text_at_caret(chunk)
	
	# Scroll to keep up with new text
	left_editor.set_v_scroll(left_editor.get_v_scroll_bar().max_value)



func _handle_streaming_chunk(chunk: String) -> void:
	if not is_streaming_response:
		is_streaming_response = true
		left_editor.text = ""  # Clear editor when starting new stream
		var indicator = left_editor.get_node_or_null("ProcessingIndicator")
		if indicator:
			indicator.hide()
	
	# Append the chunk without interfering with debug logs.
	left_editor.text += chunk
	left_editor.set_caret_line(left_editor.get_line_count() - 1)
	error_handler.log_debug("Added streaming chunk", {"total_length": str(left_editor.text.length())})



func _on_stream_complete() -> void:
	is_streaming_response = false
	is_processing_ai = false
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		var tween = create_tween()
		tween.tween_property(indicator, "modulate:a", 0.0, 0.5)
		tween.tween_callback(indicator.queue_free)



func _create_processing_indicator():
	var indicator = HBoxContainer.new()
	indicator.name = "ProcessingIndicator"
	indicator.position = Vector2(10, 10)
	
	var spinner = TextureRect.new()  # You'll need to add a spinner texture
	var label = Label.new()
	label.text = "Processing..."
	label.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	
	indicator.add_child(spinner)
	indicator.add_child(label)
	left_editor.add_child(indicator)
	indicator.hide()



func _remove_processing_indicator():
	var indicator = left_editor.get_node_or_null("ProcessingIndicator")
	if indicator:
		indicator.queue_free()
	is_processing_ai = false












###########################
##COMPARING FUNCTIONALITY##
func _highlight_differences():
	# Store text from both editors
	var left_lines = left_editor.text.split("\n")
	var right_lines = right_editor.text.split("\n")
	
	# Create color styles for different states
	var deletion_color = Color(1, 0.8, 0.8, 0.3)  # Light red
	var addition_color = Color(0.8, 1, 0.8, 0.3)  # Light green
	var modification_color = Color(0.95, 0.95, 0.8, 0.3)  # Light yellow
	
	# Clear any existing background colors
	for i in range(left_editor.get_line_count()):
		left_editor.set_line_background_color(i, Color.TRANSPARENT)
	for i in range(right_editor.get_line_count()):
		right_editor.set_line_background_color(i, Color.TRANSPARENT)
	
	# Compare lines and highlight differences
	var max_lines = max(left_lines.size(), right_lines.size())
	
	for i in range(max_lines):
		var left_line = left_lines[i] if i < left_lines.size() else ""
		var right_line = right_lines[i] if i < right_lines.size() else ""
		
		# If lines are different, highlight them
		if left_line != right_line:
			# Line exists in both editors but is different
			if i < left_lines.size() and i < right_lines.size():
				left_editor.set_line_background_color(i, modification_color)
				right_editor.set_line_background_color(i, modification_color)
			# Line only exists in left editor (deletion)
			elif i < left_lines.size():
				left_editor.set_line_background_color(i, deletion_color)
			# Line only exists in right editor (addition)
			else:
				right_editor.set_line_background_color(i, addition_color)
	var stats = _count_differences()
	_update_status_bar(stats)



func _on_text_changed() -> void:
	if not is_instance_valid(left_editor) or not is_instance_valid(right_editor):
		return
	
	if current_mode == EditorMode.AI:
		if is_shift_pressed:
			return
	elif current_mode == EditorMode.COMPARE:
		_highlight_differences()

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


















###########################
##STATUS BAR CREATION######
func _create_status_bar() -> void:
	# First, remove any existing status bar
	var existing_status_bar = root_container.get_node_or_null("StatusBar")
	if existing_status_bar:
		existing_status_bar.queue_free()
	
	# Create the main status bar container
	status_bar = PanelContainer.new()
	status_bar.name = "StatusBar"
	status_bar.set_h_size_flags(Control.SIZE_FILL)
	status_bar.custom_minimum_size.y = 24
	
	# Create and apply the style
	var style = StyleBoxFlat.new()
	style.bg_color = COLORS.surface.darkened(0.1)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	status_bar.add_theme_stylebox_override("panel", style)
	
	# Create the main horizontal layout
	var h_box = HBoxContainer.new()
	h_box.set_h_size_flags(Control.SIZE_FILL)
	h_box.set_v_size_flags(Control.SIZE_FILL)  # Added vertical fill
	status_bar.add_child(h_box)
	
	# Mode indicator section (left)
	mode_indicator = Label.new()
	mode_indicator.name = "ModeIndicator"
	mode_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	mode_indicator.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mode_indicator.add_theme_font_size_override("font_size", 12)
	mode_indicator.add_theme_color_override("font_color", COLORS.ai_mode_accent)
	mode_indicator.text = "○ Compare Mode"  # Set initial text
	h_box.add_child(mode_indicator)
	
	# Add first separator
	var separator1 = VSeparator.new()
	separator1.custom_minimum_size.x = 8
	h_box.add_child(separator1)
	
	# Stats section (center)
	stats_label = Label.new()
	stats_label.name = "StatsLabel"
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	stats_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stats_label.add_theme_font_size_override("font_size", 12)
	stats_label.text = "No diffs"  # Set initial text
	h_box.add_child(stats_label)
	
	# Flexible spacer
	var spacer = Control.new()
	spacer.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	h_box.add_child(spacer)
	
	# File info section (right)
	file_info = Label.new()
	file_info.name = "FileInfo"
	file_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	file_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	file_info.add_theme_font_size_override("font_size", 12)
	file_info.text = "No file | No file"  # Set initial text
	h_box.add_child(file_info)
	
# Add the status bar to the root container
	if root_container and is_instance_valid(root_container):
		root_container.add_child(status_bar)
		
		# Ensure it's the last child
		root_container.move_child(status_bar, root_container.get_child_count() - 1)
		
		# Force an immediate update
		_update_status_info()
	
	# Schedule a deferred update to ensure proper layout
	call_deferred("_ensure_status_bar_visibility")



func _ensure_status_bar_visibility() -> void:
	if status_bar:
		# Force the status bar to the front
		status_bar.show()
		status_bar.move_to_front()
		
		# Print debug info about the status bar's state
		print("Status bar visibility check:")
		print("- Visible: ", status_bar.visible)
		print("- Position: ", status_bar.position)
		print("- Size: ", status_bar.size)
		print("- Global position: ", status_bar.global_position)
		
		# Verify child visibility
		print("Child visibility:")
		print("- Mode indicator visible: ", mode_indicator.visible)
		print("- Stats label visible: ", stats_label.visible)
		print("- File info visible: ", file_info.visible)



func _update_status_info() -> void:
	if not is_instance_valid(status_bar):
		return
	if not is_instance_valid(mode_indicator):
		return
	if not is_instance_valid(stats_label):
		return
	if not is_instance_valid(file_info):
		return
	
	var mode_text := "● AI Mode" if ai_mode_active else "○ Compare Mode"
	mode_indicator.text = mode_text
	mode_indicator.add_theme_color_override(
		"font_color",
		COLORS.ai_mode_accent if ai_mode_active else COLORS.on_surface
	)
	
	file_info.text = "%s | %s" % [left_file_name, right_file_name]

	
	# Force labels to update their visibility
	mode_indicator.show()
	stats_label.show()
	file_info.show()
	
	# Print debug info
	print("Status info updated:")
	print("- Mode text: ", mode_indicator.text)
	print("- File info: ", file_info.text)



func _update_status_bar(stats: Dictionary):
	if not stats_label:
		return
		
	if stats.total > 0:
		# Simplified display of just the total differences
		stats_label.text = str(stats.total) + " diff" + ("s" if stats.total != 1 else "")
	else:
		stats_label.text = "No diffs"



func _update_editor_labels(left_label: String, right_label: String):
	# We'll create labels if they don't exist, update them if they do
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













func _configure_syntax_highlighting(highlighter: CodeHighlighter, is_dark: bool = true):
	# Color definitions
	var colors: Dictionary
	if is_dark:
		colors = {
			"symbol": Color("#abc9ff"),
			"keyword": Color("#ff7085"),
			"control": Color("#ff8ccc"),
			"base_type": Color("#42ffc2"),
			"engine_type": Color("#8fffdb"),
			"comment": Color("#676767"),
			"doc_comment": Color("#99b3cc"),
			"string": Color("#ffeda1"),
			"number": Color("#b5cea8"),
			"function": Color("#57b3ff"),
			"member": Color("#bce0ff"),
		}
	else:
		colors = {
			"symbol": Color("#0066cc"),
			"keyword": Color("#d73a49"),
			"control": Color("#b31d28"),
			"base_type": Color("#22863a"),
			"engine_type": Color("#005cc5"),
			"comment": Color("#6a737d"),
			"doc_comment": Color("#6a737d"),
			"string": Color("#032f62"),
			"number": Color("#005cc5"),
			"function": Color("#005cc5"),
			"member": Color("#005cc5"),
		}
	
	# Clear existing
	highlighter.clear_keyword_colors()
	highlighter.clear_member_keyword_colors()
	highlighter.clear_color_regions()
	
	# Built-in color properties (these handle the "regex-like" patterns automatically)
	highlighter.number_color = colors.number
	highlighter.symbol_color = colors.symbol
	highlighter.function_color = colors.function
	highlighter.member_variable_color = colors.member
	
	# Color regions (delimited content)
	highlighter.add_color_region("#", "", colors.comment, true)
	highlighter.add_color_region("\"", "\"", colors.string, false)
	highlighter.add_color_region("'", "'", colors.string, false)
	highlighter.add_color_region("\"\"\"", "\"\"\"", colors.string, false)
	
	# Keywords - must be literal strings, no regex
	var keywords := {
		"control": ["if", "elif", "else", "for", "while", "break", "continue", 
			"pass", "return", "match", "when"],
		"keyword": ["func", "class", "class_name", "extends", "static", "enum",
			"var", "const", "signal", "self", "super", "null", "true", "false",
			"and", "or", "not", "in", "is", "as", "await", "yield",
			"@export", "@onready", "@tool", "@icon", "@warning_ignore"],
		"base_type": ["bool", "int", "float", "String", "StringName", "Array",
			"Dictionary", "Variant", "void"],
		"engine_type": ["Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4",
			"Color", "Transform2D", "Transform3D", "Basis", "Quaternion",
			"Node", "Node2D", "Node3D", "Control", "Resource", "RefCounted",
			"PackedScene", "Texture2D", "Timer", "HTTPRequest", "FileAccess",
			"DirAccess", "Rect2", "Rect2i", "AABB", "Callable", "Signal",
			"Tween", "StyleBoxFlat", "StyleBoxEmpty", "Theme", "CodeEdit",
			"TextEdit", "LineEdit", "Label", "Button", "MenuButton",
			"PopupMenu", "PanelContainer", "VBoxContainer", "HBoxContainer",
			"HSplitContainer", "VSplitContainer", "MarginContainer",
			"CodeHighlighter", "InputEventKey", "InputEventMouseButton",
			"JSON", "RegEx", "Time", "OS", "Input", "Engine"],
	}
	
	for category in keywords:
		var color: Color = colors[category]
		for kw in keywords[category]:
			highlighter.add_keyword_color(kw, color)

# Fix the black text issue by being more aggressive about color application
func _create_styled_editor() -> CodeEdit:
	var editor = CodeEdit.new()
	editor.set_h_size_flags(Control.SIZE_EXPAND_FILL)
	editor.set_v_size_flags(Control.SIZE_EXPAND_FILL)
	
	# Apply Material Design styling to the editor
	var editor_style = StyleBoxFlat.new()
	editor_style.bg_color = COLORS.code_background
	editor_style.corner_radius_top_left = 4
	editor_style.corner_radius_top_right = 4
	editor_style.corner_radius_bottom_left = 4
	editor_style.corner_radius_bottom_right = 4
	editor_style.shadow_color = COLORS.elevation_1
	editor_style.shadow_size = 2
	editor_style.content_margin_left = 8
	editor_style.content_margin_right = 8
	editor_style.content_margin_top = 8
	editor_style.content_margin_bottom = 8
	
	editor.add_theme_stylebox_override("normal", editor_style)
	
	# AGGRESSIVE COLOR FIXING - Clear any existing overrides first
	editor.remove_theme_color_override("font_color")
	editor.remove_theme_color_override("font_selected_color")
	editor.remove_theme_color_override("caret_color")
	
	# Force the white color explicitly
	editor.add_theme_color_override("font_color", Color.WHITE)
	editor.add_theme_color_override("font_selected_color", Color.WHITE)
	editor.add_theme_color_override("caret_color", Color.WHITE)
	editor.add_theme_color_override("selection_color", Color(0.2, 0.4, 0.8, 0.3))
	editor.add_theme_color_override("line_number_color", Color(1.0, 1.0, 1.0, 0.6))
	editor.add_theme_color_override("current_line_color", Color(0.2, 0.4, 0.8, 0.1))
	
	# Basic editor settings
	editor.gutters_draw_line_numbers = true
	editor.minimap_draw = false
	editor.draw_tabs = true
	editor.draw_spaces = false
	editor.highlight_current_line = true
	editor.add_theme_constant_override("line_spacing", 6)
	
	# DON'T apply syntax highlighter yet - let's see if base white text works first
	print("Created editor with explicit white font color")
	
	return editor



func _refresh_syntax_highlighting() -> void:
	var is_dark := true
	if is_instance_valid(view_menu_button):
		is_dark = view_menu_button.get_popup().is_item_checked(2)
	
	var text_color := COLORS.code_text if is_dark else Color("#24292e")
	var bg_color := COLORS.code_background if is_dark else Color("#ffffff")
	
	for editor in [left_editor, right_editor]:
		if not is_instance_valid(editor):
			continue
		
		# Background
		var style: StyleBoxFlat = editor.get_theme_stylebox("normal").duplicate()
		style.bg_color = bg_color
		editor.add_theme_stylebox_override("normal", style)
		
		# Font colors
		editor.add_theme_color_override("font_color", text_color)
		editor.add_theme_color_override("font_selected_color", text_color)
		editor.add_theme_color_override("caret_color", text_color)
		editor.add_theme_color_override("line_number_color", text_color * Color(1, 1, 1, 0.6))
		
		# Fresh highlighter
		var highlighter := CodeHighlighter.new()
		_configure_syntax_highlighting(highlighter, is_dark)
		editor.syntax_highlighter = highlighter


func _handle_shift_enter() -> void:
	if not is_instance_valid(right_editor):
		return
		
	# Get current cursor position
	var current_line = right_editor.get_caret_line()
	var current_column = right_editor.get_caret_column()
	
	# Get the current line's text
	var line_text = right_editor.get_line(current_line)
	
	# Split the line at cursor position
	var text_before = line_text.substr(0, current_column)
	var text_after = line_text.substr(current_column)
	
	# Create the new line with proper indentation
	var indentation = ""
	var i = 0
	while i < text_before.length() and text_before[i] == " ":
		indentation += " "
		i += 1
	
	# Insert the new line with indentation
	right_editor.remove_text(current_line, 0, current_line, line_text.length())
	right_editor.insert_text_at_caret(text_before + "\n" + indentation + text_after)
	
	# Move cursor to the start of the new line (after indentation)
	right_editor.set_caret_line(current_line + 1)
	right_editor.set_caret_column(indentation.length())



func _clear_editor(editor: CodeEdit):
	editor.text = ""
	if editor == left_editor:
		left_file_name = "No file"
	else:
		right_file_name = "No file"
	_update_status_info()




func _show_api_key_dialog() -> void:
	# Show a more informative dialog about the missing API key
	if not api_settings:
		push_error("API settings dialog not initialized!")
		return
		
	# Check if we're already showing the dialog
	if api_settings.visible:
		return
		
	# Show the API settings dialog with better messaging
	api_settings.popup_centered()
	
	# Ensure it gets focus
	api_settings.grab_focus()


##What is this?
func _apply_theme(dark_theme: bool):
	var editor_style = StyleBoxFlat.new()
	
	if dark_theme:
		editor_style.bg_color = COLORS.code_background
		# Refresh syntax highlighting with dark theme colors
		_refresh_syntax_highlighting()
	else:
		editor_style.bg_color = Color("ffffff")
		# Refresh syntax highlighting with light theme colors
		_refresh_syntax_highlighting()
	
	# Apply the style to both editors
	editor_style.corner_radius_top_left = 4
	editor_style.corner_radius_top_right = 4
	editor_style.corner_radius_bottom_left = 4
	editor_style.corner_radius_bottom_right = 4
	
	left_editor.add_theme_stylebox_override("normal", editor_style.duplicate())
	right_editor.add_theme_stylebox_override("normal", editor_style.duplicate())



func _load_system_prompt_from_file():
	# Allow users to load system prompts from files
	var file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Load System Prompt"
	file_dialog.add_filter("*.txt ; Text files")
	file_dialog.add_filter("*.md ; Markdown files")
	file_dialog.add_filter("* ; All files")
	
	add_child(file_dialog)
	file_dialog.popup_centered(Vector2(600, 400))
	
	file_dialog.file_selected.connect(
		func(path):
			var file = FileAccess.open(path, FileAccess.READ)
			if file:
				system_prompt_editor.text = file.get_as_text()
				print("Loaded system prompt from: ", path)
			file_dialog.queue_free()
	)



func _save_system_prompt_to_file():
	# Allow users to save system prompts to files
	var file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.title = "Save System Prompt"
	file_dialog.add_filter("*.txt ; Text files")
	file_dialog.add_filter("*.md ; Markdown files")
	
	add_child(file_dialog)
	file_dialog.popup_centered(Vector2(600, 400))
	
	file_dialog.file_selected.connect(
		func(path):
			var file = FileAccess.open(path, FileAccess.WRITE)
			if file:
				file.store_string(system_prompt_editor.text)
				print("Saved system prompt to: ", path)
			file_dialog.queue_free()
	)



func _cleanup_resources():
	# Clean up any lingering resources when switching modes or exiting
	
	# Clean up timers
	if streaming_timer and is_instance_valid(streaming_timer):
		streaming_timer.stop()
	
	# Clean up HTTP requests
	if request_manager and is_instance_valid(request_manager):
		request_manager._current_request.clear()
	
	# Clean up processing indicators
	for editor in [left_editor, right_editor]:
		if is_instance_valid(editor):
			var indicator = editor.get_node_or_null("ProcessingIndicator")
			if indicator:
				indicator.queue_free()
	
	# Reset state variables
	is_processing_ai = false
	is_streaming_response = false
	current_streaming_text = ""
