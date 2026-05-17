# `:PTermList` + default-shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `:PTermList`, expose `require("persistent_term").list()`, and let `:PTerm <name>` (no `-- cmd`) fall back to the user's default shell.

**Architecture:** All changes are additive. `is_no_server` is promoted from a file-local helper in `command.lua` to a public function on `tmux.lua` so both `command.cmd_open` and the new `command.list` can share it. `tmux list-panes` format string grows a `#{pane_dead}` field. A new `resolve_shell` helper picks `$SHELL`, falling back to `/bin/sh`. `cmd_list` formats a fixed-width table and emits it via `vim.notify`. No new modules.

**Tech Stack:** Lua (Neovim 0.10+), tmux 3.0+, plenary.nvim busted runner.

**Spec:** `docs/superpowers/specs/2026-05-17-pterm-list-and-default-shell-design.md`

---

### Task 1: Promote `is_no_server` to `tmux.lua`

**Files:**
- Modify: `lua/persistent_term/tmux.lua` (add `M.is_no_server`)
- Modify: `lua/persistent_term/command.lua` (delete the local copy, use `tmux.is_no_server`)
- Modify: `tests/spec/tmux_spec.lua` (add tests for the new public function)

No behavior change — pure refactor that opens the door for `command.list` (Task 7) to share the helper without duplicating it.

- [ ] **Step 1: Add failing tests in `tests/spec/tmux_spec.lua`**

Find the existing `describe("persistent_term.tmux executor + helpers", ...)` block (it starts around line 117) and append these `it` blocks inside it, before the `end)` that closes the describe:

```lua
  it("is_no_server detects fresh-server stderr", function()
    assert.is_true(tmux.is_no_server({ ok = false, stderr = "no server running on /tmp/x" }))
    assert.is_true(tmux.is_no_server({ ok = false, stderr = "error connecting to /tmp/x (No such file or directory)" }))
  end)

  it("is_no_server returns false for unrelated failures", function()
    assert.is_false(tmux.is_no_server({ ok = false, stderr = "tmux: invalid option" }))
    assert.is_false(tmux.is_no_server({ ok = true, stderr = "" }))
    assert.is_false(tmux.is_no_server({ ok = false, stderr = nil }))
  end)
```

- [ ] **Step 2: Run the new tests, watch them fail**

Run: `make lua-test 2>&1 | tail -30`
Expected: two new failures along the lines of `attempt to call field 'is_no_server' (a nil value)`.

- [ ] **Step 3: Add `M.is_no_server` to `lua/persistent_term/tmux.lua`**

Insert this function just after the existing `M.run` function (around line 122, after the closing `end` of `run`):

```lua
function M.is_no_server(res)
  return not res.ok
    and res.stderr
    and (res.stderr:find("No such file or directory", 1, true)
      or res.stderr:find("no server running", 1, true)) ~= nil
end
```

- [ ] **Step 4: Remove the local copy from `lua/persistent_term/command.lua`**

Delete lines 147-154 of `command.lua` (the `-- A fresh tmux server ...` comment plus the local `is_no_server` function). Then replace the three call sites — in `cmd_open` (around line 183), `cmd_attach` (around line 351), and `list_known` (around line 290) — by changing `is_no_server(...)` to `tmux.is_no_server(...)`. The variable `tmux` is already in scope in `cmd_open` and `cmd_attach`. In `list_known`, the parameter is named `tmux` so `tmux.is_no_server(res)` works there too.

After the edits, grep to confirm no stale references:

```bash
grep -n 'is_no_server' lua/persistent_term/command.lua
```

Expected: three lines, each beginning `tmux.is_no_server(`.

- [ ] **Step 5: Run full test suite, expect all green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures (the two new tests pass; the existing command tests pass because the behavior is identical).

- [ ] **Step 6: Commit**

```bash
git add lua/persistent_term/tmux.lua lua/persistent_term/command.lua tests/spec/tmux_spec.lua
git commit -m "$(cat <<'EOF'
refactor(tmux): promote is_no_server to public helper

Moves the fresh-server stderr detector from command.lua (file-local) to
tmux.lua (public) so the upcoming list() API can share it without
duplicating the pattern-match logic.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Extend `list-panes` format with `#{pane_dead}`

**Files:**
- Modify: `lua/persistent_term/tmux.lua` (`builders.list_panes`, `parse_list_panes`)
- Modify: `tests/spec/tmux_spec.lua` (existing `list_panes`/`parse_list_panes` tests + new dead-field cases)

`parse_list_panes` must default `dead = false` when the trailing field is missing, so an old cached row format does not crash the parser.

- [ ] **Step 1: Update the existing `list_panes argv` test in `tests/spec/tmux_spec.lua`**

Find the `it("list_panes builds correct argv", ...)` block (around line 29) and replace the format string in the expected argv. The whole assertion should become:

```lua
  it("list_panes builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "list-panes", "-a",
      "-F", "#{pane_id}\t#{window_id}\t#{@pterm_name}\t#{pane_dead}",
    }, tmux.builders.list_panes())
  end)
```

