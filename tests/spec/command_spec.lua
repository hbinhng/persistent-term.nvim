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

  it("rejects missing --", function()
    local r, err = command.parse_open_args("dev npm run dev")
    assert.is_nil(r)
    assert.is_truthy(err:match("%-%-"))
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
      { "list-panes", "new-session", "set-option", "set-option", "pipe-pane" },
      subs
    )
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

  it("refuses when a name already exists", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
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
