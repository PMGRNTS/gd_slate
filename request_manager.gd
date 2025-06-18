# request_manager.gd
class_name AIRequestManager
extends Node

# Add signals for our request system
signal request_completed(response: String)
signal request_queued(position: int)
signal request_started
signal error_occurred(message: String)

# Updated constants for current Claude API
const API_URL = "https://api.anthropic.com/v1/messages"
const API_VERSION = "2023-06-01"  # This is still correct
const MODEL_NAME = "claude-3-5-sonnet-20241022"  # Updated to current model
const MAX_REQUESTS_PER_MINUTE = 20

# Private variables for request management
var _request_queue: Array = []
var _request_history: Array = []
var _current_request: Dictionary = {}
var _request_timer: Timer
var _response_cache: Dictionary = {}
var _http_request: HTTPRequest
const MAX_CACHE_SIZE = 50

# Parent node reference for API key access
var _parent_node: Node
var _error_handler: AIErrorHandler
var _api_key: String = ""

# Add streaming state tracking
var _current_response_buffer: String = ""
var _is_streaming: bool = false

func _ready():
	# Initialize timers for request management
	_request_timer = Timer.new()
	_request_timer.wait_time = 60.0  # Clear history every minute
	_request_timer.timeout.connect(_clear_old_requests)
	add_child(_request_timer)
	_request_timer.start()
	
	# Initialize HTTP request node for API communication
	_http_request = HTTPRequest.new()
	_http_request.use_threads = true
	_http_request.request_completed.connect(_on_http_request_completed)
	add_child(_http_request)
	
	# Store reference to parent node for API key access
	_parent_node = get_parent()
	
	# Initialize error handler reference
	_error_handler = get_node_or_null("/root/Control").error_handler
	if not _error_handler:
		push_error("Error handler not found!")
		return

# Create a setup function to initialize dependencies
func setup(error_handler_ref: AIErrorHandler) -> void:
	_error_handler = error_handler_ref

# Updated queue_request function with better error handling
func queue_request(code: String, system_prompt: String) -> void:
	if _error_handler:
		_error_handler.handle_error("debug", {"message": "Queue request started", "details": "Code length: " + str(code.length())})
	
	# Check cache before making a new request
	var cached_response = _get_cached_response(code, system_prompt)
	if not cached_response.is_empty():
		_error_handler.log_debug("Cache hit, returning cached response")
		request_completed.emit(cached_response)
		return
	
	_error_handler.log_debug("Cache miss, proceeding with request")
	var request = {
		"code": code,
		"system_prompt": system_prompt,
		"timestamp": Time.get_unix_time_from_system()
	}
	
	_request_queue.push_back(request)
	request_queued.emit(_request_queue.size())
	_process_next_request()

func _process_next_request() -> void:
	if _current_request or _request_queue.is_empty():
		return
		
	_clean_request_history()
	if _request_history.size() >= MAX_REQUESTS_PER_MINUTE:
		var wait_time = 60.0 - (Time.get_unix_time_from_system() - _request_history[0]["timestamp"])
		error_occurred.emit("Rate limit reached. Please wait %d seconds." % wait_time)
		return
	
	_current_request = _request_queue.pop_front()
	request_started.emit()
	_make_api_request(_current_request)

