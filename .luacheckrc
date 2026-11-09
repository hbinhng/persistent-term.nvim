std = "luajit"
globals = { "vim" }
read_globals = { "describe", "it", "before_each", "after_each", "pending", "assert" }
exclude_files = { ".deps/" }
max_line_length = 120

-- Test fakes are written as `function fake:method()` and often ignore self.
files["tests/"] = { self = false }
