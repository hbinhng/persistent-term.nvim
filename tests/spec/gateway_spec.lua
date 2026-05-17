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

describe("gateway command queue", function()
  local gateway
  before_each(function()
    package.loaded["persistent_term.gateway"] = nil
    gateway = require("persistent_term.gateway")
  end)

  local function ready_gw(t)
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    return gw
  end

  it("writes a command to the transport with trailing newline", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    gw:send_cmd("display-message -p '#{version}'", function() end)
    -- Find the command line we wrote (after the empty initial state).
    local last = t.written[#t.written]
    assert.equals("display-message -p '#{version}'\n", last)
  end)

  it("fires the callback with the response body on %end", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local result
    gw:send_cmd("display-message -p '#{version}'", function(r)
      result = r
    end)
    t.feed("%begin 2 1 1\n3.4\n%end 2 1 1\n")
    assert.is_table(result)
    assert.is_true(result.ok)
    assert.equals("3.4", result.stdout)
  end)

  it("fires the callback with an error on %error", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local result
    gw:send_cmd("kill-window -t @99", function(r)
      result = r
    end)
    t.feed("%begin 3 1 1\ncan't find window: @99\n%error 3 1 1\n")
    assert.is_table(result)
    assert.is_false(result.ok)
    assert.is_truthy(result.stderr:find("can't find window"))
  end)

  it("preserves callback order across two interleaved commands", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local results = {}
    gw:send_cmd("a", function(r)
      table.insert(results, "a:" .. r.stdout)
    end)
    gw:send_cmd("b", function(r)
      table.insert(results, "b:" .. r.stdout)
    end)
    t.feed("%begin 1 1 1\nA\n%end 1 1 1\n")
    t.feed("%begin 2 2 1\nB\n%end 2 2 1\n")
    assert.same({ "a:A", "b:B" }, results)
  end)

  it("accumulates a multi-line response body", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local result
    gw:send_cmd("list-windows", function(r)
      result = r
    end)
    t.feed("%begin 1 1 1\n")
    t.feed("@1\t%1\tdev\t0\n")
    t.feed("@2\t%2\ttest\t0\n")
    t.feed("%end 1 1 1\n")
    assert.equals("@1\t%1\tdev\t0\n@2\t%2\ttest\t0", result.stdout)
  end)
end)

describe("gateway subscribers", function()
  local gateway
  before_each(function()
    package.loaded["persistent_term.gateway"] = nil
    gateway = require("persistent_term.gateway")
  end)

  local function ready_gw(t)
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    return gw
  end

  it("dispatches %output bytes to the subscribed pane callback", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local received = {}
    gw:subscribe("%1", "@1", function(bytes)
      table.insert(received, bytes)
    end, function() end)
    t.feed("%output %1 hello\n")
    assert.same({ "hello" }, received)
  end)

  it("decodes octal escapes in %output payload before dispatching", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local received
    gw:subscribe("%1", "@1", function(bytes)
      received = bytes
    end, function() end)
    t.feed("%output %1 \\033[K\n")
    assert.equals("\27[K", received)
  end)

  it("drops %output for an unknown pane id without erroring", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    -- No subscriber.
    assert.has_no.errors(function()
      t.feed("%output %99 hello\n")
    end)
  end)

  it("calls on_close when %window-close arrives for the subscribed window", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local closed = false
    gw:subscribe("%1", "@1", function() end, function()
      closed = true
    end)
    t.feed("%window-close @1\n")
    assert.is_true(closed)
  end)

  it("removes the subscriber after %window-close", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local received = {}
    gw:subscribe("%1", "@1", function(b)
      table.insert(received, b)
    end, function() end)
    t.feed("%window-close @1\n")
    t.feed("%output %1 stale\n")
    assert.same({}, received)
  end)

  it("supports multiple subscribers across different panes", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local a, b = {}, {}
    gw:subscribe("%1", "@1", function(x)
      table.insert(a, x)
    end, function() end)
    gw:subscribe("%2", "@2", function(x)
      table.insert(b, x)
    end, function() end)
    t.feed("%output %2 to-b\n%output %1 to-a\n")
    assert.same({ "to-a" }, a)
    assert.same({ "to-b" }, b)
  end)
end)
