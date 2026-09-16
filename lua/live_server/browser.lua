local M = {}

local function launch(command, options)
    local ok, job = pcall(vim.fn.jobstart, command, options or { detach = true })
    return ok and job > 0
end

---Open a URL with either the system handler or a configured browser.
---@param url string
---@param browser string|string[]|nil Browser executable/app name, or a command prefix.
---@param opts? { title?: string, notify?: boolean }
---@return boolean
function M.open(url, browser, opts)
    assert(type(url) == "string" and url ~= "", "browser.open: url is required")
    opts = opts or {}

    local function warn(message)
        if opts.notify == false then return end
        vim.notify(("%s.\nOpen manually: %s"):format(message, url), vim.log.levels.WARN,
            { title = opts.title or "live-server.nvim" })
    end

    if browser ~= nil then
        local command
        local job_opts = { detach = true }
        if type(browser) == "table" then
            command = vim.list_extend(vim.deepcopy(browser), { url })
        elseif type(browser) ~= "string" or browser == "" then
            error("browser.open: browser must be a non-empty string or command table")
        elseif vim.fn.has("mac") == 1 then
            command = { "open", "-a", browser, url }
            job_opts.on_exit = function(_, code)
                if code ~= 0 then
                    vim.schedule(function()
                        warn(('configured browser "%s" could not be opened'):format(browser))
                    end)
                end
            end
        else
            command = { browser, url }
        end

        if launch(command, job_opts) then return true end
        warn(("could not launch configured browser (%s)"):format(command[1]))
        return false
    end

    if vim.ui and vim.ui.open then
        local ok, result, err = pcall(vim.ui.open, url)
        if ok and not err then return true end
        warn(tostring(ok and err or result))
        return false
    end

    warn("no system URL opener is available")
    return false
end

return M
