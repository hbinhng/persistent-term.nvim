# TERM rendering fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate rendering corruption in `:PTerm` panes (blank rows between zsh completion entries, fragmented prompts, leftover prompt fragments) by advertising `xterm-256color` + truecolor to the tmux server and the child process, instead of the inherited `screen` default.

**Architecture:** Inline bootstrap before every `new-session` on the `tmux -L persistent-term` socket: run three short tmux commands (`set-option -g default-terminal xterm-256color`, optionally `set-option -g terminal-features xterm-256color:RGB` when tmux ≥ 3.2, and `set-environment -g COLORTERM truecolor`). Add `-e TERM=xterm-256color -e COLORTERM=truecolor` to every `new-session` argv for per-session redundancy. No new public API, no protocol change in `bridge.lua` or the Go helper.

**Tech Stack:** Lua (Neovim 0.10+), tmux 3.0+, Plenary busted (`PlenaryBustedDirectory`) for the test runner. Tests live in `tests/spec/*.lua` and execute through `make lua-test`.

**Spec reference:** `docs/superpowers/specs/2026-05-17-term-rendering-fix-design.md`.

---

## File Map

| File | Change | Why |
|---|---|---|
| `lua/persistent_term/tmux.lua` | Modify | Add `set_server_option` and `set_server_env` builders; extend `new_session` builder with `-e` flags. |
| `lua/persistent_term/command.lua` | Modify | Insert bootstrap step in `cmd_open` between `install.is_installed()` check and `list-panes` call. |
| `tests/spec/tmux_spec.lua` | Modify | Update `new_session` argv expectation; add two new builder tests. |
| `tests/spec/command_spec.lua` | Modify | Update existing orchestration call-sequence assertion; add three new tests (3.2 bootstrap order, 3.0 skip, failure abort). |
| `tests/spec/integration_spec.lua` | Modify | Add one integration test verifying `default-terminal`, `terminal-features`, `COLORTERM`, and child-visible env. |

No new files. No deletions.

---

## Task 1: `set_server_option` builder

**Files:**
- Modify: `lua/persistent_term/tmux.lua` (add new function after `M.builders.set_window_option` at line 102-106)
- Modify: `tests/spec/tmux_spec.lua` (add new test in the `builders` describe block, near line 109)

- [ ] **Step 1: Write the failing test**

In `tests/spec/tmux_spec.lua`, immediately after the `set_window_option builds correct argv` test (which ends around line 110), add:

```lua
  it("set_server_option builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "set-option", "-g", "default-terminal", "xterm-256color",
    }, tmux.builders.set_server_option("default-terminal", "xterm-256color"))
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make lua-test 2>&1 | grep -E "set_server_option|FAIL|Error"`
Expected: failure mentioning `set_server_option` is nil / attempt to call a nil value.

- [ ] **Step 3: Add the builder**

In `lua/persistent_term/tmux.lua`, immediately after `M.builders.set_window_option` (currently ends at line 106 — closing `end` of that function), add:

