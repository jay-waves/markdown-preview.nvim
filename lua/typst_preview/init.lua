local M = {}
local bridge = require("typst_preview.bridge")
local task_id = "nvim_browsing_preview"
local session, exiting, configured

local function notify(message)
    if not exiting then vim.notify(message, vim.log.levels.ERROR, { title = "Typst Preview" }) end
end

local function current_client()
    return vim.lsp.get_clients({ bufnr = 0, name = "tinymist" })[1]
end

local function cancel_scroll(s)
    if s.timer and not s.timer:is_closing() then s.timer:stop(); s.timer:close() end
    s.timer = nil
end

local function close_page(s)
    cancel_scroll(s)
    if s.page then s.page:stop(exiting); s.page = nil end
end

local function release(s)
    close_page(s)
    if session == s then session = nil end
end

local function kill(s)
    if s.killing then return end
    s.stopping, s.killing = true, true
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

function M.stop()
    local s = session
    if not s or s.stopping then return end
    s.stopping = true
    cancel_scroll(s)
    if s.task_started then kill(s) end
end

local function focus(client, bufnr)
    client:exec_cmd({
        title = "Focus Tinymist Preview", command = "tinymist.focusMain",
        arguments = { vim.api.nvim_buf_get_name(bufnr) },
    }, { bufnr = bufnr })
end

local function schedule_scroll(s)
    cancel_scroll(s)
    if session ~= s or not s.ready or s.stopping then return end
    local timer
    timer = vim.defer_fn(function()
        if session ~= s or s.timer ~= timer or s.stopping then return end
        s.timer = nil
        if s.client:is_stopped() or current_client() ~= s.client then return end
        local bufnr = vim.api.nvim_get_current_buf()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
        if not line or line:match("^%s*//") then return end
        local col = vim.fn.matchend(line, [[\k]])
        if col < 0 then return end
        s.client:exec_cmd({
            title = "Follow Cursor in Tinymist Preview", command = "tinymist.scrollPreview",
            arguments = { task_id, {
                event = "panelScrollTo", filepath = vim.api.nvim_buf_get_name(bufnr),
                line = row - 1, character = col,
            } },
        }, { bufnr = bufnr }, function(err)
            if err then notify(vim.inspect(err)) end
        end)
    end, 300)
    s.timer = timer
end

local function sync_page(s, bufnr)
    if session ~= s or not s.page or s.stopping then return end
    local name = vim.api.nvim_buf_get_name(bufnr)
    s.page:title(name ~= "" and vim.fn.fnamemodify(name, ":t") or "Typst Preview")
    schedule_scroll(s)
end

function M.start()
    if exiting then return end
    local client = current_client()
    if not client then return notify("Tinymist is not attached to the current buffer") end
    local bufnr = vim.api.nvim_get_current_buf()
    if session then
        if session.stopping then return notify("Preview is stopping; retry shortly") end
        if session.client ~= client then return notify("Stop the existing preview before changing workspace") end
        if session.ready then
            focus(client, bufnr)
            sync_page(session, bufnr)
            session.page:open()
        end
        return
    end

    local s = { client = client }
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
        s.task_started = true
        if session ~= s or exiting or s.stopping then return kill(s) end
        local port = type(result) == "table" and (result.staticServerPort or result.dataPlanePort)
        if type(port) ~= "number" then
            kill(s)
            return notify("Tinymist returned no preview port: " .. vim.inspect(result))
        end
        local ok, page = pcall(bridge.start, ("http://127.0.0.1:%d/"):format(port), {
            connected = function() sync_page(s, vim.api.nvim_get_current_buf()) end,
            ready = function(prepare_err)
                if session ~= s or s.stopping then return end
                if prepare_err then kill(s); return notify("Preview injection failed: " .. prepare_err) end
                s.ready = true
                if current_client() == client then
                    local current_buf = vim.api.nvim_get_current_buf()
                    focus(client, current_buf)
                    sync_page(s, current_buf)
                end
                s.page:open()
            end,
        })
        if not ok then kill(s); return notify(tostring(page)) end
        s.page = page
    end)
end

function M.on_dispose(_, result, ctx)
    local s = session
    if not s or not result or result.taskId ~= task_id or ctx.client_id ~= s.client.id then return end
    if s.task_started then
        if not s.stopping then release(s) end
    else
        s.stopping = true
    end
end

function M.setup()
    if configured then return end
    configured = true
    vim.api.nvim_create_user_command("TypstPreview", M.start, { desc = "Start or reopen Typst preview" })
    vim.api.nvim_create_user_command("TypstPreviewStop", M.stop, { desc = "Stop Typst preview" })
    local group = vim.api.nvim_create_augroup("TypstPreview", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved", "InsertLeave", "BufLeave", "WinLeave" }, {
        group = group, pattern = "*.typ",
        callback = function(args)
            local s = session
            if not s then return end
            if args.event == "BufLeave" or args.event == "WinLeave" then return cancel_scroll(s) end
            if args.event ~= "BufEnter" then return schedule_scroll(s) end
            vim.schedule(function()
                if session ~= s or vim.api.nvim_get_current_buf() ~= args.buf then return end
                local client = current_client()
                if client == s.client then focus(client, args.buf); sync_page(s, args.buf) end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        callback = function(args)
            local s = session
            if not s or s.client.id ~= args.data.client_id then return end
            vim.schedule(function()
                if session == s and (s.client:is_stopped() or vim.tbl_isempty(s.client.attached_buffers)) then
                    M.stop()
                end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group, callback = function() exiting = true; M.stop() end,
    })
end

return M
