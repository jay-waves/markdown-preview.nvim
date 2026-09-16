local M = {}

function M.read(path)
    assert(type(path) == "string" and path ~= "", "html.read: path is required")
    local fd = assert(vim.uv.fs_open(path, "r", 420))
    local stat = assert(vim.uv.fs_fstat(fd))
    local content = assert(vim.uv.fs_read(fd, stat.size, 0))
    assert(vim.uv.fs_close(fd))
    return content
end

---Replace literal placeholders. Replacement values may safely contain `%`.
function M.render(content, values)
    for placeholder, value in pairs(values or {}) do
        content = content:gsub(vim.pesc(placeholder), function() return tostring(value) end)
    end
    return content
end

local function element_pattern(name, closing)
    assert(type(name) == "string" and name:match("^[%a][%w:_-]*$"), "invalid HTML element name")
    local chars = {}
    for index = 1, #name do
        local char = name:sub(index, index)
        chars[#chars + 1] = "[" .. char:lower() .. char:upper() .. "]"
    end
    return closing and ("</" .. table.concat(chars) .. "%s*>")
        or ("<" .. table.concat(chars) .. "[^>]*>")
end

function M.prepend_to(content, element, fragment)
    local result, count = content:gsub("(" .. element_pattern(element, false) .. ")", function(tag)
        return tag .. fragment
    end, 1)
    return result, count == 1
end

function M.append_to(content, element, fragment)
    local result, count = content:gsub("(" .. element_pattern(element, true) .. ")", function(tag)
        return fragment .. tag
    end, 1)
    return result, count == 1
end

function M.escape(value)
    local entities = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
    return (tostring(value):gsub("[&<>\"']", entities))
end

return M