```lua
function M.builders.set_server_option(key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-option", "-g", key, value })
  return argv
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make lua-test 2>&1 | tail -20`
Expected: All tests pass, total count up by 1 from previous run.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/tmux.lua tests/spec/tmux_spec.lua
git commit -m "feat(tmux): add set_server_option builder for global tmux options"
```

---

## Task 2: `set_server_env` builder

**Files:**
- Modify: `lua/persistent_term/tmux.lua` (add new function after `set_server_option` from Task 1)
- Modify: `tests/spec/tmux_spec.lua` (add new test near the one from Task 1)

- [ ] **Step 1: Write the failing test**

In `tests/spec/tmux_spec.lua`, immediately after the `set_server_option builds correct argv` test from Task 1, add:

```lua
  it("set_server_env builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "set-environment", "-g", "COLORTERM", "truecolor",
    }, tmux.builders.set_server_env("COLORTERM", "truecolor"))
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make lua-test 2>&1 | grep -E "set_server_env|FAIL|Error"`
Expected: failure mentioning `set_server_env` is nil.

- [ ] **Step 3: Add the builder**

In `lua/persistent_term/tmux.lua`, immediately after `M.builders.set_server_option` from Task 1, add:

```lua
function M.builders.set_server_env(key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-environment", "-g", key, value })
  return argv
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make lua-test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/tmux.lua tests/spec/tmux_spec.lua
git commit -m "feat(tmux): add set_server_env builder for global tmux env vars"
```

---

## Task 3: Extend `new_session` builder with `-e TERM` and `-e COLORTERM` env

**Files:**
- Modify: `lua/persistent_term/tmux.lua` (the existing `new_session` builder, currently at lines 24-36)
- Modify: `tests/spec/tmux_spec.lua` (update the existing `new_session builds correct argv` test, currently at lines 10-27)

- [ ] **Step 1: Update the existing test to expect new -e flags**

In `tests/spec/tmux_spec.lua` at the `new_session builds correct argv` test, replace the existing `assert.same(...)` block with the version that includes the `-e` flags:

```lua
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
      "-e", "TERM=xterm-256color",
      "-e", "COLORTERM=truecolor",
      "-P", "-F", "#{session_id}\t#{pane_id}\t#{window_id}",
      "--", "npm", "run", "dev",
    }, argv)
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make lua-test 2>&1 | grep -E "new_session|FAIL|expected"`
Expected: failure — actual argv has no `-e` entries.

- [ ] **Step 3: Add `-e` flags to the builder**

In `lua/persistent_term/tmux.lua`, replace the body of `M.builders.new_session` with the version that emits the env flags. The change is one insertion inside the `vim.list_extend` block:

```lua
function M.builders.new_session(opts)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "new-session", "-d",
    "-s", opts.session_name,
    "-x", tostring(opts.cols), "-y", tostring(opts.rows),
    "-c", opts.cwd,
    "-e", "TERM=xterm-256color",
    "-e", "COLORTERM=truecolor",
    "-P", "-F", "#{session_id}\t#{pane_id}\t#{window_id}",
    "--",
  })
  vim.list_extend(argv, opts.argv)
  return argv
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make lua-test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/tmux.lua tests/spec/tmux_spec.lua
git commit -m "feat(tmux): set TERM=xterm-256color and COLORTERM=truecolor on new-session"
```

---

## Task 4: Bootstrap server options before `new-session` (happy path, tmux 3.2+)

This task does three things at once because they are tightly coupled:
1. Updates the existing `orchestrates: pre-flight, dup check, new-session, options, pipe-pane` orchestration test (which currently expects no bootstrap calls) to expect the new sequence.
2. Adds a new dedicated unit test that pins down the exact bootstrap argvs.
3. Implements the bootstrap in `cmd_open`.

The version gate (skipping `terminal-features` on tmux < 3.2) and the failure-abort logic are NOT in this task — they come in Tasks 5 and 6. This task always emits all three commands and ignores their result codes for the moment.

**Files:**
- Modify: `tests/spec/command_spec.lua` (update orchestration test at ~line 84; add a new test in the `cmd_open` describe block)
- Modify: `lua/persistent_term/command.lua` (insert bootstrap block in `cmd_open` between line 200 and line 202)

- [ ] **Step 1: Update the existing orchestration test's call-sequence assertion**

In `tests/spec/command_spec.lua`, find the test `orchestrates: pre-flight, dup check, new-session, options, pipe-pane` (starts at ~line 84). Its current assertion is:

```lua
    assert.same(
      { "list-panes", "new-session", "set-option", "set-option", "pipe-pane" },
      subs
    )
```

Replace with the new expected sequence (bootstrap commands are now emitted before `list-panes`):

```lua
    assert.same(
      {
        "set-option", "set-option", "set-environment",
        "list-panes", "new-session", "set-option", "set-option", "pipe-pane",
      },
      subs
    )
