local events = require 'typst-preview.events'
local fetch = require 'typst-preview.fetch'
local utils = require 'typst-preview.utils'
local config = require 'typst-preview.config'
local servers = require 'typst-preview.servers'

local M = {}

local function get_path(action)
  local path = utils.get_buf_path(0)
  if path == '' then
    local message = action or 'preview'
    utils.notify(
      'Can not ' .. message .. ' an unsaved buffer.',
      vim.log.levels.ERROR
    )
    return nil
  end

  return config.opts.get_main_file(path)
end

local function normalize_export_args(path, output)
  local args = {
    'compile',
    '--root',
    config.opts.get_root(path),
  }

  if config.opts.export_args ~= nil then
    local extra = config.opts.export_args
    if type(extra) == 'function' then
      local ok, res = pcall(extra, path, output)
      if ok and res ~= nil then
        if type(res) == 'table' then
          for _, v in ipairs(res) do
            table.insert(args, v)
          end
        elseif type(res) == 'string' then
          table.insert(args, res)
        end
      end
    elseif type(extra) == 'table' then
      for _, v in ipairs(extra) do
        table.insert(args, v)
      end
    else
      error 'config.opts.export_args must be a table or function'
    end
  end

  table.insert(args, path)
  if output ~= nil and output ~= '' then
    table.insert(args, output)
  end

  return args
end

local function parse_typst_diagnostics(text)
  if text == nil or text == '' then
    return nil, nil
  end

  local blocks = {}
  local current = nil

  for line in (text .. '\n'):gmatch '([^\n]*)\n' do
    if line:match '^warning:' or line:match '^error:' then
      if current ~= nil then
        table.insert(blocks, current)
      end
      current = { kind = line:match '^(%w+):', lines = { line } }
    elseif current ~= nil then
      table.insert(current.lines, line)
    end
  end

  if current ~= nil then
    table.insert(blocks, current)
  end

  local warnings = {}
  local errors = {}
  for _, block in ipairs(blocks) do
    local filtered = {}
    for _, line in ipairs(block.lines) do
      if not line:match '^[%s]*[┌└│]' then
        table.insert(filtered, line)
      end
    end
    local msg = table.concat(filtered, '\n')
    if block.kind == 'warning' then
      table.insert(warnings, msg)
    elseif block.kind == 'error' then
      table.insert(errors, msg)
    end
  end

  local warn_text = #warnings > 0 and table.concat(warnings, '\n') or nil
  local err_text = #errors > 0 and table.concat(errors, '\n') or nil
  return warn_text, err_text
end

---Scroll all preview to cursor position.
function M.sync_with_cursor()
  for _, ser in pairs(servers.get_all()) do
    servers.sync_with_cursor(ser)
  end
end

---Export the current typst file to PDF using typst compile.
---@param output string|nil
function M.export_pdf(output)
  local path = get_path 'export'
  if path == nil then
    return
  end

  if output == nil or output == '' then
    output = vim.fn.fnamemodify(path, ':r') .. '.pdf'
  end

  local typst_bin = config.opts.typst_bin or 'typst'
  if vim.fn.executable(typst_bin) == 0 then
    utils.notify(
      'typst binary not found. Set typst_bin in setup or install typst.',
      vim.log.levels.ERROR
    )
    return
  end

  local args = normalize_export_args(path, output)
  local stdout = assert(vim.uv.new_pipe())
  local stderr = assert(vim.uv.new_pipe())
  local out_chunks = {}
  local err_chunks = {}

  local handle, _ = vim.uv.spawn(typst_bin, {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code)
    stdout:close()
    stderr:close()
    if handle then
      handle:close()
    end

    local err_msg = table.concat(err_chunks, '')
    local warn_text, err_text = parse_typst_diagnostics(err_msg)
    if code == 0 then
      if warn_text ~= nil then
        utils.notify(warn_text, vim.log.levels.WARN)
      end
      utils.notify('Exported PDF to ' .. output, vim.log.levels.INFO)
    else
      if warn_text ~= nil then
        utils.notify(warn_text, vim.log.levels.WARN)
      end
      local report = err_text
      if report == nil or report == '' then
        report = err_msg
      end
      if report == '' then
        report = table.concat(out_chunks, '')
      end
      utils.notify(
        'typst compile failed (exit ' .. tostring(code) .. '): ' .. report,
        vim.log.levels.ERROR
      )
    end
  end)

  if not handle then
    utils.notify('Failed to spawn typst process.', vim.log.levels.ERROR)
    return
  end

  stdout:read_start(function(err, data)
    if err then
      utils.debug('typst stdout error: ' .. err)
    elseif data then
      table.insert(out_chunks, data)
    end
  end)

  stderr:read_start(function(err, data)
    if err then
      utils.debug('typst stderr error: ' .. err)
    elseif data then
      table.insert(err_chunks, data)
    end
  end)
