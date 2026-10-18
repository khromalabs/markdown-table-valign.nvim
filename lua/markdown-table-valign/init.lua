-- markdown-table-valign.nvim ─────────────────────────────────────────────────
-- Virtually aligns markdown table columns (each column as wide as its widest
-- cell) using *inline virtual text*. The buffer is never modified: no real
-- spaces or hyphens are inserted, so the file on disk is always exactly as
-- it was, whether you save, quit, or never touch it again.
--
-- Behaviour:
--   * On load / text change, every table is aligned to its natural width
--     (never stretched beyond it, regardless of window size).
--   * Body cells are padded with virtual spaces; separator rows are padded
--     with virtual hyphens, so rules render continuously.
--   * Column alignment hints (`|:---|`, `---:|`, `:---:|`) are respected.
--   * Virtual characters are highlighted (see the `highlight` option) so it
--     is visible that they are not real.
--   * On save, padding is cleared; optionally re-applied afterwards.
--   * Tables inside fenced code blocks and indented code blocks are skipped.

local M = {}

local NS = vim.api.nvim_create_namespace("markdown-table-valign")
local HL = "MarkdownTableValignVirt"

local defaults = {
  enabled = true,               -- master switch
  highlight = "Comment",        -- highlight group for virtual characters
  highlight_bg_alpha = 0.1,     -- background tint strength (0 disables bg)
  nowrap = "auto",              -- "auto"|"always"|false: disable wrap for wide tables
  max_file_bytes = 1024 * 1024, -- skip larger files (with a one-time warning)
  expand_after_save = true,     -- re-align tables after :w
}

local config = vim.tbl_deep_extend("force", {}, defaults)

local augroup
local warned = {}      -- [bufnr] = true, warn about oversized files only once
local state = {}       -- [bufnr] = { tick, active } (skip redundant work)
local parse_cache = {} -- [bufnr] = { tick, tables }

-- ── parsing ──────────────────────────────────────────────────────────────────