func _make_api_request(request: Dictionary) -> void:
	if _api_key.is_empty():
		_error_handler.handle_error("api_key")
		_current_request = {}
		return
		
	_error_handler.log_debug("Making API request", {
		"has_api_key": str(not _api_key.is_empty()),
		"api_version": API_VERSION
	})
	
	var headers = [
		"x-api-key: " + _api_key,
		"anthropic-version: " + API_VERSION,
		"content-type: application/json"
	]
	
	# Create the messages array with just the user message
	var messages = [
		{
			"role": "user",
			"content": request["code"]
		}
	]
	
	# Create the request body with updated parameters
	var body = {
		"model": MODEL_NAME,
		"messages": messages,
		"max_tokens": 4096,
		"stream": true,
		"temperature": 0.7  # Add some creativity for code suggestions
	}
	
	# Add system prompt if it exists
	if not request["system_prompt"].is_empty():
		body["system"] = request["system_prompt"]
	
	print("Request body:", JSON.stringify(body))  # Debug print
	
	# Reset streaming state
	_current_response_buffer = ""
	_is_streaming = false
	
	var error = _http_request.request(API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		_error_handler.handle_error("network", {"details": str(error)})
		_current_request = {}
		return
		
	_error_handler.log_debug("Request sent successfully")

# Improved response handling for current Claude API format
func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	print("=== Starting response processing ===")
	print("Response code:", response_code)
	print("Result:", result)
	
	# Handle different response codes
	if response_code != 200:
		var error_msg = "API request failed with code: " + str(response_code)
		if response_code == 401:
			error_msg = "Invalid API key. Please check your settings."
		elif response_code == 429:
			error_msg = "Rate limit exceeded. Please try again later."
		elif response_code >= 500:
			error_msg = "Server error. Please try again later."
		
		error_occurred.emit(error_msg)
		_current_request = {}
		return
	
	var response_text = body.get_string_from_utf8()
	print("Raw response text (first 200 chars):", response_text.substr(0, 200))
	
	var lines = response_text.split("\n")
	var complete_response = ""
	
	for line in lines:
		if line.is_empty():
			continue
			
		print("Processing line:", line)
		
		# Check if it's a data line for server-sent events
		if line.begins_with("data: "):
			var json_str = line.substr(6)  # Remove "data: " prefix
			
			# Handle stream end marker
			if json_str == "[DONE]":
				print("Found end of stream marker")
				_finish_streaming_response(complete_response)
				return
				
			print("Parsing JSON:", json_str)
			
			var json = JSON.new()
			var parse_result = json.parse(json_str)
			
			if parse_result == OK:
				var response_data = json.get_data()
				print("Response data:", response_data)
				
				# Handle different types of streaming chunks
				if response_data.has("type"):
					match response_data["type"]:
						"message_start":
							_is_streaming = true
							print("Message started")
						"content_block_start":
							print("Content block started")
						"content_block_delta":
							if response_data.has("delta") and response_data["delta"].has("text"):
								var chunk = response_data["delta"]["text"]
								print("Found text chunk:", chunk)
								complete_response += chunk
								request_completed.emit(chunk)
								_error_handler.log_debug("Emitted chunk", {"length": str(chunk.length())})
						"content_block_stop":
							print("Content block stopped")
						"message_delta":
							# Handle usage information if needed
							if response_data.has("usage"):
								print("Usage info:", response_data["usage"])
						"message_stop":
							print("Message stopped")
							_finish_streaming_response(complete_response)
							return
	
	# If we get here without proper streaming, try to parse as complete response
	if not _is_streaming:
		_handle_complete_response(response_text)

func _finish_streaming_response(complete_response: String) -> void:
	# Cache the complete response
	if _current_request.has("code") and _current_request.has("system_prompt"):
		_cache_response(_current_request["code"], _current_request["system_prompt"], complete_response)
	
	# Add to request history
	_request_history.push_back(_current_request)
	_current_request = {}
	_is_streaming = false
	
	# Process next request if any
	_process_next_request()

func _handle_complete_response(response_text: String) -> void:
	# Fallback for non-streaming responses
	var json = JSON.new()
	var parse_result = json.parse(response_text)
	
	if parse_result == OK:
		var response_data = json.get_data()
		if response_data.has("content") and response_data["content"].size() > 0:
			var content = response_data["content"][0]
			if content.has("text"):
				var text = content["text"]
				request_completed.emit(text)
				_finish_streaming_response(text)
				return
	
	# If parsing fails, emit error
	error_occurred.emit("Failed to parse API response")
	_current_request = {}

func _clear_old_requests() -> void:
	var current_time = Time.get_unix_time_from_system()
	_request_history = _request_history.filter(
		func(request): return current_time - request["timestamp"] < 60.0
	)

func _clean_request_history() -> void:
	var current_time = Time.get_unix_time_from_system()
	_request_history = _request_history.filter(
		func(request): return current_time - request["timestamp"] < 60.0
	)

func _cache_response(code: String, system_prompt: String, response: String) -> void:
	var cache_key = _generate_cache_key(code, system_prompt)
	
	if _response_cache.size() >= MAX_CACHE_SIZE:
		var oldest_key = _response_cache.keys()[0]
		_response_cache.erase(oldest_key)
	
	_response_cache[cache_key] = {
		"response": response,
		"timestamp": Time.get_unix_time_from_system()
	}

func _get_cached_response(code: String, system_prompt: String) -> String:
	var cache_key = _generate_cache_key(code, system_prompt)
	var cached = _response_cache.get(cache_key)
	
	if cached and Time.get_unix_time_from_system() - cached["timestamp"] < 3600:
		return cached["response"]
	return ""

func _generate_cache_key(code: String, system_prompt: String) -> String:
	return code.sha256_text() + system_prompt.sha256_text()

# Add this new function
func set_api_key(key: String) -> void:
	_api_key = key
