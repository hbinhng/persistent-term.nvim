-- tests/spec/command_spec.lua
describe("persistent_term.command parse_open_args", function()
  local command

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    command = require("persistent_term.command")
  end)

  it("parses `dev -- npm run dev`", function()
    local r, err = command.parse_open_args("dev -- npm run dev")
    assert.is_nil(err)
    assert.equals("dev", r.name)
    assert.same({ "npm", "run", "dev" }, r.argv)
  end)

  it("rejects missing -- (multi-token raw)", function()
    local r, err = command.parse_open_args("dev npm run dev")
    assert.is_nil(r)
    assert.is_truthy(err:match("invalid name"))
  end)

  it("rejects empty argv after --", function()
    local r, err = command.parse_open_args("dev --")
    assert.is_nil(r)
    assert.is_truthy(err:match("empty"))
  end)

  it("rejects names with bad characters", function()
    for _, bad in ipairs({ "dev/x", "dev x", "dev'", "../foo", "" }) do
      local _, err = command.parse_open_args(bad .. " -- ls")
      assert.is_truthy(err, "expected error for name " .. bad)
    end
  end)

  it("accepts names with safe characters", function()
    for _, good in ipairs({ "dev", "DEV1", "my.app", "a_b", "a-b" }) do
      local r, err = command.parse_open_args(good .. " -- ls")
      assert.is_nil(err)
      assert.equals(good, r.name)
    end
  end)

  it("preserves multiple spaces in argv elements", function()
    local r = command.parse_open_args('dev -- sh -c "echo hi"')
    -- Double quotes are stripped; content is kept as one token.
    assert.same({ "sh", "-c", "echo hi" }, r.argv)
  end)

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
end)

describe("persistent_term.command.cmd_open", function()
  local command
  local original_tmux

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    package.loaded["persistent_term.bridge"] = nil
    original_tmux = package.loaded["persistent_term.tmux"]
  end)

  after_each(function()
    package.loaded["persistent_term.tmux"] = original_tmux
  end)

  it("orchestrates: pre-flight, dup check, new-session, options, pipe-pane", function()
    local calls = {}
    local fake_builders = require("persistent_term.tmux").builders
    package.loaded["persistent_term.tmux"] = {
      builders = fake_builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
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
      create_buffer = function(name)
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

    local subs = {}
    for _, argv in ipairs(calls) do
      table.insert(subs, argv[4])
    end
    assert.same(
      {
        "set-option", "set-option", "set-environment",
        "list-panes", "new-session", "set-option", "set-option", "pipe-pane",
      },
      subs
    )
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

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
    assert.is_true(#calls >= 4, "expected at least 4 tmux calls; got " .. #calls)
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
        set_server_option = function() return { "true" } end,
        set_server_env    = function() return { "true" } end,
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

  it("refuses when a name already exists", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_) return { ok = true, code = 0, stdout = "%99\t@9\tdev\n", stderr = "" } end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/x" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function() error("should not be called") end,
    }
    command = require("persistent_term.command")
    local handle, err = command.cmd_open("dev -- bash")
    assert.is_nil(handle)
    assert.is_truthy(err:match("already exists"))
  end)
end)

