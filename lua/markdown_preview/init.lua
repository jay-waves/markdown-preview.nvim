-- lua/markdown_preview/init.lua
local util = require("markdown_preview.util")
local session_runtime = require("live_server.session")
local html = require("live_server.html")

local M = {}
local AUTO_REFRESH_EVENTS = { "TextChanged", "TextChangedI", "BufWritePost" }
local BOTTOM_PADDING = 0.5

local function supported_file(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr):lower()
	return name:match("%.md$") ~= nil or name:match("%.mmd$") ~= nil
end

M.config = {
	port = 0, -- 0 = auto
	host = "127.0.0.1", -- bind address; "0.0.0.0" for network access (e.g. over SSH)
	open_browser = true,

	-- nil = system default browser. String for app/binary name (e.g. "Firefox",
	-- "google-chrome"). Table for full command with args (URL is appended).
	-- On macOS, string values are passed via `open -a <name>`.
	browser = nil,

	-- Path or ordered list of CSS files injected after the bundled styles.
	-- Supports ~ and $VARS. "" or {} = disabled.
	custom_css = "",

	auto_refresh = true,
	debounce_ms = 300,

	-- After the first :MarkdownPreview, reuse the same server and browser tab
	-- when entering another Markdown buffer. Non-Markdown buffers are ignored.
	follow_current_buffer = true,

	-- Load ELK layout engine for mermaid diagrams (requires internet; adds ~800 KB).
	-- Enables %%{init: {"layout": "elk"}}%% in diagrams.
	mermaid_elk = false,

	-- Opening or retargeting always scrolls to the current Markdown line.
	-- Later cursor movement is followed only when scroll_sync is enabled.
	scroll_sync = false, -- sync browser scroll to cursor position
	click_to_nvim = true, -- click a rendered block to scroll Neovim to its source

	-- "auto" follows the OS color scheme; "dark" or "light" forces a theme
	default_theme = "auto",

	-- Render raw HTML embedded in markdown (GitHub-like). Set false when
	-- previewing untrusted markdown: raw HTML runs inside the preview page.
	allow_raw_html = true,

	-- YAML front matter (--- ... --- at the top of the file):
	-- "code"  = render its source as a syntax-highlighted YAML code block
	-- "hide"  = strip it entirely
	-- "raw"   = leave it in the document (renders as markdown)
	yaml_mode = "code",

	hooks = {
		-- fun(url: string)|nil — called after preview starts; receives the preview URL
		on_start = nil,
		-- fun()|nil — called after preview stops
		on_stop = nil,
	},
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- One private session owns the server, document, and callbacks.
local session

---------------------------------------------------------------------------
-- Index HTML
---------------------------------------------------------------------------

local function render_index(token)
	local src = util.resolve_asset("index.html")
	if not src then error("Could not locate markdown_preview/assets/index.html") end

	local yaml_mode = M.config.yaml_mode
	if yaml_mode == "panel" then yaml_mode = "code" end -- compatibility with older configs
	if yaml_mode ~= "code" and yaml_mode ~= "hide" and yaml_mode ~= "raw" then yaml_mode = "code" end
	local custom_styles = html.styles(M.config.custom_css, {
		on_error = function(index, value, resolved)
			local detail = resolved and " not readable: " .. resolved or " must be a file path"
			vim.notify("Markdown Preview: custom_css[" .. index .. "]" .. detail, vim.log.levels.WARN)
		end,
	})
	return html.build({
		template = src,
		replacements = {
			["__MARKDOWN_THEME_CSS__"] = { file = assert(util.resolve_asset("theme.css"), "Missing theme.css") },
			["__HIGHLIGHT_THEME_CSS__"] = { file = assert(util.resolve_asset("highlight.css"), "Missing highlight.css") },
			["__MERMAID_ELK__"] = M.config.mermaid_elk and "true" or "false",
			["<!-- __NVIM_ADAPTER__ -->"] = '<script src="https://cdn.jsdelivr.net/npm/morphdom@2/dist/morphdom-umd.min.js"></script>\n'
				.. '<script src="nvim-preview.js"></script>',
			["__THEME__"] = M.config.default_theme,
			["__ALLOW_HTML__"] = M.config.allow_raw_html ~= false and "true" or "false",
			["__YAML_MODE__"] = yaml_mode,
		},
		attributes = { html = {
			["data-bottom-padding"] = BOTTOM_PADDING,
			["data-live-token"] = token,
			["data-click-to-nvim"] = M.config.click_to_nvim and "true" or "false",
		} },
		append = custom_styles ~= "" and { head = custom_styles .. "\n" } or nil,
	})
end

---------------------------------------------------------------------------
-- Content writing (.md or .mmd)
---------------------------------------------------------------------------

---Get the full content of a Markdown or Mermaid file.
---@param bufnr integer
---@return string
local function get_content(bufnr)
	local text
	local name = vim.api.nvim_buf_get_name(bufnr):lower()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if name:match("%.mmd$") then
		text = "```mermaid\n" .. table.concat(lines, "\n") .. "\n```\n"
	elseif name:match("%.md$") then
		text = table.concat(lines, "\n")
	else
		error("Only .md and .mmd files are supported")
	end

	return text
end

local function asset_context(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local src_dir = name ~= "" and vim.fs.normalize(vim.fs.dirname(name)) or nil
	if not src_dir or src_dir == "" then return nil, "" end

	-- Match :pwd, including :lcd/:tcd for the active window. Only widen the
	-- boundary when the Markdown directory is actually inside that directory.
	local cwd = vim.fs.normalize(vim.fn.getcwd())
	local root_cmp = package.config:sub(1, 1) == "\\" and cwd:lower() or cwd
	local src_cmp = package.config:sub(1, 1) == "\\" and src_dir:lower() or src_dir
	if src_cmp == root_cmp then return cwd, "" end
	-- vim.fs.normalize() uses forward slashes on Windows too. Appending
	-- package.config's "\\" here makes e.g. E:/project\\ fail to match
	-- E:/project/docs, so a refreshed :pwd is silently ignored on Windows.
	local root_with_sep = root_cmp
	if not root_with_sep:match("/$") then
		root_with_sep = root_with_sep .. "/"
	end
	if src_cmp:sub(1, #root_with_sep) == root_with_sep then
		local prefix = src_dir:sub(#cwd + 1):gsub("^[/\\]+", ""):gsub("\\", "/")
		return cwd, prefix
	end
	return src_dir, ""
end

local function initial_scroll(bufnr)
	local winid = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_get_current_win()
		or vim.fn.win_findbuf(bufnr)[1]
	if not winid then return nil end
	return {
		id = tostring(vim.uv.hrtime()) .. ":" .. tostring(vim.fn.getpid()),
		line = vim.api.nvim_win_get_cursor(winid)[1] - 1,
		total = vim.api.nvim_buf_line_count(bufnr),
	}
end

local function update_document(s, bufnr, text, reset)
	local root, prefix = asset_context(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	local title = name ~= "" and vim.fn.fnamemodify(name, ":t") or "Markdown Preview"
	local previous = s.document
	if not reset and previous and previous.content == text and previous.title == title
		and previous.assetPrefix == prefix and s.asset_root == root then return end
	local position = previous and previous.initialScroll
	if reset then position = initial_scroll(bufnr) end
	if s.bufnr ~= bufnr then s.last_scroll_line = nil end
	s.bufnr, s.asset_root = bufnr, root
	s.document = {
		content = text,
		assetPrefix = prefix,
		title = title,
		initialScroll = position,
	}
	if s.preview then s.preview:send("reload") end
end

---------------------------------------------------------------------------
-- Refresh logic
---------------------------------------------------------------------------

local function debounced_refresh(s)
	local bufnr = s.bufnr
	s.timer = s.timer or assert(vim.uv.new_timer())
	local timer = s.timer
	timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(function()
		if session == s and s.bufnr == bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			local ok, text = pcall(get_content, bufnr)
			if ok then update_document(s, bufnr, text, false) end
		end
	end))
end

---------------------------------------------------------------------------
-- Scroll sync (line-based)
---------------------------------------------------------------------------

--- Send cursor line to browser for scroll sync.
local function send_scroll_sync(s)
	if not M.config.scroll_sync then return end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
	local pending = s.suppress_scroll_sync
	if pending then
		-- A preview click changes the Neovim cursor programmatically. Consume
		-- that CursorMoved event instead of sending the click back to the page.
		s.suppress_scroll_sync = nil
		if pending.bufnr == s.bufnr and pending.line == cursor_line then
			s.last_scroll_line = cursor_line
			return
		end
	end
	if cursor_line == s.last_scroll_line then return end
	s.last_scroll_line = cursor_line
	local total = vim.api.nvim_buf_line_count(s.bufnr)
	local payload = vim.json.encode({ line = cursor_line - 1, total = total })
	if s.preview then s.preview:send("scroll", payload) end
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

local function set_autocmds(s)
	s.group = vim.api.nvim_create_augroup("MarkdownPreviewAuto", { clear = true })

	if M.config.auto_refresh then
		vim.api.nvim_create_autocmd(AUTO_REFRESH_EVENTS, {
			group = s.group,
			callback = function(args)
				if session == s and args.buf == s.bufnr then debounced_refresh(s) end
			end,
			desc = "Markdown Preview auto-refresh (debounced)",
		})

		-- :cd, :lcd, and :tcd can widen or narrow the root used for relative
		-- assets without changing the Markdown buffer. DirChanged is not a
		-- buffer-local event, so refresh the active preview buffer explicitly.
		vim.api.nvim_create_autocmd("DirChanged", {
			group = s.group,
			callback = function()
				if session == s then debounced_refresh(s) end
			end,
			desc = "Markdown Preview: refresh relative assets after cwd changes",
		})
	end

	if M.config.scroll_sync then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			group = s.group,
			callback = function(args)
				if session == s and args.buf == s.bufnr then send_scroll_sync(s) end
			end,
			desc = "Markdown Preview scroll sync",
		})
	end

	if M.config.follow_current_buffer then
		vim.api.nvim_create_autocmd("BufEnter", {
			group = s.group,
			callback = function(args)
				if session ~= s
					or args.buf == s.bufnr
					or not supported_file(args.buf)
				then
					return
				end

				-- Follow after BufEnter finishes; callbacks belong to this session.
				vim.schedule(function()
					if session == s and vim.api.nvim_get_current_buf() == args.buf then
						M.start()
					end
				end)
			end,
			desc = "Markdown Preview: follow current Markdown buffer",
		})
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

local function scroll_nvim_to_line(s, line)
	local bufnr = s.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
	local wins = vim.fn.win_findbuf(bufnr)
	if #wins == 0 then return end

	local winid = wins[1]
	if vim.api.nvim_get_current_buf() == bufnr then
		winid = vim.api.nvim_get_current_win()
	end
	local last_line = vim.api.nvim_buf_line_count(bufnr)
	local target = math.max(1, math.min(last_line, line + 1))
	s.suppress_scroll_sync = { bufnr = bufnr, line = target }
	pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
	pcall(vim.api.nvim_win_call, winid, function()
		vim.cmd("normal! zz")
	end)
end

function M.start()
	local bufnr = vim.api.nvim_get_current_buf()
	local ok_content, text = pcall(get_content, bufnr)
	if not ok_content then
		vim.notify("Markdown Preview: " .. tostring(text), vim.log.levels.ERROR)
		return
	end
	local s = session or {}
	update_document(s, bufnr, text, true)

	-- Start the embedded preview server if not already running.
	if not s.server then
		local port = M.config.port
		local asset_dir = vim.fs.dirname(assert(util.resolve_asset("index.html")))
		s.token = s.token or session_runtime.token(16)
		local index = render_index(s.token)
		local ok, inst = pcall(session_runtime.start, {
			token = s.token,
			port = port,
			host = M.config.host,
			root = asset_dir,
			headers = { ["Cache-Control"] = "no-cache" },
			live = { enabled = false, inject_script = false },
			browser = M.config.browser,
			browser_title = "Markdown Preview",
			routes = {
				["/"] = function()
					if not index then return "Preview is not ready", 503 end
					return index, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
				end,
				["/document"] = function()
					return vim.json.encode(s.document), 200, { ["Content-Type"] = "application/json" }
				end,
			},
			-- Resolve relative image paths against the source file's dir
			-- (issue #17). Read current in-memory state per request.
			asset_root = function()
				return s.asset_root
			end,
			on_event = function(event, data)
				if session ~= s or event ~= "markdown-click" or not M.config.click_to_nvim then return end
				local ok_decode, value = pcall(vim.json.decode, data)
				if ok_decode and type(value) == "table" and type(value.line) == "number"
					and value.line >= 0 and value.line % 1 == 0 then
					scroll_nvim_to_line(s, value.line)
				end
			end,
		})
		if not ok then
			vim.notify(
				("Markdown Preview: failed to start server (port %s) — %s"):format(tostring(port), tostring(inst)),
				vim.log.levels.ERROR
			)
			return
		end
		s.preview = inst
		s.server = inst.server
		s.token = inst.token
		s.url = inst.url
		session = s
		set_autocmds(s)

		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(s.url)
		end
	end
	-- Coalesce open requests and discard callbacks belonging to a stopped session.
	if session == s and M.config.open_browser and not s.open_pending
			and not s.preview:connected() then
		s.open_pending = true
		vim.defer_fn(function()
			s.open_pending = nil
			if session == s and not s.preview:connected() then
				s.preview:open()
			end
		end, 200)
	end
end

function M.stop()
	local s = session
	if not s then return end
	session = nil
	if s.timer then
		s.timer:stop()
		s.timer:close()
	end
	if s.group then
		vim.api.nvim_del_augroup_by_id(s.group)
	end
	if s.server then
		if s.preview then s.preview:stop(true, "markdown-preview-close") end
	end

	if type(M.config.hooks.on_stop) == "function" then
		M.config.hooks.on_stop()
	end
end

return M
