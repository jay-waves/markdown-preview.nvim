local M = {}
local session_runtime = require("live_server.session")
local html_util = require("live_server.html")
local source_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local root = vim.fs.joinpath(source_dir, "assets")

function M.start(upstream, callbacks)
    assert(upstream:match("^http://127%.0%.0%.1:%d+/$"), "Invalid Tinymist address")
    local self = { stopped = false }
    local instance = session_runtime.start({
        host = "127.0.0.1", port = 0, root = root,
        headers = { ["Cache-Control"] = "no-store", ["Referrer-Policy"] = "no-referrer" },
        live = { enabled = false, inject_script = false },
        protected_paths = { "^/typst%-inject%.js$" },
        routes = {
            ["/"] = function()
                if not self.html then return "Preview is not ready", 503 end
                return self.html, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
            end,
        },
        on_event = function(event, data)
            if self.stopped then return end
            if event == "typst-connected" then callbacks.connected()
            elseif event == "typst-outline-jump" then callbacks.outline_jump(data)
            elseif event == "typst-preview-jump" then callbacks.preview_jump() end
        end,
        browser_title = "Typst Preview",
    })
    self.preview = instance
    self.url = instance.url

    function self:connected()
        return instance:connected()
    end
    function self:prepared()
        return self.html ~= nil
    end
    function self:buffer(value)
        instance:send("typst-buffer", vim.json.encode(value))
    end
    function self:follow()
        instance:send("typst-follow", "{}")
    end
    function self:outline(value)
        instance:send("typst-outline", vim.json.encode(value))
    end
    function self:cursor(line)
        instance:send("typst-cursor", vim.json.encode({ line = line }))
    end
    function self:open()
        if self.stopped or not self.html or self:connected() then return end
        instance:open()
    end
    function self:stop(exiting)
        if self.stopped then return end
        self.stopped = true
        if self.fetch then self.fetch:kill(15) end
        instance:stop(exiting, "typst-close")
    end

    self.fetch = vim.system({ vim.fn.has("win32") == 1 and "curl.exe" or "curl",
        "--silent", "--show-error", "--fail", "--noproxy", "*",
        "--max-time", "8", upstream }, { text = true }, vim.schedule_wrap(function(result)
        self.fetch = nil
        if self.stopped then return end
        if result.code ~= 0 then return callbacks.ready(result.stderr) end
        local origin = ("http://127.0.0.1:%d"):format(instance.server.port)
        local config = vim.json.encode({ upstream = upstream, origin = origin, token = instance.token })
        local injection = html_util.tag("base", { href = upstream })
            .. html_util.tag("link", { rel = "stylesheet", href = origin .. "/typst-preview.css?t=" .. instance.token })
            .. html_util.tag("script", nil, "window.__typstBridge=" .. config .. ";")
            .. html_util.tag("script", { src = origin .. "/typst-inject.js?t=" .. instance.token }, "")
        local document, inserted = html_util.prepend_to(result.stdout, "head", injection)
        if not inserted then return callbacks.ready("Tinymist HTML has no head element") end
        self.html = document
        callbacks.ready()
    end))
    return self
end

return M
