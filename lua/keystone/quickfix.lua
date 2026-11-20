local M = {}

local cfgutil = require("keystone.util.config")

-- ---------------------------------------------------------------------------
-- Quickfix and location lists in a floating window
--
-- Every quickfix or location list window is adopted as it opens: the list's
-- buffer is shown in a bottom-anchored float and the native split is closed.
-- The real quickfix buffer is reused, so list updates, `:cnext`, `:lnext` and
-- the `qf` ftplugin keep working as they do in the split.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

---@class keystone.quickfix.Keys
---@field close string? close the float; default "<Esc>"
---@field split string? replace the float with the native split; default "<C-q>"

---@class keystone.quickfix.Config
---@field enabled boolean? master switch; when false no window is adopted
---@field height number? float height as a fraction of the editor area, border included
---@field width number? float width as a fraction of the editor columns
---@field border string? border style passed to `nvim_open_win`; "none" disables it
---@field title boolean? show the list title in the border
---@field keys keystone.quickfix.Keys?

---@type keystone.quickfix.Config
local _default_config = {
  enabled = true,
  height  = 0.3,
  width   = 1.0,
  border  = "rounded",
  title   = true,
  keys    = {
    close = "<Esc>",
    split = "<C-q>",
  },
}

---@type keystone.quickfix.Config
M.config = vim.deepcopy(_default_config)

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local _AUGROUP = "keystone.quickfix"

---@class keystone.quickfix.State
---@field win integer the float
---@field buf integer the quickfix or location list buffer
---@field kind "quickfix"|"loclist"
---@field origin integer window the native split was opened from
---@field title string? list title shown in the border
---@field group integer autogroup watching the float
---@field maps string[] buffer-local keys installed for the float
---@field detached boolean? keys already removed

--- Buffer number -> state of the float showing it.
---@type table<integer, keystone.quickfix.State>
local _floats = {}

--- Native windows waiting for the next tick to be adopted.
---@type table<integer, true>
local _pending = {}

-- ---------------------------------------------------------------------------
-- Window queries
-- ---------------------------------------------------------------------------

---@param win integer
---@return boolean
local function _is_native(win)
  if not vim.api.nvim_win_is_valid(win) then return false end
  return vim.api.nvim_win_get_config(win).relative == ""
end

--- `win_gettype()` reports "unknown" for a window in another tabpage, so it is
--- read in the window's own context.
---@param win integer
---@return "quickfix"|"loclist"?
local function _kind_of(win)
  local kind = vim.api.nvim_win_call(win, function() return vim.fn.win_gettype() end)
  if kind == "quickfix" or kind == "loclist" then return kind end
  return nil
end

--- The window the list was opened from: the qf window's alternate, else any
--- other window in its tabpage.
---@param win integer
---@return integer
local function _origin_of(win)
  local alt = vim.api.nvim_win_call(win, function()
    return vim.fn.win_getid(vim.fn.winnr("#"))
  end)
  if alt ~= 0 and alt ~= win and vim.api.nvim_win_is_valid(alt) then return alt end
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if other ~= win then return other end
  end
  return win
end

-- ---------------------------------------------------------------------------
-- Float geometry
-- ---------------------------------------------------------------------------

--- Editor rows a bottom bar may use: everything `'lines'` counts, less the
--- command line and a status line when one occupies a row.
---@return integer
local function _usable_lines()
  local laststatus = vim.o.laststatus
  local reserved = vim.o.cmdheight + ((laststatus ~= 0 and laststatus ~= 1) and 1 or 0)
  return math.max(1, vim.o.lines - reserved)
end

--- A bottom-anchored float `M.config.width` wide and `M.config.height` tall.
--- With the default width the border sits one cell in from either edge, the
--- same bar `lspnav.nvim` uses for its side windows.
---@param title? string
---@return vim.api.keyset.win_config
local function _geometry(title)
  local cfg = M.config
  local usable = _usable_lines()
  local border = (cfg.border and cfg.border ~= "none") and 2 or 0

  local height = math.ceil(usable * math.max(0.1, math.min(0.9, cfg.height)))
  height = math.min(math.max(1, height), math.max(1, usable - border))

  local width = math.max(0, math.min(1, cfg.width or 1))
  local inner_w = math.floor((vim.o.columns - 2 * border) * width)
  inner_w = math.max(1, inner_w)
  local outer_w = inner_w + border

  local show_title = cfg.title and border > 0 and title ~= nil

  return {
    relative  = "editor",
    width     = inner_w,
    height    = height,
    row       = math.max(0, usable - height - border),
    col       = math.max(0, math.floor((vim.o.columns - outer_w) / 2)),
    border    = cfg.border or "none",
    title     = show_title and (" " .. title .. " ") or nil,
    title_pos = show_title and "center" or nil,
    style     = "minimal",
  }
end

-- Paint the float with Normal so it reads as part of the editor rather than a
-- popup, the same way lspnav.nvim's side windows and details float do.
local _WINHL = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title"

---@param win integer
local function _style_window(win)
  local wo = vim.wo[win][0]
  wo.winhighlight = _WINHL
  -- "minimal" forces 'cursorline' off; take the opener's setting back.
  wo.cursorline = vim.wo.cursorline
  wo.wrap = false
  wo.winfixbuf = true
  -- A new window inherits its opener's options; don't let the bar scroll with
  -- the code behind it.
  wo.scrollbind = false
  wo.cursorbind = false
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

