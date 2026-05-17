-- lua/persistent_term/command.lua
local M = {}

local NAME_PATTERN = "^[A-Za-z0-9_.-]+$"

--- Split a string into tokens, honoring shell-like quoting.
--- Splits on whitespace outside of quotes; quote pairs are stripped from the
--- resulting token value so that  bash -c 'echo hi'  or  bash -c "echo hi"
--- each produce the argv element  echo hi  (one element, no quote chars).
local function split_tokens(s)
  local out = {}
  local i = 1
  local len = #s
  while i <= len do
    -- skip whitespace
    while i <= len and s:sub(i, i):match("%s") do
      i = i + 1
    end
    if i > len then
      break
    end
    local tok = ""
    -- collect token (may contain quoted sections)
    while i <= len and not s:sub(i, i):match("%s") do
      local c = s:sub(i, i)
      if c == '"' or c == "'" then
        -- Quoted section: strip the surrounding quote characters and keep
        -- the content as a single unbroken piece of the token.
        local q = c
        i = i + 1
        while i <= len and s:sub(i, i) ~= q do
          tok = tok .. s:sub(i, i)
          i = i + 1
        end
        if i <= len then
          i = i + 1 -- skip closing quote
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
      local raw_name_trail = vim.trim(name_part)
      if raw_name_trail ~= name or #name > 64 or not name:match(NAME_PATTERN) then
        return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. raw_name_trail
      end
      return nil, "empty command after --"
    end
    -- No "--" separator anywhere: treat raw as a name-only invocation
    -- and let cmd_open substitute the resolved shell as argv.
    local raw_trim = vim.trim(raw)
    local tokens = split_tokens(raw_trim)
    if #tokens ~= 1 then
      return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. raw_trim
    end
    local n = tokens[1]
    if raw_trim ~= n or #n > 64 or not n:match(NAME_PATTERN) then
      return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. raw_trim
    end
    return { name = n, argv = nil }
  end

  local name_part = raw:sub(1, sep_pos - 1)
  local cmd_part = raw:sub(sep_pos + 4) -- skip " -- "

  -- Validate name part: must be exactly one valid token.
  -- We check the raw name_part directly (no quote-stripping) so that names
  -- containing quote characters like  dev'  are correctly rejected.
  local name_tokens = split_tokens(name_part)
  if #name_tokens ~= 1 then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name_part
  end
  local name = name_tokens[1]
  -- Re-validate against the raw trimmed name_part to catch quote chars that
  -- split_tokens would otherwise strip (e.g. "dev'" → token "dev" but raw has "'").
  local raw_name = vim.trim(name_part)
  if raw_name ~= name or #name > 64 or not name:match(NAME_PATTERN) then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. raw_name
  end

  -- Parse argv from cmd_part
  local argv = split_tokens(cmd_part)
  if #argv == 0 then
    return nil, "empty command after --"
  end

  return { name = name, argv = argv }
end

function M.resolve_shell()
  local shell = vim.env.SHELL
  if shell and shell ~= "" and vim.fn.executable(shell) == 1 then
    return shell
  end
  if vim.fn.executable("/bin/sh") == 1 then
    return "/bin/sh"
  end
  error(string.format("no usable shell: $SHELL=%q, /bin/sh missing", shell or ""), 0)
end