describe("persistent_term.command.cmd_attach + complete_attach", function()
  before_each(function()
    package.loaded["persistent_term.command"] = nil
    package.loaded["persistent_term.bridge"] = nil
  end)

  it("complete_attach returns names and pane_ids from list-panes", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true } end,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_)
        return { ok = true, code = 0, stdout = "%12\t@1\tdev\n%13\t@2\ttest\n%14\t@3\t\n", stderr = "" }
      end,
    }
    local cmd = require("persistent_term.command")
    local items = cmd.complete_attach("", "PTermAttach ", 12)
    table.sort(items)
    assert.same({ "%12", "%13", "%14", "dev", "test" }, items)
  end)

  it("complete_attach filters by prefix", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true } end,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_)
        return { ok = true, code = 0, stdout = "%12\t@1\tdev\n%13\t@2\tdx\n%14\t@3\tother\n", stderr = "" }
      end,
    }
    local cmd = require("persistent_term.command")
    local items = cmd.complete_attach("d", "PTermAttach d", 13)
    table.sort(items)
    assert.same({ "dev", "dx" }, items)
  end)

  it("cmd_attach by name: replay history then pipe-pane", function()
    local calls = {}
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(argv)
        table.insert(calls, argv)
        if argv[4] == "list-panes" then
          return { ok = true, stdout = "%12\t@1\tdev\n", code = 0, stderr = "" }
        elseif argv[4] == "capture-pane" then
          return { ok = true, stdout = "history line\n", code = 0, stderr = "" }
        end
        return { ok = true, stdout = "", code = 0, stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/h" end,
      is_installed = function() return true end,
    }
    local sent = {}
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(name)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      chan_send_history = function(_, data) table.insert(sent, data) end,
    }
    local cmd = require("persistent_term.command")
    local handle, err = cmd.cmd_attach("dev")
    assert.is_nil(err)
    assert.is_truthy(handle)
    assert.equals("%12", handle.pane_id)
    local capture_idx, pipe_idx
    for i, argv in ipairs(calls) do
      if argv[4] == "capture-pane" then capture_idx = i end
      if argv[4] == "pipe-pane" then pipe_idx = i end
    end
    assert.is_truthy(capture_idx and pipe_idx and capture_idx < pipe_idx)
    assert.same({ "history line\n" }, sent)
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

  it("cmd_attach by raw pane_id works without name lookup", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(argv)
        if argv[4] == "list-panes" then
          return { ok = true, stdout = "%12\t@1\t\n", code = 0, stderr = "" }
        elseif argv[4] == "capture-pane" then
          return { ok = true, stdout = "", code = 0, stderr = "" }
        end
        return { ok = true, stdout = "", code = 0, stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/h" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(name)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      chan_send_history = function(_, _) end,
    }
    local cmd = require("persistent_term.command")
    local handle, err = cmd.cmd_attach("%12")
    assert.is_nil(err)
    assert.equals("%12", handle.pane_id)
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

  it("cmd_attach refuses unknown name", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true } end,
      is_no_server = require("persistent_term.tmux").is_no_server,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_) return { ok = true, stdout = "%99\t@9\tother\n", code = 0, stderr = "" } end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/h" end,
      is_installed = function() return true end,
    }
    local cmd = require("persistent_term.command")
    local handle, err = cmd.cmd_attach("ghost")
    assert.is_nil(handle)
    assert.is_truthy(err:match("unknown"))
  end)
end)

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
    -- error(msg, 0) suppresses the file:line: prefix so callers can
    -- forward the message verbatim without string surgery.
    assert.is_nil(tostring(err):match("command%.lua:%d+:"))
    assert.is_truthy(tostring(err):match('^no usable shell: %$SHELL="/missing/shell", /bin/sh missing$'))
  end)
end)

describe("persistent_term.command.cmd_kill", function()
  before_each(function()
    package.loaded["persistent_term.command"] = nil
    package.loaded["persistent_term.bridge"] = nil
  end)

  it("refuses outside a pterm:// buffer", function()
    local cmd = require("persistent_term.command")
    local ok, err = cmd.cmd_kill(vim.api.nvim_create_buf(true, true))
    assert.is_false(ok)
    assert.is_truthy(err:match("not a persistent%-term buffer"))
  end)

  it("kills pane and wipes buffer when invoked from a pterm:// buffer", function()
    local killed_pane = nil
    package.loaded["persistent_term.bridge"] = {
      kill = function(handle)
        killed_pane = handle.pane_id
        if vim.api.nvim_buf_is_valid(handle.bufnr) then
          vim.api.nvim_buf_delete(handle.bufnr, { force = true })
        end
      end,
    }
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(bufnr, "pterm://dev")
    vim.b[bufnr].persistent_term_name = "dev"
    vim.b[bufnr].persistent_term_pane_id = "%77"

    local cmd = require("persistent_term.command")
    local ok, err = cmd.cmd_kill(bufnr)
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("%77", killed_pane)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)
end)

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
    assert.is_truthy(out:find("NAME",     1, true))
    assert.is_truthy(out:find("PANE",     1, true))
    assert.is_truthy(out:find("ATTACHED", 1, true))
    assert.is_truthy(out:find("STATUS",   1, true))
    assert.is_truthy(out:find("dev",   1, true))
    assert.is_truthy(out:find("logs",  1, true))
    assert.is_truthy(out:find("build", 1, true))
    assert.is_truthy(out:find("dead",  1, true))
    local n = 0
    for _ in out:gmatch("[^\n]+") do n = n + 1 end
    assert.equals(4, n)
  end)
end)
