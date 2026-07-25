local uv = vim.loop
local ls_util = require("live_server.util")

local M = {}

local function query_param(query, key)
	for part in query:gmatch("[^&]+") do
		local name, value = part:match("^([^=]+)=(.*)$")
		if name == key then return value end
	end
	return nil
end

local function respond(sock, status, body)
	local response = table.concat({
		("HTTP/1.1 %s\r\n"):format(status),
		"Content-Type: text/plain\r\n",
		"Access-Control-Allow-Origin: *\r\n",
		("Content-Length: %d\r\n"):format(#body),
		"Connection: close\r\n",
		"\r\n",
		body,
	})
	sock:write(response, function()
		pcall(function() sock:shutdown() end)
		pcall(function() sock:close() end)
	end)
end

function M.start(host, token, on_click)
	local server = assert(uv.new_tcp())
	local bind_host = host == "localhost" and "127.0.0.1" or host
	assert(server:bind(bind_host, 0))
	assert(server:listen(16, function(err)
		if err then return end
		local sock = uv.new_tcp()
		if not sock then return end
		server:accept(sock)

		local request = ""
		sock:read_start(function(read_err, chunk)
			if read_err or not chunk then
				pcall(function() sock:close() end)
				return
			end
			request = request .. chunk
			if #request > 8192 then
				sock:read_stop()
				respond(sock, "413 Payload Too Large", "request too large")
				return
			end
			if not request:find("\r\n\r\n", 1, true) then return end
			sock:read_stop()

			local target = request:match("^GET%s+([^%s]+)%s+HTTP/")
			local path, query
			if target then
				path, query = target:match("^([^?]+)%??(.*)$")
			end
			local line = query and query_param(query, "line")
			local supplied = query and query_param(query, "t")

			if path ~= "/__markdown_preview/click"
				or not line
				or not line:match("^%d+$")
				or not supplied
				or not ls_util.secure_compare(vim.uri_decode(supplied), token)
			then
				respond(sock, "403 Forbidden", "forbidden")
				return
			end

			vim.schedule(function() on_click(tonumber(line)) end)
			respond(sock, "204 No Content", "")
		end)
	end))

	return {
		server = server,
		port = assert(server:getsockname()).port,
	}
end

function M.stop(instance)
	if instance and instance.server then
		pcall(function() instance.server:close() end)
	end
end

return M
