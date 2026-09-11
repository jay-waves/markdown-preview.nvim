-- plugin/markdown-preview.lua
if vim.g.loaded_markdown_preview then
	return
end
vim.g.loaded_markdown_preview = true

vim.api.nvim_create_autocmd("VimLeavePre", {
	group = vim.api.nvim_create_augroup("MarkdownPreviewLifecycle", { clear = true }),
	callback = function()
		local preview = package.loaded["markdown_preview"]
		if preview and (preview._server_instance or preview._active_bufnr) then
			preview.stop()
		end
	end,
	desc = "Stop Markdown preview and close owned preview tabs",
})

-- User commands
vim.api.nvim_create_user_command("MarkdownPreview", function()
	require("markdown_preview").start()
end, {})

vim.api.nvim_create_user_command("MarkdownPreviewRefresh", function()
	require("markdown_preview").refresh()
end, {})

vim.api.nvim_create_user_command("MarkdownPreviewStop", function()
	require("markdown_preview").stop()
end, {})
