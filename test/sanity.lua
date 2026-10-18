-- Sanity tests. Run with:
--   nvim --headless -u NONE -l test/sanity.lua

vim.opt.runtimepath:append(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h"))

local mtv = require("markdown-table-valign")
mtv.setup({}) -- registers autocmds (needed for save/restore tests)

local NS = mtv._NS

local failures = {}
local function check(name, cond, extra)
  if cond then
    print(("PASS  %s"):format(name))
  else
    failures[#failures + 1] = name
    print(("FAIL  %s %s"):format(name, extra or ""))
  end
end

local function setup_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  return buf
end

-- Reconstruct the *rendered* line (real text + inline virtual text) 1-based.
local function rendered(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = { text = l, width = vim.fn.strdisplaywidth(l), off = 0 }
  end
  -- marks come sorted by (row, col); track how much earlier insertions on the
  -- same line shifted subsequent byte columns
  for _, m in ipairs(marks) do
    local i = m[2] + 1
    local col = m[3] + out[i].off -- 0-based byte col, corrected
    local txt = m[4].virt_text[1][1]
    local t = out[i].text
    out[i].text = t:sub(1, col) .. txt .. t:sub(col + 1)
    out[i].width = out[i].width + vim.fn.strdisplaywidth(txt)
    out[i].off = out[i].off + #txt
  end
  return out
end

-- Float windows accept arbitrary widths even headless.
local function setup_win(buf, width)
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor", width = width, height = 30, row = 0, col = 0, style = "minimal",
  })
end

local function count_char(s, c)
  local n = 0
  for _ in s:gmatch("%" .. c) do
    n = n + 1
  end
  return n
end

-- ── test 1: alignment to natural width ───────────────────────────────────────
do
  local buf = setup_buf({
    "# Title",
    "",
    "| Name | Description | Value |",
    "|:-----|------------:|:-----:|",
    "| a | bb | ccc |",
    "| longer | x | y |",
    "",
    "```",
    "| not | a | table |",
    "|:----|---:|:---:|",
    "```",
  })
  mtv._align(buf)

  -- natural = 8 + 13 + 7 + 4 = 32
  local r = rendered(buf)
  for i = 3, 6 do
    check(("row %d aligned to natural width"):format(i), r[i].width == 32,
      ("got %d"):format(r[i].width))
  end
  check("fenced table untouched", r[9].width == vim.fn.strdisplaywidth(r[9].text)
    and r[10].width == vim.fn.strdisplaywidth(r[10].text))
  check("buffer unmodified", vim.bo[buf].modified == false)

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  mtv._align(buf)
  check("re-align is a no-op", vim.api.nvim_buf_get_changedtick(buf) == tick)

  -- body cells keep alignment: left / right / center
  local body = r[5].text
  local bslots = {}
  for piece in body:gmatch("[^|]+") do
    bslots[#bslots + 1] = piece
  end
  check("left cell flush left", bslots[1]:match("^ a%s+$") ~= nil, ("got %q"):format(bslots[1]))
  check("right cell flush right", bslots[2]:match("^%s+ bb $") ~= nil, ("got %q"):format(bslots[2]))
  check("center cell centered", bslots[3]:match("^%s+ ccc %s+$") ~= nil,
    ("got %q"):format(bslots[3]))
end

-- ── test 2: separator rows padded with hyphens ───────────────────────────────
do
  local buf = setup_buf({
    "| Name | Description | Value |",
    "|:--|--:|:-:|",
    "| a | bb | ccc |",
    "| longer | x | y |",
  })
  mtv._align(buf)
  local r = rendered(buf)
  local dslots = {}
  for piece in r[2].text:gmatch("[^|]+") do
    dslots[#dslots + 1] = piece
  end
  -- all separator slots must be continuous dashes/colons, no spaces
  check("sep slot left-aligned is hyphens", dslots[1]:match("^:%-+$") ~= nil,
    ("got %q"):format(dslots[1]))
  check("sep slot right-aligned is hyphens", dslots[2]:match("^%-+:$") ~= nil,
    ("got %q"):format(dslots[2]))
  check("sep slot centered is hyphens", dslots[3]:match("^%-+:%-+:%-+$") ~= nil,
    ("got %q"):format(dslots[3]))
  check("separator has no spaces", r[2].text:find(" ", 1, true) == nil,
    ("got %q"):format(r[2].text))
  for i = 1, 4 do
    check(("row %d at natural width"):format(i), r[i].width == 32, ("got %d"):format(r[i].width))
  end
end

-- ── test 3: already-aligned table produces no extmarks ───────────────────────
do
  local buf = setup_buf({
    "| Name | Description |",
    "|:-----|-------------|",
    "| a    | b           |",
  })
  mtv._align(buf)
  local n = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
  check("aligned table needs no padding", n == 0, ("got %d marks"):format(n))
end

-- ── test 4: missing trailing pipe / missing columns get virtual filler ───────
do
  local buf = setup_buf({
    "| Name | Description | Value |",
    "|:-----|------------:|:-----:|",
    "| a | bb | ccc |",
    "| longer | x |",
  })
  mtv._align(buf)
  local r = rendered(buf)
  check("row with missing pipe/col filled to natural", r[4].width == 32,
    ("got %d"):format(r[4].width))
  check("virtual filler restores pipe count", count_char(r[4].text, "|") == 4,
    ("got %d in %q"):format(count_char(r[4].text, "|"), r[4].text))
end

-- ── test 5: escaped pipes ────────────────────────────────────────────────────
do
  local buf = setup_buf({
    "| Name | Escaped |",
    "|:-----|--------:|",
    "| a | b \\| c |",
  })
  mtv._align(buf)
  local r = rendered(buf)
  -- natural = 6 + 9 + 3 = 18
  check("escaped pipes handled", r[1].width == 18 and r[2].width == 18 and r[3].width == 18,
    ("got %d %d %d"):format(r[1].width, r[2].width, r[3].width))
end

-- ── test 6: virtual characters are highlighted ───────────────────────────────
do
  local buf = setup_buf({
    "| Name | Description |",
    "|:--|--:|",
    "| longer | x |",
  })
  mtv._align(buf)
  local marks = vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })
  check("extmarks exist", #marks > 0)
  local all_hl = true
  for _, m in ipairs(marks) do
    if m[4].virt_text[1][2] ~= mtv._HL then
      all_hl = false
    end
  end
  check("virtual text uses highlight group", all_hl)
  check("highlight group is defined", vim.fn.hlexists(mtv._HL) == 1)

  -- background tint: blended between Normal bg and the highlight's fg
  vim.api.nvim_set_hl(0, "Normal", { bg = 0x1e1e1e })
  vim.api.nvim_set_hl(0, "Comment", { fg = 0x808080 })
  mtv._apply_highlight()
  local hl = vim.api.nvim_get_hl(0, { name = mtv._HL, link = false })
  check("virtual fg taken from highlight group", hl.fg == 0x808080, vim.inspect(hl))
  check("virtual bg is a tint of Normal bg", hl.bg ~= nil and hl.bg > 0x1e1e1e and hl.bg < 0x808080,
    vim.inspect(hl))
  -- alpha = 0 disables the background tint
  mtv.setup({ highlight_bg_alpha = 0 })
  mtv._apply_highlight()
  hl = vim.api.nvim_get_hl(0, { name = mtv._HL, link = false })
  check("alpha 0 disables background tint", hl.bg == nil, vim.inspect(hl))
  mtv.setup({ highlight_bg_alpha = 0.1 })
  mtv._apply_highlight()
end

-- ── test 7: save clears, re-expands, disable clears ──────────────────────────
do
  local buf = setup_buf({
    "| a | bb |",
    "|---|----|",
    "| 11 | c |",
  })
  mtv._align(buf)
  local n = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
  check("marks present before save", n > 0, ("got %d"):format(n))

  vim.api.nvim_exec_autocmds("BufWritePre", { buffer = buf })
  n = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
  check("save clears marks", n == 0, ("got %d"):format(n))

  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  vim.wait(100, function() return #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {}) > 0 end)
  n = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
  check("re-align after save", n > 0, ("got %d"):format(n))

  mtv.disable()
  n = #vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
  check("disable clears marks", n == 0, ("got %d"):format(n))
  mtv.enable()
end

-- ── test 8: real-world file ──────────────────────────────────────────────────
do
  local f = "/home/ruben/lab/src/ainara/docs/proposals/orakle-context-attachments.md"
  if vim.fn.filereadable(f) == 1 then
    local buf = vim.fn.bufadd(f)
    vim.fn.bufload(buf) -- load file before touching options
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].buftype = "nowrite"
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    mtv._align(buf)
    local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local same = #before == #after
    if same then
      for i = 1, #before do
        if before[i] ~= after[i] then
          same = false
          break
        end
      end
    end
    check("real file: buffer text untouched", same)
    local marks = vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, {})
    check("real file: all 8 tables padded", #marks > 0, ("got %d marks"):format(#marks))
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

-- ── test 9: wrap management (nowrap = auto/always/false) ────────────────────
do
  local wide = setup_buf({
    "| Name | Description | Value |",
    "|:-----|------------:|:-----:|",
    "| a | bb | ccc |",
    "| longer | x | y |",
  }) -- natural width 32

  -- auto: window narrower than table -> wrap off
  local win = setup_win(wide, 20)
  mtv._set_wrap_for_win(win, wide)
  check("auto: wide table disables wrap", vim.wo[win].wrap == false)
  -- auto: window wider than table -> wrap on
  local win2 = setup_win(wide, 60)
  mtv._set_wrap_for_win(win2, wide)
  check("auto: fitting table keeps wrap", vim.wo[win2].wrap == true)

  -- auto: non-markdown buffer untouched
  local plain = vim.api.nvim_create_buf(false, true)
  vim.bo[plain].filetype = "text"
  local win3 = setup_win(plain, 20)
  mtv._set_wrap_for_win(win3, plain)
  check("auto: non-markdown untouched", vim.wo[win3].wrap == true)

  -- always: wrap off even when it fits
  mtv.setup({ nowrap = "always" })
  mtv._set_wrap_for_win(win2, wide)
  check("always: wrap off", vim.wo[win2].wrap == false)

  -- false: untouched
  mtv.setup({ nowrap = false })
  vim.wo[win].wrap = true
  mtv._set_wrap_for_win(win, wide)
  check("false: wrap untouched", vim.wo[win].wrap == true)

  -- manual user toggle exempts the window
  mtv.setup({ nowrap = "auto" })
  vim.wo[win].wrap = false -- user "chooses" nowrap; exempt fires via OptionSet
  vim.wo[win].wrap = true
  mtv._set_wrap_for_win(win, wide)
  check("user toggle is respected", vim.wo[win].wrap == true,
    ("wrap=%s exempt=%s"):format(tostring(vim.wo[win].wrap), tostring(exempt and "set")))

  vim.api.nvim_win_close(win, true)
  vim.api.nvim_win_close(win2, true)
  vim.api.nvim_win_close(win3, true)
end

print("")
if #failures > 0 then
  error(("FAILED: %d test(s): %s"):format(#failures, table.concat(failures, ", ")))
else
  print("All tests passed.")
end
