# markdown-table-valign.nvim

Virtually aligns markdown table columns — each column becomes as wide as its
widest cell — using **inline virtual text**. The buffer is **never modified**:
no real spaces or hyphens are inserted, so the file on disk is always exactly
as it was, whether you save, quit, or never touch it again.

```
 ragged source                    virtual view (file unchanged)
┌──────────────────────────┐      ┌─────────────────────────────────────┐
| Name | Long header here | │      | Name   | Long header here          | │
|---|---------------------| │  ──► |--------|---------------------------| │
| a very long cell | x      | │      | a very long cell          | x    | │
| y | short                | │      | y                 | short           | │
└──────────────────────────┘      └─────────────────────────────────────┘
```

## How it works

- **On load** (`FileType markdown`) and on every text change, each table is
  aligned to its *natural* width (the widest cell per column) — never
  stretched beyond it, regardless of window size.
- Body cells are padded with virtual **spaces**; separator rows are padded
  with virtual **hyphens**, so rules render continuously.
- Column alignment hints (`|:---|`, `---:|`, `:---:|`) are respected.
- Virtual characters are highlighted with a dim style
  (`MarkdownTableValignVirt`, linked to `Comment` by default) so it is
  visually obvious that they are not real. Neovim natively skips inline
  virtual text during cursor movement.
- **On save** the padding is cleared. Since the buffer is never modified, the
  saved file is identical to the original regardless; padding is re-applied
  afterwards by default (`expand_after_save`).
- Tables inside fenced (```` ``` ````/`~~~`) or indented code blocks are
  skipped. Rows with a missing trailing pipe or missing columns are padded
  virtually too, so they still look right.

## Requirements

- Neovim **0.10+** (inline virtual text).

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "~/..." -- or your plugin host once published
}
```

There is no configuration required; dropping the plugin into
`pack/dist/start/` also works (which is how this copy is installed).

## Configuration

```lua
require("markdown-table-valign").setup({
  enabled = true,               -- master switch
  highlight = "Comment",        -- highlight group for virtual characters
                                -- (false / "" disables styling)
  highlight_bg_alpha = 0.1,     -- strength of the background tint (0 disables)
  nowrap = "auto",              -- "auto" | "always" | false (see below)
  max_file_bytes = 1024 * 1024, -- skip larger files (warns once)
  expand_after_save = true,     -- re-align tables after :w
})
```

### Reading tables wider than the window (`nowrap`)

Inline virtual text cannot introduce line breaks, so a table wider than the
window would normally wrap mid-column and become unreadable. The `nowrap`
option handles this:

- `"auto"` (default) — `wrap` is turned **off** for a window when its buffer
  contains a table wider than that window (re-evaluated on resize), and back
  **on** when everything fits. Note this affects the whole window, prose
  included.
- `"always"` — `wrap` off in every markdown window.
- `false` — never touch `wrap`.

If you manually toggle `wrap` (`:setlocal wrap!`) the plugin stops managing it
for that window/buffer. With `wrap` off, read wide tables with the horizontal
scroll keys:

| Keys | Effect |
|---|---|
| `zh` / `zl` | scroll view 1 column left/right (like `Ctrl+Y`/`Ctrl+E`, sideways) |
| `zH` / `zL` | scroll half a screen width |
| `zs` / `ze` | snap the view to the cursor |

`vim.o.sidescroll = 1` makes all horizontal scrolling smooth (1 column at a
time) instead of jumping half a screen per keypress.

### Styling of virtual characters

Virtual characters use the highlight group `MarkdownTableValignVirt`. By
default it takes its foreground from `highlight` (dimmed, like `Comment`) and
adds a subtle **background tint** computed at runtime by blending your Normal
background toward that foreground (`highlight_bg_alpha`, 0–1). This makes even
the padded spaces visibly "virtual" — you see faint highlighted bands where
the padding is — while staying subtle and adapting automatically to any
colorscheme (re-computed on `ColorScheme`). Set `highlight_bg_alpha = 0` to
get plain dimmed text without background, or define
`MarkdownTableValignVirt` yourself after `setup()` for full control.

## Commands

| Command | Effect |
|---|---|
| `:MarkdownTableAlign` | Re-align tables of the current buffer now |
| `:MarkdownTableAlignEnable` | Enable alignment |
| `:MarkdownTableAlignDisable` | Disable and clear all padding |

## Known limitations

- Tables must use leading pipes (`| a | b |` style); pipe-less GFM tables
  (`a|b`) are not detected.
- Tabs inside table cells confuse width computation (avoid them in tables).
- Byte-exact alignment isn't guaranteed for cells containing wide (CJK)
  characters mixed with padding — display width is used, which is correct in
  terminals with proper wide-char support.
- A table already wider than its window stays wider (virtual text can add
  width but never hide content).

## Development

Run the sanity tests headlessly:

```sh
nvim --headless -u NONE -l test/sanity.lua
```

## License

MIT