- [ ] **Step 2: Update the existing `parse_list_panes` test**

Find the `it("parse_list_panes splits lines into {pane_id, name}", ...)` block (around line 125) and replace it with this version. Note the input now carries the trailing `\t0` / `\t1` fields:

```lua
  it("parse_list_panes splits 4-field rows", function()
    local rows = tmux.parse_list_panes(
      "%12\t@1\tdev\t0\n%13\t@2\ttest\t1\n%14\t@3\t\t0\n"
    )
    assert.same({
      { pane_id = "%12", window_id = "@1", name = "dev",  dead = false },
      { pane_id = "%13", window_id = "@2", name = "test", dead = true },
      { pane_id = "%14", window_id = "@3", name = "",     dead = false },
    }, rows)
  end)

  it("parse_list_panes tolerates 3-field rows (back-compat)", function()
    local rows = tmux.parse_list_panes("%12\t@1\tdev\n")
    assert.same({
      { pane_id = "%12", window_id = "@1", name = "dev", dead = false },
    }, rows)
  end)
```

- [ ] **Step 3: Run tests, watch them fail**

Run: `make lua-test 2>&1 | tail -30`
Expected: failures on both updated tests because the builder format and parser don't yet include `dead`.

- [ ] **Step 4: Update the builder in `lua/persistent_term/tmux.lua`**

Change `M.builders.list_panes` (around line 38) so the `-F` value carries the extra field:

```lua
function M.builders.list_panes()
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "list-panes", "-a", "-F",
    "#{pane_id}\t#{window_id}\t#{@pterm_name}\t#{pane_dead}",
  })
  return argv
end
```

- [ ] **Step 5: Update `M.parse_list_panes`**

Replace the existing function (around line 124) with:

```lua
function M.parse_list_panes(stdout)
  local rows = {}
  for line in stdout:gmatch("[^\n]+") do
    local pane_id, window_id, name, dead = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t?(.*)$")
    if pane_id then
      table.insert(rows, {
        pane_id   = pane_id,
        window_id = window_id,
        name      = name or "",
        dead      = dead == "1",
      })
    end
  end
  return rows
end
```

The trailing `\t?(.*)$` makes the dead field optional so a row without it (the 3-field back-compat case) parses cleanly and `dead` becomes `false`.

- [ ] **Step 6: Run tests, expect all green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add lua/persistent_term/tmux.lua tests/spec/tmux_spec.lua
git commit -m "$(cat <<'EOF'
feat(tmux): surface pane_dead in list_panes rows

Extends the list-panes format string with #{pane_dead} and parses it
into a boolean `dead` field on each row. Existing 3-field input is still
accepted (defaults to dead=false) so a stale cached row layout cannot
crash the parser.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `resolve_shell` helper

**Files:**
- Modify: `lua/persistent_term/command.lua` (add `M.resolve_shell`)
- Modify: `tests/spec/command_spec.lua` (add `describe("resolve_shell")` block)

Pure unit-test-only step — `cmd_open` is rewired in Task 5.

- [ ] **Step 1: Add a failing test block at the end of `tests/spec/command_spec.lua`**

Append this whole `describe` block after the existing `describe("persistent_term.command parse_open_args", ...)` block:

```lua
describe("persistent_term.command.resolve_shell", function()
  local command
  local orig_env_shell, orig_executable

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    command = require("persistent_term.command")
    orig_env_shell = vim.env.SHELL
    orig_executable = vim.fn.executable
  end)

  after_each(function()
    vim.env.SHELL = orig_env_shell
    vim.fn.executable = orig_executable
  end)

  it("returns $SHELL when set and executable", function()
    vim.env.SHELL = "/usr/bin/fish"
    vim.fn.executable = function(p)
      if p == "/usr/bin/fish" then return 1 end
      return 0
    end
    assert.equals("/usr/bin/fish", command.resolve_shell())
  end)

  it("falls back to /bin/sh when $SHELL is not executable", function()
    vim.env.SHELL = "/nonexistent/zsh"
    vim.fn.executable = function(p)
      if p == "/bin/sh" then return 1 end
      return 0
    end
    assert.equals("/bin/sh", command.resolve_shell())
  end)

  it("falls back to /bin/sh when $SHELL is unset", function()
    vim.env.SHELL = nil
    vim.fn.executable = function(p)
      if p == "/bin/sh" then return 1 end
      return 0
    end
    assert.equals("/bin/sh", command.resolve_shell())
  end)

  it("errors when neither $SHELL nor /bin/sh is usable", function()
    vim.env.SHELL = "/missing/shell"
    vim.fn.executable = function(_) return 0 end
    local ok, err = pcall(command.resolve_shell)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match("no usable shell"))
  end)
end)
```

- [ ] **Step 2: Run, watch the new tests fail**

Run: `make lua-test 2>&1 | tail -20`
Expected: `attempt to call field 'resolve_shell' (a nil value)`.

- [ ] **Step 3: Implement `M.resolve_shell` in `lua/persistent_term/command.lua`**

