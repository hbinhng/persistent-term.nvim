local uv = vim.uv or vim.loop

local M = {}

local AUTH_PATTERN = "^AUTH%s+(%S+)\n$"

local function reply(client, line)
  client:write(line, function() end)
end

local function reply_and_close(client, line)
  client:write(line, function() client:close() end)
end

local function handle_client_handshake(client, expected_token, on_attach, on_error)
  local buf = {}
  client:read_start(function(err, chunk)
    if err then
      on_error("read: " .. err)
      client:close()
      return
    end
    if not chunk then
      client:close()
      return
    end
    table.insert(buf, chunk)
    local line = table.concat(buf)
    -- We treat the AUTH line as the first newline-terminated chunk.
    local nl = line:find("\n", 1, true)
    if nl then
      client:read_stop()
      local auth_line = line:sub(1, nl)   -- includes the trailing \n
      -- Note: line:sub(nl + 1) (any bytes after \n) is currently silently dropped.
      -- The Go helper's protocol guarantees no post-AUTH bytes arrive before OK
      -- is received, so this is safe today. If you change the helper to pipeline,
      -- you must rework this path to forward leftover bytes to on_attach.
      local token = auth_line:match(AUTH_PATTERN)
      if not token then
        reply_and_close(client, "ERR malformed\n")
        on_error("malformed handshake: " .. vim.inspect(auth_line))
        return
      end
      if token ~= expected_token then
        reply_and_close(client, "ERR auth\n")
        on_error("auth failed")
        return
      end
      reply(client, "OK\n")
      on_attach(client)
    end
  end)
end

local function bind_listen(socket_path, opts)
  local server = uv.new_pipe(false)
  -- Make sure no stale socket file is in the way.
  pcall(os.remove, socket_path)
  local ok, err = server:bind(socket_path)
  if not ok then
    server:close()
    error("bridge: bind " .. socket_path .. ": " .. tostring(err))
  end
  ok, err = server:listen(1, function(lerr)
    if lerr then
      opts.on_error("listen: " .. lerr)
      return
    end
    local client = uv.new_pipe(false)
    server:accept(client)
    handle_client_handshake(client, opts.token, opts.on_attach, opts.on_error)
  end)
  if not ok then
    server:close()
    error("bridge: listen " .. socket_path .. ": " .. tostring(err))
  end
  return server
end

function M.start_server(opts)
  assert(type(opts.socket_path) == "string", "socket_path required")
  assert(type(opts.token) == "string", "token required")
  assert(type(opts.on_attach) == "function", "on_attach required")
  assert(type(opts.on_error) == "function", "on_error required")
  local server = bind_listen(opts.socket_path, opts)
  local closed = false
  return {
    close = function()
      if closed then return end
      closed = true
      if not server:is_closing() then
        server:close()
      end
      pcall(os.remove, opts.socket_path)
    end,
  }
end

local function rename_buffer(bufnr, name)
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

local function set_buffer_options(bufnr)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
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

function M.attach(handle, client)
  handle._attached = true
  handle.client = client
  handle._pending_writes = 0

  -- Pane -> buffer.
  client:read_start(function(err, data)
    if err then
      vim.schedule(function()
        M.detach(handle, "socket read: " .. err)
      end)
      return
    end
    if not data then
      vim.schedule(function()
        M.detach(handle, "socket eof")
      end)
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(handle.bufnr) then
        vim.api.nvim_chan_send(handle.chan, data)
      end
    end)
  end)

  -- Buffer -> pane. Wire the per-buffer handle's on_input now.
  local function on_input(_event, _term, _bnr, data)
    if handle._closing or not client or client:is_closing() then return end
    if handle._pending_writes > 64 * 1024 then
      require("persistent_term.log").warn(
        "persistent-term: input queue full for " .. (handle.name or "?") .. "; dropping keystroke"
      )
      return
    end
    handle._pending_writes = handle._pending_writes + #data
    client:write(data, function(werr)
      handle._pending_writes = math.max(0, handle._pending_writes - #data)
      if werr then
        vim.schedule(function()
          M.detach(handle, "socket write: " .. werr)
        end)
      end
    end)
  end

  if handle._on_input_holder then
    handle._on_input_holder._on_input = on_input
  end
  handle._on_input = on_input
end

function M.detach(handle, reason)
  if handle._closing then return end
  handle._closing = true
  if handle.client and not handle.client:is_closing() then
    handle.client:close()
  end
  if handle._server and type(handle._server.close) == "function" then
    pcall(handle._server.close, handle._server)
    handle._server = nil
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
    require("persistent_term.log").warn(
      "persistent-term: bridge detached: " .. reason
    )
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
      if not handle._pending_size then return end
      local size = handle._pending_size
      handle._pending_size = nil
      if not handle.pane_id then return end
      local tmux = require("persistent_term.tmux")
      local argv = tmux.builders.resize_pane(handle.pane_id, size.cols, size.rows)
      local res = tmux.run(argv)
      if not res.ok then
        require("persistent_term.log").warn(
          string.format("resize-pane failed for %s: %s", handle.pane_id, res.stderr)
        )
      end
    end)
    if not timer:is_closing() then
      timer:close()
    end
    if handle._resize_timer == timer then
      handle._resize_timer = nil
    end
  end)
end

return M
