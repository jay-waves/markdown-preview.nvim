-- tests/token_auth_test.lua
-- End-to-end check that :MarkdownPreview generates a token, threads it into
-- the served HTML, gates content.md, and that scroll-sync RPC carries it.
--
-- Run: nvim --headless -c "set rtp+=./live-server-rtp" -c "set rtp+=." \
--          -c "luafile tests/token_auth_test.lua" -c "qa!"
--
-- The CI workflow shims live-server.nvim into ./live-server-rtp before run.

local uv = vim.loop

-- ─── Setup: open a markdown buffer ──────────────────────────────────────────
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local mdfile = vim.fs.joinpath(tmpdir, "test.md")
do
	local fd = uv.fs_open(mdfile, "w", 420)
	uv.fs_write(fd, "# hello\n\nbody text here.\n", 0)
	uv.fs_close(fd)
end
local image_dir = vim.fs.joinpath(tmpdir, "images")
vim.fn.mkdir(image_dir, "p")
local encoded_name_asset = vim.fs.joinpath(image_dir, "Pasted image 20260701195255.png")
local special_name_asset = vim.fs.joinpath(image_dir, "hash#percent%plus+.txt")
do
	local fd = uv.fs_open(encoded_name_asset, "w", 420)
	uv.fs_write(fd, "encoded-name-ok", 0)
	uv.fs_close(fd)
	fd = uv.fs_open(special_name_asset, "w", 420)
	uv.fs_write(fd, "special-name-ok", 0)
	uv.fs_close(fd)
end
local theme_css = vim.fs.joinpath(tmpdir, "theme.css")
local highlight_css = vim.fs.joinpath(tmpdir, "highlight.css")
local second_mdfile = vim.fs.joinpath(tmpdir, "second.md")
do
	local fd = uv.fs_open(theme_css, "w", 420)
	uv.fs_write(fd, "/* custom-theme-marker */\n", 0)
	uv.fs_close(fd)
	fd = uv.fs_open(highlight_css, "w", 420)
	uv.fs_write(fd, "/* custom-highlight-marker */\n", 0)
	uv.fs_close(fd)
	fd = uv.fs_open(second_mdfile, "w", 420)
	uv.fs_write(fd, "# second buffer\n\nfollow marker.\n", 0)
	uv.fs_close(fd)
end

vim.cmd("edit " .. mdfile)
vim.bo.filetype = "markdown"

-- ─── Configure: avoid opening a real browser, force multi mode for isolation
local mp = require("markdown_preview")
mp.setup({
	open_browser = false,
	instance_mode = "multi",
	custom_css = { theme_css, highlight_css },
	follow_current_buffer = true,
})

-- ─── Start ──────────────────────────────────────────────────────────────────
mp.start()

local passed, failed = 0, 0
local function ok(cond, msg)
	if cond then
		passed = passed + 1
		print("  PASS: " .. msg)
	else
		failed = failed + 1
		print("  FAIL: " .. msg)
	end
end

