-- plugin/html-preview.lua
if vim.g.loaded_html_preview then return end
vim.g.loaded_html_preview = true

local group = vim.api.nvim_create_augroup("HtmlPreviewLifecycle", { clear = true })
vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
        local preview = package.loaded["html_preview"]
        if preview then preview.stop() end
    end,
    desc = "Stop HTML preview and close owned preview tabs",
})

vim.api.nvim_create_user_command("HtmlPreview", function()
    require("html_preview").start()
end, { desc = "Open the current HTML file in a browser" })

vim.api.nvim_create_user_command("HtmlPreviewStop", function()
    require("html_preview").stop()
end, { desc = "Stop HTML preview" })
