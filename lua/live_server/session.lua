-- Small preview-session facade shared by browser-based plugins.
-- It owns only server/browser lifecycle; rendering stays with callers.
local server = require("live_server.server")
local browser = require("live_server.browser")
local util = require("live_server.util")

local M = {}
M.token = util.random_token

local function display_host(host)
    if host == "0.0.0.0" then
        local udp = vim.uv.new_udp()
        if udp then
            local ok = pcall(udp.connect, udp, "8.8.8.8", 80)
            local address = ok and udp:getsockname()
            pcall(udp.close, udp)
            if address and address.ip then return address.ip end
        end
        return "127.0.0.1"
    end
    return host
end

---@param options table server.start options plus url_host, browser, browser_title
function M.start(options)
    options = vim.deepcopy(options or {})
    local self = {
        token = options.token or util.random_token(16),
        stopped = false,
        browser = options.browser,
        browser_title = options.browser_title or "Preview",
    }
    options.token = self.token
    local host = options.host or "127.0.0.1"
    local url_host = options.url_host or display_host(host)
    options.url_host, options.browser, options.browser_title = nil, nil, nil
    self.server = server.start(options)
    self.url = ("http://%s:%d/?t=%s"):format(url_host, self.server.port, self.token)

    function self:connected()
        return not self.stopped and server.connected_client_count(self.server) > 0
    end
    function self:send(event, data)
        if not self.stopped then server.send_event(self.server, event, data or "{}") end
    end
    function self:open()
        if not self.stopped and not self:connected() then
            return browser.open(self.url, self.browser, { title = self.browser_title })
        end
    end
    function self:stop(exiting, close_event)
        if self.stopped then return end
        if close_event then server.send_event(self.server, close_event, "{}") end
        self.stopped = true
        if exiting then
            vim.wait(100, function() return server.connected_client_count(self.server) == 0 end, 10)
            server.stop(self.server)
        else
            vim.defer_fn(function() server.stop(self.server) end, 150)
        end
    end
    return self
end

return M
