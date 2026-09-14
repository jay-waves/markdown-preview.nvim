local uv = vim.uv
local M = {}

function M.notify(message, opts, level)
    if opts and opts.notify == false then return end
    vim.notify(message, vim.log.levels[level or "INFO"], { title = "Preview" })
end

function M.joinpath(...)
    return vim.fs.joinpath(...)
end

function M.url_decode(value)
    return (value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function M.url_encode(value)
    return (tostring(value):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function M.random_token(bytes)
    math.randomseed((uv.hrtime() % 2147483647) + os.time() + vim.fn.getpid())
    local result = {}
    for index = 1, bytes or 16 do
        result[index] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(result)
end

function M.secure_compare(left, right)
    if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then return false end
    local mismatch = 0
    for index = 1, #left do
        if left:byte(index) ~= right:byte(index) then mismatch = mismatch + 1 end
    end
    return mismatch == 0
end

function M.path_has_prefix(path, prefix)
    local separator = package.config:sub(1, 1)
    if prefix:sub(-1) ~= separator then prefix = prefix .. separator end
    return path == prefix:sub(1, -2) or path:sub(1, #prefix) == prefix
end

function M.html_escape(value)
    local entities = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
    return (tostring(value):gsub("[&<>\"']", entities))
end

function M.parse_liveignore(root)
    local file = io.open(vim.fs.joinpath(root, ".liveignore"), "r")
    if not file then return {} end
    local patterns = {}
    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            patterns[#patterns + 1] = line:gsub("([%.%+%-%^%$%(%)%%])", "%%%1"):gsub("%*", ".*")
        end
    end
    file:close()
    return patterns
end

function M.match_ignore(path, patterns)
    for _, pattern in ipairs(patterns) do
        if path:find(pattern) then return true end
    end
    return false
end

return M
