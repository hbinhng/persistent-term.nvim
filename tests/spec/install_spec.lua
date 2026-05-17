-- tests/spec/install_spec.lua
describe("persistent_term.install", function()
  local install
  local tmpdir

  before_each(function()
    package.loaded["persistent_term.install"] = nil
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    vim.env.PERSISTENT_TERM_INSTALL_DIR = tmpdir
    install = require("persistent_term.install")
  end)

  after_each(function()
    vim.fn.delete(tmpdir, "rf")
    vim.env.PERSISTENT_TERM_INSTALL_DIR = nil
  end)

  it("binary_path uses the override", function()
    assert.equals(tmpdir .. "/persistent-term-pipe", install.binary_path())
  end)

  it("is_installed returns false when the file is missing", function()
    assert.is_false(install.is_installed())
  end)

  it("is_installed returns true when file exists and is executable", function()
    local path = install.binary_path()
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
    vim.fn.system({ "chmod", "0755", path })
    assert.is_true(install.is_installed())
  end)

  it("verify_sha256 returns true when hash matches", function()
    local path = tmpdir .. "/payload.bin"
    vim.fn.writefile({ "hello world" }, path, "b")
    local expected = vim.fn.sha256(table.concat(vim.fn.readfile(path, "b"), "\n"))
    assert.is_true(install.verify_sha256(path, expected))
  end)

  it("verify_sha256 returns false on mismatch", function()
    local path = tmpdir .. "/payload.bin"
    vim.fn.writefile({ "hello world" }, path, "b")
    assert.is_false(install.verify_sha256(path, string.rep("0", 64)))
  end)

  it("install_from_local copies+chmods+verifies", function()
    local src = tmpdir .. "/src"
    vim.fn.writefile({ "#!/bin/sh", "echo ok" }, src)
    local sha = vim.fn.sha256(table.concat(vim.fn.readfile(src, "b"), "\n"))
    local ok, err = install.install_from_local(src, sha)
    assert.is_true(ok, err)
    assert.is_true(install.is_installed())
  end)

  it("install_from_local refuses when hash does not match", function()
    local src = tmpdir .. "/src"
    vim.fn.writefile({ "garbage" }, src)
    local ok, err = install.install_from_local(src, string.rep("0", 64))
    assert.is_false(ok)
    assert.is_truthy(err:match("sha256 mismatch"))
  end)
end)