Add this function just before the existing `function M.cmd_open(raw)` (around line 156):

```lua
function M.resolve_shell()
  local shell = vim.env.SHELL
  if shell and shell ~= "" and vim.fn.executable(shell) == 1 then
    return shell
  end
  if vim.fn.executable("/bin/sh") == 1 then
    return "/bin/sh"
  end
  error(string.format(
    "no usable shell: $SHELL=%q, /bin/sh missing",
    shell or ""
  ))
end
```

- [ ] **Step 4: Run, expect green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "$(cat <<'EOF'
feat(command): add resolve_shell helper

Returns $SHELL if set and executable, else /bin/sh, else raises. This
will back the upcoming :PTerm <name> shell-default form.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Extend `parse_open_args` to accept name-only form

**Files:**
- Modify: `lua/persistent_term/command.lua` (`parse_open_args`)
- Modify: `tests/spec/command_spec.lua` (add 2 new `it` blocks)

The parser returns `argv = nil` for the new shell-default form. `cmd_open` (Task 5) will treat `nil` as the signal to substitute the resolved shell.

- [ ] **Step 1: Add failing tests in the existing `describe("persistent_term.command parse_open_args", ...)` block**

Append these inside the existing describe, before its closing `end)`:

```lua
  it("parses name-only `dev` as shell-default form (argv = nil)", function()
    local r, err = command.parse_open_args("dev")
    assert.is_nil(err)
    assert.equals("dev", r.name)
    assert.is_nil(r.argv)
  end)

  it("name-only form still validates the name pattern", function()
    local _, err = command.parse_open_args("dev/x")
    assert.is_truthy(err)
    local _, err2 = command.parse_open_args("dev'")
    assert.is_truthy(err2)
  end)

  it("name-only form rejects multi-token raw (missing --)", function()
    local _, err = command.parse_open_args("dev npm run")
    assert.is_truthy(err)
  end)
```

- [ ] **Step 2: Run, watch them fail**

Run: `make lua-test 2>&1 | tail -20`
Expected: the first test fails because `parse_open_args("dev")` currently returns `nil, "missing -- separator before command"`.

- [ ] **Step 3: Add the new branch to `M.parse_open_args` in `lua/persistent_term/command.lua`**

Locate the existing logic that detects the `--` separator (around line 55). After the existing block that handles "ends with ` --`" (the `if trail` branch that returns `nil, "empty command after --"`), and after the `return nil, "missing -- separator before command"` line, you'll find the function ends. Replace that final `return nil, "missing -- separator before command"` line with the new shell-default branch:

The current code at that spot looks like:

```lua
  local sep_pos = raw:find("%s%-%-%s")
  if not sep_pos then
    -- also check if raw ends with " --" (empty cmd)
    local trail = raw:find("%s%-%-$")
    if trail then
      ... existing empty-after-dashdash block ...
      return nil, "empty command after --"
    end
    return nil, "missing -- separator before command"
  end
```

Change the final `return nil, "missing -- separator before command"` (and only that line) to the following block:

```lua
    -- No "--" separator anywhere: treat raw as a name-only invocation
    -- and let cmd_open substitute the resolved shell as argv.
    local raw_trim = vim.trim(raw)
    local tokens = split_tokens(raw_trim)
    if #tokens ~= 1 then
      return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. raw_trim
    end
    local n = tokens[1]
    if raw_trim ~= n or #n > 64 or not n:match(NAME_PATTERN) then
      return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. raw_trim
    end
    return { name = n, argv = nil }
```

The validation mirrors the existing name-half validation exactly (split_tokens, single token, trimmed raw equals the token, length cap, pattern match) so names containing quote characters or shell metacharacters are still rejected.

- [ ] **Step 4: Run, expect green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures. All four new tests pass; the existing `rejects missing --` test now needs review:

The pre-existing test `it("rejects missing --", function() local r, err = command.parse_open_args("dev npm run dev") ...` still passes because `"dev npm run dev"` has multiple tokens, which the new branch rejects with "invalid name". The error message changed from "missing -- separator" to "invalid name", but the test only asserts `err:match("%-%-")` (looks for `--` in the error), which is no longer satisfied. Update that test:

```lua
  it("rejects missing -- (multi-token raw)", function()
    local r, err = command.parse_open_args("dev npm run dev")
    assert.is_nil(r)
    assert.is_truthy(err:match("invalid name"))
  end)
```

Re-run `make lua-test 2>&1 | tail -10` and confirm 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "$(cat <<'EOF'
feat(command): accept :PTerm <name> with no -- as shell-default form

parse_open_args now returns { name, argv = nil } when the raw input is a
single valid name token with no -- separator. cmd_open will substitute
the resolved shell argv in a follow-up commit. The existing
"missing --" error path becomes "invalid name" for multi-token raw,
which is a clearer diagnostic for what users actually mistyped.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire `resolve_shell` into `cmd_open`

**Files:**
- Modify: `lua/persistent_term/command.lua` (`cmd_open`)
- Modify: `tests/spec/command_spec.lua` (add a `cmd_open` unit test with mocked tmux)

