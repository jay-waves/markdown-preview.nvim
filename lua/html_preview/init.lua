-- lua/html_preview/init.lua
-- Preview the current HTML file through the shared local live server.
local session_runtime = require("live_server.session")

local M = {}

M.config = {
    port = 0,
    host = "127.0.0.1",
    open_browser = true,
    browser = nil,
}

local session

local function html_path(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then return nil end
    local lower = name:lower()
    if not (lower:match("%.html$") or lower:match("%.htm$")) then return nil end
    return name
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.start()
    local bufnr = vim.api.nvim_get_current_buf()
    local path = html_path(bufnr)
    if not path then
        vim.notify("HtmlPreview: current buffer is not an HTML file", vim.log.levels.ERROR)
        return
    end

    if session and session.path ~= path then
        M.stop()
    end

    if not session then
        local root = vim.fs.dirname(path)
        local index = vim.fs.basename(path)
        local token = session_runtime.token(16)
        local ok, preview = pcall(session_runtime.start, {
            token = token,
            port = M.config.port,
            host = M.config.host,
            root = root,
            default_index = index,
            browser = M.config.browser,
            browser_title = "HTML Preview",
            headers = { ["Cache-Control"] = "no-cache" },
            -- The server watches the HTML file and reloads the browser when
            -- the file changes, which also updates document.title.
            live = { enabled = true, inject_script = true },
        })
        if not ok then
            vim.notify("HtmlPreview: failed to start server — " .. tostring(preview), vim.log.levels.ERROR)
            return
        end
        session = { bufnr = bufnr, path = path, preview = preview }
    end

    if M.config.open_browser and not session.preview:connected() then
        session.preview:open()
    end
end

function M.stop()
    local s = session
    if not s then return end
    session = nil
    s.preview:stop(true, "html-preview-close")
end

return M