local function buf_size(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    end
  end
  return vim.o.columns, math.max(vim.o.lines - 2, 5)
end

local function gateway()
  return require("persistent_term.gateway").singleton()
end

function M.cmd_open(raw)
  local parsed, perr = M.parse_open_args(raw)
  if not parsed then
    return nil, perr
  end

  if parsed.argv == nil then
    local ok, shell = pcall(M.resolve_shell)
    if not ok then
      return nil, tostring(shell)
    end
    parsed.argv = { shell }
  end

  local gw = gateway()
  local ok, err = gw:ensure_started(5000)
  if not ok then
    return nil, err
  end

  if gw:get_pane_by_name(parsed.name) then
    return nil, string.format('terminal "%s" already exists', parsed.name)
  end

  local bridge = require("persistent_term.bridge")
  local codec = require("persistent_term.codec")
  local buf = bridge.create_buffer(parsed.name)
  local cols, rows = buf_size(buf.bufnr)

  local handle = {
    bufnr = buf.bufnr,
    chan = buf.chan,
    name = parsed.name,
    _on_input_holder = buf._on_input_holder,
  }

  -- Build the argv portion: each token shell-escaped.
  local argv_parts = {}
  for _, a in ipairs(parsed.argv) do
    table.insert(argv_parts, codec.shell_escape(a))
  end
  local cmd =
    string.format("new-window -d -t pterm -P -F '#{pane_id}\t#{window_id}' -- %s", table.concat(argv_parts, " "))

  gw:send_cmd(cmd, function(r)
    if not r.ok then
      local msg = "tmux new-window failed: " .. (r.stderr or "")
      handle._open_err = msg
      require("persistent_term.log").error(msg)
      pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
      return
    end
    local tmux = require("persistent_term.tmux")
    local ids = tmux.parse_id_tuple(r.stdout)
    if not ids then
      local msg = "tmux returned unparseable ids: " .. r.stdout
      handle._open_err = msg
      require("persistent_term.log").error(msg)
      pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
      return
    end
    handle.pane_id = ids.pane_id
    handle.window_id = ids.window_id
    bridge.attach(handle, gw, ids.pane_id, ids.window_id)
    gw:register_pane(parsed.name, ids.pane_id, ids.window_id)
    vim.b[buf.bufnr].persistent_term_pane_id = ids.pane_id
    vim.b[buf.bufnr].persistent_term_window_id = ids.window_id

    gw:send_cmd(string.format("set-option -wt %s @pterm_name %s", ids.window_id, parsed.name), function()
      handle._set_option_done = true
    end)
    gw:send_cmd(string.format("set-option -wt %s remain-on-exit on", ids.window_id), function() end)
    -- Initial resize.
    bridge.resize_to(handle, cols, rows)
    bridge.install_buffer_hook(handle)
  end)

  -- Block until the new-window callback (and set-option) have completed, so
  -- that callers see a fully-registered pane when cmd_open returns. The
  -- gateway is async; without this wait, tests that immediately query
  -- tmux list-panes or the pane map would race the callback.
  vim.wait(5000, function()
    return handle.pane_id ~= nil and handle._set_option_done == true
  end, 20)

  if handle._open_err then
    return nil, handle._open_err
  end

  return handle
end

local PANE_ID_PATTERN = "^%%[0-9]+$"

function M.complete_attach(arg_lead, _cmd_line, _cursor_pos)
  local gw = gateway()
  if gw:state() ~= "ready" then
    return {}
  end
  local out = {}
  for _, p in ipairs(gw:all_panes()) do
    table.insert(out, p.name)
    table.insert(out, p.pane_id)
  end
  if arg_lead == "" then
    return out
  end
  local filtered = {}
  for _, item in ipairs(out) do
    if vim.startswith(item, arg_lead) then
      table.insert(filtered, item)
    end
  end
  return filtered
end

function M.cmd_attach(target)
  if type(target) ~= "string" or target == "" then
    return nil, "usage: :PTermAttach {name|pane_id}"
  end
  local gw = gateway()
  local ok, err = gw:ensure_started(5000)
  if not ok then
    return nil, err
  end

  -- Resolve target -> { pane_id, window_id, name }.
  local resolved
  if target:match(PANE_ID_PATTERN) then
    -- Pane id given; we need to know its window id. Issue list-windows.
    local result = { done = false }
    gw:send_cmd("list-windows -t pterm -F '#{window_id}\t#{pane_id}\t#{@pterm_name}\t#{pane_dead}'", function(r)
      result.r = r
      result.done = true
    end)
    vim.wait(2000, function()
      return result.done
    end, 20)
    if not result.r or not result.r.ok then
      return nil, "tmux list-windows failed: " .. ((result.r and result.r.stderr) or "?")
    end
    local rows = require("persistent_term.tmux").parse_list_panes(result.r.stdout)
    for _, row in ipairs(rows) do
      if row.pane_id == target then
        resolved = { pane_id = row.pane_id, window_id = row.window_id, name = row.name ~= "" and row.name or target }
        break
      end
    end
  else
    local e = gw:get_pane_by_name(target)
    if e then
      resolved = { pane_id = e.pane_id, window_id = e.window_id, name = target }
    end
  end
  if not resolved then
    return nil, "unknown pane: " .. target
  end

  -- If a buffer already exists for this name, just focus it.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == "pterm://" .. resolved.name then
      vim.cmd.buffer(b)
      return { bufnr = b, pane_id = resolved.pane_id, window_id = resolved.window_id, name = resolved.name }
    end
  end

  local bridge = require("persistent_term.bridge")
  local buf = bridge.create_buffer(resolved.name)
  local handle = {
    bufnr = buf.bufnr,
    chan = buf.chan,
    name = resolved.name,
    pane_id = resolved.pane_id,
    window_id = resolved.window_id,
    _on_input_holder = buf._on_input_holder,
  }
  bridge.attach(handle, gw, resolved.pane_id, resolved.window_id)
  vim.b[buf.bufnr].persistent_term_pane_id = resolved.pane_id
  vim.b[buf.bufnr].persistent_term_window_id = resolved.window_id

  -- Replay scrollback.
  gw:send_cmd("capture-pane -p -e -J -t " .. resolved.pane_id, function(r)
    if r.ok and r.stdout and r.stdout ~= "" then
      vim.schedule(function()
        bridge.chan_send_history(handle, r.stdout)
      end)
    end
  end)
  bridge.install_buffer_hook(handle)
  return handle
end

function M.cmd_kill(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("^pterm://") then
    return false, "not a persistent-term buffer"
  end
  local gw = gateway()
  local window_id = vim.b[bufnr].persistent_term_window_id
  if window_id then
    gw:send_cmd("kill-window -t " .. window_id, function() end)
    -- Eagerly remove the pane from the in-memory map so that callers that
    -- query list() immediately after cmd_kill see a consistent view without
    -- having to wait for the async %window-close event.
    gw:forget_pane_by_window(window_id)
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  return true
end

function M.list()
  local gw = gateway()
  if gw:state() ~= "ready" then
    return {}
  end
  -- Refresh the pane map synchronously so that dead-pane status and
  -- recently-killed panes are reflected accurately.
  local refreshed = false
  gw:refresh_pane_map(function()
    refreshed = true
  end)
  vim.wait(2000, function()
    return refreshed
  end, 20)
  local rows = gw:all_panes()
  local attached = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local bn = vim.api.nvim_buf_get_name(b)
    local m = bn:match("^pterm://([^%s]+)$")
    if m then
      attached[m] = true
    end
  end
  local out = {}
  for _, r in ipairs(rows) do
    table.insert(out, {
      name = r.name,
      pane_id = r.pane_id,
      window_id = r.window_id,
      attached = attached[r.name] == true,
      status = r.dead and "dead" or "live",
    })
  end
  return out
end

function M.cmd_list()
  local rows = M.list()
  if #rows == 0 then
    vim.notify("no persistent terminals", vim.log.levels.INFO)
    return
  end
  local headers = { "NAME", "PANE", "ATTACHED", "STATUS" }
  local data = {}
  for _, r in ipairs(rows) do
    table.insert(data, { r.name, r.pane_id, r.attached and "yes" or "no", r.status })
  end
  local widths = { #headers[1], #headers[2], #headers[3], #headers[4] }
  for _, d in ipairs(data) do
    for i = 1, 4 do
      if #d[i] > widths[i] then
        widths[i] = #d[i]
      end
    end
  end
  local function fmt_row(cells)
    local parts = {}
    for i = 1, 4 do
      parts[i] = cells[i] .. string.rep(" ", widths[i] - #cells[i])
    end
    return table.concat(parts, "  ")
  end
  local lines = { fmt_row(headers) }
  for _, d in ipairs(data) do
    table.insert(lines, fmt_row(d))
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