This is where `argv = nil` from the parser is replaced by the resolved-shell argv.

- [ ] **Step 1: Add a failing unit test in `tests/spec/command_spec.lua`**

Find the existing `describe("persistent_term.command.cmd_open", ...)` block (starts at line 51). Inside it (before its closing `end)`), append:

```lua
  it("substitutes resolved shell argv when parse returns nil argv", function()
    local recorded_argv
    package.loaded["persistent_term.tmux"] = {
      builders = {
        new_session = function(opts) recorded_argv = opts.argv; return { "true" } end,
        list_panes  = function() return { "true" } end,
        kill_pane   = function() return { "true" } end,
        pipe_pane   = function() return { "true" } end,
        set_window_option = function() return { "true" } end,
        set_pane_option   = function() return { "true" } end,
      },
      run = function(_) return { ok = true, code = 0, stdout = "", stderr = "" } end,
      parse_list_panes = function(_) return {} end,
      parse_new_session_output = function(_)
        return { session_id = "$1", pane_id = "%1", window_id = "@1" }
      end,
      check_version = function(_) return { ok = true } end,
      is_no_server = function(_) return false end,
    }
    package.loaded["persistent_term.install"] = {
      is_installed = function() return true end,
      binary_path  = function() return "/tmp/persistent-term-pipe" end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(_)
        local bufnr = vim.api.nvim_create_buf(false, true)
        return { bufnr = bufnr, chan = 1, _on_input_holder = {} }
      end,
      start_server  = function(_) return { close = function() end } end,
      attach        = function() end,
      install_buffer_hook = function() end,
    }
    package.loaded["persistent_term.command"] = nil
    local cmd = require("persistent_term.command")

    -- Force a known shell so the assertion is deterministic.
    local orig_env, orig_exec = vim.env.SHELL, vim.fn.executable
    vim.env.SHELL = "/bin/dash"
    vim.fn.executable = function(p) return p == "/bin/dash" and 1 or 0 end

    local handle, err = cmd.cmd_open("noargv")
    assert.is_nil(err)
    assert.is_truthy(handle)
    assert.same({ "/bin/dash" }, recorded_argv)

    vim.env.SHELL = orig_env
    vim.fn.executable = orig_exec
  end)
```

- [ ] **Step 2: Run, watch it fail**

Run: `make lua-test 2>&1 | tail -20`
Expected: `cmd_open` reaches `new_session` with `parsed.argv == nil` (or errors before that), so either the assertion fails or the call crashes.

- [ ] **Step 3: Modify `cmd_open` to substitute the shell argv**

In `lua/persistent_term/command.lua`, find `function M.cmd_open(raw)` (around line 156). Right after the `parse_open_args` call and its error return — the lines:

```lua
function M.cmd_open(raw)
  local parsed, perr = M.parse_open_args(raw)
  if not parsed then
    return nil, perr
  end
```

Insert this block immediately after the `end` of the `if not parsed` check (before the existing `local tmux = require(...)` line):

```lua
  if parsed.argv == nil then
    local ok, shell = pcall(M.resolve_shell)
    if not ok then
      return nil, tostring(shell):gsub("^.-:%s*", "")
    end
    parsed.argv = { shell }
  end
```

The `gsub` strips the `path/to/file:line:` prefix Lua adds to `error()` messages so the user-facing string is just `no usable shell: $SHELL=...`.

- [ ] **Step 4: Run, expect green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "$(cat <<'EOF'
feat(command): substitute resolved shell when cmd_open argv is nil

When parse_open_args signals the shell-default form by returning
argv=nil, cmd_open now calls resolve_shell and uses its result as a
single-element argv. A resolve failure surfaces as a clean error
string back to the user before any tmux call is made.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Implement `command.list` (Lua API)

**Files:**
- Modify: `lua/persistent_term/command.lua` (add `M.list`)
- Modify: `tests/spec/command_spec.lua` (new `describe("list")` block)

Pure data-shaping function with one tmux call. Uses `tmux.is_no_server` (added in Task 1) for fresh-server graceful handling.

- [ ] **Step 1: Add failing tests at the end of `tests/spec/command_spec.lua`**

Append:

