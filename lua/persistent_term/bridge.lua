-- lua/persistent_term/bridge.lua
local uv = vim.uv or vim.loop
local M = {}

local function rename_buffer(bufnr, name)
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

local function set_buffer_options(bufnr)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "terminal"
end

function M.create_buffer(name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  local handle = { _on_input = function() end }
  local chan = vim.api.nvim_open_term(bufnr, {
    on_input = function(event, term, bnr, data)
      handle._on_input(event, term, bnr, data)
    end,
  })
  set_buffer_options(bufnr)
  rename_buffer(bufnr, "pterm://" .. name)
  vim.b[bufnr].persistent_term_name = name
  return {
    bufnr = bufnr,
    chan = chan,
    _on_input_holder = handle,
  }
end

--- Wire a buffer handle to a gateway-managed tmux pane.
--- @param handle table  buffer handle returned by create_buffer + extras
--- @param gateway table the persistent_term.gateway instance
--- @param pane_id string tmux pane id (e.g. "%1")
--- @param window_id string tmux window id (e.g. "@1")
function M.attach(handle, gateway, pane_id, window_id)
  handle.gateway = gateway
  handle.pane_id = pane_id
  handle.window_id = window_id

  gateway:subscribe(pane_id, window_id, function(bytes)
    if handle._closing then
      return
    end
    if vim.api.nvim_buf_is_valid(handle.bufnr) then
      vim.api.nvim_chan_send(handle.chan, bytes)
    end
  end, function()
    vim.schedule(function()
      M.detach(handle, "tmux window closed")
    end)
  end)

  local function on_input(_event, _term, _bnr, data)
    if handle._closing then
      return
    end
    local codec = require("persistent_term.codec")
    local cleaned = codec.is_libvterm_response(data)
    if cleaned == "" then
      return
    end
    gateway:send_keys(pane_id, cleaned)
  end

  if handle._on_input_holder then
    handle._on_input_holder._on_input = on_input
  end
  handle._on_input = on_input
end

function M.detach(handle, reason)
  if handle._closing then
    return
  end
  handle._closing = true
  if handle.gateway and handle.pane_id then
    handle.gateway:unsubscribe(handle.pane_id)
  end
  if handle._resize_timer and not handle._resize_timer:is_closing() then
    handle._resize_timer:stop()
    handle._resize_timer:close()
    handle._resize_timer = nil
  end
  if handle._on_input_holder then
    handle._on_input_holder._on_input = function() end
  end
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    rename_buffer(handle.bufnr, "pterm://" .. (handle.name or "?") .. " [detached]")
  end
  if reason then
    require("persistent_term.log").warn("persistent-term: bridge detached: " .. reason)
  end
end

local RESIZE_DEBOUNCE_MS = 50

function M.resize_to(handle, cols, rows)
  handle._pending_size = { cols = cols, rows = rows }
  if handle._resize_timer then
    handle._resize_timer:stop()
    handle._resize_timer:close()
    handle._resize_timer = nil
  end
  local timer = uv.new_timer()
  handle._resize_timer = timer
  timer:start(RESIZE_DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      if not handle._pending_size then
        return
      end
      local size = handle._pending_size
      handle._pending_size = nil
      if not handle.gateway or not handle.window_id then
        return
      end
      local cmd
      local tmux = require("persistent_term.tmux")
      local v = handle.gateway:version() or "3.0"
      if tmux.version_at_least(v, "3.4") then
        cmd = string.format("refresh-client -C %s:%dx%d", handle.window_id, size.cols, size.rows)
      else
        cmd = string.format("resize-window -t %s -x %d -y %d", handle.window_id, size.cols, size.rows)
      end
      handle.gateway:send_cmd(cmd, function(r)
        if not r.ok then
          require("persistent_term.log").warn(
            string.format("resize failed for %s: %s", handle.window_id, r.stderr or "?")
          )
        end
      end)
    end)
    if not timer:is_closing() then
      timer:close()
    end
    if handle._resize_timer == timer then
      handle._resize_timer = nil
    end
  end)
end

function M.kill(handle)
  if handle.gateway and handle.window_id then
    handle.gateway:send_cmd("kill-window -t " .. handle.window_id, function(r)
      if not r.ok then
        require("persistent_term.log").warn("kill-window failed for " .. handle.window_id .. ": " .. (r.stderr or "?"))
      end
    end)
  end
  M.detach(handle, "kill")
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end
end

local function buf_size_for(bufnr)
  local cols, rows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local w = vim.api.nvim_win_get_width(win)
      local h = vim.api.nvim_win_get_height(win)
      if not cols or w < cols then
        cols = w
      end
      if not rows or h < rows then
        rows = h
      end
    end
  end
  return cols, rows
end

function M.install_buffer_hook(handle)
  local group = vim.api.nvim_create_augroup("PersistentTerm_" .. handle.bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = handle.bufnr,
    once = true,
    callback = function()
      M.detach(handle, "buffer wiped")
      if handle._on_detach then
        handle._on_detach()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      if handle._closing then
        return
      end
      local cols, rows = buf_size_for(handle.bufnr)
      if cols and rows then
        M.resize_to(handle, cols, rows)
      end
    end,
  })
end

function M.chan_send_history(handle, data)
  if data == nil or data == "" then
    return
  end
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then
    return
  end
  vim.api.nvim_chan_send(handle.chan, data)
end

return M
