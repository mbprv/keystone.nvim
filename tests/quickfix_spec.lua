local quickfix = require("keystone.quickfix")

--- Reset to a single window on a single buffer, with no lists.
local function reset()
  quickfix.disable()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! only!")
  vim.cmd("enew")
  vim.fn.setqflist({}, "f")
  vim.fn.setloclist(0, {}, "f")
end

---@return integer[] floats, integer[] native
local function partition_windows()
  local floats, native = {}, {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      table.insert(native, win)
    else
      table.insert(floats, win)
    end
  end
  return floats, native
end

---@return integer
local function float_count()
  return #partition_windows()
end

---@param pred fun():boolean
local function wait_for(pred)
  assert.is_true(vim.wait(1000, pred, 10), "timed out waiting for the float")
end

---@param keys string
local function feed(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "x", false)
end

---@param kind "quickfix"|"loclist"
local function open_list(kind)
  local items = {
    { filename = "/tmp/keystone-qf-a.txt", lnum = 1, text = "one" },
    { filename = "/tmp/keystone-qf-b.txt", lnum = 2, text = "two" },
  }
  if kind == "quickfix" then
    vim.fn.setqflist({}, " ", { title = "Test Quickfix", items = items })
    vim.cmd("copen")
  else
    vim.fn.setloclist(0, {}, " ", { title = "Test Loclist", items = items })
    vim.cmd("lopen")
  end
  wait_for(function() return float_count() > 0 end)
  return partition_windows()
end

describe("keystone.quickfix", function()
  before_each(function()
    reset()
    quickfix.setup({})
  end)

  after_each(reset)

  it("shows :copen in a float and closes the split", function()
    local floats, native = open_list("quickfix")

    assert.equal(1, #floats)
    assert.equal(1, #native)
    local win = floats[1]
    assert.is_true(vim.api.nvim_win_is_valid(win))
    assert.equal("quickfix", vim.bo[vim.api.nvim_win_get_buf(win)].buftype)
    assert.equal(2, vim.fn.getqflist({ size = 0 }).size)
  end)

  it("closes the float with <Esc> and returns to the original window", function()
    local origin = vim.api.nvim_get_current_win()
    open_list("quickfix")

    feed("<Esc>")

    wait_for(function() return float_count() == 0 end)
    local floats, native = partition_windows()
    assert.equal(0, #floats)
    assert.equal(1, #native)
    assert.equal(origin, vim.api.nvim_get_current_win())
  end)

  it("jumps to an entry in the original window, closing the float", function()
    local origin = vim.api.nvim_get_current_win()
    local target = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(target, 0, -1, false, { "first", "second" })

    vim.fn.setqflist({}, " ", {
      title = "Jump",
      items = { { bufnr = target, lnum = 1, col = 1, text = "first" } },
    })
    vim.cmd("copen")
    wait_for(function() return float_count() > 0 end)

    feed("<CR>")

    wait_for(function() return float_count() == 0 end)
    assert.equal(origin, vim.api.nvim_get_current_win())
    assert.equal(target, vim.api.nvim_win_get_buf(origin))
  end)

  it("closes the float when focus moves to another window", function()
    vim.cmd("vsplit")
    local left = vim.api.nvim_get_current_win()
    vim.cmd("wincmd p")
    local right = vim.api.nvim_get_current_win()

    open_list("quickfix")
    vim.api.nvim_set_current_win(left)

    wait_for(function() return float_count() == 0 end)
    assert.equal(left, vim.api.nvim_get_current_win())
    assert.is_true(vim.api.nvim_win_is_valid(right))
  end)

  it("keeps the float open when :copen refreshes the list", function()
    open_list("quickfix")
    local first = partition_windows()[1]

    vim.cmd("copen")
    wait_for(function()
      local floats, native = partition_windows()
      return #floats == 1 and #native == 1
    end)

    local floats = partition_windows()[1]
    assert.same(first, floats)
    assert.equal(1, float_count())
  end)

  it("replaces the float with the native split with <C-q>", function()
    open_list("quickfix")

    feed("<C-q>")

    wait_for(function()
      local floats, native = partition_windows()
      return #floats == 0 and #native == 2
    end)
    -- The reopened split must stay native rather than being adopted again.
    assert.equal("quickfix", vim.bo[0].buftype)
  end)

  it("handles a location list the same way", function()
    local origin = vim.api.nvim_get_current_win()
    local floats, native = open_list("loclist")

    assert.equal(1, #floats)
    assert.equal(1, #native)
    local size = vim.api.nvim_win_call(origin, function()
      return vim.fn.getloclist(0, { size = 0 }).size
    end)
    assert.equal(2, size)

    feed("<C-q>")

    wait_for(function()
      local f, n = partition_windows()
      return #f == 0 and #n == 2
    end)
    assert.equal("quickfix", vim.bo[0].buftype)
  end)
end)
