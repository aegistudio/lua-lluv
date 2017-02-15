------------------------------------------------------------------
--
--  Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Copyright (C) 2014-2017 Alexey Melnichuk <alexeymelnichuck@gmail.com>
--
--  Licensed according to the included 'LICENSE' document
--
--  This file is part of lua-lluv library.
--
------------------------------------------------------------------

--! @usage
-- ut.corun(function()
--   local f = cofs.open('test.txt', 'rb+')
--   f:read("*l", "*l")
--   f:seek('end')
--   f:write('\nhello', 'world')
-- end)

local uv = require "lluv"
local ut = require "lluv.utils"

local unpack = unpack or table.unpack

local function _check_resume(status, ...)
  if not status then return error(..., 3) end
  return ...
end

local function co_resume(...)
  return _check_resume(coroutine.resume(...))
end

local function co_yield(...)
  return coroutine.yield(...)
end

local EOF = uv.error(uv.ERROR_UV, uv.EOF)

local EOL = "\n"

local File = ut.class() do

function File:__init()
  self._co  = assert(coroutine.running())
  self._buf = uv.buffer(10)

  return self
end

function File:_resume(...)
  return co_resume(self._co, ...)
end

function File:_yield(...)
  return coroutine.yield(...)
end

function File:attach(co)
  self._co = co or coroutine.running()
  return self
end

function File:interrupt(...)
  if self._co and self._co ~= coroutine.running() then
    self:_resume(nil, ...)
  end
end

function File:open(path, mode)
  local terminated

  -- uv suppots only binary mode
  mode = mode:gsub('[bt]', '')

  uv.fs_open(path, mode, function(file, err, path)
    if terminated then
      if file and not err then
        file:close()
      end
      return
    end

    if err then
      self:_resume(nil, err)
      return
    end

    self:_resume(file, path)
  end)

  local fd, err = self:_yield()
  terminated = true

  if not fd then return nil, err end

  self._fd, self._pos = fd, 0

  self._stat, err = self:stat()
  if not self._stat then
    self:close()
    return nil, err
  end

  return self
end

function File:close()
  local terminated

  self._fd:close(function(file, err, result)
    if terminated then return end

    if err then return self:_resume(nil, err) end

    self:_resume(result)
  end)

  local ok, err = self:_yield()
  terminated = true

  self._fd, self._pos, self._stat = nil

  return ok, err
end

function File:_read_some(n)
  local terminated

  n = n or self._buf:size()

  assert(n <= self._buf:size())

  self._fd:read(self._buf, self._pos, 0, n, function(file, err, buffer, size)
    if terminated then return end

    if err then return self:_resume(nil, err) end

    if size == 0 then return self:_resume('') end

    self._pos = self._pos + size
    self:_resume(buffer:to_s(size))
  end)

  local ok, err = self:_yield()
  terminated = true

  if not ok then return nil, err end

  return ok
end

