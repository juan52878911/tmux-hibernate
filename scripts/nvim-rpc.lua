-- RPC client, run as: nvim --headless --clean -u NONE -c "luafile nvim-rpc.lua"
-- Connects to another Neovim and runs nvim-save.lua inside it, printing what
-- it returns. Uses only sockconnect + nvim_exec_lua (Neovim >= 0.5), not the
-- --remote-* flags, which older versions lack or treat differently.
-- Arguments come in the environment to avoid any quoting.
local function out(s)
  io.stdout:write(s)
  vim.cmd("qall!")
end

local ok, chan = pcall(vim.fn.sockconnect, "pipe", os.getenv("HIB_NVIM_SOCK"), { rpc = true })
if not ok or chan == 0 then
  return out("error")
end

local code = "return dofile(...)(select(2, ...))"
local args = {
  os.getenv("HIB_NVIM_SAVE"),
  os.getenv("HIB_NVIM_SESSION"),
  os.getenv("HIB_NVIM_SESSIONOPTIONS") or "",
}
local rok, res = pcall(vim.fn.rpcrequest, chan, "nvim_exec_lua", code, args)
out(rok and tostring(res) or "error")
