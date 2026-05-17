local uv = vim.uv or vim.loop

local M = {}

local AUTH_PATTERN = "^AUTH%s+(%S+)\n$"

local function reply(client, line)
  client:write(line, function() end)
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
    if line:find("\n", 1, true) then
      client:read_stop()
      local token = line:match(AUTH_PATTERN)
      if not token then
        reply(client, "ERR malformed\n")
        on_error("malformed handshake: " .. vim.inspect(line))
        vim.defer_fn(function() client:close() end, 10)
        return
      end
      if token ~= expected_token then
        reply(client, "ERR auth\n")
        on_error("auth failed")
        vim.defer_fn(function() client:close() end, 10)
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

return M
