-- lua/markdown_preview/util.lua
local M = {}

local sep = package.config:sub(1, 1)

function M.file_exists(path)
	if not path then
		return false
	end
	local stat = vim.uv.fs_stat(path)
	return stat and stat.type == "file"
end

function M.read_text(path)
	assert(type(path) == "string" and #path > 0, "read_text: path is nil")
	local fd = assert(vim.uv.fs_open(path, "r", 420))
	local stat = assert(vim.uv.fs_fstat(fd))
	local data = assert(vim.uv.fs_read(fd, stat.size, 0))
	assert(vim.uv.fs_close(fd))
	return data
end

---Resolve a file shipped in markdown_preview/assets.
---@param name string
---@return string|nil
function M.resolve_asset(name)
	local rel = "lua/markdown_preview/assets/" .. name
	-- Prefer runtimepath discovery (robust across plugin managers and symlinks)
	local hits = vim.api.nvim_get_runtime_file(rel, false)
	if hits and #hits > 0 then
		return hits[1]
	end

	-- Fallback to path math from this file location
	local info = debug.getinfo(1, "S")
	local this = type(info.source) == "string" and info.source or ""
	if this:sub(1, 1) == "@" then
		this = this:sub(2)
	end
	local module_dir = this:match("(.-)" .. sep .. "util%.lua$")
	if module_dir then
		local candidate = table.concat({ module_dir, "assets", name }, sep)
		if M.file_exists(candidate) then
			return candidate
		end
	end
	return nil
end

---Launch a detached command; true when the process spawned.
---(vim.fn.jobstart raises for a non-executable command, so pcall it.)
local function try_launch(cmd, opts)
	local ok, job = pcall(vim.fn.jobstart, cmd, opts or { detach = true })
	return ok and job > 0
end

---Open a URL in the browser.
---@param url string
---@param browser string|table|nil Optional override. String = browser name/binary.
---  Table = full command (URL appended). nil = system default.
function M.open_in_browser(url, browser)
	local function warn(what)
		vim.notify(
			("Markdown Preview: %s.\nOpen manually: %s"):format(what, url),
			vim.log.levels.WARN
		)
	end

	if browser then
		local cmd
		local opts = { detach = true }
		if type(browser) == "table" then
			cmd = vim.list_extend(vim.deepcopy(browser), { url })
		elseif vim.fn.has("mac") == 1 then
			-- On macOS, `open -a` resolves app names like "Firefox" or
			-- "Google Chrome". The spawn succeeds even when the app doesn't
			-- exist (`open` itself exits non-zero), so check the exit code.
			cmd = { "open", "-a", browser, url }
			opts.on_exit = function(_, code)
				if code ~= 0 then
					vim.schedule(function()
						warn(('configured browser "%s" could not be opened'):format(browser))
					end)
				end
			end
		else
			cmd = { browser, url }
		end
		if not try_launch(cmd, opts) then
			warn(("could not launch configured browser (%s)")
				:format(type(browser) == "table" and browser[1] or browser))
		end
		return
	end

	local ok, _, err = pcall(vim.ui.open, url)
	if not ok then err = _ end
	if err then warn(tostring(err)) end
end

return M