```lua
describe("persistent_term.command.list", function()
  local command
  local orig_list_bufs, orig_buf_get_name

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    orig_list_bufs    = vim.api.nvim_list_bufs
    orig_buf_get_name = vim.api.nvim_buf_get_name
  end)

  after_each(function()
    vim.api.nvim_list_bufs    = orig_list_bufs
    vim.api.nvim_buf_get_name = orig_buf_get_name
  end)

  local function set_tmux(rows)
    package.loaded["persistent_term.tmux"] = {
      builders = { list_panes = function() return { "true" } end },
      run = function(_) return { ok = true, code = 0, stdout = "", stderr = "" } end,
      parse_list_panes = function(_) return rows end,
      is_no_server = function(_) return false end,
    }
  end

  local function set_bufs(names)
    vim.api.nvim_list_bufs    = function() local out = {}; for i = 1, #names do out[i] = i end; return out end
    vim.api.nvim_buf_get_name = function(i) return names[i] end
  end

  it("returns rows with attached + status mapped", function()
    set_tmux({
      { pane_id = "%12", window_id = "@1", name = "dev",   dead = false },
      { pane_id = "%13", window_id = "@2", name = "logs",  dead = false },
      { pane_id = "%14", window_id = "@3", name = "build", dead = true },
    })
    set_bufs({ "pterm://dev" })
    command = require("persistent_term.command")
    assert.same({
      { name = "dev",   pane_id = "%12", window_id = "@1", attached = true,  status = "live" },
      { name = "logs",  pane_id = "%13", window_id = "@2", attached = false, status = "live" },
      { name = "build", pane_id = "%14", window_id = "@3", attached = false, status = "dead" },
    }, command.list())
  end)

  it("returns empty list on fresh tmux server", function()
    package.loaded["persistent_term.tmux"] = {
      builders = { list_panes = function() return { "true" } end },
      run = function(_) return { ok = false, code = 1, stdout = "", stderr = "no server running" } end,
      parse_list_panes = function(_) return {} end,
      is_no_server = function(r) return r.stderr == "no server running" end,
    }
    set_bufs({})
    command = require("persistent_term.command")
    assert.same({}, command.list())
  end)

  it("skips rows with empty name", function()
    set_tmux({
      { pane_id = "%12", window_id = "@1", name = "dev", dead = false },
      { pane_id = "%99", window_id = "@9", name = "",    dead = false },
    })
    set_bufs({})
    command = require("persistent_term.command")
    local rows = command.list()
    assert.equals(1, #rows)
    assert.equals("dev", rows[1].name)
  end)

  it("detached buffer is not counted as attached", function()
    set_tmux({ { pane_id = "%12", window_id = "@1", name = "dev", dead = false } })
    set_bufs({ "pterm://dev [detached]" })
    command = require("persistent_term.command")
    assert.is_false(command.list()[1].attached)
  end)
end)
```

- [ ] **Step 2: Run, watch them fail**

Run: `make lua-test 2>&1 | tail -20`
Expected: `attempt to call field 'list' (a nil value)`.

- [ ] **Step 3: Implement `M.list` in `lua/persistent_term/command.lua`**

Add this near the bottom of the file, just before the `return M` line:

```lua
function M.list()
  local tmux = require("persistent_term.tmux")
  local res = tmux.run(tmux.builders.list_panes())
  if tmux.is_no_server(res) then
    return {}
  end
  if not res.ok then
    require("persistent_term.log").warn("tmux list-panes failed: " .. (res.stderr or ""))
    return {}
  end
  local rows = tmux.parse_list_panes(res.stdout)

  -- Build a quick lookup of attached pterm:// buffers in THIS nvim.
  local attached = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local bname = vim.api.nvim_buf_get_name(bufnr)
    local match = bname:match("^pterm://([^%s]+)$")
    if match then attached[match] = true end
  end

  local out = {}
  for _, row in ipairs(rows) do
    if row.name and row.name ~= "" then
      table.insert(out, {
        name      = row.name,
        pane_id   = row.pane_id,
        window_id = row.window_id,
        attached  = attached[row.name] == true,
        status    = row.dead and "dead" or "live",
      })
    end
  end
  return out
end
```

The regex `^pterm://([^%s]+)$` matches only the live form (no whitespace after the name), so the renamed `pterm://dev [detached]` form (which contains a space) does not match — exactly what the spec specifies.

- [ ] **Step 4: Run, expect green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "$(cat <<'EOF'
feat(command): add list() Lua API

Returns one row per pterm pane on the tmux server:
{ name, pane_id, window_id, attached, status }. attached is true when
this nvim has a live pterm://<name> buffer (detached buffers are
renamed and excluded). Empty pane list on a fresh tmux server.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Implement `command.cmd_list` (formatted output)

**Files:**
- Modify: `lua/persistent_term/command.lua` (add `M.cmd_list`)
- Modify: `tests/spec/command_spec.lua` (new `describe("cmd_list")` block)

Captures `vim.notify` to assert formatting. No `:PTermList` user command yet — that's Task 8.

- [ ] **Step 1: Add failing tests at the end of `tests/spec/command_spec.lua`**

Append:

