-- lua/markdown_preview/init.lua
local ts = require("markdown_preview.ts")
local util = require("markdown_preview.util")
local ls_server = require("live_server.server")
local ls_util = require("live_server.util")

local M = {}

M.config = {
	port = 0, -- 0 = auto
	host = "127.0.0.1", -- bind address; "0.0.0.0" for network access (e.g. over SSH)
	open_browser = true,

	-- nil = system default browser. String for app/binary name (e.g. "Firefox",
	-- "google-chrome"). Table for full command with args (URL is appended).
	-- On macOS, string values are passed via `open -a <name>`.
	browser = nil,

	-- Path or ordered list of paths to CSS files injected after the bundled
	-- styles. Supports ~ and $VARS. "" or {} = disabled.
	custom_css = "",

	auto_refresh = true,
	auto_refresh_events = { "TextChanged", "TextChangedI", "BufWritePost" },
	debounce_ms = 300,

	-- After the first :MarkdownPreview, reuse the same server and browser tab
	-- when entering another Markdown buffer. Non-Markdown buffers are ignored.
	follow_current_buffer = true,

	-- Load ELK layout engine for mermaid diagrams (requires internet; adds ~800 KB).
	-- Enables %%{init: {"layout": "elk"}}%% in diagrams.
	mermaid_elk = false,

	-- Scroll to the current Markdown line once when opening/retargeting the
	-- preview. Unlike scroll_sync, later cursor movement is not followed.
	initial_scroll = true,
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

	-- Fraction (0–1): vertical position of the final line when scrolled to end.
	-- 0.5 = middle of viewport (default), 1.0 = bottom edge (no extra space)
	bottom_padding = 0.5,

	hooks = {
		-- fun(url: string)|nil — called after preview starts; receives the preview URL
		on_start = nil,
		-- fun()|nil — called after preview stops
		on_stop = nil,
	},
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	M.config.bottom_padding = math.max(0, math.min(1, M.config.bottom_padding))
end

-- One private session owns the server, document, and callbacks.
local session

---------------------------------------------------------------------------
-- Index HTML
---------------------------------------------------------------------------

local function render_index(token)
	local src = util.resolve_asset("index.html")
	if not src then
		error("Could not locate markdown_preview/assets/index.html")
	end
	local content = util.read_text(src)

	-- Inline the shipped Markdown and syntax themes. Keeping them as separate
	-- assets makes the preview shell independent from replaceable typography.
	for placeholder, asset in pairs({
		__MARKDOWN_THEME_CSS__ = "theme.css",
		__HIGHLIGHT_THEME_CSS__ = "highlight.css",
	}) do
		local css_path = util.resolve_asset(asset)
		if not css_path then
			error("Could not locate " .. asset .. " in runtimepath")
		end
		local css = util.read_text(css_path)
		content = content:gsub(placeholder, function() return css end)
	end

	-- gsub with function replacement: avoids the "%n is a capture reference"
	-- escape problem if any substituted value contains '%'.
	content = content:gsub("__MERMAID_ELK__", function() return M.config.mermaid_elk and "true" or "false" end)
	content = content:gsub("<!%-%- __NVIM_ADAPTER__ %-%->", function()
		return '<script src="https://cdn.jsdelivr.net/npm/morphdom@2/dist/morphdom-umd.min.js"></script>\n'
			.. '<script src="nvim-preview.js"></script>'
	end)
	content = content:gsub("__THEME__", function() return M.config.default_theme end)
	content = content:gsub("__ALLOW_HTML__", function()
		return M.config.allow_raw_html ~= false and "true" or "false"
	end)
	content = content:gsub("__YAML_MODE__", function()
		local m = M.config.yaml_mode
		if m == "panel" then m = "code" end -- compatibility with older configs
		if m ~= "code" and m ~= "hide" and m ~= "raw" then m = "code" end
		return m
	end)

	-- Host-only configuration is added to generated preview pages; the source
	-- index remains a standalone renderer with no Neovim protocol attributes.
	local host_attrs = table.concat({
		'data-bottom-padding="' .. tostring(M.config.bottom_padding) .. '"',
		'data-live-token="' .. token .. '"',
		'data-click-to-nvim="' .. (M.config.click_to_nvim and "true" or "false") .. '"',
	}, " ")
	content = content:gsub('<html lang="en"', function()
		return '<html lang="en" ' .. host_attrs
	end, 1)

	-- Inline custom CSS after the bundled styles so user rules win the cascade.
	-- A list keeps base theme and syntax highlighting files independent while
	-- preserving their configured cascade order.
	local custom_css = M.config.custom_css
	local css_sources = type(custom_css) == "table" and custom_css or { custom_css }
	local css_blocks = {}
	for index, css_path in ipairs(css_sources) do
		if type(css_path) == "string" then
			if css_path ~= "" then
				local css_src = vim.fn.expand(css_path)
				local ok, css = pcall(util.read_text, css_src)
				if ok and css then
					css_blocks[#css_blocks + 1] = "<style>\n" .. css .. "\n</style>"
				else
					vim.notify("Markdown Preview: custom_css[" .. index .. "] not readable: " .. css_src,
						vim.log.levels.WARN)
				end
			end
		elseif css_path ~= nil then
			vim.notify("Markdown Preview: custom_css[" .. index .. "] must be a file path",
				vim.log.levels.WARN)
		end
	end
	if #css_blocks > 0 then
		content = content:gsub("</head>", function()
			return table.concat(css_blocks, "\n") .. "\n</head>"
		end, 1)
	end

	return content
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

local function extract_mermaid_under_cursor(bufnr)
	local ok, text = pcall(ts.extract_under_cursor, bufnr)
	if ok and text and text ~= "" then return text end
	local fallback = ts.fallback_scan(bufnr)
	if not fallback or #fallback == 0 then
		error("No ```mermaid fenced code block found under (or above) the cursor")
	end
	return fallback
end

---Get the content to write based on filetype.
---Markdown buffers: entire buffer.
---Mermaid files (.mmd, .mermaid): entire buffer wrapped in mermaid fence.
---Others: mermaid block under cursor wrapped in fence.
---@param bufnr integer
---@return string
local function get_content(bufnr)
	local text
	local ft = vim.bo[bufnr].filetype
	local name = vim.api.nvim_buf_get_name(bufnr)
	if ft == "markdown" then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = table.concat(lines, "\n")
	elseif name:match("%.mmd$") or name:match("%.mermaid$") then
		-- .mmd / .mermaid files: treat entire buffer as mermaid
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = "```mermaid\n" .. table.concat(lines, "\n") .. "\n```\n"
	else
		-- Other filetypes: extract mermaid block under cursor, wrap in code fence
		local mermaid_text = extract_mermaid_under_cursor(bufnr)
		text = "```mermaid\n" .. mermaid_text .. "\n```\n"
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
	if M.config.initial_scroll == false then return nil end
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
	if s.server then ls_server.send_event(s.server, "reload") end
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
	if cursor_line == s.last_scroll_line then return end
	s.last_scroll_line = cursor_line
	local total = vim.api.nvim_buf_line_count(s.bufnr)
	local payload = vim.json.encode({ line = cursor_line - 1, total = total })
	ls_server.send_event(s.server, "scroll", payload)
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

local function set_autocmds(s)
	s.group = vim.api.nvim_create_augroup("MarkdownPreviewAuto", { clear = true })

	if M.config.auto_refresh then
		vim.api.nvim_create_autocmd(M.config.auto_refresh_events, {
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
					or vim.bo[args.buf].filetype ~= "markdown"
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

-- When bound to 0.0.0.0 detect the outbound LAN IP via a UDP connect trick
-- (no packets are sent; it just lets the kernel pick the right interface).
local function lan_ip()
	local udp = vim.uv.new_udp()
	if not udp then return "127.0.0.1" end
	local ok = pcall(function() udp:connect("8.8.8.8", 80) end)
	local addr = ok and udp:getsockname()
	pcall(function() udp:close() end)
	return (addr and addr.ip) or "127.0.0.1"
end

-- Build the URL the browser opens to. Embeds the auth token when one exists
-- so the first request includes it (the page then stashes it in
-- sessionStorage for refreshes).
local function browser_url(port, token)
	local display_host = (M.config.host == "0.0.0.0") and lan_ip() or M.config.host
	local base = ("http://%s:%d/"):format(display_host, port)
	return base .. "?t=" .. token
end

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
	local s = session or { token = ls_util.random_token(16) }
	update_document(s, bufnr, text, true)

	-- Start the embedded preview server if not already running.
	if not s.server then
		local port = M.config.port
		local index = render_index(s.token)
		local asset_dir = vim.fs.dirname(assert(util.resolve_asset("index.html")))
		local ok, inst = pcall(ls_server.start, {
			port = port,
			host = M.config.host,
			root = asset_dir,
			headers = { ["Cache-Control"] = "no-cache" },
			live = { enabled = false, inject_script = false },
			features = { dirlist = { enabled = false } },
			token = s.token,
			routes = {
				["/"] = function()
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
		s.server = inst
		s.url = browser_url(inst.port, s.token)
		session = s
		set_autocmds(s)

		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(s.url)
		end
	end
	-- Coalesce open requests and discard callbacks belonging to a stopped session.
	if session == s and M.config.open_browser and not s.open_pending
		and ls_server.connected_client_count(s.server) == 0 then
		s.open_pending = true
		vim.defer_fn(function()
			s.open_pending = nil
			if session == s and ls_server.connected_client_count(s.server) == 0 then
				util.open_in_browser(s.url, M.config.browser)
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
		local instance = s.server
		pcall(ls_server.send_event, instance, "markdown-preview-close", "{}")
		-- stop() closes sockets immediately. Allow the close event to flush,
		-- including during VimLeavePre, but never wait indefinitely for a tab.
		if ls_server.connected_client_count(instance) > 0 then
			vim.wait(100, function()
				return ls_server.connected_client_count(instance) == 0
			end, 10)
		end
		pcall(ls_server.stop, instance)
	end

	if type(M.config.hooks.on_stop) == "function" then
		M.config.hooks.on_stop()
	end
end

return M
