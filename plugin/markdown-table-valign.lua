if vim.fn.has("nvim-0.10") == 0 then
  vim.notify_once("markdown-table-valign.nvim requires Neovim >= 0.10", vim.log.levels.WARN)
  return
end

local mtv = require("markdown-table-valign")

vim.api.nvim_create_user_command("MarkdownTableAlign", function()
  mtv.refresh()
end, { desc = "Re-align markdown table columns to the current window width" })

vim.api.nvim_create_user_command("MarkdownTableAlignEnable", function()
  mtv.enable()
end, { desc = "Enable markdown table column alignment" })

vim.api.nvim_create_user_command("MarkdownTableAlignDisable", function()
  mtv.disable()
end, { desc = "Disable markdown table column alignment" })

mtv.setup()
