-- tests/spec/tmux_spec.lua
describe("tmux.version_at_least", function()
  local tmux
  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("returns true when have == want", function()
    assert.is_true(tmux.version_at_least("3.0", "3.0"))
  end)

  it("returns true when have > want", function()
    assert.is_true(tmux.version_at_least("3.4", "3.2"))
  end)

  it("returns false when have < want", function()
    assert.is_false(tmux.version_at_least("3.0", "3.2"))
  end)

  it("ignores non-numeric suffixes in the comparison", function()
    -- "3.0a" -> {3,0}, equal to "3.0"
    assert.is_true(tmux.version_at_least("3.0a", "3.0"))
  end)

  it("returns true when have has a two-digit minor and want has a single-digit minor", function()
    assert.is_true(tmux.version_at_least("3.10", "3.4"))
  end)
end)

describe("tmux.parse_list_panes", function()
  local tmux
  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("parses a single row", function()
    local rows = tmux.parse_list_panes("@1\t%1\tdev\t0\n")
    assert.same({ { window_id = "@1", pane_id = "%1", name = "dev", dead = false } }, rows)
  end)

  it("parses multiple rows", function()
    local rows = tmux.parse_list_panes("@1\t%1\tdev\t0\n@2\t%2\ttest\t1\n")
    assert.equals(2, #rows)
    assert.is_true(rows[2].dead)
  end)

  it("tolerates empty name", function()
    local rows = tmux.parse_list_panes("@1\t%1\t\t0\n")
    assert.equals("", rows[1].name)
  end)
end)

describe("tmux.parse_id_tuple", function()
  local tmux
  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("parses pane_id<TAB>window_id with trailing newline", function()
    assert.same({ pane_id = "%1", window_id = "@1" }, tmux.parse_id_tuple("%1\t@1\n"))
  end)

  it("returns nil on malformed input", function()
    assert.is_nil(tmux.parse_id_tuple("garbage"))
  end)
end)
