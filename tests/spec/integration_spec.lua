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

local function tmux_socket_path()
  local tmpdir = vim.env.TMUX_TMPDIR or "/tmp"
  local uid = vim.fn.system("id -u"):gsub("%s+$", "")
  return tmpdir .. "/tmux-" .. uid .. "/persistent-term"
end

local function reset_tmux_server()
  run({ "tmux", "-L", "persistent-term", "kill-server" })
  -- Do NOT remove the stale socket file: tmux -L requires the socket file to
  -- exist in order to start a new server at that path. When kill-server exits,
  -- the socket file is left behind in a stale (unconnectable) state, and the
  -- next new-session will atomically replace it with a fresh server socket.
  -- Removing the socket file here would break that restart cycle.
end

local function install_local_binary()
  local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1).source:sub(2)), ":h:h:h")
  local src = root .. "/go/bin/persistent-term-pipe"
  assert(vim.fn.filereadable(src) == 1, "build the helper first (make build)")
  local dst_dir = vim.fn.tempname()
  vim.fn.mkdir(dst_dir, "p")
  vim.env.PERSISTENT_TERM_INSTALL_DIR = dst_dir
  vim.fn.writefile(vim.fn.readfile(src, "b"), dst_dir .. "/persistent-term-pipe", "b")
  vim.fn.system({ "chmod", "0755", dst_dir .. "/persistent-term-pipe" })
end

local function wait_until(predicate, ms)
  return vim.wait(ms or 2000, predicate, 20)
end

describe("persistent-term integration", function()
  before_each(function()
    reset_tmux_server()
    install_local_binary()
    for _, mod in ipairs({
      "persistent_term", "persistent_term.command", "persistent_term.bridge",
      "persistent_term.tmux", "persistent_term.install",
    }) do
      package.loaded[mod] = nil
    end
    -- Reset the version cache so each test starts fresh.
    require("persistent_term.tmux")._reset_version_cache()
    package.loaded["persistent_term.tmux"] = nil
    -- Reset the plugin guard so runtime re-registers all commands.
    vim.g.loaded_persistent_term = nil
    vim.cmd("runtime plugin/persistent_term.lua")
  end)

  after_each(function()
    reset_tmux_server()
  end)

  it("PTerm starts a pane and pipes output into the buffer", function()
    vim.cmd([[PTerm dev -- bash -c 'sleep 1; printf hello; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("hello", 1, true) then return true end
      end
      return false
    end, 5000))
  end)

  it("PTermAttach after :bd replays scrollback", function()
    vim.cmd([[PTerm rep -- bash -c 'sleep 1; echo replay-line; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do if l:find("replay-line", 1, true) then return true end end
      return false
    end, 5000))
    vim.cmd("bdelete!")
    vim.cmd("PTermAttach rep")
    local bufnr2 = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
      for _, l in ipairs(lines) do if l:find("replay-line", 1, true) then return true end end
      return false
    end, 5000))
  end)

  it("duplicate-name :PTerm fails", function()
    vim.cmd([[PTerm dup -- bash -c 'sleep 30']])
    local result = pcall(vim.cmd, [[PTerm dup -- bash -c 'sleep 30']])
    local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
    local count = 0
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      if line == "dup" then count = count + 1 end
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
    local res = run({ "tmux", "-L", "persistent-term", "display-message", "-p", "-t",
      vim.b.persistent_term_pane_id, "#{pane_width}" })
    assert.equals("60", vim.trim(res.stdout))
  end)
end)

