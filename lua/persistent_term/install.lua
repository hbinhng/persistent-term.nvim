-- lua/persistent_term/install.lua
local M = {}

local PINNED_VERSION = "v0.1.0"
local REPO = "hbinhng/persistent-term.nvim"

local function detect_os()
  local sys = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
  local lower = sys.sysname:lower()
  if lower:match("linux") then return "linux" end
  if lower:match("darwin") then return "darwin" end
  error("unsupported OS: " .. sys.sysname)
end

local function detect_arch()
  local sys = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
  local m = sys.machine
  if m == "x86_64" or m == "amd64" then return "amd64" end
  if m == "aarch64" or m == "arm64" then return "arm64" end
  error("unsupported arch: " .. m)
end

local function install_dir()
  if vim.env.PERSISTENT_TERM_INSTALL_DIR and vim.env.PERSISTENT_TERM_INSTALL_DIR ~= "" then
    return vim.env.PERSISTENT_TERM_INSTALL_DIR
  end
  local dir = vim.fn.stdpath("data") .. "/persistent-term/bin"
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.binary_path()
  return install_dir() .. "/persistent-term-pipe"
end

function M.is_installed()
  local path = M.binary_path()
  if vim.fn.filereadable(path) ~= 1 then return false end
  if vim.fn.executable(path) ~= 1 then return false end
  return true
end

function M.verify_sha256(path, expected_hex)
  if vim.fn.filereadable(path) ~= 1 then return false end
  -- vim.fn.sha256() cannot handle binary data containing null bytes (treats it
  -- as a Vim blob and errors). Use the system sha256sum / openssl instead so
  -- that the hash is byte-exact and matches what release .sha256 files contain.
  local hash
  if vim.fn.executable("sha256sum") == 1 then
    local out = vim.fn.system({ "sha256sum", path })
    hash = out:match("^(%x+)")
  elseif vim.fn.executable("openssl") == 1 then
    local out = vim.fn.system({ "openssl", "dgst", "-sha256", path })
    hash = out:match("= (%x+)%s*$")
  end
  if not hash then return false end
  return hash:lower() == expected_hex:lower()
end

local function asset_name()
  return string.format("persistent-term-pipe-%s-%s", detect_os(), detect_arch())
end

local function release_url(suffix)
  return string.format(
    "https://github.com/%s/releases/download/%s/%s%s",
    REPO, PINNED_VERSION, asset_name(), suffix or ""
  )
end

function M.install_from_local(src_path, expected_sha256)
  if not M.verify_sha256(src_path, expected_sha256) then
    return false, "sha256 mismatch for " .. src_path
  end
  local dst = M.binary_path()
  vim.fn.writefile(vim.fn.readfile(src_path, "b"), dst, "b")
  vim.fn.system({ "chmod", "0755", dst })
  return true
end

local function download(url, dst)
  local res = vim.system({ "curl", "-fsSL", "-o", dst, url }, { text = true }):wait()
  if res.code ~= 0 then
    return false, "curl failed: " .. (res.stderr or "")
  end
  return true
end

function M.run_install()
  local log = require("persistent_term.log")
  local tmp_bin = vim.fn.tempname() .. "-pipe"
  local tmp_sha = tmp_bin .. ".sha256"
  local ok, err = download(release_url(""), tmp_bin)
  if not ok then return false, err end
  ok, err = download(release_url(".sha256"), tmp_sha)
  if not ok then return false, err end
  local sha_line = (vim.fn.readfile(tmp_sha)[1] or ""):lower()
  local sha = sha_line:match("^([a-f0-9]+)") or sha_line
  if #sha ~= 64 then
    return false, "invalid sha256 file contents"
  end
  ok, err = M.install_from_local(tmp_bin, sha)
  if not ok then return false, err end
  log.warn("persistent-term-pipe installed at " .. M.binary_path())
  return true
end

return M