```lua
describe("persistent_term.command.cmd_list", function()
  local command
  local orig_notify, captured

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    captured = {}
    orig_notify = vim.notify
    vim.notify = function(msg, _level) table.insert(captured, msg) end
  end)

  after_each(function()
    vim.notify = orig_notify
  end)

  it("prints 'no persistent terminals' for empty list", function()
    package.loaded["persistent_term.command"] = nil
    command = require("persistent_term.command")
    command.list = function() return {} end
    command.cmd_list()
    assert.equals(1, #captured)
    assert.equals("no persistent terminals", captured[1])
  end)

  it("formats rows as a padded table with header", function()
    command = require("persistent_term.command")
    command.list = function()
      return {
        { name = "dev",   pane_id = "%12", attached = true,  status = "live" },
        { name = "logs",  pane_id = "%18", attached = false, status = "live" },
        { name = "build", pane_id = "%22", attached = false, status = "dead" },
      }
    end
    command.cmd_list()
    assert.equals(1, #captured)
    local out = captured[1]
    -- Header present
    assert.is_truthy(out:find("NAME",     1, true))
    assert.is_truthy(out:find("PANE",     1, true))
    assert.is_truthy(out:find("ATTACHED", 1, true))
    assert.is_truthy(out:find("STATUS",   1, true))
    -- Rows present
    assert.is_truthy(out:find("dev",   1, true))
    assert.is_truthy(out:find("logs",  1, true))
    assert.is_truthy(out:find("build", 1, true))
    assert.is_truthy(out:find("dead",  1, true))
    -- Exactly 4 lines (header + 3 rows)
    local n = 0
    for _ in out:gmatch("[^\n]+") do n = n + 1 end
    assert.equals(4, n)
  end)
end)
```

- [ ] **Step 2: Run, watch them fail**

Run: `make lua-test 2>&1 | tail -20`
Expected: `attempt to call field 'cmd_list' (a nil value)`.

- [ ] **Step 3: Implement `M.cmd_list` in `lua/persistent_term/command.lua`**

Add just before `return M`:

```lua
function M.cmd_list()
  local rows = M.list()
  if #rows == 0 then
    vim.notify("no persistent terminals", vim.log.levels.INFO)
    return
  end
  local headers = { "NAME", "PANE", "ATTACHED", "STATUS" }
  local data = {}
  for _, r in ipairs(rows) do
    table.insert(data, {
      r.name,
      r.pane_id,
      r.attached and "yes" or "no",
      r.status,
    })
  end
  local widths = { #headers[1], #headers[2], #headers[3], #headers[4] }
  for _, d in ipairs(data) do
    for i = 1, 4 do
      if #d[i] > widths[i] then widths[i] = #d[i] end
    end
  end
  local function fmt_row(cells)
    local parts = {}
    for i = 1, 4 do
      parts[i] = cells[i] .. string.rep(" ", widths[i] - #cells[i])
    end
    return table.concat(parts, "  ")
  end
  local lines = { fmt_row(headers) }
  for _, d in ipairs(data) do table.insert(lines, fmt_row(d)) end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end
```

- [ ] **Step 4: Run, expect green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "$(cat <<'EOF'
feat(command): add cmd_list (formatted :PTermList output)

Builds a fixed-width table from list() with a header row and emits it
as a single vim.notify INFO message so notification UIs render it as
one block. Empty list prints 'no persistent terminals'.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Expose façades + register `:PTermList`

**Files:**
- Modify: `lua/persistent_term/init.lua` (add `M.list` and `M.cmd_list`)
- Modify: `plugin/persistent_term.lua` (register `:PTermList`, update `:PTerm` desc)

Pure wiring — no new tests needed; integration tests in Task 10 cover the user-facing command.

- [ ] **Step 1: Add the façade functions to `lua/persistent_term/init.lua`**

After the existing `function M.complete_attach(...) ... end` and before `return M`, insert:

```lua
function M.list()
  return require("persistent_term.command").list()
end

function M.cmd_list()
  require("persistent_term.command").cmd_list()
end
```

- [ ] **Step 2: Register the user command in `plugin/persistent_term.lua`**

After the existing `:PTermInstall` registration (around line 35), append:

```lua
vim.api.nvim_create_user_command("PTermList", function(_)
  require("persistent_term").cmd_list()
end, {
  desc = "List persistent-term panes on the tmux server",
})
```

Also update the `:PTerm` command's `desc` (the existing block at line 13) so its help text reflects the new shell-default form:

```lua
vim.api.nvim_create_user_command("PTerm", lazy("open"), {
  nargs = "+",
  desc = "Open a persistent terminal: :PTerm {name} [-- {cmd...}] (no -- runs $SHELL)",
})
```

- [ ] **Step 3: Smoke-check the registration**

Run:

```bash
nvim --headless -u NONE \
  --cmd "set rtp+=$(pwd)" \
  --cmd "runtime plugin/persistent_term.lua" \
  -c 'lua print(vim.fn.exists(":PTermList"))' \
  -c 'quit'
```

Expected output: `2` (the value vim returns for an existing user command).

- [ ] **Step 4: Run the full lua test suite, expect all green**

Run: `make lua-test 2>&1 | tail -10`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/init.lua plugin/persistent_term.lua
git commit -m "$(cat <<'EOF'
feat(plugin): register :PTermList and expose list() / cmd_list façades

:PTermList prints the formatted table from cmd_list. The public Lua
API require('persistent_term').list() is documented for users wiring
their own picker (telescope/fzf-lua/snacks). :PTerm desc updated to
mention the new shell-default form.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Integration test — `:PTerm <name>` runs the resolved shell

**Files:**
- Modify: `tests/spec/integration_spec.lua` (add one `it` block)

