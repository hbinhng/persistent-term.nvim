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
