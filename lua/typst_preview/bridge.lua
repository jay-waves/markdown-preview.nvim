-- Experimental wrapper around Tinymist's LSP-owned preview frontend.
local M = {}
local server = require("live_server.server")
local source_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local root = vim.fs.normalize(vim.fs.joinpath(source_dir, "..", "..", "assets"))

function M.start(upstream, on_scroll)
    assert(upstream:match("^http://127%.0%.0%.1:%d+/$"), "Invalid Tinymist address")
    local self = { sequence = 0, stopped = false }
    local token = require("live_server.util").random_token(24)
    local instance

    instance = server.start({
        host = "127.0.0.1", port = 0, root = root,
        default_index = vim.fs.joinpath(root, "typst-preview.html"),
        headers = { ["Cache-Control"] = "no-store", ["Referrer-Policy"] = "no-referrer" },
        live = { enabled = false, inject_script = false },
        features = { dirlist = { enabled = false } },
        token = token,
        protected_paths = { "^/$", "^/typst%-preview%.html$", "^/typst%-inject%.js$" },
        routes = {
            ["/state"] = function()
                return vim.json.encode(self.latest or { active = false, seq = 0 }), 200,
                    { ["Content-Type"] = "application/json" }
            end,
            ["/frame"] = function()
                if not self.html then
                    return "Preview is not ready", 503, { ["Content-Type"] = "text/plain" }
                end
                return self.html, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
            end,
        },
        on_event = function(event, data)
            if self.stopped or event ~= "typst-scroll" then return end
            local ok, value = pcall(vim.json.decode, data)
            local latest = self.latest
            if ok and type(value) == "table" and type(value.seq) == "number"
                and latest and value.seq == latest.seq and self.consumed ~= value.seq then
                self.consumed = value.seq
                on_scroll(latest)
            end
        end,
    })
    self.origin = "http://127.0.0.1:" .. instance.port
    self.url = self.origin .. "/?t=" .. token

    function self:send(event, value)
        server.send_event(instance, event, vim.json.encode(value))
    end
    function self:cursor(value)
        self.sequence = self.sequence + 1
        value.seq = self.sequence
        self.latest = value
        self:send("cursor", value)
    end
    function self:connected()
        return server.connected_client_count(instance) > 0
    end
    function self:open()
        if self.stopped or not self.html or self:connected() then return end
        local _, err = vim.ui.open(self.url)
        if err then vim.notify(tostring(err), vim.log.levels.ERROR, { title = "Typst Preview" }) end
    end
    function self:stop(exiting)
        if self.stopped then return end
        self.stopped = true
        self:send("typst-close", {})
        if self.fetch then self.fetch:kill(15) end
        if exiting then
            vim.wait(100, function() return not self:connected() end, 10)
            server.stop(instance)
        else
            vim.defer_fn(function() server.stop(instance) end, 150)
        end
    end
    function self:prepare(callback)
        self.fetch = vim.system({ vim.fn.has("win32") == 1 and "curl.exe" or "curl",
            "--silent", "--show-error", "--fail", "--noproxy", "*",
            "--max-time", "8", upstream }, { text = true }, vim.schedule_wrap(function(result)
            self.fetch = nil
            if self.stopped then return end
            if result.code ~= 0 then return callback(result.stderr) end
            local config = vim.json.encode({ upstream = upstream, origin = self.origin })
            local injection = '<base href="' .. upstream .. '"><script>window.__typstBridge=' .. config
                .. ';</script><script src="' .. self.origin .. '/typst-inject.js?t=' .. token .. '"></script>'
            local html, count = result.stdout:gsub("(<[hH][eE][aA][dD][^>]*>)", function(head)
                return head .. injection
            end, 1)
            if count ~= 1 then return callback("Tinymist HTML has no head element") end
            self.html = html
            callback()
        end))
    end
    return self
end

return M
