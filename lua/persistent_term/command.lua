-- lua/persistent_term/command.lua
local M = {}

local NAME_PATTERN = "^[A-Za-z0-9_.-]+$"

--- Split a string into tokens, treating double-quoted substrings as single tokens.
--- Only splits on whitespace outside of quotes.
local function split_tokens(s)
  local out = {}
  local i = 1
  local len = #s
  while i <= len do
    -- skip whitespace
    while i <= len and s:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then break end
    local tok = ""
    -- collect token (may contain quoted sections)
    while i <= len and not s:sub(i, i):match("%s") do
      local c = s:sub(i, i)
      if c == '"' then
        -- collect until closing quote (or end of string)
        tok = tok .. c
        i = i + 1
        while i <= len and s:sub(i, i) ~= '"' do
          tok = tok .. s:sub(i, i)
          i = i + 1
        end
        if i <= len then
          tok = tok .. s:sub(i, i) -- closing quote
          i = i + 1
        end
      else
        tok = tok .. c
        i = i + 1
      end
    end
    if tok ~= "" then
      table.insert(out, tok)
    end
  end
  return out
end

function M.parse_open_args(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, "usage: :PTerm {name} -- {cmd...}"
  end

  -- Split on the literal " -- " separator to separate name-part from cmd-part.
  -- We look for whitespace-bounded "--" to distinguish it from flags like "--foo".
  local sep_pos = raw:find("%s%-%-%s")
  if not sep_pos then
    -- also check if raw ends with " --" (empty cmd)
    local trail = raw:find("%s%-%-$")
    if trail then
      -- name part exists but argv is empty
      local name_part = raw:sub(1, trail - 1)
      local name_tokens = split_tokens(name_part)
      if #name_tokens ~= 1 then
        return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name_part
      end
      local name = name_tokens[1]
      if #name > 64 or not name:match(NAME_PATTERN) then
        return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name
      end
      return nil, "empty command after --"
    end
    return nil, "missing -- separator before command"
  end

  local name_part = raw:sub(1, sep_pos - 1)
  local cmd_part = raw:sub(sep_pos + 4) -- skip " -- "

  -- Validate name part: must be exactly one valid token
  local name_tokens = split_tokens(name_part)
  if #name_tokens ~= 1 then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name_part
  end
  local name = name_tokens[1]
  if #name > 64 or not name:match(NAME_PATTERN) then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name
  end

  -- Parse argv from cmd_part
  local argv = split_tokens(cmd_part)
  if #argv == 0 then
    return nil, "empty command after --"
  end

  return { name = name, argv = argv }
end

local function dir_for_socket()
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and xdg ~= "" then
    return xdg .. "/persistent-term"
  end
  return "/tmp/persistent-term-" .. vim.fn.getpid()
end

local function ensure_runtime_dir(dir)
  vim.fn.mkdir(dir, "p", "0700")
end

local function random_hex(nbytes)
  local uv = vim.uv or vim.loop
  local raw = uv.random and uv.random(nbytes) or nil
  if not raw then
    math.randomseed(os.time())
    local t = {}
    for _ = 1, nbytes do
      table.insert(t, string.char(math.random(0, 255)))
    end
    raw = table.concat(t)
  end
  return (raw:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function buf_size(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    end
  end
  return vim.o.columns, math.max(vim.o.lines - 2, 5)
end

local function name_in_use(rows, name)
  for _, row in ipairs(rows) do
    if row.name == name then
      return row.pane_id
    end
  end
  return nil
end

function M.cmd_open(raw)
  local parsed, perr = M.parse_open_args(raw)
  if not parsed then
    return nil, perr
  end

  local tmux = require("persistent_term.tmux")
  local install = require("persistent_term.install")
  local bridge = require("persistent_term.bridge")
  local log = require("persistent_term.log")

  local v = tmux.check_version("3.0")
  if not v.ok then
    log.error(v.reason)
    return nil, v.reason
  end
  if not install.is_installed() then
    local msg = "helper binary not installed; run :PTermInstall"
    log.error(msg)
    return nil, msg
  end

  local list = tmux.run(tmux.builders.list_panes())
  if not list.ok then
    return nil, "tmux list-panes failed: " .. list.stderr
  end
  local existing_pid = name_in_use(tmux.parse_list_panes(list.stdout), parsed.name)
  if existing_pid then
    return nil, string.format('terminal "%s" already exists (pane %s)', parsed.name, existing_pid)
  end

  local dir = dir_for_socket()
  ensure_runtime_dir(dir)
  local socket_path = dir .. "/" .. random_hex(16) .. ".sock"
  local token = random_hex(32)

  local buf = bridge.create_buffer(parsed.name)
  local cols, rows = buf_size(buf.bufnr)

  local handle = {
    bufnr = buf.bufnr, chan = buf.chan,
    name = parsed.name,
    _on_input_holder = buf._on_input_holder,
    _on_detach = function() end,
  }

  local server
  server = bridge.start_server({
    socket_path = socket_path,
    token = token,
    on_attach = function(client)
      handle._attached = true
      bridge.attach(handle, client)
    end,
    on_error = function(reason)
      log.warn("bridge: " .. reason)
    end,
  })
  handle._server = server

  -- Handshake watchdog: if the helper does not connect+AUTH within 2s,
  -- tear down the partial state.
  vim.defer_fn(function()
    if handle._attached or handle._closing then return end
    log.error(string.format('handshake timeout for "%s"; rolling back', parsed.name))
    if handle.pane_id then
      tmux.run(tmux.builders.kill_pane(handle.pane_id))
    end
    bridge.detach(handle, "handshake timeout")
    if vim.api.nvim_buf_is_valid(handle.bufnr) then
      vim.api.nvim_buf_delete(handle.bufnr, { force = true })
    end
  end, 2000)

  local new = tmux.run(tmux.builders.new_session({
    session_name = "pterm_" .. random_hex(4) .. "_" .. parsed.name,
    cols = cols,
    rows = rows,
    cwd = vim.fn.getcwd(),
    argv = parsed.argv,
  }))
  if not new.ok then
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux new-session failed: " .. new.stderr
  end
  local ids = tmux.parse_new_session_output(new.stdout)
  if not ids then
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux returned unparseable ids: " .. new.stdout
  end
  handle.pane_id = ids.pane_id
  handle.session_id = ids.session_id
  handle.window_id = ids.window_id
  vim.b[buf.bufnr].persistent_term_pane_id = ids.pane_id
  vim.b[buf.bufnr].persistent_term_session_id = ids.session_id

  tmux.run(tmux.builders.set_window_option(ids.window_id, "remain-on-exit", "on"))
  tmux.run(tmux.builders.set_pane_option(ids.pane_id, "@pterm_name", parsed.name))

  local helper = install.binary_path()
  local pipe = tmux.run(tmux.builders.pipe_pane({
    pane_id = ids.pane_id,
    bin_path = helper,
    socket_path = socket_path,
    token = token,
  }))
  if not pipe.ok then
    tmux.run(tmux.builders.kill_pane(ids.pane_id))
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux pipe-pane failed: " .. pipe.stderr
  end

  bridge.install_buffer_hook(handle)
  return handle
end

return M