end

---Create user commands
function M.create_commands()
  local function preview_off()
    local path = utils.get_buf_path(0)

    if path ~= '' and servers.remove(config.opts.get_main_file(path)) then
      utils.print 'Preview stopped'
    else
      utils.print 'Preview not running'
    end
  end

  ---@param mode mode?
  local function preview_on(mode)
    -- check if binaries are available and tell them to fetch first
    for _, bin in pairs(fetch.bins_to_fetch()) do
      if
        not config.opts.dependencies_bin[bin.name] and not fetch.up_to_date(bin)
      then
        utils.notify(
          bin.name
            .. ' not found or out of date\nPlease run :TypstPreviewUpdate first!',
          vim.log.levels.ERROR
        )
        return
      end
    end

    local path = get_path 'preview'
    if path == nil then
      return
    end

    mode = mode or 'document'

    local ser = servers.get(path)
    if ser == nil or ser[mode] == nil then
      servers.init(path, mode, function(s)
        events.listen(s)
      end)
    else
      local s = ser[mode]
      print 'Opening another frontend'
      utils.visit(s.link)
    end
  end

  vim.api.nvim_create_user_command('TypstPreviewUpdate', function()
    fetch.fetch(false)
  end, {})

  vim.api.nvim_create_user_command('TypstPreview', function(opts)
    local mode
    if #opts.fargs == 1 then
      mode = opts.fargs[1]
      if mode ~= 'document' and mode ~= 'slide' then
        utils.notify(
          'Invalid preview mode: "'
            .. mode
            .. '.'
            .. ' Should be one of "document" and "slide"',
          vim.log.levels.ERROR
        )
      end
    else
      assert(#opts.fargs == 0)
      local path = get_path 'preview'
      if path == nil then
        return
      end
      local sers = servers.get(path)
      if sers ~= nil then
        mode = servers.get_last_mode(path)
      end
    end

    preview_on(mode)
  end, {
    nargs = '?',
    complete = function(_, _, _)
      return { 'document', 'slide' }
    end,
  })
  vim.api.nvim_create_user_command('TypstPreviewStop', preview_off, {})
  vim.api.nvim_create_user_command('TypstPreviewToggle', function()
    local path = get_path 'preview'
    if path == nil then
      return
    end

    if servers.get(path) ~= nil then
      preview_off()
    else
      preview_on(servers.get_last_mode(path))
    end
  end, {})

  vim.api.nvim_create_user_command('TypstPreviewFollowCursor', function()
    config.set_follow_cursor(true)
  end, {})
  vim.api.nvim_create_user_command('TypstPreviewNoFollowCursor', function()
    config.set_follow_cursor(false)
  end, {})
  vim.api.nvim_create_user_command('TypstPreviewFollowCursorToggle', function()
    config.set_follow_cursor(not config.get_follow_cursor())
  end, {})
  vim.api.nvim_create_user_command('TypstPreviewSyncCursor', function()
    M.sync_with_cursor()
  end, {})

  vim.api.nvim_create_user_command('TypstPreviewExport', function(opts)
    local output
    if #opts.fargs == 1 then
      output = opts.fargs[1]
    end
    M.export_pdf(output)
  end, {
    nargs = '?',
  })
end

return M
