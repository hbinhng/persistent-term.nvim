-- tests/spec/tmux_spec.lua
describe("persistent_term.tmux builders", function()
  local tmux

  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("new_session builds correct argv", function()
    local argv = tmux.builders.new_session({
      session_name = "pterm_abc",
      cols = 120,
      rows = 32,
      cwd = "/home/u",
      argv = { "npm", "run", "dev" },
    })
    assert.same({
      "tmux", "-L", "persistent-term",
      "new-session", "-d",
      "-s", "pterm_abc",
      "-x", "120", "-y", "32",
      "-c", "/home/u",
      "-P", "-F", "#{session_id}\t#{pane_id}\t#{window_id}",
      "--", "npm", "run", "dev",
    }, argv)
  end)

  it("list_panes builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "list-panes", "-a",
      "-F", "#{pane_id}\t#{window_id}\t#{@pterm_name}",
    }, tmux.builders.list_panes())
  end)

  it("kill_pane builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "kill-pane", "-t", "%12",
    }, tmux.builders.kill_pane("%12"))
  end)

  it("pipe_pane builds shell-quoted helper invocation", function()
    local argv = tmux.builders.pipe_pane({
      pane_id = "%12",
      bin_path = "/home/u/.local/share/nvim/persistent-term/bin/persistent-term-pipe",
      socket_path = "/run/user/1000/persistent-term/abc.sock",
      token = "deadbeef",
    })
    assert.same({
      "tmux", "-L", "persistent-term",
      "pipe-pane", "-t", "%12", "-IO",
      "'/home/u/.local/share/nvim/persistent-term/bin/persistent-term-pipe'"
        .. " --socket '/run/user/1000/persistent-term/abc.sock'"
        .. " --token 'deadbeef'",
    }, argv)
  end)

  it("pipe_pane rejects unsafe characters in any field", function()
    assert.has_error(function()
      tmux.builders.pipe_pane({
        pane_id = "%12",
        bin_path = "/tmp/x'/persistent-term-pipe",
        socket_path = "/tmp/x.sock",
        token = "ABCD",
      })
    end)
    assert.has_error(function()
      tmux.builders.pipe_pane({
        pane_id = "%12",
        bin_path = "/tmp/bin",
        socket_path = "/tmp/x.sock",
        token = "ABCD; rm",
      })
    end)
  end)

  it("capture_pane builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "capture-pane", "-p", "-e", "-J",
      "-S", "-", "-E", "-",
      "-t", "%12",
    }, tmux.builders.capture_pane("%12"))
  end)

  it("resize_pane builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "resize-pane", "-t", "%12",
      "-x", "80", "-y", "24",
    }, tmux.builders.resize_pane("%12", 80, 24))
  end)

  it("set_pane_option builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "set-option", "-p", "-t", "%12",
      "@pterm_name", "dev",
    }, tmux.builders.set_pane_option("%12", "@pterm_name", "dev"))
  end)

  it("set_window_option builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "set-option", "-w", "-t", "@7",
      "remain-on-exit", "on",
    }, tmux.builders.set_window_option("@7", "remain-on-exit", "on"))
  end)

  it("version_check_argv builds correct argv", function()
    assert.same({ "tmux", "-V" }, tmux.builders.version_check())
  end)
end)

describe("persistent_term.tmux executor + helpers", function()
  local tmux

  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("parse_list_panes splits lines into {pane_id, name}", function()
    local rows = tmux.parse_list_panes("%12\t@1\tdev\n%13\t@2\ttest\n%14\t@3\t\n")
    assert.same({
      { pane_id = "%12", window_id = "@1", name = "dev" },
      { pane_id = "%13", window_id = "@2", name = "test" },
      { pane_id = "%14", window_id = "@3", name = "" },
    }, rows)
  end)

  it("parse_new_session_output splits ids", function()
    local r = tmux.parse_new_session_output("$3\t%12\t@7\n")
    assert.same({ session_id = "$3", pane_id = "%12", window_id = "@7" }, r)
  end)

  it("compare_versions handles 3.0a vs 3.0", function()
    assert.is_true(tmux.version_at_least("3.0", "3.0"))
    assert.is_true(tmux.version_at_least("3.1", "3.0"))
    assert.is_true(tmux.version_at_least("3.0a", "3.0"))
    assert.is_false(tmux.version_at_least("2.9", "3.0"))
  end)

  it("run executes argv and returns ok/stdout/stderr/code", function()
    -- Use a portable trivial command via the executor.
    local res = tmux.run({ "true" })
    assert.is_true(res.ok)
    assert.equals(0, res.code)
    local res2 = tmux.run({ "false" })
    assert.is_false(res2.ok)
    assert.is_true(res2.code ~= 0)
  end)
end)
