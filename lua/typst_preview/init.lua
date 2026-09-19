local M = {}
local bridge = require("typst_preview.bridge")
local session, exiting, configured
local PREVIEW_JUMP_GRACE_NS = 500000000

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

local function stop_task(s)
    local stop = s.stop_task
    if not stop then return end
    s.stop_task = nil
    stop()
end

function M.stop()
    local s = session
    if not s then return end
    session = nil
    close_page(s)
    stop_task(s)
end

local function focus(client, bufnr)
    client:exec_cmd({
        title = "Focus Tinymist Preview", command = "tinymist.focusMain",
        arguments = { vim.api.nvim_buf_get_name(bufnr) },
    }, { bufnr = bufnr })
end

local function schedule_scroll(s)
    cancel_scroll(s)
    if session ~= s or not s.page or not s.page:prepared() then return end
    local timer
    timer = vim.defer_fn(function()
        if session ~= s or s.timer ~= timer then return end
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
            arguments = { s.task_id, {
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
    if session ~= s or not s.page or not s.page:prepared() then return end
    local name = vim.api.nvim_buf_get_name(bufnr)
    s.cursor = vim.api.nvim_win_get_cursor(0)
    s.page:cursor(s.cursor[1] - 1)
    s.bufnr = bufnr
    s.page:buffer({ id = vim.uri_from_bufnr(bufnr), title = name ~= "" and vim.fn.fnamemodify(name, ":t") or "Typst Preview" })
    local ok, result = pcall(s.client.request, s.client, "textDocument/documentSymbol",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }, function(err, symbols)
            if session ~= s or not s.page or err then return end
            local function mark_headings(items)
                for _, item in ipairs(items or {}) do
                    local range = item.range or item.selectionRange
                    local line = range and range.start and range.start.line
                    local text = type(line) == "number"
                        and vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
                    item.isHeading = type(text) == "string" and text:match("^%s*=+%s+") ~= nil
                    mark_headings(item.children)
                end
            end
            mark_headings(symbols or {})
            s.page:outline({ symbols = symbols or {} })
        end, bufnr)
    if not ok then notify("Document Symbols request failed: " .. tostring(result)) end
    focus(s.client, bufnr)
    schedule_scroll(s)
end

function M.start()
    if exiting then return end
    local client = current_client()
    if not client then return notify("Tinymist is not attached to the current buffer") end
    local bufnr = vim.api.nvim_get_current_buf()
    if session then
        if session.client ~= client then return notify("Stop the existing preview before changing workspace") end
        if session.page and session.page:prepared() then
            sync_page(session, bufnr)
            session.page:open()
        end
        return
    end

    local s = {
        client = client,
        task_id = ("nvim_browsing_preview_%x"):format(vim.uv.hrtime()),
    }
    session = s
    focus(client, bufnr)
    client:exec_cmd({
        title = "Start Tinymist Preview", command = "tinymist.doStartBrowsingPreview",
        arguments = { {
            "--data-plane-host=127.0.0.1:0", "--invert-colors=auto",
            "--no-open", "--task-id=" .. s.task_id,
        } },
    }, { bufnr = bufnr }, function(err, result)
        if err then release(s); return notify(vim.inspect(err)) end
        s.stop_task = function()
            if client:is_stopped() then return end
            client:exec_cmd({
                title = "Stop Tinymist Preview", command = "tinymist.doKillPreview",
                arguments = { s.task_id },
            }, {}, function(kill_err)
                if kill_err then notify(vim.inspect(kill_err)) end
                if client:is_stopped() or (session and session.client == client) then return end
                client:exec_cmd({
                    title = "Clear Tinymist Cache", command = "tinymist.doClearCache",
                    arguments = {},
                }, {}, function(clear_err)
                    if clear_err then notify(vim.inspect(clear_err)) end
                end)
            end)
        end
        if session ~= s or exiting then return stop_task(s) end
        local port = type(result) == "table" and (result.staticServerPort or result.dataPlanePort)
        if type(port) ~= "number" then
            M.stop()
            return notify("Tinymist returned no preview port: " .. vim.inspect(result))
        end
        local ok, page = pcall(bridge.start, ("http://127.0.0.1:%d/"):format(port), {
            connected = function()
                if current_client() == s.client then sync_page(s, vim.api.nvim_get_current_buf()) end
            end,
            outline_jump = function(data)
                local ok, value = pcall(vim.json.decode, data or "")
                local line = ok and type(value) == "table" and value.line
                if type(line) == "number" and s.bufnr and vim.api.nvim_buf_is_valid(s.bufnr) then
                    local wins = vim.fn.win_findbuf(s.bufnr)
                    if #wins > 0 then
                        local row = math.max(1, math.min(vim.api.nvim_buf_line_count(s.bufnr), line + 1))
                        pcall(vim.api.nvim_win_set_cursor, wins[1], { row, 0 })
                        pcall(vim.api.nvim_win_call, wins[1], function() vim.cmd("normal! zz") end)
                    end
                end
            end,
            preview_jump = function()
                -- Tinymist moves the editor cursor as a consequence of the
                -- preview click. Ignore that one CursorMoved event; a later
                -- movement is a real editor action and should follow again.
                s.suppress_follow_until = vim.uv.hrtime() + PREVIEW_JUMP_GRACE_NS
            end,
            ready = function(prepare_err)
                if session ~= s then return end
                if prepare_err then M.stop(); return notify("Preview injection failed: " .. prepare_err) end
                if current_client() == client then
                    sync_page(s, vim.api.nvim_get_current_buf())
                end
                s.page:open()
            end,
        })
        if not ok then M.stop(); return notify(tostring(page)) end
        s.page = page
    end)
end

function M.on_dispose(_, result, ctx)
    local s = session
    if not s or not result or result.taskId ~= s.task_id or ctx.client_id ~= s.client.id then return end
    s.stop_task = nil
    release(s)
end

function M.setup()
    if configured then return end
    configured = true
    vim.api.nvim_create_user_command("TypstPreview", M.start, { desc = "Start or reopen Typst preview" })
    vim.api.nvim_create_user_command("TypstPreviewStop", M.stop, { desc = "Stop Typst preview" })
    local group = vim.api.nvim_create_augroup("TypstPreview", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "InsertLeave", "BufLeave", "TextChanged", "TextChangedI" }, {
        group = group, pattern = "*.typ",
        callback = function(args)
            local s = session
            if not s then return end
            if args.event == "BufLeave" then return cancel_scroll(s) end
            if args.event == "TextChanged" or args.event == "TextChangedI" then
                if args.buf == s.bufnr and current_client() == s.client then sync_page(s, args.buf) end
                return
            end
            if args.event ~= "BufEnter" then
                local cursor = vim.api.nvim_win_get_cursor(0)
                if vim.deep_equal(cursor, s.cursor) then return end
                s.cursor = cursor
                if s.suppress_follow_until then
                    local suppressed = vim.uv.hrtime() <= s.suppress_follow_until
                    s.suppress_follow_until = nil
                    if suppressed then return end
                end
                if s.page then s.page:cursor(cursor[1] - 1) end
                if s.page then s.page:follow() end
                return schedule_scroll(s)
            end
            vim.schedule(function()
                if session ~= s or vim.api.nvim_get_current_buf() ~= args.buf then return end
                local client = current_client()
                if client == s.client then sync_page(s, args.buf) end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("LspDetach", {
        group = group,
        callback = function(args)
            local s = session
            if not s or s.client.id ~= args.data.client_id then return end
            vim.schedule(function()
                if session == s and s.client:is_stopped() then release(s) end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group, callback = function() exiting = true; M.stop() end,
    })
end

return M
