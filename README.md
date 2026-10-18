# markdown-table-valign.nvim

Virtually aligns markdown table columns — each column becomes as wide as its
widest cell — using **inline virtual text**. The buffer is **never modified**:
no real spaces or hyphens are inserted, so the file on disk is always exactly
as it was, whether you save, quit, or never touch it again.

```
Ragged Source                   Virtual View (File Unchanged)

| Name | Long header here |     | Name             | Long header here |
|---|---|                   ──► |------------------|------------------|
| a very long cell | x |        | a very long cell | x                |
| y | short |                   | y                | short            |
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

## TODO / Roadmap

### 1. Virtual reflow for tables wider than the window (the big one)

**Goal.** Rows wider than the window are displayed *word-wrapped per column,
proportionally* (like a rendered markdown table in a browser), while the
buffer remains untouched. Today such rows simply overflow (with `nowrap =
"auto"`) and must be read by scrolling sideways.

**Why it is possible.** Neovim 0.10+ extmarks provide the two missing pieces:

- `conceal_lines = ""` — an extmark spanning a buffer line makes the line not
  be rendered at all (this is how render-markdown.nvim hides code fences).
- `virt_lines = { ... }` — fully virtual screen lines attached to a real line.
  The cursor can never enter them, and they still render when their anchor
  line is concealed.

Combined: conceal each overflowing real row and render, in its place, N
virtual sub-rows containing the word-wrapped cell fragments.

**Implementation sketch.**

1. *Layout engine (pure function, in a new `lua/markdown-table-valign/layout.lua`).*
   Input: the table's rows/slots (`row_slots`), natural column widths,
   alignment hints, and the available width (window text width minus gutters).
   Steps:
   - Only rows whose rendered width exceeds the available width get reflowed;
     everything else keeps the current inline alignment (no concealment), so
     normal tables render exactly as today.
   - Shrink overflowing columns proportionally down to a sensible floor
     (e.g. `max(longest word, 6)` columns), re-measuring with
     `strdisplaywidth` (wide-char safe).
   - Greedy word-wrap each cell's content (split on spaces; respect escaped
     `\|`) into fragments. A logical row becomes `max(fragments per column)`
     sub-rows; empty cells contribute blank fragments.
   - Rebuild the separator row virtually to match the new display widths
     (hyphens, honoring `:` placement).
   - Output: pure data — a list of sub-rows, each a list of chunks
     `{ text, is_padding, align }` — with zero Neovim API calls, so it can be
     unit-tested exhaustively.

2. *Rendering.*
   - Per overflowing row: one extmark with `conceal_lines = ""` spanning the
     line, plus `virt_lines` attached to it carrying the generated sub-rows:
     text chunks styled normally, padding chunks (`-`/spaces) styled with
     `MarkdownTableValignVirt`, separated by `|` chunks.
   - The row under concealment still owns the cursor position, so keep
     `virt_lines` ordered and document that vertical motion (`j`/`k`) skips
     straight to the next real row.

3. *Interaction policy (the hard UX part).*
   - The cursor cannot enter `virt_lines`, so editing a reflowed row means
     typing into invisible text. Policy v1: reflow is a per-buffer toggle
     (`:MarkdownTableReflow`, default off) and is automatically suspended for
     any table the cursor edits — on `InsertEnter`/`TextChangedI` inside a
     reflowed table, drop its concealment and show the real (aligned) rows;
     restore on `InsertLeave`/`CursorMoved` away.
   - Policy v2 (nicer): reflow every table *except* the one under the cursor.

4. *Window coupling.*
   - Available width is per-window, so the reflow decision is recomputed on
     `WinResized`/`WinEnter` (same pattern as the existing `nowrap` logic,
     including "focused window wins" for multi-window conflicts).
   - Cache layouts per `(changedtick, width)`; debounce resize handling.

5. *Compatibility & guards.*
   - Verify `conceal_lines` behavior with the installed `conceallevel`
     settings; if another conceal-based renderer is active
     (render-markdown.nvim, markview.nvim), disable reflow by default or
     coordinate to avoid fighting over the same lines.
   - Text inside `virt_lines` does not receive the original line's treesitter
     highlighting. v1: plain text + our padding highlight; inline-code spans
     could be detected during parsing and styled with `@markup.raw`-style
     groups as a cheap improvement.

6. *Testing.*
   - Exhaustive unit tests of the layout engine (pure data in/out).
   - Rendering tests using the same reconstruction technique as the current
     `rendered()` test helper, plus assertions on `conceal_lines`/`virt_lines`
     extmark counts.

### 2. Smaller items

- [ ] Support pipe-less GFM tables (`a | b` without leading/trailing pipes).
- [ ] Handle tabs inside cells (expand by `tabstop` for width computation).
- [ ] Opt-in `keymaps = true` for horizontal-scroll mappings.
- [ ] Incremental re-alignment (only re-pad tables intersecting changed
      lines) for very large buffers.
- [ ] Publish to GitHub with lazy.nvim/rocks.nvim metadata; add a `LICENSE`
      file with the real copyright holder name; generate a vimdoc help file
      from this README.

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

## Authorship

- **Idea, design decisions, requirements and real-world testing:** Rubén Gómez.
- **Design discussion and implementation:** GLM (Z.ai), as a coding pair, October 2026.
