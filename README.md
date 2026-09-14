# markdown-preview.nvim

Browser previews for Markdown and Typst in Neovim. The plugin contains its own small local HTTP/SSE server; it has no external runtime dependency.

Install with your Neovim package manager from `https://github.com/jay-waves/markdown-preview.nvim`, then configure:

```lua
require("markdown_preview").setup({
  default_theme = "auto",
  follow_current_buffer = true,
  scroll_sync = true,
  initial_scroll = false,
})
require("typst_preview").setup()
```

Commands:

- `:MarkdownPreview`, `:MarkdownPreviewRefresh`, `:MarkdownPreviewStop`
- `:TypstPreview`, `:TypstPreviewStop`

Typst requires `tinymist` on `PATH`. Its LSP remains responsible for compilation and source mapping; the bundled `typst_preview` module supplies the browser wrapper and cursor-following bridge.

Markdown options are configured through `markdown_preview.setup()`. The implementation and browser assets live under `lua/markdown_preview`, `lua/typst_preview`, and `assets`.

## Thanks

This project builds on the ideas and code from 
* [live-server.nvim](https://github.com/selimacerbas/live-server.nvim), 
* [markdown-preview.nvim](https://github.com/jay-waves/markdown-preview.nvim),  
* [Tinymist](https://github.com/Myriad-Dreamin/tinymist).