function File:read_n(n)
  local chunk_size = self._buf:size()
  if n <= chunk_size then
    return self:_read_some(n)
  end
  local res = {}
  while n > 0 do
    local chunk, err = self:_read_some(math.min(chunk_size, n))
    if not chunk then return nil, err, table.concat(res) end
    if #chunk == 0 then break end
    n = n - #chunk
    res[#res + 1] = chunk
  end
  if #res == 0 then return nil end
  return table.concat(res)
end

function File:read_all()
  return self:read_n(math.huge)
end

function File:read_line(keep)
  local res = ''
  while true do
    local chunk, err = self:_read_some()
    if not chunk then return nil, err end
    if chunk == '' then return res end

    res = res .. chunk
    local i = string.find(res, EOL, nil, true)

    if i then
      local rest_size = #res - (i - 1 + #EOL)
      self._pos = self._pos - rest_size

      if keep then i = i + #EOL end
      return string.sub(res, 1, i - 1)
    end
  end
end

function File:read_pat(pat)
  if pat == '*a'           then return self:read_all()      end
  if pat == nil            then return self:read_line()     end
  if pat == '*l'           then return self:read_line()     end
  if pat == '*L'           then return self:read_line(true) end
  if type(pat) == 'number' then return self:read_n(pat)     end

  error("invalid format '" .. tostring(pat), 2)
end

function File:read(p, ...)
  if not ... then return self:read_pat(p) end

  local res, i = {}, 1
  repeat
    local chunk, err = self:read_pat(p)
    if err and (not chunk) then return nil, err end
    res[i] = chunk
    p = select(i, ...)
    i = i + 1
  until not p

  return unpack(res, 1, i - 1)
end

function File:write_string(str)
  local terminated

  self._fd:write(str, self._pos, function(file, err, ...)
    if terminated then return end

    if err then return self:_resume(nil, err) end

    self._pos = self._pos + #str

    self:_resume(...)
  end)

  local ok, err = self:_yield()
  terminated = true

  if not ok then return nil, err end

  return true
end

function File:write(s, ...)
  if not ... then return self:write_string(s) end

  local i = 1
  repeat
    local ok, err = self:write_string(s)
    if err and (not ok) then return nil, err end
    s = select(i, ...)
    i = i + 1
  until not s

  return true
end

function File:size()
  local stat, err = self:stat()
  if not stat then return nil, err end

  local size = stat.size

  return size
end

function File:seek(whence, offset)
  whence = whence or 'cur'
  offset = offset or 0

  local pos

  if whence == 'set' then
    pos = offset
  elseif whence == 'cur' then
    pos = self._pos + offset
  elseif whence == 'end' then
    local size, err = self:size()
    if not size then return nil, err end
    pos = size + offset
  else
    error("invalid option '" .. tostring(whence) .. "'", 2)
  end

  self._pos = math.max(0, pos)

  return self._pos
end

function File:stat()
  local terminated

  self._fd:stat(function(file, err, ...)
    if terminated then return end

    if err then return self:_resume(nil, err) end

    self:_resume(...)
  end)

  local ok, err = self:_yield()
  terminated = true

  if not ok then return nil, err end

  return ok
end

--! @todo
-- sync
-- datasync
-- truncate
-- chown
-- chmod
-- utime

end

local cofs = {}

function cofs.open(...)
  local file = File.new()
  return file:open(...)
end

function cofs.unlink(path)
  local co = coroutine.running()

  uv.fs_unlink(path, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.mkdtemp(path)
  local co = coroutine.running()

  uv.fs_mkdtemp(path, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.mkdir(path, mode)
  local co = coroutine.running()

  uv.fs_mkdir(path, mode or 0, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.rmdir(path)
  local co = coroutine.running()

  uv.fs_rmdir(path, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.scandir(path, flags)
  local co = coroutine.running()

  uv.fs_scandir(path, flags or 0, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.stat(path)
  local co = coroutine.running()

  uv.fs_stat(path, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.lstat(path)
  local co = coroutine.running()

  uv.fs_lstat(path, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.rename(path, new)
  local co = coroutine.running()

  uv.fs_rename(path, new, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.chmod(path, mode)
  local co = coroutine.running()

  uv.fs_chmod(path, mode, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.utime(path, atime, mtime)
  local co = coroutine.running()

  uv.fs_utime(path, atime, mtime, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.symlink(path, new)
  local co = coroutine.running()

  uv.fs_symlink(path, new, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.readlink(path)
  local co = coroutine.running()

  uv.fs_readlink(path, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.chown(path, uid, gid)
  local co = coroutine.running()

  uv.fs_chown(path, uid, gid, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

function cofs.access(path, flags)
  local co = coroutine.running()

  uv.fs_access(path, flags, function(loop, err, ...)
    if err then return co_resume(co, nil, err) end

    co_resume(co, ...)
  end)

  return co_yield()
end

return cofs