describe("persistent-term crash recovery", function()
  local function find_repo_root()
    local here = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1).source:sub(2)), ":h:h:h")
    return here
  end

  local function child_nvim(repo_root, lua_payload)
    -- Spawn a fully isolated child Neovim that loads this repo's plugin
    -- and runs `lua_payload`, then exits.
    local minimal_init = repo_root .. "/tests/minimal_init.lua"
    local install_dir = vim.env.PERSISTENT_TERM_INSTALL_DIR
    assert(install_dir and install_dir ~= "", "test must set PERSISTENT_TERM_INSTALL_DIR before spawning child")
    return vim.system({
      "nvim", "--headless",
      "--clean",
      "-u", minimal_init,
      "-c", "runtime plugin/persistent_term.lua",
      "-c", "lua " .. lua_payload,
    }, {
      text = true,
      timeout = 10000,
      env = {
        HOME = vim.env.HOME,
        PATH = vim.env.PATH,
        XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
        XDG_RUNTIME_DIR = vim.env.XDG_RUNTIME_DIR,
        PERSISTENT_TERM_INSTALL_DIR = install_dir,
      },
    }):wait()
  end

  local function child_nvim_background(repo_root, lua_payload)
    local minimal_init = repo_root .. "/tests/minimal_init.lua"
    local install_dir = vim.env.PERSISTENT_TERM_INSTALL_DIR
    assert(install_dir and install_dir ~= "", "test must set PERSISTENT_TERM_INSTALL_DIR before spawning child")
    return vim.system({
      "nvim", "--headless",
      "--clean",
      "-u", minimal_init,
      "-c", "runtime plugin/persistent_term.lua",
      "-c", "lua " .. lua_payload,
    }, {
      text = true,
      env = {
        HOME = vim.env.HOME,
        PATH = vim.env.PATH,
        XDG_DATA_HOME = vim.env.XDG_DATA_HOME,
        XDG_RUNTIME_DIR = vim.env.XDG_RUNTIME_DIR,
        PERSISTENT_TERM_INSTALL_DIR = install_dir,
      },
    })
  end

  local function tmux_list_panes()
    local r = vim.system({
      "tmux", "-L", "persistent-term",
      "list-panes", "-aF", "#{@pterm_name}",
    }, { text = true }):wait()
    return r.stdout or ""
  end

  before_each(function()
    -- inherit the install_local_binary + reset_tmux_server semantics from
    -- the prior describe block. Run them explicitly.
    vim.system({ "tmux", "-L", "persistent-term", "kill-server" }, { text = true }):wait()
    -- Use the same install pattern as the prior integration tests.
    local root = find_repo_root()
    local src = root .. "/go/bin/persistent-term-pipe"
    assert(vim.fn.filereadable(src) == 1, "build the helper first (make build)")
    local dst_dir = vim.fn.tempname()
    vim.fn.mkdir(dst_dir, "p")
    vim.env.PERSISTENT_TERM_INSTALL_DIR = dst_dir
    vim.fn.writefile(vim.fn.readfile(src, "b"), dst_dir .. "/persistent-term-pipe", "b")
    vim.fn.system({ "chmod", "0755", dst_dir .. "/persistent-term-pipe" })
  end)

  after_each(function()
    vim.system({ "tmux", "-L", "persistent-term", "kill-server" }, { text = true }):wait()
  end)

  it("pane survives child Neovim SIGKILL and is reattachable", function()
    local root = find_repo_root()

    -- Phase 1: spawn child A in background, have it create a long-lived
    -- pane and then sit idle (vim.wait) so we can SIGKILL it mid-life.
    local marker = "crash-survives-" .. tostring(math.random(1000000))
    local payload_a = string.format(
      [[vim.cmd("PTerm crashtest -- bash -c 'printf %s; sleep 120'") vim.wait(1500) vim.wait(30000)]],
      marker
    )
    local proc_a = child_nvim_background(root, payload_a)
    -- Wait until the pane shows up in tmux. (Polling is more robust than
    -- a fixed sleep.)
    local pane_seen = vim.wait(8000, function()
      return tmux_list_panes():find("crashtest", 1, true) ~= nil
    end, 100)
    assert.is_true(pane_seen, "pane was never created by child A")

    -- Phase 2: SIGKILL the child.
    proc_a:kill("sigkill")
    proc_a:wait()

    -- After SIGKILL, the tmux pane MUST still be alive (this is the core promise).
    local survives = vim.wait(3000, function()
      return tmux_list_panes():find("crashtest", 1, true) ~= nil
    end, 100)
    assert.is_true(survives, "pane disappeared after child A was killed")

    -- Phase 3: spawn fresh child B, run :PTermAttach crashtest, capture
    -- the buffer contents, write them to a known file, then exit.
    local capture_path = vim.fn.tempname() .. ".out"
    local payload_b = string.format(
      [[
        vim.cmd("PTermAttach crashtest")
        local bufnr = vim.api.nvim_get_current_buf()
        local ok = vim.wait(3000, function()
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          for _, l in ipairs(lines) do
            if l:find(%q, 1, true) then return true end
          end
          return false
        end, 50)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local fp = io.open(%q, "w")
        fp:write(tostring(ok) .. "\n")
        fp:write(table.concat(lines, "\n"))
        fp:close()
        vim.cmd("qall!")
      ]],
      marker,
      capture_path
    )

    local result_b = child_nvim(root, payload_b)
    assert.equals(0, result_b.code,
      "child B exited non-zero; stderr=\n" .. (result_b.stderr or ""))

    -- Phase 4: verify child B saw the marker in its scrollback.
    local out = vim.fn.readfile(capture_path)
    local saw_marker = false
    for _, line in ipairs(out) do
      if line:find(marker, 1, true) then
        saw_marker = true
        break
      end
    end
    assert.is_true(saw_marker,
      "child B did not see marker " .. marker .. " in its buffer; capture:\n" ..
      table.concat(out, "\n"))
  end)
end)
