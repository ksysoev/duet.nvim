-- duet.nvim entry point. Only defines the :Duet command; every module is loaded on first use.

if vim.g.loaded_duet then
  return
end
vim.g.loaded_duet = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("[duet] requires Neovim >= 0.11", vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command("Duet", function(opts)
  require("duet.commands").run(opts)
end, {
  nargs = "*",
  range = true,
  bang = true,
  desc = "duet.nvim: pair with AI coding agents",
  complete = function(arglead, cmdline, cursorpos)
    return require("duet.commands").complete(arglead, cmdline, cursorpos)
  end,
})
