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
    assert.equals(1, vim.fn.filereadable(sock_path) + (vim.fn.getftype(sock_path) == "socket" and 1 or 0) >= 1 and 1 or 0)
    server:close()
    assert.equals("", vim.fn.getftype(sock_path))
  end)
end)
