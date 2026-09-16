# markdown-preview.nvim

Browser previews for Markdown and Typst in Neovim. The plugin contains its own small local HTTP/SSE server; it has no external runtime dependency.

Install with your Neovim package manager from `https://github.com/jay-waves/markdown-preview.nvim`, then configure:

```lua
require("markdown_preview").setup({
  default_theme = "auto",
  follow_current_buffer = true,
  scroll_sync = true,
})
require("typst_preview").setup()
```

Commands:

- `:MarkdownPreview`, `:MarkdownPreviewStop`
- `:TypstPreview`, `:TypstPreviewStop`

Typst requires Tinymist 0.15.2 or newer on `PATH`. Its LSP remains responsible for compilation and source mapping; the bundled `typst_preview` module supplies the browser wrapper and cursor-following bridge. `:TypstPreviewStop` stops the preview task and calls `tinymist.doClearCache` to release Tinymist's memoized analysis resources.

Typst preview remembers each buffer's browser position for the lifetime of the tab,
using its file URI. Returning to a buffer restores its vertical scroll offset;
moving the editor cursor resumes source following. Positions are approximate after
zooming or repagination. Restoration uses Tinymist's internal SVG renderer hooks; overlapping
document compilations are not identified by file in that interface.

Markdown options are configured through `markdown_preview.setup()`. Each module keeps its browser assets in its own `assets` directory under `lua/markdown_preview` or `lua/typst_preview`.

Set `custom_css` to a CSS file path, or a list of paths, to add styles after the bundled theme. The default `""` uses only the bundled styles.

Markdown preview uses one server and browser tab per Neovim instance. By default, entering another Markdown buffer retargets that preview to the current buffer.

Markdown and Typst preview sessions belong to the Neovim instance, rather than
individual buffers. They remain available across buffer unloads until explicitly
stopped, their underlying service exits, or Neovim exits. Stop commands release
the session's timers, browser bridge, server, and cached document state.

## Thanks

This project builds on the ideas and code from 
* [live-server.nvim](https://github.com/selimacerbas/live-server.nvim), 
* [markdown-preview.nvim](https://github.com/jay-waves/markdown-preview.nvim),  
* [Tinymist](https://github.com/Myriad-Dreamin/tinymist).