Uses a tempfile shell script set as `$SHELL` so the assertion is fully deterministic and does not depend on whatever shell the CI image happens to ship.

- [ ] **Step 1: Add the test inside the existing `describe("persistent-term integration", ...)` block in `tests/spec/integration_spec.lua`**

Find the existing `it("PTerm starts a pane and pipes output into the buffer", ...)` block (around line 67). Below it (still inside the same describe), insert this new test:

```lua
  it("PTerm <name> with no -- runs $SHELL", function()
    -- Write a fake shell that emits a sentinel and then sleeps. Setting it
    -- as $SHELL pins that the shell-default path actually exec'd this script.
    local fake = vim.fn.tempname() .. "-fake-shell.sh"
    vim.fn.writefile({
      "#!/bin/sh",
      "echo PTERM-SHELL-READY-$$",
      "sleep 30",
    }, fake)
    vim.fn.system({ "chmod", "0755", fake })

    local orig_shell = vim.env.SHELL
    vim.env.SHELL = fake

    vim.cmd("PTerm shdef")
    local bufnr = vim.api.nvim_get_current_buf()
    local ok = wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("PTERM-SHELL-READY-", 1, true) then return true end
      end
      return false
    end, 5000)

    vim.env.SHELL = orig_shell
    assert.is_truthy(ok, "expected fake $SHELL to be exec'd and produce sentinel")
  end)
```

- [ ] **Step 2: Run the integration test, expect green**

Run: `make test 2>&1 | tail -30` (or `make lua-test`, whichever runs the integration suite — both work).
Expected: the new test passes alongside the existing 8.

- [ ] **Step 3: Commit**

```bash
git add tests/spec/integration_spec.lua
git commit -m "$(cat <<'EOF'
test(integration): verify :PTerm <name> with no -- runs $SHELL

Sets $SHELL to a tempfile script that emits a sentinel and asserts the
sentinel reaches the buffer. Pins both that resolve_shell read $SHELL
and that the substituted argv is what tmux exec'd.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Integration tests — `:PTermList` lifecycle

**Files:**
- Modify: `tests/spec/integration_spec.lua` (add 4 `it` blocks)

- [ ] **Step 1: Add the tests inside the existing `describe("persistent-term integration", ...)` block**

Append (still inside the describe, before its closing `end)`):

```lua
  local function capture_notify(thunk)
    local out = {}
    local orig = vim.notify
    vim.notify = function(msg, _l) table.insert(out, msg) end
    thunk()
    vim.wait(100, function() return #out > 0 end)
    vim.notify = orig
    return table.concat(out, "\n")
  end

  it("PTermList on a fresh server prints 'no persistent terminals'", function()
    -- before_each already killed the server.
    local out = capture_notify(function() vim.cmd("PTermList") end)
    assert.is_truthy(out:find("no persistent terminals", 1, true), "got: " .. out)
  end)

  it("PTermList lists 2 panes with attached=yes", function()
    vim.cmd([[PTerm l1 -- bash -c 'sleep 1; printf one;   sleep 30']])
    vim.cmd([[PTerm l2 -- bash -c 'sleep 1; printf two;   sleep 30']])
    -- Give tmux a moment to register both.
    wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
      local seen_l1, seen_l2
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        if line == "l1" then seen_l1 = true end
        if line == "l2" then seen_l2 = true end
      end
      return seen_l1 and seen_l2
    end, 3000)

    local out = capture_notify(function() vim.cmd("PTermList") end)
    -- Header + 2 rows = 3 lines.
    local n = 0
    for _ in out:gmatch("[^\n]+") do n = n + 1 end
    assert.equals(3, n, "expected 3 lines (header + 2), got:\n" .. out)
    assert.is_truthy(out:find("l1", 1, true))
    assert.is_truthy(out:find("l2", 1, true))
    -- Both should be ATTACHED=yes (this nvim has the buffers).
    local yes_count = 0
    for _ in out:gmatch("yes") do yes_count = yes_count + 1 end
    assert.equals(2, yes_count, "expected 2 'yes', got:\n" .. out)
  end)

  it("PTermList drops the killed pane", function()
    vim.cmd([[PTerm k1 -- bash -c 'sleep 1; printf one; sleep 30']])
    vim.cmd([[PTerm k2 -- bash -c 'sleep 1; printf two; sleep 30']])
    wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
      return (res.stdout or ""):find("k1") and (res.stdout or ""):find("k2")
    end, 3000)
    -- Focus the k1 buffer so :PTermKill targets it.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b) == "pterm://k1" then
        vim.api.nvim_set_current_buf(b)
        break
      end
    end
    vim.cmd("PTermKill")
    wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
      return not (res.stdout or ""):find("k1", 1, true)
    end, 3000)
    local out = capture_notify(function() vim.cmd("PTermList") end)
    assert.is_nil(out:find("k1", 1, true), "k1 should be gone, got:\n" .. out)
    assert.is_truthy(out:find("k2", 1, true), "k2 should remain, got:\n" .. out)
  end)

  it("PTermList marks a dead pane as STATUS=dead", function()
    -- Run a command that exits quickly. remain-on-exit on keeps the pane alive.
    vim.cmd([[PTerm dx -- bash -c 'sleep 1; exit 0']])
    -- Wait for the pane to register dead.
    assert.is_truthy(wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF",
        "#{@pterm_name}\t#{pane_dead}" })
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local n, d = line:match("^(.-)\t(.)$")
        if n == "dx" and d == "1" then return true end
      end
      return false
    end, 5000))
    local out = capture_notify(function() vim.cmd("PTermList") end)
    -- Find the dx row and confirm dead is on the same line.
    local dx_line
    for line in out:gmatch("[^\n]+") do
      if line:find("dx", 1, true) then dx_line = line; break end
    end
    assert.is_truthy(dx_line, "no dx row in:\n" .. out)
    assert.is_truthy(dx_line:find("dead", 1, true), "dx row missing 'dead': " .. dx_line)
  end)
