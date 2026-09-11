-- Run with this repository and live-server.nvim on runtimepath, using -u NONE.
local uv = vim.uv
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "# Close lifecycle", "", "Preview content" }, dir .. "/test.md")
vim.cmd.edit(dir .. "/test.md")
vim.bo.filetype = "markdown"
vim.cmd.runtime("plugin/markdown-preview.lua")
local preview = require("markdown_preview")
preview.setup({ open_browser = false, workspace_dir = dir .. "/web" })

local function listen()
    preview.start()
    local instance = assert(preview._server_instance)
    local sock = uv.new_tcp()
    local result = { data = "", closed = false }
    sock:connect("127.0.0.1", instance.port, function(err)
        assert(not err, err)
        sock:read_start(function(read_err, data)
            assert(not read_err, read_err)
            if data then result.data = result.data .. data
            else result.closed = true; sock:close() end
        end)
        sock:write(("GET /__live/events?t=%s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"):format(preview._token))
    end)
    assert(vim.wait(3000, function() return result.data:find("text/event%-stream") ~= nil end), "SSE did not connect")
    return result
end

local function stopped(result, should_close)
    assert(vim.wait(3000, function() return result.closed end), "SSE did not shut down")
    assert((result.data:find("event: markdown-preview-close", 1, true) ~= nil) == should_close,
        "Unexpected close event: " .. result.data)
    assert(preview._server_instance == nil)
end

local result = listen()
vim.cmd.MarkdownPreviewStop()
stopped(result, true)
result = listen()
vim.api.nvim_exec_autocmds("VimLeavePre", {})
stopped(result, true)
preview.stop() -- repeated cleanup must be harmless
print("PASS: explicit stop, restart and VimLeavePre deliver the expected SSE lifecycle")
