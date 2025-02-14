# error_handler.gd
class_name AIErrorHandler
extends Node

signal error_occurred(message: String, level: int)
signal error_cleared

enum ErrorLevel {
	INFO,
	WARNING,
	ERROR,
	CRITICAL
}

const ERROR_MESSAGES = {
	"rate_limit": "Rate limit reached. Please try again in {time} seconds.",
	"api_key": "Invalid API key. Please check your API key in settings.",
	"network": "Network error: {details}. Please check your internet connection.",
	"timeout": "Request timed out after {timeout} seconds. Please try again.",
	"parse_error": "Failed to parse API response. Please try again or contact support.",
	"server_error": "Server error ({code}): {message}",
	"quota_exceeded": "API quota exceeded. Please check your usage limits.",
	"invalid_request": "Invalid request: {details}"
}

func log_debug(message: String, context: Dictionary = {}) -> void:
	# Use our existing error handling infrastructure for debug logs
	handle_error("debug", {"message": message, "context": str(context)}, true)

# Modify our handle_error function to accept a debug parameter
func handle_error(error_type: String, context: Dictionary = {}, is_debug: bool = false) -> void:
	var message = ERROR_MESSAGES.get(error_type, "An unknown error occurred")
	
	# Special handling for debug messages
	if is_debug:
		message = context.get("message", "Debug message")
		if not context.get("context").is_empty():
			message += " | Context: " + context.get("context")
	else:
		# Normal error message formatting
		for key in context:
			message = message.replace("{" + key + "}", str(context[key]))
	
	var level = _get_error_level(error_type)
	_log_error(error_type, message, level)
	error_occurred.emit(message, level)

func _get_error_level(error_type: String) -> int:
	match error_type:
		"rate_limit", "quota_exceeded":
			return ErrorLevel.WARNING
		"api_key", "network", "timeout":
			return ErrorLevel.ERROR
		"server_error":
			return ErrorLevel.CRITICAL
		_:
			return ErrorLevel.INFO

func _log_error(error_type: String, message: String, level: int) -> void:
	var timestamp = Time.get_datetime_string_from_system()
	var level_str = ErrorLevel.keys()[level]
	print("[%s] [%s] %s: %s" % [timestamp, level_str, error_type, message])
