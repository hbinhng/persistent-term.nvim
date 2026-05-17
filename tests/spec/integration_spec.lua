-- tests/spec/integration_spec.lua
local has_tmux = (vim.fn.executable("tmux") == 1)

if not has_tmux then
  describe("persistent-term integration", function()
    pending("requires tmux on PATH")
  end)
  return
end

local function run(argv)
  return vim.system(argv, { text = true }):wait()
end

local function reset_tmux_server()
  run({ "tmux", "-L", "persistent-term", "kill-server" })
  -- Do NOT remove the stale socket file: tmux -L requires the socket file to
  -- exist in order to start a new server at that path. When kill-server exits,
  -- the socket file is left behind in a stale (unconnectable) state, and the
  -- next new-session will atomically replace it with a fresh server socket.
  -- Removing the socket file here would break that restart cycle.
end

local function wait_until(predicate, ms)
  return vim.wait(ms or 2000, predicate, 20)
end

describe("persistent-term integration", function()
  before_each(function()
    reset_tmux_server()
    for _, mod in ipairs({
      "persistent_term",
      "persistent_term.command",
      "persistent_term.bridge",
      "persistent_term.tmux",
      "persistent_term.gateway",
      "persistent_term.codec",
    }) do
      package.loaded[mod] = nil
    end
    -- Make sure the gateway singleton is fresh.
    package.loaded["persistent_term.gateway"] = nil
    -- Reset the plugin guard so runtime re-registers all commands.
    vim.g.loaded_persistent_term = nil
    vim.cmd("runtime plugin/persistent_term.lua")
  end)

  after_each(function()
    local ok, gw_mod = pcall(require, "persistent_term.gateway")
    if ok then
      pcall(gw_mod._reset_singleton_for_test)
    end
    reset_tmux_server()
  end)

  it("PTerm starts a pane and pipes output into the buffer", function()
    vim.cmd([[PTerm dev -- bash -c 'sleep 1; printf hello; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("hello", 1, true) then
          return true
        end
      end
      return false
    end, 5000))
  end)

  it("PTerm <name> with no -- runs $SHELL", function()
    local fake = vim.fn.tempname() .. "-fake-shell.sh"
    vim.fn.writefile({
      "#!/bin/sh",
      "sleep 1",
      "echo PTERM-SHELL-READY-$$",
      "sleep 30",
    }, fake)
    vim.fn.system({ "chmod", "0755", fake })

    local orig_shell = vim.env.SHELL
    vim.env.SHELL = fake

    local ok_call, err = pcall(function()
      vim.cmd("PTerm shdef")
      local bufnr = vim.api.nvim_get_current_buf()
      local ok = wait_until(function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for _, l in ipairs(lines) do
          if l:find("PTERM-SHELL-READY-", 1, true) then
            return true
          end
        end
        return false
      end, 5000)
      assert.is_truthy(ok, "expected fake $SHELL to be exec'd and produce sentinel")
    end)

    vim.env.SHELL = orig_shell
    vim.fn.delete(fake)
    if not ok_call then
      error(err)
    end
  end)

  it("PTermAttach after :bd replays scrollback", function()
    vim.cmd([[PTerm rep -- bash -c 'sleep 1; echo replay-line; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("replay-line", 1, true) then
          return true
        end
      end
      return false
    end, 5000))
    vim.cmd("bdelete!")
    vim.cmd("PTermAttach rep")
    local bufnr2 = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("replay-line", 1, true) then
          return true
        end
      end
      return false
    end, 5000))
  end)

  it("duplicate-name :PTerm fails", function()
    vim.cmd([[PTerm dup -- bash -c 'sleep 30']])
    local result = pcall(vim.cmd, [[PTerm dup -- bash -c 'sleep 30']])
    local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
    local count = 0
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      if line == "dup" then
        count = count + 1
      end
    end
    assert.equals(1, count)
  end)

  it("PTermKill removes the pane", function()
    vim.cmd([[PTerm kx -- bash -c 'sleep 30']])
    vim.cmd("PTermKill")
    assert.is_truthy(wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
      return not (res.stdout or ""):find("kx", 1, true)
    end, 3000))
  end)

  it("resize forwards to tmux", function()
    vim.cmd([[PTerm rz -- bash -c 'sleep 30']])
    -- Use `set columns` instead of `vertical resize` so the VimResized autocmd fires
    -- even when there is only one window (headless / CI environments).
    vim.cmd("set columns=60")
    vim.wait(200)
    local res = run({
      "tmux",
      "-L",
      "persistent-term",
      "display-message",
      "-p",
      "-t",
      vim.b.persistent_term_pane_id,
      "#{pane_width}",
    })
    assert.equals("60", vim.trim(res.stdout))
  end)

  it("PTerm works with no pre-existing tmux server", function()
    -- before_each already killed the server. Verify list-panes really fails.
    local probe = run({ "tmux", "-L", "persistent-term", "list-panes", "-a" })
    assert.is_false(probe.code == 0)
    assert.is_truthy((probe.stderr or ""):find("no server running", 1, true))

    -- :PTerm against a dead server should NOT surface that error; it should
    -- spawn the server via new-session and proceed normally. `sleep 1;` avoids
    -- the well-known race where the pane's command finishes before pipe-pane
    -- has wired the output into our socket.
    vim.cmd([[PTerm fresh -- bash -c 'sleep 1; printf hi-fresh; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("hi-fresh", 1, true) then
          return true
        end
      end
      return false
    end, 5000))
  end)

  it("PTermAttach to unknown name with no server reports a clean error", function()
    -- before_each already killed the server.
    local probe = run({ "tmux", "-L", "persistent-term", "list-panes", "-a" })
    assert.is_false(probe.code == 0)

    -- Should NOT propagate "no server running"; should report "unknown pane".
    -- The command is wired to log.error via init.lua; log writes to vim.notify
    -- via vim.schedule, so we must drain scheduled callbacks before restoring.
    local captured = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, _level)
      table.insert(captured, msg)
    end
    pcall(vim.cmd, [[PTermAttach ghostname]])
    vim.wait(100, function()
      return #captured > 0
    end)
    vim.notify = orig_notify

    local joined = table.concat(captured, "\n")
    assert.is_truthy(joined:find("unknown pane", 1, true), "expected 'unknown pane' notification, got:\n" .. joined)
    assert.is_nil(
      joined:find("no server running", 1, true),
      "should not propagate 'no server running' to user; got:\n" .. joined
    )
  end)

  local function capture_notify(thunk)
    local out = {}
    local orig = vim.notify
    vim.notify = function(msg, _l)
      table.insert(out, msg)
    end
    local ok, err = pcall(thunk)
    vim.wait(100, function()
      return #out > 0
    end)
    vim.notify = orig
    if not ok then
      error(err)
    end
    return table.concat(out, "\n")
  end

  it("PTermList on a fresh server prints 'no persistent terminals'", function()
    local out = capture_notify(function()
      vim.cmd("PTermList")
    end)
    assert.is_truthy(out:find("no persistent terminals", 1, true), "got: " .. out)
  end)

  it("PTermList lists 2 panes with attached=yes", function()
    vim.cmd([[PTerm l1 -- bash -c 'sleep 1; printf one;   sleep 30']])
    vim.cmd([[PTerm l2 -- bash -c 'sleep 1; printf two;   sleep 30']])
    assert.is_truthy(
      wait_until(function()
        local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
        local seen_l1, seen_l2
        for line in (res.stdout or ""):gmatch("[^\n]+") do
          if line == "l1" then
            seen_l1 = true
          end
          if line == "l2" then
            seen_l2 = true
          end
        end
        return seen_l1 and seen_l2
      end, 3000),
      "tmux never showed both panes"
    )

    local out = capture_notify(function()
      vim.cmd("PTermList")
    end)
    local n = 0
    for _ in out:gmatch("[^\n]+") do
      n = n + 1
    end
    assert.equals(3, n, "expected 3 lines (header + 2), got:\n" .. out)
    assert.is_truthy(out:find("l1", 1, true))
    assert.is_truthy(out:find("l2", 1, true))
    local yes_count = 0
    for _ in out:gmatch("%f[%w]yes%f[%W]") do
      yes_count = yes_count + 1
    end
    assert.equals(2, yes_count, "expected 2 'yes' (whole-word), got:\n" .. out)
  end)

  it("PTermList drops the killed pane", function()
    vim.cmd([[PTerm k1 -- bash -c 'sleep 1; printf one; sleep 30']])
    vim.cmd([[PTerm k2 -- bash -c 'sleep 1; printf two; sleep 30']])
    assert.is_truthy(
      wait_until(function()
        local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
        return (res.stdout or ""):find("k1") and (res.stdout or ""):find("k2")
      end, 3000),
      "tmux never showed both k1 and k2"
    )
    local k1_buf
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == "pterm://k1" then
        k1_buf = b
        break
      end
    end
    assert.is_truthy(k1_buf, "could not find pterm://k1 buffer")
    require("persistent_term.command").cmd_kill(k1_buf)
    assert.is_truthy(
      wait_until(function()
        local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
        return not (res.stdout or ""):find("k1", 1, true)
      end, 3000),
      "k1 never disappeared from tmux after kill"
    )
    local out = capture_notify(function()
      vim.cmd("PTermList")
    end)
    assert.is_nil(out:find("k1", 1, true), "k1 should be gone, got:\n" .. out)
    assert.is_truthy(out:find("k2", 1, true), "k2 should remain, got:\n" .. out)
  end)

  it("PTermList marks a dead pane as STATUS=dead", function()
    vim.cmd([[PTerm dx -- bash -c 'sleep 1; exit 0']])
    assert.is_truthy(wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}\t#{pane_dead}" })
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local n, d = line:match("^(.-)\t(.)$")
        if n == "dx" and d == "1" then
          return true
        end
      end
      return false
    end, 5000))
    local out = capture_notify(function()
      vim.cmd("PTermList")
    end)
    local dx_line
    for line in out:gmatch("[^\n]+") do
      if line:find("dx", 1, true) then
        dx_line = line
        break
      end
    end
    assert.is_truthy(dx_line, "no dx row in:\n" .. out)
    assert.is_truthy(dx_line:find("dead", 1, true), "dx row missing 'dead': " .. dx_line)
  end)

  it("PTerm configures the server with xterm-256color and truecolor", function()
    vim.cmd([[PTerm tterm -- bash -c 'sleep 1; echo PTERM_TERM=$TERM; echo PTERM_COLORTERM=$COLORTERM; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()

    -- The child must see TERM=xterm-256color and COLORTERM=truecolor in its env.
    -- Two echoes so line-wrap at narrow terminal widths cannot truncate the assertion.
    assert.is_truthy(
      wait_until(function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for _, l in ipairs(lines) do
          if l:find("PTERM_TERM=xterm-256color", 1, true) then
            return true
          end
        end
        return false
      end, 5000),
      "child never reported PTERM_TERM=xterm-256color"
    )

    assert.is_truthy(
      wait_until(function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for _, l in ipairs(lines) do
          if l:find("PTERM_COLORTERM=truecolor", 1, true) then
            return true
          end
        end
        return false
      end, 5000),
      "child never reported PTERM_COLORTERM=truecolor"
    )

    -- The server-side options must be set.
    local opt = run({ "tmux", "-L", "persistent-term", "show-options", "-gv", "default-terminal" })
    assert.equals(0, opt.code, "show-options default-terminal failed: " .. (opt.stderr or ""))
    assert.equals("xterm-256color", (opt.stdout or ""):gsub("%s+$", ""))

    local envr = run({ "tmux", "-L", "persistent-term", "show-environment", "-g", "COLORTERM" })
    assert.equals(0, envr.code, "show-environment COLORTERM failed: " .. (envr.stderr or ""))
    assert.equals("COLORTERM=truecolor", (envr.stdout or ""):gsub("%s+$", ""))

    -- terminal-features is only set on tmux >= 3.2. Read the installed tmux version
    -- and gate this sub-assertion the same way cmd_open does.
    local vres = run({ "tmux", "-V" })
    local vstr = (vres.stdout or ""):match("tmux%s+(%S+)")
    if vstr and require("persistent_term.tmux").version_at_least(vstr, "3.2") then
      local feat = run({ "tmux", "-L", "persistent-term", "show-options", "-gv", "terminal-features" })
      assert.equals(0, feat.code, "show-options terminal-features failed: " .. (feat.stderr or ""))
      assert.is_truthy(
        (feat.stdout or ""):find("xterm-256color:RGB", 1, true),
        "terminal-features did not contain xterm-256color:RGB; got: " .. tostring(feat.stdout)
      )
    end
  end)

  it("only one cursor-position-report arrives per \\e[6n query (no double-response leak)", function()
    -- Write the bash script to a tempfile to sidestep tmux -CC command-parser
    -- quoting limitations (it does not support \" inside double-quoted tokens).
    -- The script:
    --  1. Switches the pane tty to raw mode (no echo).
    --  2. Sends the CPR query \e[6n to the pane PTY.
    --  3. Collects every byte that arrives within a 500 ms inactivity window
    --     using `while read -t 0.5 -N 1`; this captures both tmux's own
    --     immediate vterm response AND any delayed second response that a buggy
    --     bridge might inject (the double-response bug we are regressing).
    --  4. Hex-encodes the collected bytes with `od | tr` so escape sequences
    --     survive shell variable assignment and terminal rendering unchanged.
    --  5. Prints the sentinel line "RESPONSE=<hex>|END" for the test to scrape.
    local script_path = vim.fn.tempname() .. "-cprtest.sh"
    vim.fn.writefile({
      "#!/bin/bash",
      "stty -echo raw 2>/dev/null",
      "printf '\\033[6n'",
      "ACCUM=",
      'while IFS= read -r -t 0.5 -N 1 CH; do ACCUM="${ACCUM}${CH}"; done',
      "stty cooked 2>/dev/null",
      'R=$(printf "%s" "$ACCUM" | od -An -tx1 | tr -d " \n")',
      'printf "RESPONSE=%s|END\\n" "$R"',
      "sleep 30",
    }, script_path)
    vim.fn.system({ "chmod", "0755", script_path })

    local ok_call, call_err = pcall(function()
      vim.cmd(string.format("PTerm cprtest -- %s", script_path))
    end)

    if not ok_call then
      vim.fn.delete(script_path)
      error(call_err)
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local found = wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("RESPONSE=", 1, true) and l:find("|END", 1, true) then
          local resp = l:match("RESPONSE=(.-)|END")
          if resp == nil then
            return false
          end
          -- Count CPR sequences in the hex-encoded response.
          -- A CPR has the shape ESC [ <row> ; <col> R, which hex-encodes
          -- (via od -tx1 | tr -d ' ') as:
          --   1b  5b  <row-hex-pairs>  3b  <col-hex-pairs>  52
          -- Pattern: "1b5b" + hex digits + "3b" + hex digits + "52"
          local count = 0
          for _ in resp:gmatch("1b5b[0-9a-f]+3b[0-9a-f]+52") do
            count = count + 1
          end
          -- With the bug present we'd see 2; with the fix in place we see 1.
          rawset(_G, "_pterm_cpr_count", count)
          return true
        end
      end
      return false
    end, 8000)

    vim.fn.delete(script_path)
    assert.is_truthy(found, "RESPONSE sentinel never appeared in the buffer")
    assert.equals(1, rawget(_G, "_pterm_cpr_count"))
  end)

  it("%window-close event renames the buffer to [detached]", function()
    vim.cmd([[PTerm killme -- bash -c 'sleep 300']])
    local bufnr = vim.api.nvim_get_current_buf()
    -- Wait for the pane to actually be alive.
    assert.is_truthy(wait_until(function()
      return vim.b[bufnr].persistent_term_pane_id ~= nil
    end, 5000))
    local window_id = vim.b[bufnr].persistent_term_window_id
    assert.is_truthy(window_id, "expected persistent_term_window_id to be set")
    -- Kill the tmux window directly (bypassing :PTermKill which deletes the
    -- buffer first). The %window-close notification from tmux will fire the
    -- on_close callback -> bridge.detach -> buffer rename to [detached].
    run({ "tmux", "-L", "persistent-term", "kill-window", "-t", window_id })
    assert.is_truthy(wait_until(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
      end
      local name = vim.api.nvim_buf_get_name(bufnr)
      return name:find("%[detached%]") ~= nil
    end, 5000))
  end)

  it("server persistence: detach + re-attach rediscovers existing panes", function()
    vim.cmd([[PTerm persist -- bash -c 'sleep 300']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      return vim.b[bufnr].persistent_term_pane_id ~= nil
    end, 5000))
    -- Detach the gateway; tmux server keeps running with the pane.
    local gw_mod = require("persistent_term.gateway")
    local gw = gw_mod.singleton()
    gw:detach()
    assert.is_truthy(wait_until(function()
      return gw:state() == "stopped"
    end, 5000))
    -- Reset the singleton so the next gateway.singleton() creates a fresh one.
    gw_mod._reset_singleton_for_test()
    -- Start the fresh gateway; bootstrap issues list-windows to rediscover panes.
    local new_gw = gw_mod.singleton()
    local started = new_gw:ensure_started(5000)
    assert.is_truthy(started, "new gateway failed to reach ready state")
    -- Wait for the pane map to repopulate (bootstrap's refresh_pane_map).
    assert.is_truthy(wait_until(function()
      local rows = require("persistent_term").list()
      for _, r in ipairs(rows) do
        if r.name == "persist" then
          return true
        end
      end
      return false
    end, 5000))
    -- Confirm.
    local list = require("persistent_term").list()
    local found = false
    for _, r in ipairs(list) do
      if r.name == "persist" then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
