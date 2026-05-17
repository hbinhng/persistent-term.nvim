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
    -- Drain the 5 bootstrap commands queued by _run_bootstrap.
    t.feed("%begin 2 1 1\n3.4\n%end 2 1 1\n") -- display-message (version)
    t.feed("%begin 3 2 1\n%end 3 2 1\n") -- set-option default-terminal
    t.feed("%begin 4 3 1\n%end 4 3 1\n") -- set-environment COLORTERM
    t.feed("%begin 5 4 1\n%end 5 4 1\n") -- display-message (2nd, gates terminal-features)
    -- terminal-features set-option was written directly; drain its ack too.
    t.feed("%begin 6 5 1\n%end 6 5 1\n")
    -- refresh_pane_map sends list-windows; drain its ack.
    t.feed("%begin 7 6 1\n%end 7 6 1\n")
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

  it("continues to deliver to other subscribers when one on_bytes throws", function()
    local t = make_fake_transport()
    local gw = ready_gw(t)
    local a, b = {}, {}
    gw:subscribe("%1", "@1", function()
      error("boom")
    end, function() end)
    gw:subscribe("%2", "@2", function(x)
      table.insert(b, x)
    end, function() end)
    t.feed("%output %1 bad\n")
    t.feed("%output %2 good\n")
    assert.same({}, a)
    assert.same({ "good" }, b)
  end)
end)

describe("gateway.send_keys", function()
  local gateway
  before_each(function()
    package.loaded["persistent_term.gateway"] = nil
    gateway = require("persistent_term.gateway")
  end)

  local function ready_gw_with_version(t, version)
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    gw:_set_version_for_test(version)
    return gw
  end

  it("writes one send-keys command for a printable run on tmux 3.4", function()
    local t = make_fake_transport()
    local gw = ready_gw_with_version(t, "3.4")
    -- Reset the captured writes so we only see what send_keys produced.
    t.written = {}
    gw:send_keys("%1", "hi")
    assert.same({ "send-keys -lt %1 'hi'\n" }, t.written)
  end)

  it("writes one literal-byte command for Enter on tmux 3.0a", function()
    local t = make_fake_transport()
    local gw = ready_gw_with_version(t, "3.0a")
    t.written = {}
    gw:send_keys("%1", "\r")
    assert.same({ "send-keys -H -t %1 0d\n" }, t.written)
  end)

  it("writes three commands for ESC [ D on tmux 3.4", function()
    local t = make_fake_transport()
    local gw = ready_gw_with_version(t, "3.4")
    t.written = {}
    gw:send_keys("%1", "\27[D")
    assert.same({
      "send-keys -H -t %1 1b\n",
      "send-keys -t %1 0x5b\n",
      "send-keys -lt %1 'D'\n",
    }, t.written)
  end)

  it("does nothing for empty input", function()
    local t = make_fake_transport()
    local gw = ready_gw_with_version(t, "3.4")
    t.written = {}
    gw:send_keys("%1", "")
    assert.same({}, t.written)
  end)
end)

describe("gateway.detach", function()
  local gateway
  before_each(function()
    package.loaded["persistent_term.gateway"] = nil
    gateway = require("persistent_term.gateway")
  end)

  it("writes 'detach' and transitions to detaching, then stopped on %exit", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    t.written = {}
    gw:detach()
    assert.same({ "detach\n" }, t.written)
    assert.equals("detaching", gw:state())
    t.feed("%exit\n")
    assert.equals("stopped", gw:state())
  end)

  it("fires on_close for every active subscriber on %exit", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    local closed = {}
    gw:subscribe("%1", "@1", function() end, function()
      table.insert(closed, "%1")
    end)
    gw:subscribe("%2", "@2", function() end, function()
      table.insert(closed, "%2")
    end)
    t.feed("%exit\n")
    table.sort(closed)
    assert.same({ "%1", "%2" }, closed)
  end)
end)

describe("gateway bootstrap", function()
  local gateway
  before_each(function()
    package.loaded["persistent_term.gateway"] = nil
    gateway = require("persistent_term.gateway")
  end)

  it("issues display-message + set-options after entering ready", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    -- Bootstrap should have been issued by now.
    local cmds = table.concat(t.written, "")
    assert.is_truthy(cmds:find("display%-message %-p '#{version}'"))
    assert.is_truthy(cmds:find("set%-option %-g default%-terminal xterm%-256color"))
    assert.is_truthy(cmds:find("set%-environment %-g COLORTERM truecolor"))
  end)

  it("sends terminal-features when tmux >= 3.2 (after version is known)", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    -- Drain the bootstrap responses: version first.
    t.feed("%begin 2 1 1\n3.4\n%end 2 1 1\n")
    -- The terminal-features command is conditionally sent AFTER version is known.
    t.feed("%begin 3 2 1\n%end 3 2 1\n") -- default-terminal response
    t.feed("%begin 4 3 1\n%end 4 3 1\n") -- COLORTERM response
    t.feed("%begin 5 4 1\n%end 5 4 1\n") -- terminal-features response
    local cmds = table.concat(t.written, "")
    assert.is_truthy(cmds:find("set%-option %-g terminal%-features"))
  end)

  it("skips terminal-features when tmux < 3.2", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    t.feed("%begin 2 1 1\n3.0a\n%end 2 1 1\n")
    t.feed("%begin 3 2 1\n%end 3 2 1\n")
    t.feed("%begin 4 3 1\n%end 4 3 1\n")
    local cmds = table.concat(t.written, "")
    assert.is_nil(cmds:find("terminal%-features"))
  end)

  it("captures version string on the gateway", function()
    local t = make_fake_transport()
    local gw = gateway.new({ transport = t })
    gw:start()
    t.feed("%begin 1 0 0\n%end 1 0 0\n%session-changed $0 pterm\n")
    t.feed("%begin 2 1 1\n3.4\n%end 2 1 1\n")
    assert.equals("3.4", gw:version())
  end)
end)