---@param state keystone.quickfix.State
local function _detach_keys(state)
  if state.detached then return end
  state.detached = true
  if not vim.api.nvim_buf_is_valid(state.buf) then return end
  for _, lhs in ipairs(state.maps) do
    vim.api.nvim_buf_del_keymap(state.buf, "n", lhs)
  end
end

---@param state keystone.quickfix.State
local function _release(state)
  _detach_keys(state)
  _floats[state.buf] = nil
end

---@param state keystone.quickfix.State
local function _close(state)
  local win = state.win
  _release(state)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, false)
  end
end

--- Replace the float with the native split, so the list gets a normal window
--- back. `:noautocmd` keeps the reopened split from being adopted again.
---@param state keystone.quickfix.State
local function _to_split(state)
  local win, kind, origin = state.win, state.kind, state.origin
  _release(state)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, false)
  end
  if vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  vim.cmd(("noautocmd %s"):format(kind == "loclist" and "lopen" or "copen"))
end

---@param state keystone.quickfix.State
local function _attach_keys(state)
  local keys = M.config.keys or {}
  local close = keys.close or "<Esc>"
  local split = keys.split or "<C-q>"

  vim.keymap.set("n", close, function() _close(state) end, {
    buffer = state.buf,
    nowait = true,
    desc   = "Quickfix: close the floating window",
  })
  state.maps = { close }

  if split ~= close then
    vim.keymap.set("n", split, function() _to_split(state) end, {
      buffer = state.buf,
      nowait = true,
      desc   = "Quickfix: replace the float with a split",
    })
    table.insert(state.maps, split)
  end
end

-- ---------------------------------------------------------------------------
-- Adoption
-- ---------------------------------------------------------------------------

--- Move the buffer of native quickfix window `win` into a float and close the
--- split. Runs outside the triggering autocmd, so the qf subsystem has finished
--- setting the window up.
---@param win integer
local function _adopt(win)
  if not _is_native(win) then return end
  -- The float is opened in the current tabpage; a window elsewhere keeps its
  -- native split.
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return end

  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "quickfix" then return end

  local kind = _kind_of(win)
  if not kind then return end

  -- Keep the buffer (and its `qf` ftplugin state) when the native split and
  -- later the float close; a reopened split must not start from a wiped buffer.
  vim.bo[buf].bufhidden = "hide"

  local existing = _floats[buf]
  if existing and vim.api.nvim_win_is_valid(existing.win) then
    -- The list is already floating; this is the split that reopened it.
    local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
    if #wins > 1 then
      vim.api.nvim_win_close(win, false)
    end
    vim.api.nvim_set_current_win(existing.win)
    return
  end

  local title = vim.w[win].quickfix_title
  if title == nil or title == "" then
    title = kind == "quickfix" and "Quickfix" or "Location List"
  end

  local state = {
    buf    = buf,
    kind   = kind,
    origin = _origin_of(win),
    maps   = {},
  }

  state.title = title
  state.win = vim.api.nvim_open_win(buf, true, _geometry(title))
  _floats[buf] = state
  _style_window(state.win)

  state.group = vim.api.nvim_create_augroup("keystone.quickfix." .. state.win, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = state.group,
    callback = function(args)
      if tonumber(args.match) ~= state.win then return end
      _release(state)
      vim.api.nvim_del_augroup_by_id(state.group)
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group    = state.group,
    callback = function()
      if not vim.api.nvim_win_is_valid(state.win) then return end
      vim.api.nvim_win_set_config(state.win, _geometry(state.title))
    end,
  })

  _attach_keys(state)

  -- The buffer is displayed by the float now, so the split can go. A qf window
  -- that is its tabpage's only window has to stay, or the tabpage closes.
  local wins = vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
  if #wins > 1 then
    vim.api.nvim_win_close(win, false)
  end
end

---@param win integer
local function _schedule(win)
  if not _is_native(win) or _pending[win] then return end
  _pending[win] = true
  vim.schedule(function()
    _pending[win] = nil
    _adopt(win)
  end)
end

-- ---------------------------------------------------------------------------
-- Enable / disable
-- ---------------------------------------------------------------------------

--- Hook quickfix and location list windows. Runs at `FileType qf` and
--- `BufWinEnter`, since a reused qf buffer raises only the latter.
function M.enable()
  local group = vim.api.nvim_create_augroup(_AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group    = group,
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= "quickfix" then return end
      _schedule(vim.api.nvim_get_current_win())
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group    = group,
    pattern  = "qf",
    callback = function(ev)
      local tab = vim.api.nvim_get_current_tabpage()
      for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do
        if vim.api.nvim_win_get_tabpage(win) == tab then _schedule(win) end
      end
    end,
  })
end

--- Remove the hooks and close every float this module opened. The lists stay
--- usable; the next native command opens them as splits again.
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, _AUGROUP)
  local states = {}
  for _, state in pairs(_floats) do
    table.insert(states, state)
  end
  _floats = {}
  for _, state in ipairs(states) do
    _release(state)
    if vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, false)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local _setup = false

--- A fresh copy of the module defaults, as `setup()` starts from. Safe to mutate.
---@return table
function M.get_default_config()
  return vim.deepcopy(_default_config)
end

--- Whether `setup()` has been called for this module.
---@return boolean
function M.is_setup()
  return _setup
end

---@param opts keystone.quickfix.Config?
function M.setup(opts)
  _setup = true
  cfgutil.apply(M.config, _default_config, opts)

  M.disable()
  if M.config.enabled then
    M.enable()
  end
end

return M