-- Byte positions (1-based) of all unescaped `|` in a line.
local function find_pipes(line)
  local pipes = {}
  local i = 1
  while true do
    local p = line:find("|", i, true)
    if not p then
      break
    end
    if p == 1 or line:sub(p - 1, p - 1) ~= "\\" then
      pipes[#pipes + 1] = p
    end
    i = p + 1
  end
  return pipes
end

-- Split a table row into "slots" (the text between consecutive pipes).
-- Each slot: { text, s, e, open } with s/e = 1-based byte indices of the
-- slot's first/last character; `open` means the row lacks a trailing pipe,
-- so the slot extends to end-of-line.
local function row_slots(line)
  local pipes = find_pipes(line)
  if #pipes == 0 then
    return nil
  end
  local slots = {}
  for j = 1, #pipes - 1 do
    local a, b = pipes[j] + 1, pipes[j + 1] - 1
    slots[#slots + 1] = { text = line:sub(a, b), s = a, e = b, open = false }
  end
  local last = pipes[#pipes]
  if last < #line then
    slots[#slots + 1] = { text = line:sub(last + 1), s = last + 1, e = #line, open = true }
  end
  return slots
end

local function is_delim_slots(slots)
  if not slots or #slots == 0 then
    return false
  end
  for _, s in ipairs(slots) do
    if not s.text:match("^%s*:?-+:?%s*$") then
      return false
    end
  end
  return true
end

local function slot_aligns(slots)
  local out = {}
  for _, s in ipairs(slots) do
    local l = s.text:match("^%s*(:)") ~= nil
    local r = s.text:match("(:)%s*$") ~= nil
    if l and r then
      out[#out + 1] = "center"
    elseif r then
      out[#out + 1] = "right"
    else
      out[#out + 1] = "left"
    end
  end
  return out
end

local function is_table_line(line)
  return line:match("^%s*|") ~= nil
end

local function is_indented_code(line)
  return line:match("^    ") ~= nil or line:match("^\t") ~= nil
end

-- Find all table blocks in the buffer. Returns a list of
-- { start, stop } with 1-based line numbers (inclusive).
local function parse_tables(lines)
  local tables = {}
  local in_fence = false
  local i, n = 1, #lines
  while i <= n do
    local line = lines[i]
    local fence = not in_fence and (line:match("^%s*(```+)") or line:match("^%s*(~~~+)"))
    if fence then
      in_fence = true
      i = i + 1
    elseif in_fence then
      if line:match("^%s*```+") or line:match("^%s*~~~+") then
        in_fence = false
      end
      i = i + 1
    elseif is_indented_code(line) then
      i = i + 1
    elseif is_table_line(line) then
      local j = i
      while j <= n and is_table_line(lines[j]) and not is_indented_code(lines[j]) do
        j = j + 1
      end
      if j - i >= 2 and is_delim_slots(row_slots(lines[i + 1])) then
        tables[#tables + 1] = { start = i, stop = j - 1 }
      end
      i = j
    else
      i = i + 1
    end
  end
  return tables
end

local function get_tables(bufnr, lines)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = parse_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.tables
  end
  local tables = parse_tables(lines)
  parse_cache[bufnr] = { tick = tick, tables = tables }
  return tables
end

-- ── padding ──────────────────────────────────────────────────────────────────

local function set_pad(bufnr, row0, col, text)
  local vt = { text }
  if config.highlight and config.highlight ~= "" then
    vt[2] = HL
  end
  vim.api.nvim_buf_set_extmark(bufnr, NS, row0, col, {
    virt_text = { vt },
    virt_text_pos = "inline",
  })
end

-- Compute per-column natural (maximum) slot widths of a table.
-- Returns S, rows ({ r, slots }), ncols, delim_slots; or nil if not a table.
local function column_widths(lines, t)
  local delim_slots = row_slots(lines[t.start + 1])
  if not is_delim_slots(delim_slots) then
    return nil
  end
  local ncols = #delim_slots
  local S = {}
  for i = 1, ncols do
    S[i] = 0
  end
  local rows = {}
  for r = t.start, t.stop do
    local slots = row_slots(lines[r])
    if slots then
      rows[#rows + 1] = { r = r, slots = slots }
      for i = 1, math.min(#slots, ncols) do
        local w = vim.fn.strdisplaywidth(slots[i].text)
        if w > S[i] then
          S[i] = w
        end
      end
    end
  end
  return S, rows, ncols, delim_slots
end

-- Align one table: each column becomes as wide as its widest slot.
local function pad_table(bufnr, lines, t)
  local delim_line = t.start + 1
  local S, rows, ncols, delim_slots = column_widths(lines, t)
  if not S then
    return
  end
  local aligns = slot_aligns(delim_slots)

  -- Place one extmark per padding point. Separator rows are padded with
  -- hyphens (so rules stay continuous), body rows with spaces. Padding is
  -- inserted adjacent to the cell content, respecting alignment hints.
  for _, row in ipairs(rows) do
    local slots = row.slots
    local row0 = row.r - 1
    local padchar = (row.r == delim_line) and "-" or " "
    for i = 1, math.min(#slots, ncols) do
      local slot = slots[i]
      local pad = S[i] - vim.fn.strdisplaywidth(slot.text)
      if pad > 0 then
        local a = aligns[i] or "left"
        -- cell = slot content without surrounding source spaces; pad hugs it
        local lead = #slot.text:match("^%s*")
        local trail = #slot.text:match("%s*$")
        local cell_s, cell_e = slot.s + lead, slot.e - trail
        if lead + trail >= #slot.text then -- empty cell: pad at slot edges
          cell_s, cell_e = slot.s, slot.e
        end
        local left, right = 0, 0
        if a == "right" then
          left = pad
        elseif a == "center" then
          left = math.floor(pad / 2)
          right = pad - left
        else
          right = pad
        end
        -- extmark col is a 0-based byte offset: insert *before* char at
        -- 1-based c means col = c - 1; insert *after* it means col = c.
        if left > 0 then
          set_pad(bufnr, row0, cell_s - 1, string.rep(padchar, left))
        end
        if right > 0 then
          set_pad(bufnr, row0, cell_e, string.rep(padchar, right))
        end
      end
    end
    -- Rows with fewer cells than columns: fill the remainder virtually
    -- (virtual pipes + spaces) so the table still looks complete.
    if #slots < ncols then
      local txt = slots[#slots].open and "|" or ""
      for i = #slots + 1, ncols do
        txt = txt .. string.rep(" ", S[i]) .. "|"
      end
      if txt ~= "" then
        set_pad(bufnr, row0, #lines[row.r], txt)
      end
    end
  end
end

-- ── wrap management ──────────────────────────────────────────────────────────

-- Widest natural table width in the buffer (cached per changedtick).
local function max_natural_width(bufnr)
  local cached = parse_cache[bufnr]
  if cached and cached.max_width ~= nil then
    return cached.max_width
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local max = 0
  for _, t in ipairs(get_tables(bufnr, lines)) do
    local S, _, ncols = column_widths(lines, t)
    if S then
      local w = ncols + 1
      for _, c in ipairs(S) do
        w = w + c
      end
      if w > max then
        max = w
      end
    end
  end
  if parse_cache[bufnr] then
    parse_cache[bufnr].max_width = max
  end
  return max
end

local exempt = {}   -- [winid] = bufnr: user took manual control of 'wrap'
local applying = false

local function set_wrap_for_win(win, bufnr)
  if not config.nowrap or config.nowrap == false then
    return
  end
  if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "markdown" then
    return
  end
  if exempt[win] == bufnr then
    return -- user manually toggled 'wrap' for this window/buffer
  end
  local info = vim.fn.getwininfo(win)[1]
  local textwidth = info and (info.width - (info.textoff or 0))
    or vim.api.nvim_win_get_width(win)
  local needs_nowrap = config.nowrap == "always" or max_natural_width(bufnr) > textwidth
  applying = true
  vim.wo[win].wrap = not needs_nowrap
  applying = false
end

local function set_wrap_for_buf(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    set_wrap_for_win(win, bufnr)
  end
end

-- ── entry points ─────────────────────────────────────────────────────────────

local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  if state[bufnr] then
    state[bufnr].active = false
  end
end

-- Align all tables of `bufnr` (width is independent of any window).
function M._align(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "markdown" then
    return
  end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local st = state[bufnr]
  if st and st.active and st.tick == tick then
    return -- nothing changed
  end

  clear(bufnr)
  if not config.enabled then
    return
  end

  local nlines = vim.api.nvim_buf_line_count(bufnr)
  local bytes = vim.api.nvim_buf_get_offset(bufnr, nlines)
  if bytes > config.max_file_bytes then
    if not warned[bufnr] then
      warned[bufnr] = true
      vim.notify(
        ("markdown-table-valign: buffer is %s bytes (max %s), skipping alignment"):format(
          tostring(bytes),
          tostring(config.max_file_bytes)
        ),
        vim.log.levels.WARN
      )
    end
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, t in ipairs(get_tables(bufnr, lines)) do
    pad_table(bufnr, lines, t)
  end

  state[bufnr] = { tick = tick, active = true }
end

function M.refresh_buf(bufnr)
  M._align(bufnr)
end

function M.refresh()
  M.refresh_buf(vim.api.nvim_get_current_buf())
end

function M.enable()
  config.enabled = true
  M.refresh()
end

function M.disable()
  config.enabled = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "markdown" then
      clear(bufnr)
    end
  end
end

-- ── highlight ────────────────────────────────────────────────────────────────

-- Resolve `attr` ("fg"/"bg") of a group, following :highlight links.
local function resolve_hl(name, attr)
  local seen = {}
  local cur = name
  for _ = 1, 5 do
    if seen[cur] then
      break
    end
    seen[cur] = true
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = cur, link = false })
    if not ok or not hl then
      return nil
    end
    if hl[attr] then
      return hl[attr]
    end
    if not hl.link then
      return nil
    end
    cur = hl.link
  end
  return nil
end

-- Blend `fg` over `bg` (both 0xRRGGBB) by `alpha` (0..1).
local function blend(fg, bg, alpha)
  local function chan(c, s)
    return math.floor(c / 2 ^ s) % 256
  end
  local function mix(a, b)
    return math.floor(a + (b - a) * alpha + 0.5)
  end
  return mix(chan(bg, 16), chan(fg, 16)) * 65536
    + mix(chan(bg, 8), chan(fg, 8)) * 256
    + mix(chan(bg, 0), chan(fg, 0))
end

local function apply_highlight()
  local name = config.highlight
  if not name or name == "" then
    vim.api.nvim_set_hl(0, HL, { default = true, clear = true })
    return
  end
  -- Preferred style: foreground from `highlight`, plus a subtle background
  -- tint computed by blending the Normal background toward that foreground,
  -- so even spaces are visibly "virtual" in any colorscheme.
  local alpha = tonumber(config.highlight_bg_alpha) or 0
  if alpha > 0 then
    local fg = resolve_hl(name, "fg")
    local bg = resolve_hl("Normal", "bg")
    if fg and bg then
      vim.api.nvim_set_hl(0, HL, { fg = fg, bg = blend(fg, bg, alpha) })
      return
    end
  end
  -- Fallback (no usable colors, or bg disabled): plain link. `force` replaces
  -- any previously set explicit attributes.
  vim.api.nvim_set_hl(0, HL, { link = name, force = true })
end

-- ── autocmds ─────────────────────────────────────────────────────────────────

local function setup_autocmds()
  augroup = vim.api.nvim_create_augroup("MarkdownTableValign", { clear = true })
  local au = vim.api.nvim_create_autocmd

  au("FileType", {
    group = augroup,
    pattern = "markdown",
    callback = function(a)
      vim.schedule(function()
        M.refresh_buf(a.buf)
        set_wrap_for_buf(a.buf)
      end)
    end,
  })

  -- Wrap decision depends on window width: re-evaluate on (re)entry/resize.
  au("WinResized", {
    group = augroup,
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        if vim.api.nvim_win_is_valid(win) then
          set_wrap_for_win(win, vim.api.nvim_win_get_buf(win))
        end
      end
    end,
  })
  au("WinEnter", {
    group = augroup,
    callback = function()
      set_wrap_for_win(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
    end,
  })
  au("WinClosed", {
    group = augroup,
    pattern = "*",
    callback = function(a)
      exempt[tonumber(a.match)] = nil
    end,
  })
  -- If the user manually toggles 'wrap', stop managing it for this
  -- window/buffer combination.
  au("OptionSet", {
    group = augroup,
    pattern = "wrap",
    callback = function()
      if applying then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_is_valid(win) then
        exempt[win] = vim.api.nvim_win_get_buf(win)
      end
    end,
  })

  -- Keep tables aligned while the user edits them.
  au({ "TextChanged", "InsertLeave" }, {
    group = augroup,
    callback = function(a)
      vim.schedule(function()
        M.refresh_buf(a.buf)
      end)
    end,
  })

  -- The buffer is never modified, so saving writes the original text; we
  -- still clear the visual padding on save (and optionally restore it after).
  au("BufWritePre", {
    group = augroup,
    callback = function(a)
      if vim.bo[a.buf].filetype == "markdown" then
        clear(a.buf)
      end
    end,
  })
  au("BufWritePost", {
    group = augroup,
    callback = function(a)
      if config.expand_after_save and vim.bo[a.buf].filetype == "markdown" then
        vim.schedule(function()
          M.refresh_buf(a.buf)
        end)
      end
    end,
  })

  au("ColorScheme", {
    group = augroup,
    callback = function()
      apply_highlight()
    end,
  })

  au("BufUnload", {
    group = augroup,
    callback = function(a)
      warned[a.buf] = nil
      state[a.buf] = nil
      parse_cache[a.buf] = nil
      for win, b in pairs(exempt) do
        if b == a.buf then
          exempt[win] = nil
        end
      end
    end,
  })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  apply_highlight()
  setup_autocmds()
  vim.schedule(function()
    M.refresh()
  end)
end

-- exposed for tests/diagnostics
M._parse_tables = parse_tables
M._NS = NS
M._HL = HL
M._apply_highlight = apply_highlight
M._set_wrap_for_win = set_wrap_for_win
M._max_natural_width = max_natural_width

return M