-- Server instance + token must exist
ok(mp._server_instance ~= nil, "server instance created")
ok(type(mp._token) == "string" and #mp._token == 32, "_token is 32 hex chars")
ok(mp._token:match("^[0-9a-f]+$") ~= nil, "_token is pure hex")

local port = mp._server_instance.port
ok(type(port) == "number" and port > 0, "server bound to a port")

-- ─── HTTP curl helper ───────────────────────────────────────────────────────
local function http_get(url)
	local out = vim.fn.system({ "curl", "-s", "-o", "-", "-w", "\nHTTPSTATUS:%{http_code}", url })
	local body, status = out:match("^(.*)\nHTTPSTATUS:(%d+)%s*$")
	return { status = tonumber(status), body = body or "" }
end

-- Static index reachable without token
local r = http_get(("http://127.0.0.1:%d/"):format(port))
ok(r.status == 200, "/ (index) is 200 without token")
ok(r.body:find("data%-live%-token=\"" .. mp._token .. "\"") ~= nil,
	"index.html has data-live-token attribute set to current token")
ok(r.body:find('data%-theme%-mode="auto"') ~= nil,
	"default preview theme follows the system color scheme")
ok(r.body:find('id="markdown%-theme"') ~= nil
		and r.body:find("__MARKDOWN_THEME_CSS__", 1, true) == nil,
	"bundled Markdown theme is inlined")
ok(r.body:find('id="highlight%-theme"') ~= nil
		and r.body:find("__HIGHLIGHT_THEME_CSS__", 1, true) == nil,
	"bundled highlight theme is inlined")
ok(r.body:find("<header", 1, true) == nil and r.body:find('id="themeBtn"', 1, true) == nil,
	"preview has no redundant theme toolbar")
ok(r.body:find('id="hljs%-theme"') == nil,
	"preview does not load a competing highlight stylesheet")
ok(r.body:find("yaml@2%.9%.0/%+esm") ~= nil
		and r.body:find("parseDocument", 1, true) ~= nil,
	"structured front matter uses the pinned browser-side YAML parser")
ok(r.body:find("dompurify@3%.4%.12/dist/purify%.min%.js") ~= nil
		and r.body:find("sanitizeRenderedHtml%(md%.render%(text%)%)") ~= nil,
	"rendered Markdown is sanitized by pinned DOMPurify")
ok(r.body:find("svgFilters: true", 1, true) ~= nil
		and r.body:find("mathMl: true", 1, true) ~= nil,
	"DOMPurify preserves SVG filters and MathML rendering")
ok(r.body:find("resolveRelativeAssetPath", 1, true) ~= nil
		and r.body:find("new URL(src, base)", 1, true) ~= nil,
	"relative image URLs use the browser URL parser")
ok(r.body:find("fetchAssetPrefix", 1, true) ~= nil
		and r.body:find("__markdown_preview_asset_root__", 1, true) ~= nil,
	"relative image URLs retain their Markdown-directory base under :pwd")
ok(r.body:find("data%-invalid%-src") ~= nil,
	"malformed and escaping image URLs fail closed")
ok(r.body:find("applyInitialScroll", 1, true) ~= nil
		and r.body:find("lastInitialScrollId", 1, true) ~= nil,
	"initial cursor position is consumed once without continuous scroll sync")
ok(r.body:find('class="fm%-title"') ~= nil
		and r.body:find("renderFrontMatterGrid", 1, true) ~= nil
		and r.body:find("View YAML source", 1, true) == nil,
	"front matter metadata card is present without a raw source view")
ok(r.body:find('<dialog id="overlay"', 1, true) ~= nil
		and r.body:find("overlay.showModal()", 1, true) ~= nil
		and r.body:find("overlay.classList.add('active')", 1, true) == nil,
	"Mermaid overlay uses the native dialog lifecycle")
ok(r.body:find("function h(tag, props", 1, true) ~= nil
		and r.body:find("element.textContent = value", 1, true) ~= nil,
	"front matter uses the safe local DOM builder")
ok(r.body:find("function attachCopyButtons", 1, true) == nil
		and r.body:find("e.target.closest('.copy-btn')", 1, true) ~= nil,
	"code copy actions use one delegated listener")
local theme_pos = r.body:find("custom%-theme%-marker")
local highlight_pos = r.body:find("custom%-highlight%-marker")
ok(theme_pos ~= nil and highlight_pos ~= nil and theme_pos < highlight_pos,
	"custom_css files are injected in configured order")

-- content.md is gated
r = http_get(("http://127.0.0.1:%d/content.md"):format(port))
ok(r.status == 401, "/content.md without token is 401")

r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token))
ok(r.status == 200, "/content.md with correct token is 200")
ok(r.body:find("hello") ~= nil, "/content.md body contains buffer text")

-- Asset URL edge cases: leading ./, mixed raw Unicode/percent encoding,
-- encoded separators, and encoded URL-special characters in real filenames.
r = http_get(("http://127.0.0.1:%d/__live/asset?p=.%%2Fimages%%2FPasted%%20image%%2020260701195255.png&t=%s")
	:format(port, mp._token))
ok(r.status == 200 and r.body == "encoded-name-ok",
	"asset route accepts ./ with encoded separators and spaces")

r = http_get(("http://127.0.0.1:%d/__live/asset?p=images%%2Fhash%%23percent%%25plus%%2B.txt&t=%s")
	:format(port, mp._token))
ok(r.status == 200 and r.body == "special-name-ok",
	"asset route preserves encoded #, percent, and plus filename characters")

r = http_get(("http://127.0.0.1:%d/__live/asset?p=..%%2Foutside.txt&t=%s"):format(port, mp._token))
ok(r.status == 404, "asset route rejects parent traversal outside its root")

-- Entering another Markdown buffer reuses the same server and retargets it.
vim.cmd("edit " .. second_mdfile)
vim.bo.filetype = "markdown"
vim.api.nvim_exec_autocmds("BufEnter", { buffer = vim.api.nvim_get_current_buf() })
vim.wait(1000, function()
	return mp._active_bufnr == vim.api.nvim_get_current_buf()
end)
ok(mp._server_instance ~= nil and mp._server_instance.port == port,
	"follow_current_buffer reuses the existing server")
r = http_get(("http://127.0.0.1:%d/content.md?t=%s"):format(port, mp._token))
ok(r.status == 200 and r.body:find("follow marker", 1, true) ~= nil,
	"follow_current_buffer retargets content to the entered Markdown buffer")

-- ─── Stop and verify cleanup ────────────────────────────────────────────────
mp.stop()
ok(mp._token == nil, "_token cleared after stop")
ok(mp._server_instance == nil, "_server_instance cleared after stop")
ok(mp._active_bufnr == nil, "_active_bufnr cleared after stop")

-- Port no longer accepts connections (give it a moment)
vim.wait(200, function() return false end)
r = http_get(("http://127.0.0.1:%d/"):format(port))
ok(r.status == nil or r.status == 0, "port no longer responds after stop (status=" .. tostring(r.status) .. ")")

print(string.format("\n========================================"))
print(string.format("Results: %d passed, %d failed", passed, failed))
print(string.format("========================================"))

if failed > 0 then vim.cmd("cq 1") end
