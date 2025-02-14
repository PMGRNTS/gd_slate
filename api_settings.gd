# api_settings.gd
class_name APISettings
extends Window

signal api_key_saved(key: String)

# UI Elements
var api_key_input: LineEdit
var status_label: Label
var save_button: Button
var api_key: String = ""

# Constants for encryption
const SETTINGS_PATH = "user://api_settings.save"
const ENCRYPTION_KEY = "gd_slate_key"  # Simple encryption key for basic protection

# Theme colors - matching main app theme
const COLORS = {
	"surface": Color("#333b4f"),        # Surface color
	"code_background": Color("#333b4f"), # Code editor background
	"code_text": Color("#ffffff"),      # Code text color
	"on_surface": Color("#699ce8"),     # Text on surface
	"error": Color("#ff7085"),          # Error text color
	"button_normal": Color("#699ce8"),  # Button normal state
	"button_hover": Color("#7cade8"),   # Button hover state
	"link": Color("#89cff0")            # Link color
}

func _ready() -> void:
	# Window setup
	title = "API Settings"
	size = Vector2(500, 220)
	exclusive = true
	unresizable = true
	transient = true
	
	# Set window background color
	var window_style = StyleBoxFlat.new()
	window_style.bg_color = COLORS.surface
	add_theme_stylebox_override("panel", window_style)
	
	# Create main container
	var main_container = VBoxContainer.new()
	main_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_container.add_theme_constant_override("separation", 16)
	add_child(main_container)
	
	# Add margins
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	main_container.add_child(margin)
	
	# Create content container
	var content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)
	
	# Add description
	var description = Label.new()
	description.text = "Enter your Anthropic API key to use AI features."
	description.add_theme_color_override("font_color", COLORS.code_text)
	content.add_child(description)
	
	# Add link-style label for the website
	var link_label = Label.new()
	link_label.text = "Get your API key from console.anthropic.com"
	link_label.add_theme_color_override("font_color", COLORS.link)
	content.add_child(link_label)
	
	# Create API key input with styling
	api_key_input = LineEdit.new()
	api_key_input.placeholder_text = "sk-ant-..."
	api_key_input.secret = true
	api_key_input.custom_minimum_size.x = 300
	
	# Style the input field
	var input_style = StyleBoxFlat.new()
	input_style.bg_color = COLORS.code_background
	input_style.corner_radius_top_left = 4
	input_style.corner_radius_top_right = 4
	input_style.corner_radius_bottom_left = 4
	input_style.corner_radius_bottom_right = 4
	input_style.content_margin_left = 8
	input_style.content_margin_right = 8
	input_style.content_margin_top = 8
	input_style.content_margin_bottom = 8
	
	api_key_input.add_theme_stylebox_override("normal", input_style)
	api_key_input.add_theme_color_override("font_color", COLORS.code_text)
	content.add_child(api_key_input)
	
	# Create status label
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", COLORS.error)
	status_label.hide()
	content.add_child(status_label)
	
	# Add spacer
	var spacer = Control.new()
	spacer.custom_minimum_size.y = 10
	content.add_child(spacer)
	
	# Create buttons container
	var button_container = HBoxContainer.new()
	button_container.size_flags_horizontal = Control.SIZE_FILL
	button_container.alignment = BoxContainer.ALIGNMENT_END
	content.add_child(button_container)
	
	# Style for buttons
	var button_style = StyleBoxFlat.new()
	button_style.bg_color = COLORS.button_normal
	button_style.corner_radius_top_left = 4
	button_style.corner_radius_top_right = 4
	button_style.corner_radius_bottom_left = 4
	button_style.corner_radius_bottom_right = 4
	
	# Create cancel button
	var cancel_button = Button.new()
	cancel_button.text = "Cancel"
	cancel_button.custom_minimum_size.x = 80
	cancel_button.pressed.connect(_on_cancel_pressed)
	cancel_button.add_theme_stylebox_override("normal", button_style.duplicate())
	button_container.add_child(cancel_button)
	
	# Add button spacing
	var button_spacer = Control.new()
	button_spacer.custom_minimum_size.x = 10
	button_container.add_child(button_spacer)
	
	# Create save button
	save_button = Button.new()
	save_button.text = "Save"
	save_button.custom_minimum_size.x = 80
	save_button.pressed.connect(_on_save_pressed)
	save_button.add_theme_stylebox_override("normal", button_style.duplicate())
	button_container.add_child(save_button)
	
	# Load existing API key if available
	_load_api_key()
	
	# Center the window when it opens
	about_to_popup.connect(_center_window)

func _center_window() -> void:
	# Convert viewport size to Vector2 for proper calculation
	var viewport_size = Vector2(get_viewport().get_visible_rect().size)
	# Convert our window size to Vector2 as well
	var window_size = Vector2(size)
	# Calculate center position
	position = ((viewport_size - window_size) / 2).floor()

func _load_api_key() -> void:
	if FileAccess.file_exists(SETTINGS_PATH):
		var file = FileAccess.open_encrypted_with_pass(SETTINGS_PATH, FileAccess.READ, ENCRYPTION_KEY)
		if file:
			api_key = file.get_line()
			api_key_input.text = api_key

func save_api_key(key: String) -> void:
	var file = FileAccess.open_encrypted_with_pass(SETTINGS_PATH, FileAccess.WRITE, ENCRYPTION_KEY)
	if file:
		file.store_line(key)
		api_key = key

func _validate_api_key(key: String) -> bool:
	# Basic validation for Anthropic API key format
	return key.begins_with("sk-ant-") and key.length() >= 32

func _on_save_pressed() -> void:
	var key = api_key_input.text.strip_edges()
	
	if _validate_api_key(key):
		save_api_key(key)
		api_key_saved.emit(key)
		hide()
		status_label.hide()
	else:
		status_label.text = "Invalid API key format. Key should start with 'sk-ant-'"
		status_label.show()

func _on_cancel_pressed() -> void:
	hide()

func get_api_key() -> String:
	return api_key

func clear_api_key() -> void:
	api_key = ""
	api_key_input.text = ""
	if FileAccess.file_exists(SETTINGS_PATH):
		DirAccess.remove_absolute(SETTINGS_PATH)
