# juicy_text_animator.gd
class_name JuicyTextAnimator
extends Node

# Colors for the juicy effect
const COLORS = {
	"default": Color("#ffffff"),  # White
	"accent": Color("#699ce8"),   # Light blue
	"emphasis": Color("#ff7085"), # Pink
	"success": Color("#42ffc2")   # Green
}

# Reference to the CodeEdit
var editor: CodeEdit
var current_text: String = ""
var visible_text: String = ""
var last_line: int = 0
var last_column: int = 0
var tween_pool: Array[Tween] = []

func _init(target_editor: CodeEdit) -> void:
	editor = target_editor

func add_text(new_text: String) -> void:
	for character in new_text:
		_animate_character(character)

func _animate_character(character: String) -> void:
	# Get current line and column
	var line = last_line
	var column = last_column
	
	# Handle newline characters
	if character == "\n":
		last_line += 1
		last_column = 0
		editor.insert_text_at_caret("\n")
		return
	
	# Create a RichTextLabel for the character
	var char_label = RichTextLabel.new()
	char_label.custom_minimum_size = Vector2(20, 25)  # Adjust based on font size
	char_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	char_label.text = character
	
	# Position the label at the caret position
	var base_pos = editor.get_caret_draw_pos()
	char_label.position = base_pos
	
	# Add label to editor
	editor.add_child(char_label)
	
	# Create juicy animation
	var tween = create_tween()
	tween.set_parallel(true)
	tween_pool.append(tween)
	
	# Initial state
	char_label.modulate = COLORS.accent
	char_label.scale = Vector2(2, 2)
	char_label.rotation = randf_range(-0.5, 0.5)
	
	# Create the animation sequence
	tween.tween_property(char_label, "modulate", COLORS.default, 0.3)
	tween.tween_property(char_label, "scale", Vector2(1, 1), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(char_label, "rotation", 0.0, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	
	# Add a small random vertical bounce
	var bounce_height = randf_range(-10, -5)
	var original_y = char_label.position.y
	tween.tween_property(char_label, "position:y", original_y + bounce_height, 0.15).set_ease(Tween.EASE_OUT)
	tween.tween_property(char_label, "position:y", original_y, 0.15).set_ease(Tween.EASE_IN)
	
	# Update the actual text in the editor
	editor.insert_text_at_caret(character)
	
	# Clean up after animation
	tween.finished.connect(func():
		char_label.queue_free()
		tween_pool.erase(tween)
	)
	
	# Update last column position
	last_column += 1

func clear() -> void:
	# Clear all active tweens
	for tween in tween_pool:
		if tween.is_valid():
			tween.kill()
	tween_pool.clear()
	
	# Clear all character labels
	for child in editor.get_children():
		if child is RichTextLabel:
			child.queue_free()
	
	# Reset state
	current_text = ""
	visible_text = ""
	last_line = 0
	last_column = 0
	editor.text = ""
