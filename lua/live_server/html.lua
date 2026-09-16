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
        if type(value) == "table" and value.file then value = M.read(value.file) end
        content = content:gsub(vim.pesc(placeholder), function() return tostring(value) end)
    end
    return content
end

function M.tag(name, attributes, content)
    local parts = { "<", name }
    for key, value in pairs(attributes or {}) do
        if value ~= false and value ~= nil then
            parts[#parts + 1] = value == true and (" " .. key)
                or (" " .. key .. '=\"' .. M.escape(value) .. '\"')
        end
    end
    if content == nil then
        parts[#parts + 1] = ">"
    else
        parts[#parts + 1] = ">"
        parts[#parts + 1] = content
        parts[#parts + 1] = "</" .. name .. ">"
    end
    return table.concat(parts)
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

function M.add_attributes(content, element, attributes)
    local result, count = content:gsub("(" .. element_pattern(element, false) .. ")", function(tag)
        local suffix = {}
        for key, value in pairs(attributes or {}) do
            if value ~= false and value ~= nil then
                suffix[#suffix + 1] = value == true and (" " .. key)
                    or (" " .. key .. '=\"' .. M.escape(value) .. '\"')
            end
        end
        table.sort(suffix)
        return tag:sub(1, -2) .. table.concat(suffix) .. ">"
    end, 1)
    return result, count == 1
end

---Assemble an HTML document from a template and declarative injections.
---@param options { template: string, replacements?: table, attributes?: table, prepend?: table, append?: table }
function M.build(options)
    local content = M.read(assert(options.template, "html.build: template is required"))
    content = M.render(content, options.replacements)
    for element, attributes in pairs(options.attributes or {}) do
        local inserted
        content, inserted = M.add_attributes(content, element, attributes)
        if not inserted then error("HTML template has no " .. element .. " element") end
    end
    for element, fragment in pairs(options.prepend or {}) do
        local inserted
        content, inserted = M.prepend_to(content, element, fragment)
        if not inserted then error("HTML template has no " .. element .. " element") end
    end
    for element, fragment in pairs(options.append or {}) do
        local inserted
        content, inserted = M.append_to(content, element, fragment)
        if not inserted then error("HTML template has no " .. element .. " element") end
    end
    return content
end

---Read files and wrap their contents in style elements.
function M.styles(paths, options)
    options = options or {}
    local blocks = {}
    for index, path in ipairs(type(paths) == "table" and paths or { paths }) do
        if type(path) == "string" and path ~= "" then
            local resolved = options.expand == false and path or vim.fn.expand(path)
            local ok, css = pcall(M.read, resolved)
            if ok then
                blocks[#blocks + 1] = M.tag("style", options.attributes, "\n" .. css .. "\n")
            elseif options.on_error then
                options.on_error(index, path, resolved)
            end
        elseif path ~= nil and options.on_error then
            options.on_error(index, path)
        end
    end
    return table.concat(blocks, "\n")
end

function M.escape(value)
    local entities = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
    return (tostring(value):gsub("[&<>\"']", entities))
end

return M
