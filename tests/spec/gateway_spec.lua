-- tests/spec/gateway_spec.lua
local function make_fake_transport()
  local t = {
    written = {}, -- list of bytes written by gateway.write
    on_stdout = nil,
    on_stderr = nil,
    on_exit = nil,
    started = false,
    killed = false,
  }
  function t.start(on_stdout, on_stderr, on_exit)
    t.started = true
    t.on_stdout = on_stdout
    t.on_stderr = on_stderr
    t.on_exit = on_exit
    return true, nil
  end
  function t.write(bytes)
    table.insert(t.written, bytes)
    return true
  end
  function t.kill()
    t.killed = true
    if t.on_exit then
      t.on_exit(0, 0)
    end
  end
  -- Helper used by tests to drive the gateway.
  function t.feed(chunk)
    t.on_stdout(chunk)
  end
  return t
end

describe("gateway state machine", function()
  local gateway

  before_each(function()
    package.loaded["persistent_term.gateway"] = nil
    gateway = require("persistent_term.gateway")
  end)

  it("starts in 'stopped' state", function()
    local gw = gateway.new({ transport = make_fake_transport() })
    assert.equals("stopped", gw:state())
  end)

  it("transitions stopped -> starting when start() is called", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    assert.equals("starting", gw:state())
    assert.is_true(t.started)
  end)

  it("transitions starting -> ready_no_session on the initial %begin/%end block", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1700000000 0 0\n")
    t.feed("%end 1700000000 0 0\n")
    assert.equals("ready_no_session", gw:state())
  end)

  it("transitions ready_no_session -> ready on %session-changed", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1700000000 0 0\n")
    t.feed("%end 1700000000 0 0\n")
    t.feed("%session-changed $0 pterm\n")
    assert.equals("ready", gw:state())
  end)

  it("transitions to stopped on %exit", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    t.feed("%exit\n")
    assert.equals("stopped", gw:state())
  end)

  it("transitions to stopped on transport on_exit", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.on_exit(0, 0)
    assert.equals("stopped", gw:state())
  end)

  it("logs stderr lines through the provided logger", function()
    local logged = {}
    local t = make_fake_transport()
    local gw = gateway.new({
      transport = t,
      log = {
        warn = function(msg)
          table.insert(logged, msg)
        end,
        error = function() end,
        debug = function() end,
      },
    })
    gw:start()
    t.on_stderr("something went wrong\n")
    assert.equals(1, #logged)
    assert.is_truthy(logged[1]:find("something went wrong"))
  end)
end)