```

The first three new entries are: `set-option default-terminal`, `set-option terminal-features`, `set-environment COLORTERM`. The existing `set-option` pair after `new-session` is `remain-on-exit` and `@pterm_name`.

- [ ] **Step 2: Add a new dedicated bootstrap-sequence test**

In `tests/spec/command_spec.lua`, immediately after the `orchestrates: ...` test you just updated, add:

```lua
  it("issues bootstrap (default-terminal + terminal-features + COLORTERM) before new-session on tmux 3.2+", function()
    local calls = {}
    local fake_builders = require("persistent_term.tmux").builders
    package.loaded["persistent_term.tmux"] = {
      builders = fake_builders,
      check_version = function(_) return { ok = true, version = "3.2" } end,
      version_at_least = require("persistent_term.tmux").version_at_least,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      parse_new_session_output = require("persistent_term.tmux").parse_new_session_output,
      run = function(argv)
        table.insert(calls, argv)
        local sub = argv[4]
        if sub == "list-panes" then
          return { ok = true, code = 0, stdout = "", stderr = "" }
        elseif sub == "new-session" then
          return { ok = true, code = 0, stdout = "$1\t%10\t@2\n", stderr = "" }
        end
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/persistent-term-pipe" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(_)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      resize_to = function(_, _, _) end,
      detach = function(_, _) end,
      kill = function(_) end,
    }

    command = require("persistent_term.command")
    local handle, err = command.cmd_open("dev -- bash -c hi")
    assert.is_nil(err)
    assert.is_truthy(handle)

    -- The first three tmux invocations are the bootstrap, in this exact order.
    assert.is_true(#calls >= 3, "expected at least 3 tmux calls; got " .. #calls)
    assert.same(
      { "tmux", "-L", "persistent-term", "set-option", "-g", "default-terminal", "xterm-256color" },
      calls[1]
    )
    assert.same(
      { "tmux", "-L", "persistent-term", "set-option", "-g", "terminal-features", "xterm-256color:RGB" },
      calls[2]
    )
    assert.same(
      { "tmux", "-L", "persistent-term", "set-environment", "-g", "COLORTERM", "truecolor" },
      calls[3]
    )
    -- And the 4th call is list-panes (bootstrap finished before pane discovery).
    assert.equals("list-panes", calls[4][4])

    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)
```

- [ ] **Step 3: Run tests to verify both fail**

Run: `make lua-test 2>&1 | grep -E "orchestrates|bootstrap|FAIL"`
Expected: both `orchestrates: ...` and `issues bootstrap ...` fail because no bootstrap calls are recorded yet.

- [ ] **Step 4: Implement the bootstrap in `cmd_open`**

In `lua/persistent_term/command.lua`, find `cmd_open`. The relevant region currently looks like (lines 191–202):

```lua
  local v = tmux.check_version("3.0")
  if not v.ok then
    log.error(v.reason)
    return nil, v.reason
  end
  if not install.is_installed() then
    local msg = "helper binary not installed; run :PTermInstall"
    log.error(msg)
    return nil, msg
  end

  local list = tmux.run(tmux.builders.list_panes())
```

Insert the bootstrap block between the `if not install.is_installed()` block (its closing `end`) and the `local list = …` line. After the change the region reads:

```lua
  local v = tmux.check_version("3.0")
  if not v.ok then
    log.error(v.reason)
    return nil, v.reason
  end
  if not install.is_installed() then
    local msg = "helper binary not installed; run :PTermInstall"
    log.error(msg)
    return nil, msg
  end

  tmux.run(tmux.builders.set_server_option("default-terminal", "xterm-256color"))
  tmux.run(tmux.builders.set_server_option("terminal-features", "xterm-256color:RGB"))
  tmux.run(tmux.builders.set_server_env("COLORTERM", "truecolor"))

  local list = tmux.run(tmux.builders.list_panes())
```

Note: no version gate yet, no error handling yet — both are added in Tasks 5 and 6.

- [ ] **Step 5: Run tests to verify both new assertions pass**

Run: `make lua-test 2>&1 | grep -E "orchestrates|bootstrap|FAIL|passed"`
Expected: both `orchestrates: ...` and `issues bootstrap …` pass. Total test count up by 1 from previous run.

- [ ] **Step 6: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "feat(command): bootstrap tmux server with xterm-256color and truecolor"
```

---

## Task 5: Version gate — skip `terminal-features` on tmux < 3.2

**Files:**
- Modify: `tests/spec/command_spec.lua` (add new test after the Task 4 bootstrap test)
- Modify: `lua/persistent_term/command.lua` (wrap the `terminal-features` call in a version check)

- [ ] **Step 1: Write the failing test**

In `tests/spec/command_spec.lua`, immediately after the bootstrap test from Task 4, add:

```lua
  it("skips terminal-features bootstrap on tmux < 3.2", function()
    local calls = {}
    local fake_builders = require("persistent_term.tmux").builders
    package.loaded["persistent_term.tmux"] = {
      builders = fake_builders,
      check_version = function(_) return { ok = true, version = "3.0" } end,
      version_at_least = require("persistent_term.tmux").version_at_least,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      parse_new_session_output = require("persistent_term.tmux").parse_new_session_output,
      run = function(argv)
        table.insert(calls, argv)
        local sub = argv[4]
        if sub == "list-panes" then
          return { ok = true, code = 0, stdout = "", stderr = "" }
        elseif sub == "new-session" then
          return { ok = true, code = 0, stdout = "$1\t%10\t@2\n", stderr = "" }
        end
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/persistent-term-pipe" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(_)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      resize_to = function(_, _, _) end,
      detach = function(_, _) end,
      kill = function(_) end,
    }

    command = require("persistent_term.command")
    local handle, err = command.cmd_open("dev -- bash -c hi")
    assert.is_nil(err)
    assert.is_truthy(handle)

    -- On tmux 3.0 the bootstrap is only two commands: default-terminal + COLORTERM.
    -- terminal-features must NOT appear anywhere in the call list.
    for _, argv in ipairs(calls) do
      if argv[4] == "set-option" and argv[6] == "terminal-features" then
        error("terminal-features should not be set on tmux 3.0; got argv: " .. vim.inspect(argv))
      end
    end
    assert.same(
      { "tmux", "-L", "persistent-term", "set-option", "-g", "default-terminal", "xterm-256color" },
      calls[1]
    )
    assert.same(
      { "tmux", "-L", "persistent-term", "set-environment", "-g", "COLORTERM", "truecolor" },
      calls[2]
    )
    assert.equals("list-panes", calls[3][4])

    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make lua-test 2>&1 | grep -E "skips terminal-features|FAIL"`
Expected: failure — `calls[2]` is `set-option terminal-features` (because Task 4 emits it unconditionally), not `set-environment`.

- [ ] **Step 3: Add the version gate in `cmd_open`**

In `lua/persistent_term/command.lua`, replace the three bootstrap lines from Task 4:

```lua
  tmux.run(tmux.builders.set_server_option("default-terminal", "xterm-256color"))
  tmux.run(tmux.builders.set_server_option("terminal-features", "xterm-256color:RGB"))
  tmux.run(tmux.builders.set_server_env("COLORTERM", "truecolor"))
```

with the version-gated version:

```lua
  tmux.run(tmux.builders.set_server_option("default-terminal", "xterm-256color"))
  if tmux.version_at_least(v.version, "3.2") then
    tmux.run(tmux.builders.set_server_option("terminal-features", "xterm-256color:RGB"))
  end
  tmux.run(tmux.builders.set_server_env("COLORTERM", "truecolor"))
```

`v.version` is available because the existing `tmux.check_version("3.0")` returns `{ ok = true, version = <version_string> }` on success (see `lua/persistent_term/tmux.lua:197`).

- [ ] **Step 4: Run tests to verify both pass**

Run: `make lua-test 2>&1 | grep -E "bootstrap|skips terminal|FAIL|passed"`
Expected: both the 3.2 bootstrap test (Task 4) and the new `skips terminal-features` test pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "feat(command): gate terminal-features bootstrap behind tmux >= 3.2"
```

---

## Task 6: Bootstrap failure aborts `cmd_open` with stderr-bearing error

**Files:**
- Modify: `tests/spec/command_spec.lua` (add new test after the Task 5 version-gate test)
- Modify: `lua/persistent_term/command.lua` (wrap each bootstrap call in an `if not ok` check)

- [ ] **Step 1: Write the failing test**

In `tests/spec/command_spec.lua`, immediately after the `skips terminal-features ...` test from Task 5, add:

```lua
  it("aborts cmd_open when bootstrap set-option default-terminal fails", function()
    local create_buffer_called = false
    local new_session_called = false
    local fake_builders = require("persistent_term.tmux").builders
    package.loaded["persistent_term.tmux"] = {
      builders = fake_builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      version_at_least = require("persistent_term.tmux").version_at_least,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      parse_new_session_output = require("persistent_term.tmux").parse_new_session_output,
      run = function(argv)
        local sub = argv[4]
        if sub == "set-option" and argv[6] == "default-terminal" then
          return { ok = false, code = 1, stdout = "", stderr = "server died" }
        elseif sub == "new-session" then
          new_session_called = true
          return { ok = true, code = 0, stdout = "$1\t%10\t@2\n", stderr = "" }
        end
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/persistent-term-pipe" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(_)
        create_buffer_called = true
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
    }

    command = require("persistent_term.command")
    local handle, err = command.cmd_open("dev -- bash -c hi")
    assert.is_nil(handle)
    assert.is_truthy(err)
    assert.is_truthy(err:match("set%-option default%-terminal failed"))
    assert.is_truthy(err:match("server died"))
    assert.is_false(create_buffer_called, "buffer must not be created when bootstrap fails")
    assert.is_false(new_session_called, "new-session must not be called when bootstrap fails")
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make lua-test 2>&1 | grep -E "aborts cmd_open|FAIL"`
Expected: failure — the current implementation ignores the bootstrap result, so `cmd_open` proceeds to `list-panes` / `new-session` / buffer creation.

- [ ] **Step 3: Add error handling to each bootstrap call in `cmd_open`**

In `lua/persistent_term/command.lua`, replace the three bootstrap lines from Task 5:

```lua
  tmux.run(tmux.builders.set_server_option("default-terminal", "xterm-256color"))
  if tmux.version_at_least(v.version, "3.2") then
    tmux.run(tmux.builders.set_server_option("terminal-features", "xterm-256color:RGB"))
  end
  tmux.run(tmux.builders.set_server_env("COLORTERM", "truecolor"))
```

with the error-checked version:

```lua
  local boot = tmux.run(tmux.builders.set_server_option("default-terminal", "xterm-256color"))
  if not boot.ok then
    return nil, "tmux set-option default-terminal failed: " .. boot.stderr
  end
  if tmux.version_at_least(v.version, "3.2") then
    boot = tmux.run(tmux.builders.set_server_option("terminal-features", "xterm-256color:RGB"))
    if not boot.ok then
      return nil, "tmux set-option terminal-features failed: " .. boot.stderr
    end
  end
  boot = tmux.run(tmux.builders.set_server_env("COLORTERM", "truecolor"))
  if not boot.ok then
    return nil, "tmux set-environment COLORTERM failed: " .. boot.stderr
  end
```

- [ ] **Step 4: Run tests to verify all three command_spec bootstrap tests pass**

Run: `make lua-test 2>&1 | grep -E "bootstrap|skips terminal|aborts cmd_open|FAIL|passed"`
Expected: all three new tests (Tasks 4, 5, 6) pass; the updated orchestration test (Task 4) still passes.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "feat(command): abort cmd_open with stderr when bootstrap fails"
```

---

## Task 7: Integration test — server is configured after `:PTerm`

**Files:**
- Modify: `tests/spec/integration_spec.lua` (add new test at the end of the main `describe` block, after the existing tests)

This is the only integration-level coverage for this work. It exercises the full stack (Lua → tmux subprocess → child process), verifying that the env vars reach the child and the server options are set globally.

- [ ] **Step 1: Find the right insertion point**

Open `tests/spec/integration_spec.lua`. Find the end of the main `describe("persistent-term integration", function()` block (right before its closing `end)` line — typically near the end of the file, after all existing `it(...)` tests).

- [ ] **Step 2: Add the integration test**

Insert this test inside the main `describe(...)` block, immediately before its closing `end)`:

```lua
  it("PTerm configures the server with xterm-256color and truecolor", function()
    vim.cmd([[PTerm tterm -- bash -c 'echo PTERM_TERM=$TERM; echo PTERM_COLORTERM=$COLORTERM; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()

    -- The child must see TERM=xterm-256color and COLORTERM=truecolor in its env.
    -- Two echoes so line-wrap at narrow terminal widths cannot truncate the assertion.
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("PTERM_TERM=xterm-256color", 1, true) then return true end
      end
      return false
    end, 5000), "child never reported PTERM_TERM=xterm-256color")

    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("PTERM_COLORTERM=truecolor", 1, true) then return true end
      end
      return false
    end, 5000), "child never reported PTERM_COLORTERM=truecolor")

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
```

Note: `run`, `wait_until`, and `before_each`-installed plugin runtime are already defined at the top of this file (lines 11, 41 respectively); the test reuses them.

- [ ] **Step 3: Build the Go helper (required for integration tests)**

Run: `make build`
Expected: produces `go/bin/persistent-term-pipe` (the test's `install_local_binary()` helper copies from this path).

- [ ] **Step 4: Run the full test suite to verify the new integration test passes and no regressions**

Run: `make lua-test 2>&1 | tail -30`
Expected: all tests pass, including the new integration test. Total count up by 1 over the previous run (Task 6's end count).

- [ ] **Step 5: Commit**

```bash
git add tests/spec/integration_spec.lua
git commit -m "test(integration): verify PTerm sets xterm-256color and truecolor server-wide"
```

---

## Final verification

After all tasks complete:

- [ ] **Step 1: Run the entire test suite**

Run: `make test`
Expected: Go tests pass, all Lua tests pass. Final count should be ~95 tests total (76 existing unit + 4 new unit = 80 unit; 13 existing integration + 1 new integration = 14 integration; 80 + 14 = 94, ±1).

- [ ] **Step 2: Manual smoke test (optional but recommended)**

Open Neovim, run `:PTerm dev` (default-shell form), and visually confirm:
- zsh prompt renders without blank lines between completion entries
- Tab-completion menu rows are adjacent (no blank line between rows)
- Prompt fragments do not linger after redraws
- `echo $TERM` inside the pane reports `xterm-256color`
- `echo $COLORTERM` reports `truecolor`

- [ ] **Step 3: Push when satisfied**

```bash
git push
```

---

## Self-review notes

Spec coverage check:
- §3 values → Tasks 1–3 (builders) + Task 4 (bootstrap wiring) + integration test (Task 7).
- §4 code changes → Tasks 1–6.
- §5 error handling → Task 6.
- §6 cross-platform → no code change required; relies on `xterm-256color` being in system terminfo, which the spec argues for. Integration test runs on whatever platform the dev is on; CI is Linux-only.
- §7 testing → Tasks 1–7 cover every numbered test from the spec.
- §8 migration → no code change; documented in spec.
- §9 open questions → none.

Type/name consistency:
- `set_server_option(key, value)` signature used identically in tmux_spec, command.lua bootstrap, and command_spec calls table.
- `set_server_env(key, value)` likewise.
- `tmux.version_at_least(v.version, "3.2")` — `v` is the result of `tmux.check_version("3.0")`, which returns `{ ok = true, version = <string> }` on success. Both `v.version` and `version_at_least` already exist in `lua/persistent_term/tmux.lua` (lines 166–177, 197).
- Error message strings (`"tmux set-option default-terminal failed: "`) match between Task 6's implementation and its test's regex assertion `err:match("set%-option default%-terminal failed")`.
