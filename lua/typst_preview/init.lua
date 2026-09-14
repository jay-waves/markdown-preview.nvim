local M = {}
local bridge = require("typst_preview.bridge")
local task_id = "nvim_browsing_preview"
local session, exiting

local function notify(message)
    if not exiting then vim.notify(message, vim.log.levels.ERROR, { title = "Typst Preview" }) end
end

local function current_client()
    return vim.lsp.get_clients({ bufnr = 0, name = "tinymist" })[1]
end

local function close_page(s)
    if s.page then s.page:stop(exiting); s.page = nil end
end

local function release(s)
    close_page(s)
    if session == s then session = nil end
end

local function kill(s)
    s.phase = "stopping"
    close_page(s)
    if s.client:is_stopped() then return release(s) end
    s.client:exec_cmd({
        title = "Stop Tinymist Preview", command = "tinymist.doKillPreview",
        arguments = { task_id },
    }, {}, function(err)
        if err then notify(vim.inspect(err)) end
        release(s)
    end)
end

function M.typst_stop()
    local s = session
    if not s or s.phase == "stopping" then return end
    -- A pending start must finish before killing its task; keep the session
    -- reserved so a new start cannot race the old task's cleanup.
    if s.phase == "starting" then s.phase = "stopping"; return end
    kill(s)
end

local function focus(client, bufnr)
    client:exec_cmd({
        title = "Focus Tinymist Preview", command = "tinymist.focusMain",
        arguments = { vim.api.nvim_buf_get_name(bufnr) },
    }, { bufnr = bufnr })
end

local function publish_cursor(force)
    local s = session
    if not s or not s.page or s.phase == "stopping" then return end
    local active = not s.client:is_stopped() and current_client() == s.client
    s.page:cursor({
        active = active, bufnr = vim.api.nvim_get_current_buf(),
        row = vim.api.nvim_win_get_cursor(0)[1], force = force,
    })
end

local function scroll(s, value)
    if session ~= s or s.phase ~= "running" or not value.active or s.client:is_stopped()
        or current_client() ~= s.client or vim.api.nvim_get_current_buf() ~= value.bufnr
        or vim.api.nvim_win_get_cursor(0)[1] ~= value.row then return end
    local line = vim.api.nvim_buf_get_lines(value.bufnr, value.row - 1, value.row, false)[1]
    if not line or line:match("^%s*//") then return end
    local col = vim.fn.matchend(line, [[\k]])
    if col < 0 then return end
    s.client:exec_cmd({
        title = "Follow Cursor in Tinymist Preview", command = "tinymist.scrollPreview",
        arguments = { task_id, {
            event = "panelScrollTo", filepath = vim.api.nvim_buf_get_name(value.bufnr),
            line = value.row - 1, character = col,
        } },
    }, { bufnr = value.bufnr }, function(err)
        if err then notify(vim.inspect(err)) end
    end)
end

function M.typst_start()
    if exiting then return end
    local client = current_client()
    if not client then return notify("Tinymist is not attached to the current buffer") end
    if session then
        if session.phase == "stopping" then return notify("Preview is stopping; retry shortly") end
        if session.client ~= client then return notify("Stop the existing preview before changing workspace") end
        if session.phase == "running" then
            focus(client, vim.api.nvim_get_current_buf())
            session.page:open()
        end
        return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local s = { client = client, phase = "starting" }
    session = s
    focus(client, bufnr)
    client:exec_cmd({
        title = "Start Tinymist Preview", command = "tinymist.doStartBrowsingPreview",
        arguments = { {
            "--data-plane-host=127.0.0.1:0", "--invert-colors=auto",
            "--no-open", "--task-id=" .. task_id,
        } },
    }, { bufnr = bufnr }, function(err, result)
        if err then release(s); return notify(vim.inspect(err)) end
        if exiting or s.phase == "stopping" then return kill(s) end
        local port = type(result) == "table" and (result.staticServerPort or result.dataPlanePort)
        if type(port) ~= "number" then
            kill(s)
            return notify("Tinymist returned no preview port: " .. vim.inspect(result))
        end
        s.phase = "preparing"
        local ok, failure = pcall(function()
            s.page = bridge.start(("http://127.0.0.1:%d/"):format(port), function(value) scroll(s, value) end)
            s.page:prepare(function(prepare_err)
                if session ~= s or s.phase ~= "preparing" then return end
                if prepare_err then kill(s); return notify("Preview injection failed: " .. prepare_err) end
                s.phase = "running"
                if current_client() == client then focus(client, vim.api.nvim_get_current_buf()) end
                s.page:open()
            end)
        end)
        if not ok then kill(s); notify(tostring(failure)) end
    end)
end

function M.on_dispose(_, result, ctx)
    local s = session
    if not s or not result or result.taskId ~= task_id or ctx.client_id ~= s.client.id then return end
    if s.phase == "starting" then
        s.phase = "stopping"
    elseif s.phase ~= "stopping" then
        release(s)
    end
end

function M.setup()
    if M.configured then return end
    M.configured = true
    vim.api.nvim_create_user_command("TypstPreview", M.typst_start, { desc = "Start or reopen Typst preview" })
    vim.api.nvim_create_user_command("TypstPreviewStop", M.typst_stop, { desc = "Stop Typst preview" })
    local group = vim.api.nvim_create_augroup("TypstPreview", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
        group = group, pattern = "*.typ",
        callback = function(args)
            vim.schedule(function()
                if exiting or vim.api.nvim_get_current_buf() ~= args.buf then return end
                local client = current_client()
                if client then focus(client, args.buf) end
            end)
        end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "InsertLeave", "BufLeave", "WinLeave" }, {
        group = group,
        callback = function(args)
            if args.event == "BufLeave" or args.event == "WinLeave" then
                if session and session.page then session.page:cursor({ active = false }) end
            else
                publish_cursor(args.event == "InsertLeave")
            end
        end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        callback = function(args)
            local s = session
            if not s or s.client.id ~= args.data.client_id then return end
            vim.schedule(function()
                if session == s and (s.client:is_stopped() or vim.tbl_isempty(s.client.attached_buffers)) then
                    M.typst_stop()
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group, callback = function() exiting = true; M.typst_stop() end,
    })
end

return M
