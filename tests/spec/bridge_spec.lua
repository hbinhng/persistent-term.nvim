local uv = vim.uv or vim.loop

local function wait_for(predicate, timeout_ms)
  timeout_ms = timeout_ms or 1000
  local deadline = uv.now() + timeout_ms
  while uv.now() < deadline do
    if predicate() then
      return true
    end
    vim.wait(20)
  end
  return false
end

local function client_send(sock_path, text, on_reply)
  local client = uv.new_pipe(false)
  client:connect(sock_path, function(err)
    assert(not err, err)
    client:write(text)
    client:read_start(function(rerr, data)
      if rerr or not data then
        client:close()
        return
      end
      on_reply(data)
    end)
  end)
  return client
end

describe("persistent_term.bridge server", function()
  local bridge

  before_each(function()
    package.loaded["persistent_term.bridge"] = nil
    bridge = require("persistent_term.bridge")
  end)

  it("accepts a connection with the correct token", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local attached = false
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "GOOD",
      on_attach = function(_client)
        attached = true
      end,
      on_error = function(_) end,
    })

    local replies = {}
    client_send(sock_path, "AUTH GOOD\n", function(data)
      table.insert(replies, data)
    end)

    assert.is_true(wait_for(function()
      return #replies > 0 and attached
    end))
    assert.equals("OK\n", replies[1])
    server:close()
  end)

  it("rejects a wrong token and does not call on_attach", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local attached = false
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "GOOD",
      on_attach = function(_) attached = true end,
      on_error = function(_) end,
    })

    local replies = {}
    client_send(sock_path, "AUTH BAD\n", function(data)
      table.insert(replies, data)
    end)

    assert.is_true(wait_for(function() return #replies > 0 end))
    assert.is_truthy(replies[1]:match("^ERR"))
    assert.is_false(attached)
    server:close()
  end)

  it("rejects a malformed handshake line", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local errors_seen = 0
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "GOOD",
      on_attach = function(_) end,
      on_error = function(_) errors_seen = errors_seen + 1 end,
    })

    local replies = {}
    client_send(sock_path, "HELLO\n", function(data)
      table.insert(replies, data)
    end)

    assert.is_true(wait_for(function() return #replies > 0 end))
    assert.is_truthy(replies[1]:match("^ERR"))
    server:close()
  end)

  it("close() removes the socket file", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "X",
      on_attach = function(_) end,
      on_error = function(_) end,
    })
    assert.equals("socket", vim.fn.getftype(sock_path))
    server:close()
    assert.equals("", vim.fn.getftype(sock_path))
  end)
end)

describe("persistent_term.bridge data path", function()
  local bridge

  before_each(function()
    package.loaded["persistent_term.bridge"] = nil
    bridge = require("persistent_term.bridge")
  end)

  it("create_buffer returns a terminal-type buffer with a channel", function()
    local result = bridge.create_buffer("dev")
    assert.is_number(result.bufnr)
    assert.is_number(result.chan)
    assert.equals("terminal", vim.bo[result.bufnr].buftype)
    assert.equals("hide", vim.bo[result.bufnr].bufhidden)
    assert.equals(false, vim.bo[result.bufnr].swapfile)
    assert.equals("pterm://dev", vim.api.nvim_buf_get_name(result.bufnr))
    vim.api.nvim_buf_delete(result.bufnr, { force = true })
  end)

  it("attach pipes socket bytes into the buffer via chan_send", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local buf = bridge.create_buffer("test")
    local handle = {
      bufnr = buf.bufnr, chan = buf.chan,
      name = "test", pane_id = "%99",
      _on_input_holder = buf._on_input_holder,
    }
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "T",
      on_attach = function(client)
        bridge.attach(handle, client)
      end,
      on_error = function(_) end,
    })

    local uv = vim.uv or vim.loop
    local client = uv.new_pipe(false)
    client:connect(sock_path, function(err)
      assert(not err, err)
      client:write("AUTH T\n")
      vim.defer_fn(function()
        client:write("hello-from-pane\n")
      end, 50)
    end)

    local ok = vim.wait(2000, function()
      local lines = vim.api.nvim_buf_get_lines(buf.bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("hello-from-pane", 1, true) then
          return true
        end
      end
      return false
    end)
    assert.is_true(ok)
    client:close()
    server:close()
    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
  end)

  it("on_input writes user keystrokes back to the socket", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local buf = bridge.create_buffer("kb")
    local handle = {
      bufnr = buf.bufnr, chan = buf.chan,
      name = "kb", pane_id = "%1",
      _on_input_holder = buf._on_input_holder,
    }

    local server = bridge.start_server({
      socket_path = sock_path,
      token = "T",
      on_attach = function(client)
        bridge.attach(handle, client)
      end,
      on_error = function(_) end,
    })

    -- Bytes written by the bridge to its server-side client flow to the
    -- OTHER end of the socket — the test_client below.
    local received = {}
    local uv = vim.uv or vim.loop
    local test_client = uv.new_pipe(false)
    test_client:connect(sock_path, function(err)
      assert(not err, err)
      test_client:write("AUTH T\n")
      test_client:read_start(function(_, data)
        if data then
          table.insert(received, data)
        end
      end)
    end)

    -- Wait for handshake to land.
    assert.is_true(vim.wait(1000, function()
      return handle._attached == true
    end))

    -- Simulate user input via the underlying channel's on_input.
    handle._on_input("i", buf.chan, buf.bufnr, "ls\r")
    assert.is_true(vim.wait(1000, function()
      for _, chunk in ipairs(received) do
        if chunk:find("ls\r", 1, true) then
          return true
        end
      end
      return false
    end))

    test_client:close()
    server:close()
    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
  end)
end)
