# request_manager.gd
class_name AIRequestManager
extends Node

# Add signals for our request system
signal request_completed(response: String)
signal request_queued(position: int)
signal request_started
signal error_occurred(message: String)

# Constants for API configuration
const API_URL = "https://api.anthropic.com/v1/messages"
const API_VERSION = "2023-06-01"
const MODEL_NAME = "claude-3-5-sonnet-20241022"
const MAX_REQUESTS_PER_MINUTE = 20
#const REQUEST_TIMEOUT = 300.0  # seconds

# Private variables for request management
var _request_queue: Array = []
var _request_history: Array = []
var _current_request: Dictionary = {}
var _request_timer: Timer
var _timeout_timer: Timer
var _response_cache: Dictionary = {}
var _http_request: HTTPRequest  # Add HTTP request node
const MAX_CACHE_SIZE = 50

# Parent node reference for API key access
var _parent_node: Node
var _error_handler: AIErrorHandler
var _api_key: String = ""



func _ready():
	# Initialize timers for request management
	_request_timer = Timer.new()
	_request_timer.wait_time = 60.0  # Clear history every minute
	_request_timer.timeout.connect(_clear_old_requests)
	add_child(_request_timer)
	_request_timer.start()
	
	#_timeout_timer = Timer.new()
	#_timeout_timer.one_shot = true
	#_timeout_timer.timeout.connect(_handle_timeout)
	#add_child(_timeout_timer)
	
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

# Modify the queue_request function to safely use the error handler
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
	#_timeout_timer.start(REQUEST_TIMEOUT)
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
	
	# Create the request body
	var body = {
		"model": MODEL_NAME,
		"messages": messages,
		"max_tokens": 4096,
		"stream": true
	}
	
	# Add system prompt if it exists
	if not request["system_prompt"].is_empty():
		body["system"] = request["system_prompt"]
	
	print("Request body:", JSON.stringify(body))  # Debug print
	
	var error = _http_request.request(API_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		_error_handler.handle_error("network", {"details": str(error)})
		_current_request = {}
		return
		
	_error_handler.log_debug("Request sent successfully")



func _on_http_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	print("=== Starting response processing ===")
	
	var response_text = body.get_string_from_utf8()
	print("Raw response text (first 100 chars):", response_text.substr(0, 100))
	
	var lines = response_text.split("\n")
	for line in lines:
		if line.is_empty():
			continue
			
		print("Processing line:", line)
		
		# Check if it's a data line
		if line.begins_with("data: "):
			var json_str = line.substr(6)  # Remove "data: " prefix
			
			# Handle stream end marker
			if json_str == "[DONE]":
				print("Found end of stream marker")
				continue
				
			print("Parsing JSON:", json_str)
			
			var json = JSON.new()
			var parse_result = json.parse(json_str)
			
			if parse_result == OK:
				var response_data = json.get_data()
				print("Response data:", response_data)
				
				# For Claude 3, the content is in delta.text for streaming
				if response_data.has("delta") and response_data["delta"].has("text"):
					var chunk = response_data["delta"]["text"]
					print("Found text chunk:", chunk)
					request_completed.emit(chunk)
					_error_handler.log_debug("Emitted chunk", {"length": str(chunk.length())})

#func _handle_timeout() -> void:
	#if _current_request:
		#error_occurred.emit("Request timed out after %d seconds" % REQUEST_TIMEOUT)
		#_current_request = {}
		#_process_next_request()

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
