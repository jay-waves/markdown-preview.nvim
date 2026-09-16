local M = {}
local server = require("live_server.server")
local browser = require("live_server.browser")
local html_util = require("live_server.html")
local source_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local root = vim.fs.joinpath(source_dir, "assets")

function M.start(upstream, callbacks)
    assert(upstream:match("^http://127%.0%.0%.1:%d+/$"), "Invalid Tinymist address")
    local self = { stopped = false }
    local token = require("live_server.util").random_token(24)
    local instance = server.start({
        host = "127.0.0.1", port = 0, root = root,
        headers = { ["Cache-Control"] = "no-store", ["Referrer-Policy"] = "no-referrer" },
        live = { enabled = false, inject_script = false },
        token = token,
        protected_paths = { "^/typst%-inject%.js$" },
        routes = {
            ["/"] = function()
                if not self.html then return "Preview is not ready", 503 end
                return self.html, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
            end,
        },
        on_event = function(event)
            if not self.stopped and event == "typst-connected" then callbacks.connected() end
        end,
    })
    self.url = ("http://127.0.0.1:%d/?t=%s"):format(instance.port, token)

    function self:connected()
        return server.connected_client_count(instance) > 0
    end
    function self:prepared()
        return self.html ~= nil
    end
    function self:buffer(value)
        server.send_event(instance, "typst-buffer", vim.json.encode(value))
    end
    function self:follow()
        server.send_event(instance, "typst-follow", "{}")
    end
    function self:open()
        if self.stopped or not self.html or self:connected() then return end
        browser.open(self.url, nil, { title = "Typst Preview" })
    end
    function self:stop(exiting)
        if self.stopped then return end
        self.stopped = true
        server.send_event(instance, "typst-close")
        if self.fetch then self.fetch:kill(15) end
        if exiting then
            vim.wait(100, function() return not self:connected() end, 10)
            server.stop(instance)
        else
            vim.defer_fn(function() server.stop(instance) end, 150)
        end
    end

    self.fetch = vim.system({ vim.fn.has("win32") == 1 and "curl.exe" or "curl",
        "--silent", "--show-error", "--fail", "--noproxy", "*",
        "--max-time", "8", upstream }, { text = true }, vim.schedule_wrap(function(result)
        self.fetch = nil
        if self.stopped then return end
        if result.code ~= 0 then return callbacks.ready(result.stderr) end
        local origin = ("http://127.0.0.1:%d"):format(instance.port)
        local config = vim.json.encode({ upstream = upstream, origin = origin, token = token })
        local injection = '<base href="' .. upstream .. '"><script>window.__typstBridge=' .. config
            .. ';</script><script src="' .. origin .. '/typst-inject.js?t=' .. token .. '"></script>'
        local document, inserted = html_util.prepend_to(result.stdout, "head", injection)
        if not inserted then return callbacks.ready("Tinymist HTML has no head element") end
        self.html = document
        callbacks.ready()
    end))
    return self
end

return M
