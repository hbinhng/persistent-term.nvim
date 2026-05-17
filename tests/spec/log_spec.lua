-- tests/spec/log_spec.lua
describe("persistent_term.log", function()
  local log
  local tmp_log

  before_each(function()
    package.loaded["persistent_term.log"] = nil
    tmp_log = vim.fn.tempname()
    vim.env.PERSISTENT_TERM_LOG_PATH = tmp_log
    vim.env.PERSISTENT_TERM_DEBUG = nil
    log = require("persistent_term.log")
  end)

  after_each(function()
    vim.fn.delete(tmp_log)
    vim.env.PERSISTENT_TERM_LOG_PATH = nil
  end)

  it("writes ERROR lines to the log file", function()
    log.error("boom")
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("ERROR%s+boom"))
  end)

  it("writes WARN lines to the log file", function()
    log.warn("careful")
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("WARN%s+careful"))
  end)

  it("skips DEBUG when env is unset", function()
    log.debug("noisy")
    local ok, lines = pcall(vim.fn.readfile, tmp_log)
    if ok then
      assert.equals(0, #lines)
    end
  end)

  it("writes DEBUG when PERSISTENT_TERM_DEBUG=1", function()
    package.loaded["persistent_term.log"] = nil
    vim.env.PERSISTENT_TERM_DEBUG = "1"
    local log2 = require("persistent_term.log")
    log2.debug("noisy")
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("DEBUG%s+noisy"))
  end)

  it("rotates the file once when it exceeds 1MB", function()
    local big = string.rep("x", 1024 * 1024 + 10)
    vim.fn.writefile({ big }, tmp_log)
    log.error("after-rotate")
    assert.equals(1, vim.fn.filereadable(tmp_log .. ".1"))
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("ERROR%s+after%-rotate"))
  end)
end)
