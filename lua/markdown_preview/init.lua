-- lua/markdown_preview/init.lua
local ts = require("markdown_preview.ts")
local util = require("markdown_preview.util")
local click = require("markdown_preview.click")
local ls_server = require("live_server.server")
local ls_util = require("live_server.util")

local M = {}

M.config = {
	port = 0, -- 0 = auto; effective port depends on instance_mode
	host = "127.0.0.1", -- bind address; "0.0.0.0" for network access (e.g. over SSH)
	open_browser = true,

	-- nil = system default browser. String for app/binary name (e.g. "Firefox",
	-- "google-chrome"). Table for full command with args (URL is appended).
	-- On macOS, string values are passed via `open -a <name>`.
	browser = nil,

	-- "takeover" = shared workspace + fixed port, one browser tab across instances
	-- "multi" = per-instance server + browser tab (port 0 recommended)
	instance_mode = "multi",

	content_name = "content.md",
	index_name = "index.html",

	-- Path or ordered list of paths to CSS files injected after the bundled
	-- styles. Supports ~ and $VARS. "" or {} = disabled.
	custom_css = "",

	-- nil = per-buffer workspace (recommended); set a path to override
	workspace_dir = nil,

	overwrite_index_on_start = true,

	auto_refresh = true,
	auto_refresh_events = { "InsertLeave", "TextChanged", "TextChangedI", "BufWritePost" },
	debounce_ms = 300,
	notify_on_refresh = false,

	-- After the first :MarkdownPreview, reuse the same server and browser tab
	-- when entering another Markdown buffer. Non-Markdown buffers are ignored.
	follow_current_buffer = false,

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
	-- "panel" = strip it from the preview, show in a collapsible panel above
	-- "hide"  = strip it entirely
	-- "raw"   = leave it in the document (renders as markdown)
	yaml_mode = "panel",

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

-- Internal state
M._augroup = nil
M._active_bufnr = nil
M._last_text_by_buf = {}
M._last_asset_context_by_buf = {}
M._server_instance = nil
M._debounce_seq = 0
M._workspace_dir = nil
M._last_scroll_line = nil
M._is_primary = nil      -- true/false/nil (takeover mode)
M._takeover_port = nil   -- port of primary server (secondary uses for HTTP events)
M._token = nil           -- live-server auth token (primary owns; secondaries read from lockfile)
M._click_server = nil

local function effective_port()
	if M.config.port ~= 0 then return M.config.port end
	if M.config.instance_mode == "takeover" then return 8421 end
	return 0
end

local function host_is_loopback()
	return M.config.host == "127.0.0.1" or M.config.host == "localhost"
end

---------------------------------------------------------------------------
-- Workspace
---------------------------------------------------------------------------

local function resolve_workspace(bufnr)
	if M.config.workspace_dir then
		return M.config.workspace_dir
	end
	return util.workspace_for_buffer(bufnr)
end

local function ensure_workspace(bufnr)
	local dir = resolve_workspace(bufnr)
	util.mkdirp(dir)
	return dir
end

---------------------------------------------------------------------------
-- Index HTML
---------------------------------------------------------------------------

local function write_index(dir)
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	local src = util.resolve_asset("assets/index.html")
	if not src then
		error("Could not locate assets/index.html in runtimepath. Make sure the plugin ships it.")
	end
	local content = util.read_text(src)

	-- Inline the shipped Markdown and syntax themes. Keeping them as separate
	-- assets makes the preview shell independent from replaceable typography.
	for placeholder, asset in pairs({
		__MARKDOWN_THEME_CSS__ = "assets/theme.css",
		__HIGHLIGHT_THEME_CSS__ = "assets/highlight.css",
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
	content = content:gsub("__BOTTOM_PADDING__", function() return tostring(M.config.bottom_padding) end)
	content = content:gsub("__MERMAID_ELK__", function() return M.config.mermaid_elk and "true" or "false" end)
	-- Anchor to the attribute: index.html also contains the bare placeholder
	-- as a JS sentinel, and substituting that too breaks auth (issue #31).
	-- Bake the token only on loopback binds: on a network bind the index is
	-- served to any peer that can reach the port, and a baked token would
	-- defeat the auth entirely (the browser gets it via ?t= instead).
	content = content:gsub('data%-live%-token="__LIVE_TOKEN__"', function()
		return 'data-live-token="' .. (host_is_loopback() and M._token or "") .. '"'
	end)
	content = content:gsub("__THEME__", function() return M.config.default_theme end)
	content = content:gsub("__ALLOW_HTML__", function()
		return M.config.allow_raw_html ~= false and "true" or "false"
	end)
	content = content:gsub("__CLICK_TO_NVIM__", function()
		return M.config.instance_mode == "multi" and M.config.click_to_nvim and M._click_server and "true" or "false"
	end)
	content = content:gsub("__CLICK_PORT__", function()
		return M._click_server and tostring(M._click_server.port) or ""
	end)
	content = content:gsub("__YAML_MODE__", function()
		local m = M.config.yaml_mode
		if m ~= "hide" and m ~= "raw" then m = "panel" end
		return m
	end)

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

	util.write_text(dst, content)
	return dst
end

local function write_index_if_needed(dir)
	if M.config.overwrite_index_on_start then
		return write_index(dir)
	end
	local dst = vim.fs.joinpath(dir, M.config.index_name)
	if not util.file_exists(dst) then
		return write_index(dir)
	end
	-- Rewrite a persisted index whose baked token no longer matches what this
	-- session serves. Covers a fresh token after restart AND a loopback<->
	-- network switch (which flips whether the token is baked at all) — a stale
	-- non-empty token on a network bind would otherwise 401 every request.
	local want = 'data-live-token="' .. (host_is_loopback() and (M._token or "") or "") .. '"'
	local want_click = 'data-click-port="' .. (M._click_server and tostring(M._click_server.port) or "") .. '"'
	local ok, existing = pcall(util.read_text, dst)
	if not ok or not existing:find(want, 1, true) or not existing:find(want_click, 1, true) then
		return write_index(dir)
	end
	return dst
end

---------------------------------------------------------------------------
-- Content writing (unified: markdown or mermaid)
---------------------------------------------------------------------------

local function extract_mermaid_under_cursor_strict(bufnr)
	local ok, text = pcall(ts.extract_under_cursor, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
end

local function extract_mermaid_under_cursor(bufnr)
	local text = extract_mermaid_under_cursor_strict(bufnr)
	if text and #text > 0 then
		return text
	end
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
	if ft == "markdown" then
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		text = table.concat(lines, "\n")
	elseif vim.api.nvim_buf_get_name(bufnr):match("%.mmd$")
        or vim.api.nvim_buf_get_name(bufnr):match("%.mermaid$") then
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

---Same as get_content but never errors (returns nil on failure).
---@param bufnr integer
---@return string|nil
local function get_content_safe(bufnr)
	local ok, text = pcall(get_content, bufnr)
	if ok and text and #text > 0 then
		return text
	end
	return nil
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
	local root_with_sep = root_cmp
	if not root_with_sep:match("[/\\]$") then
		root_with_sep = root_with_sep .. package.config:sub(1, 1)
	end
	if src_cmp:sub(1, #root_with_sep) == root_with_sep then
		local prefix = src_dir:sub(#cwd + 1):gsub("^[/\\]+", ""):gsub("\\", "/")
		return cwd, prefix
	end
	return src_dir, ""
end

local function write_content(dir, text, bufnr)
	local path = vim.fs.joinpath(dir, M.config.content_name)
	-- Sidecars record the allowed :pwd root and the source directory relative
	-- to it. Writing them before content.md ensures the file-watch reload cannot
	-- race ahead with stale asset context in takeover/follow-buffer modes.
	if bufnr then
		local root, prefix = asset_context(bufnr)
		pcall(util.write_text, vim.fs.joinpath(dir, "asset_root"), root or "")
		pcall(util.write_text, vim.fs.joinpath(dir, "asset_prefix"), prefix)
		M._last_asset_context_by_buf[bufnr] = root and (root .. "\0" .. prefix) or nil
	end
	util.write_text(path, text)
	return path
end

local function write_initial_scroll(dir, bufnr)
	local payload = ""
	if M.config.initial_scroll ~= false then
		local winid = vim.api.nvim_get_current_win()
		if vim.api.nvim_get_current_buf() ~= bufnr then
			local wins = vim.fn.win_findbuf(bufnr)
			winid = wins[1]
		end
		if winid then
			local line = vim.api.nvim_win_get_cursor(winid)[1] - 1
			payload = vim.json.encode({
				id = tostring(vim.loop.hrtime()) .. ":" .. tostring(vim.fn.getpid()),
				line = line,
				total = vim.api.nvim_buf_line_count(bufnr),
			})
		end
	end
	pcall(util.write_text, vim.fs.joinpath(dir, "initial_scroll"), payload)
end

---------------------------------------------------------------------------
-- Refresh logic
---------------------------------------------------------------------------

local function maybe_refresh(bufnr, silent)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	local text = get_content_safe(bufnr)
	if not text then
		return false
	end

	local asset_root, asset_prefix = asset_context(bufnr)
	local asset_key = asset_root and (asset_root .. "\0" .. asset_prefix) or nil
	if M._last_text_by_buf[bufnr] == text and M._last_asset_context_by_buf[bufnr] == asset_key then
		return false
	end

	local dir = M._workspace_dir or ensure_workspace(bufnr)
	write_content(dir, text, bufnr)
	M._last_text_by_buf[bufnr] = text

	-- Notify live-server of the content change for immediate SSE push
	-- In secondary takeover mode, M._server_instance is nil — fs_watch handles reload
	if M._server_instance then
		pcall(ls_server.reload, M._server_instance, M.config.content_name)
	end

	if not silent and M.config.notify_on_refresh then
		vim.notify("Markdown preview updated", vim.log.levels.INFO)
	end
	return true
end

local function debounced_refresh(bufnr)
	M._debounce_seq = M._debounce_seq + 1
	local this_call = M._debounce_seq
	vim.defer_fn(function()
		if this_call ~= M._debounce_seq then
			return
		end
		pcall(maybe_refresh, bufnr, true)
	end, M.config.debounce_ms)
end

---------------------------------------------------------------------------
-- Scroll sync (line-based)
---------------------------------------------------------------------------

--- Send cursor line to browser for scroll sync.
local function send_scroll_sync(bufnr)
	if not M.config.scroll_sync then return end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1] -- 1-based
	if cursor_line == M._last_scroll_line then return end
	M._last_scroll_line = cursor_line
	local total = vim.api.nvim_buf_line_count(bufnr)
	local payload = vim.json.encode({ line = cursor_line - 1, total = total })
	if M._server_instance then
		pcall(ls_server.send_event, M._server_instance, "scroll", payload)
	elseif M._takeover_port then
		require("markdown_preview.remote").send_event(M._takeover_port, "scroll", payload, M._token)
	end
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

local function set_autocmds_for_buffer(bufnr)
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
	end
	M._augroup = vim.api.nvim_create_augroup("MarkdownPreviewAuto", { clear = true })

	if M.config.auto_refresh then
		for _, ev in ipairs(M.config.auto_refresh_events) do
			vim.api.nvim_create_autocmd(ev, {
				group = M._augroup,
				buffer = bufnr,
				callback = function()
					debounced_refresh(bufnr)
				end,
				desc = "Markdown Preview auto-refresh (debounced)",
			})
		end
	end

	if M.config.scroll_sync then
		for _, ev in ipairs({ "CursorMoved", "CursorMovedI" }) do
			vim.api.nvim_create_autocmd(ev, {
				group = M._augroup,
				buffer = bufnr,
				callback = function() send_scroll_sync(bufnr) end,
				desc = "Markdown Preview scroll sync",
			})
		end
	end

	if M.config.follow_current_buffer then
		vim.api.nvim_create_autocmd("BufEnter", {
			group = M._augroup,
			callback = function(args)
				if not M._token
					or args.buf == M._active_bufnr
					or vim.bo[args.buf].filetype ~= "markdown"
				then
					return
				end

				-- Retarget after BufEnter finishes. start() recreates this
				-- augroup for the new active buffer.
				vim.schedule(function()
					if M._token and vim.api.nvim_get_current_buf() == args.buf then
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
	local udp = vim.loop.new_udp()
	if not udp then return "127.0.0.1" end
	local ok = pcall(function() udp:connect("8.8.8.8", 80) end)
	local addr = ok and udp:getsockname()
	pcall(function() udp:close() end)
	return (addr and addr.ip) or "127.0.0.1"
end

-- Build the URL the browser opens to. Embeds the auth token when one exists
-- so the first request includes it (the page then stashes it in
-- sessionStorage for refreshes).
local function browser_url(port)
	local display_host = (M.config.host == "0.0.0.0") and lan_ip() or M.config.host
	local base = ("http://%s:%d/"):format(display_host, port)
	if M._token and M._token ~= "" then
		return base .. "?t=" .. M._token
	end
	return base
end

local function scroll_nvim_to_line(line)
	local bufnr = M._active_bufnr
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

local function ensure_click_server()
	if not M.config.click_to_nvim or M.config.instance_mode ~= "multi" then return end
	if M._click_server then return end
	local ok, instance = pcall(click.start, M.config.host, M._token, scroll_nvim_to_line)
	if ok then
		M._click_server = instance
	else
		vim.notify("Markdown Preview: click_to_nvim unavailable — " .. tostring(instance), vim.log.levels.WARN)
	end
end

function M.start()
	local bufnr = vim.api.nvim_get_current_buf()
	M._active_bufnr = bufnr

	-- Takeover coordination (lock probe + cross-instance events) talks to
	-- 127.0.0.1, which a specific-interface bind does not answer on. Only
	-- loopback and the wildcard are supported there; multi mode has no such
	-- coupling and accepts any bind address.
	if M.config.instance_mode == "takeover" and not host_is_loopback() and M.config.host ~= "0.0.0.0" then
		vim.notify(
			'Markdown Preview: takeover mode supports host = "127.0.0.1" or "0.0.0.0" only.\n'
				.. 'Use "0.0.0.0" for LAN access, or instance_mode = "multi" to bind a specific interface.',
			vim.log.levels.ERROR
		)
		return
	end

	local ok_content, text = pcall(get_content, bufnr)
	if not ok_content then
		vim.notify("Markdown Preview: " .. tostring(text), vim.log.levels.ERROR)
		return
	end

	-- Resolve workspace: shared (takeover) or per-buffer (multi)
	local dir
	if M.config.instance_mode == "takeover" then
		dir = util.shared_workspace()
	else
		dir = ensure_workspace(bufnr)
	end
	util.mkdirp(dir)
	M._workspace_dir = dir

	-- Decide role + token BEFORE writing index.html. The index bakes the
	-- token in via the __LIVE_TOKEN__ placeholder, so we need it ready.
	if M.config.instance_mode == "takeover" and not M._server_instance then
		local lock = require("markdown_preview.lock")
		local lock_data = lock.read()
		if lock_data and lock.is_server_alive(lock_data.port) then
			-- Secondary: server is already running in another Neovim
			-- instance. Adopt its token so our scroll-sync RPC works.
			M._is_primary = false
			M._takeover_port = lock_data.port
			M._token = lock_data.token
			write_content(dir, text, bufnr)
			write_initial_scroll(dir, bufnr)
			M._last_text_by_buf[bufnr] = text
			set_autocmds_for_buffer(bufnr)
			if type(M.config.hooks.on_start) == "function" then
				M.config.hooks.on_start(browser_url(lock_data.port))
			end
			return
		end
		-- Stale lock or no lock, we become primary
		lock.remove()
	end

	-- Primary path (takeover) or single-instance (multi). Generate a token
	-- once per server lifetime and reuse it across retargets.
	if not M._token or M._token == "" then
		M._token = ls_util.random_token(16)
	end

	ensure_click_server()
	write_index_if_needed(dir)
	write_content(dir, text, bufnr)
	write_initial_scroll(dir, bufnr)
	M._last_text_by_buf[bufnr] = text

	set_autocmds_for_buffer(bufnr)

	-- Patterns matching workspace-served files that require ?t=<token>.
	-- vim.pesc escapes every Lua-pattern magic char, so custom content_name /
	-- index_name values containing '-', '+', '.', etc. still gate correctly.
	local content_path_pattern = "^/" .. vim.pesc(M.config.content_name) .. "$"

	-- The asset_root sidecar is gated too: it holds the source file's
	-- directory path, which is nobody's business but ours.
	local protected = { content_path_pattern, "^/asset_root$", "^/asset_prefix$", "^/initial_scroll$" }
	if not host_is_loopback() then
		-- On a network bind the index page must be gated too: it is the
		-- browser's bootstrap document, and serving it openly would hand the
		-- preview to any peer that can reach the port. The tokenized ?t= URL
		-- (printed by hooks.on_start / opened by the browser) unlocks it.
		table.insert(protected, "^/$")
		table.insert(protected, "^/" .. vim.pesc(M.config.index_name) .. "$")
	end

	-- Relative image support needs the asset route in live-server. The two
	-- plugins are versioned independently, so warn (once) if the installed
	-- live-server predates it — images will 404 until it's updated.
	if not (ls_server.features and ls_server.features.asset_route) and not M._warned_no_asset_route then
		M._warned_no_asset_route = true
		vim.notify(
			"Markdown Preview: relative images need a newer live-server.nvim (with the asset route).\n"
				.. "Update live-server.nvim, or relative images will not load.",
			vim.log.levels.WARN
		)
	end

	-- Start live-server if not already running
	if not M._server_instance then
		local port = effective_port()
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		local ok, inst = pcall(ls_server.start, {
			port = port,
			host = M.config.host,
			root = dir,
			default_index = index_path,
			headers = { ["Cache-Control"] = "no-cache" },
			-- No cors: the preview page is same-origin and remote.lua talks raw
			-- TCP. A wildcard ACAO would let any website in the user's browser
			-- read the token out of the (unauthenticated) index page.
			live = {
				enabled = true,
				inject_script = false,
				debounce = 100,
			},
			features = { dirlist = { enabled = false } },
			token = M._token,
			protected_paths = protected,
			-- Resolve relative image paths against the source file's dir
			-- (issue #17). Read per request so takeover secondaries and
			-- buffer switches retarget it via the sidecar.
			asset_root = function()
				local ws = M._workspace_dir
				if not ws then return nil end
				local ok_read, data = pcall(util.read_text, vim.fs.joinpath(ws, "asset_root"))
				if not ok_read or not data or data == "" then return nil end
				return (data:gsub("%s+$", ""))
			end,
		})
		if not ok then
			vim.notify(
				("Markdown Preview: failed to start server (port %s) — %s"):format(tostring(port), tostring(inst)),
				vim.log.levels.ERROR
			)
			return
		end
		M._server_instance = inst
		M._is_primary = true
		M._takeover_port = nil

		-- Write lock file in takeover mode
		if M.config.instance_mode == "takeover" then
			require("markdown_preview.lock").write(inst.port, dir, M._token)
		end

		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(browser_url(inst.port))
		end

		if M.config.open_browser then
			vim.defer_fn(function()
				util.open_in_browser(browser_url(inst.port), M.config.browser)
			end, 200)
		end
	else
		-- Server already running, retarget to this buffer's workspace
		local index_path = vim.fs.joinpath(dir, M.config.index_name)
		pcall(ls_server.update_target, M._server_instance, dir, index_path)
		pcall(ls_server.reload, M._server_instance, M.config.content_name)

		if type(M.config.hooks.on_start) == "function" then
			M.config.hooks.on_start(browser_url(M._server_instance.port))
		end

		-- No browser tab connected (user closed it)? Re-open.
		if M.config.open_browser and ls_server.connected_client_count(M._server_instance) == 0 then
			vim.defer_fn(function()
				util.open_in_browser(browser_url(M._server_instance.port), M.config.browser)
			end, 200)
		end
	end
end

function M.refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	local changed = maybe_refresh(bufnr, false)
	if not changed and M.config.notify_on_refresh then
		vim.notify("Markdown Preview: no changes detected", vim.log.levels.INFO)
	end
end

function M.stop()
	if M._augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M._augroup)
		M._augroup = nil
	end
	if M._server_instance then
		pcall(ls_server.stop, M._server_instance)
		M._server_instance = nil
	end
	click.stop(M._click_server)
	M._click_server = nil
	if M._is_primary then
		require("markdown_preview.lock").remove()
	end
	M._workspace_dir = nil
	M._active_bufnr = nil
	M._last_scroll_line = nil
	M._is_primary = nil
	M._takeover_port = nil
	M._token = nil

	if type(M.config.hooks.on_stop) == "function" then
		M.config.hooks.on_stop()
	end
end

return M