```

- [ ] **Step 2: Run, expect green**

Run: `make test 2>&1 | tail -30`
Expected: all integration tests pass, including the 4 new ones.

- [ ] **Step 3: Commit**

```bash
git add tests/spec/integration_spec.lua
git commit -m "$(cat <<'EOF'
test(integration): cover :PTermList empty/multi/killed/dead cases

Four cases: fresh server prints the empty message; two open panes list
with attached=yes; :PTermKill removes the row; a pane whose process
exits is shown with STATUS=dead (relies on remain-on-exit on).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: README — Use updates + Recipes section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the `## Use` section**

Find the `## Use` block (around line 27). Replace the code fence block plus the bullet list under it with:

```markdown
## Use

```vim
:PTerm dev -- npm run dev          " create a pane and open a buffer attached to it
:PTerm dev                         " same, but run $SHELL (falls back to /bin/sh)
:PTermAttach dev                   " reopen a buffer for an existing pane (after restart, etc.)
:PTermAttach %12                   " same, but by raw tmux pane id
:PTermList                         " print every pterm pane on the tmux server
:PTermKill                         " kill the current buffer's pane
```

- `:bd` (or `BufWipeout`) detaches the bridge but keeps the pane running. Reattach with `:PTermAttach`.
- `:PTermKill` is the only command that destroys the pane.
- Tab-completion on `:PTermAttach` lists every known name and raw pane id.
- `:PTermList` columns: `NAME PANE ATTACHED STATUS`. `ATTACHED=yes` means this Neovim instance has a live buffer for the pane; `STATUS=dead` means the pane's process exited but tmux preserved the pane (`remain-on-exit on`).
```

- [ ] **Step 2: Add a new `## Recipes` section between `## How it works` and `## Diagnostics`**

Insert this whole section before the `## Diagnostics` heading (currently around line 48):

````markdown
## Recipes

### Telescope picker

`require("persistent_term").list()` returns a table of pane rows. Wire it into your fuzzy finder of choice instead of bundling a picker into the plugin:

```lua
vim.keymap.set("n", "<leader>tp", function()
  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "persistent-term",
    finder = finders.new_table {
      results = require("persistent_term").list(),
      entry_maker = function(row)
        return {
          value   = row.pane_id,
          display = string.format("%-12s  %s  %s",
                      row.name, row.status,
                      row.attached and "[attached]" or ""),
          ordinal = row.name,
        }
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, map)
      actions.select_default:replace(function(bufnr)
        actions.close(bufnr)
        local entry = action_state.get_selected_entry()
        vim.cmd("PTermAttach " .. entry.value)
      end)
      return true
    end,
  }):find()
end, { desc = "Pick a persistent-term pane" })
```
````

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document :PTermList and shell-default :PTerm form

Updates the Use section with examples for the new shell-default form
and :PTermList. Adds a Recipes section with a telescope picker that
consumes require('persistent_term').list() — kept in docs rather than
shipped as a built-in command so the plugin stays dependency-free.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

**Spec coverage:**
- §3 argv grammar — Task 4 (parser), Task 5 (cmd_open substitution).
- §3.2 shell resolution — Task 3.
- §4 list-panes format extension + back-compat — Task 2.
- §5 `list()` API — Task 6.
- §6 `:PTermList` command — Task 7 (impl), Task 8 (registration).
- §7 README recipes — Task 11.
- §8 `is_no_server` relocation — Task 1.
- §10.1 unit tests — Tasks 2, 3, 4, 6, 7.
- §10.2 integration tests — Tasks 9, 10.

All spec sections have a task.

**Placeholder scan:** no TBDs, no "implement later", no "similar to Task N", all code blocks complete.

**Type consistency:** `M.list` returns `{ name, pane_id, window_id, attached, status }` rows in both Task 6 (definition) and Tasks 7, 10, 11 (consumers). `M.cmd_list` is the only entry point name used in both `init.lua` and `plugin/persistent_term.lua`. `M.resolve_shell` raises via `error()`; `cmd_open` wraps the call in `pcall` and strips the Lua prefix — consistent across Tasks 3 and 5.

Plan ready.
