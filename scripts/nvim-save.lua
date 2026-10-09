-- Runs inside a Neovim instance over RPC (no keys typed, so user mappings
-- cannot interfere). Called as: dofile(this)(session_file, sessionoptions)
-- Returns "dirty" when quitting would lose something, otherwise saves a
-- session and quits shortly after replying.
return function(file, sessionoptions)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local bt = vim.bo[b].buftype
      if vim.bo[b].modified and bt ~= "nofile" and bt ~= "prompt" then
        return "dirty"
      end
      -- A terminal with a live job would be killed.
      if bt == "terminal" then
        local job = vim.b[b].terminal_job_id
        if job and vim.fn.jobwait({ job }, 0)[1] == -1 then
          return "dirty"
        end
      end
    end
  end

  -- Plugin windows (file trees, outlines, pickers) do not restore well from a
  -- session: close them first. The instance is about to quit anyway.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype ~= "" and #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  -- Floating windows are never part of a session.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end

  if sessionoptions and sessionoptions ~= "" then
    vim.o.sessionoptions = sessionoptions
  end
  local ok = pcall(vim.cmd, "mksession! " .. vim.fn.fnameescape(file))
  if not ok then
    return "dirty"
  end
  -- Quit after the RPC reply has been sent.
  vim.defer_fn(function()
    pcall(vim.cmd, "qall")
  end, 50)
  return "saved"
end
