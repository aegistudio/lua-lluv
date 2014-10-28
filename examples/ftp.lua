-- FTP Client
-- This code is in development state and may be (and will) changed
------------------------------------------------------------------

-- Usage:

-- local ftp = Ftp.new("127.0.0.1:21",{
--   uid = "moteus",
--   pwd = "123456",
-- })
-- 
-- ftp:open(function(self, err)
--   assert(not err, tostring(err))
--   self:mkdir("sub") -- ignore error
--   self:store("sub/test.txt", "Some data", function(self, err)
--     assert(not err, tostring(err))
--   end)
-- end)

local uv = require "lluv"
local ut = require "lluv.utils"
local va = require "vararg"

local EOL = "\r\n"

local class       = ut.class
local usplit      = ut.usplit
local split_first = ut.split_first

local function trim(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function cb_args(...)
  local n = select("#", ...)
  local cb = va.range(n, n, ...)
  if type(cb) == 'function' then
    return cb, va.remove(n, ...)
  end
  return nil, ...
end

local function ocall(fn, ...) if fn then return fn(...) end end

local function is_xxx(n)
  local a, b = n * 100, (n+1)*100
  return function(code)
    return (code >= a) and (code < b)
  end
end

local is_1xx = is_xxx(1)
local is_2xx = is_xxx(2)
local is_3xx = is_xxx(3)
local is_4xx = is_xxx(4)
local is_5xx = is_xxx(5)

local function is_err(n) return is_4xx(n) or is_5xx(n) end

local Error = ut.Errors{
  { EPROTO = "Protocol error" },
  { ESTATE = "Can not perform commant in this state" },
  { ECBACK = "Error while calling callback function" },
  { EREADY = "Ftp client not ready" },
  { ECONN  = "Problem with server connection" },
}
local EPROTO = Error.EPROTO
local ECBACK = Error.ECBACK
local EREADY = Error.EREADY
local ECONN  = Error.ECONN

-------------------------------------------------------------------
local ErrorState do

local EState = class(Error.__class) do

function EState:__init(code, reply)
  self.__base.__init(self, "ESTATE")
  self._code  = code
  self._reply = reply
  return self
end

function EState:code()   return self._code         end

function EState:reply()  return self._reply        end

function EState:is_1xx() return is_1xx(self._code) end

function EState:is_2xx() return is_2xx(self._code) end

function EState:is_3xx() return is_3xx(self._code) end

function EState:is_4xx() return is_4xx(self._code) end

function EState:is_5xx() return is_5xx(self._code) end

function EState:__tostring()
  local str = self.__base.__tostring(self)
  return string.format("%s\n%d %s", str, self:code(), self:reply())
end

end

ErrorState = function(...)
  return EState.new(...)
end

end
-------------------------------------------------------------------

local WAIT = {}

-------------------------------------------------------------------
local ResponseParser = class() do

function ResponseParser:next(buf) while true do
  local line = buf:next_line()
  if not line then return WAIT end

-- HELP:
-- 214-The following commands are recognized:
-- USER   PASS   QUIT   CWD    PWD    PORT   PASV   TYPE
-- LIST   REST   CDUP   RETR   STOR   SIZE   DELE   RMD
-- ...
-- 214 Have a nice day.

-- GREET
--220-FileZilla Server version 0.9.43 beta
--220-written by Tim Kosse (tim.kosse@filezilla-project.org)
--220 Please visit http://sourceforge.net/projects/filezilla/

  local resp, sep
  if self._resp then
    resp, sep = string.match(line, "^(" .. self._resp .. ")(.?)")
  else
    resp, sep = string.match(line, "^(%d%d%d)(.?)")
    if not resp then return nil, Error(EPROTO, line) end
    self._resp = resp
  end

  local msg 
  if not resp then msg = line
  else msg = line:sub(5) end

  if resp then
    if (sep == " ") or (sep == "") then -- end of response
      self:append(msg)

      local resp, data = tonumber(resp), self._data
      self:reset()

      return resp, data
    end
    if sep ~= "-" then return nil, Error(EPROTO, line) end
  end

  self:append(msg)
end end

function ResponseParser:reset()
  -- @todo check if preview state is done
  self._data = nil
  self._resp = nil
end

function ResponseParser:append(msg)
  if msg == "" then return end

  if self._data then
    if type(self._data) == "string" then
      self._data = {self._data, msg}
    else
      self._data[#self._data + 1] = msg
    end
  else
    self._data = msg
  end
end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
local TcpConnection = class() do

function TcpConnection:__init(host, port)
  self._host  = assert(host)
  self._port  = assert(port)
  self._sock  = uv.tcp()
  self._ready = false
  return self
end

function TcpConnection:_disconnect(err)
  self._sock:close()
  self._sock = uv.tcp()
  if self._ready then ocall(self.on_disconnect, self, err) end
  self._ready = false
  return self
end

function TcpConnection:connect()
  local ok, err = self._sock:connect(self._host, self._port, function(cli, err)
    if err then self:_disconnect(err) end
    ocall(self.on_connect, self, err)
    if err then return end

    self._ready = true

    cli:start_read(function(cli, err, data)
      if err then return self:_disconnect(err) end
      return ocall(self.on_data, self, data)
    end)

  end)
  return self
end

function TcpConnection:disconnect(err)
  return self:_disconnect(err)
end

function TcpConnection:reconnect()
  return self
    :disconnect()
    :connect()
end

function TcpConnection:ready()
  return not not self._ready
end

function TcpConnection:write(data, cb)
  self._sock:write(data, function(self, err)
    if err then self._disconnect(err) end
    ocall(cb, self, err)
  end)
end

function TcpConnection:close()
  if not self._sock then return end
  self._sock:close()
  self._defer, self._sock = nil
end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
local Connection = class() do

function Connection:__init(server, opt)
  local host, port = split_first(server or "127.0.0.1", ":")
  self._host  = host
  self._port  = port or "21"
  self._user  = opt.uid
  self._pass  = opt.pwd
  self._cnn   = TcpConnection.new(self._host, self._port)
  self._auth  = false

  self._buff         = ut.Buffer.new(EOL) -- pending data
  self._queue        = ut.Queue.new()     -- pending requests
  self._pasv_pending = ut.Queue.new()     -- passive requests

  local this = self

  function self._cnn:on_connect(err)
    assert(this._queue        :empty())
    assert(this._pasv_pending :empty())

    local cb = this._open_cb
    this._open_cb = nil
 
    if not err then
      this._queue:push{parser = ResponseParser:new(), cb = cb}
    end

  end

  function self._cnn:on_data(data)
    this:_read(data)
  end

  function self._cnn:on_disconnect(err)
    this:_reset_queue(err)
    this._buff:reset()
  end

  return self
end

function Connection:ready()
  return self._cnn:ready()
end

function Connection:_connect(cb)
  if self:ready() then return ocall(cb, self) end

  self._open_cb = cb
  self._cnn:connect()
  return self
end

function Connection:_disconnect()
  self._cnn:disconnect()
end

function Connection:_read(data)
  local req = self._queue:peek()
  if not req then -- unexpected reply
    -- @fixme server can send message before close connection (e.g. timeout)
    self:_disconnect()
    return ocall(self.on_error, self, Error(EPROTO, data))
  end

  self._buff:append(data)

  ocall(self.on_trace_control, self, data, false)

  while req do
    local parser = req.parser
    local resp, msg = parser:next(self._buff)

    if resp == WAIT then return end

    if resp then
      ocall(self.on_trace_req, self, req, resp, data)
      if is_1xx(resp) then
        ocall(req.cb_1xx, self, resp, msg)
      else
        assert(req == self._queue:pop())
        if is_err(resp) then
          if type(msg) == "table" then msg = table.concat(msg, "\n") end
          ocall(req.cb, self, ErrorState(resp, msg))
        else
          ocall(req.cb, self, nil, resp, msg)
        end
      end
    else
      -- parser in invalid state. Protocol error?
      local err = Error(EPROTO, data)
      self:_disconnect(err)
      return ocall(self.on_error, self, err)
    end

    
    req = self._queue:peek()
  end
end

function Connection:_send(data, cb, cb_1xx)
  ocall(self.on_trace_control, self, data, true)
  self._cnn:write(data)
  self._queue:push{parser = ResponseParser:new(data), cb = cb, cb_1xx = cb_1xx, data = trim(data)}
  return self
end

function Connection:_command(...)
  local cmd, arg, cb, cb_1xx = ...
  if type(arg) == "function" then
    arg, cb, cb_1xx = nil, arg, cb
  end

  if arg then cmd = cmd .. " " .. arg end
  cmd = cmd .. EOL
  return self:_send(cmd, cb, cb_1xx)
end

function Connection:_reset_queue(err)
  err = err or Error(Error.ECONN)

  if not self._queue:empty() then
    while true do
      local req = self._queue:pop()
      if not req then break end
      ocall(req.cb, self, err)
    end
  end

  if not self._pasv_pending:empty() then
    while true do
      local arg = self._pasv_pending:pop()
      if not arg then break end
      local cmd, arg, cb, chunk_cb = arg()
      if type(cmd) == "function" then
        cmd(self, err)
      else
        ocall(cb, self, err)
      end
    end
  end

end

function Connection:destroy()
  if not self._cnn then  end
  self._cnn:close()
  self._cnn = nil
end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
do -- Implement FTP pasv command

local pasv_command_impl, pasv_exec_impl

local function pasv_dispatch_impl(self)
  if self._pasv_busy then return end

  local arg = self._pasv_pending:pop()
  if not arg then return end

  local cmd, arg, cb, chunk_cb = arg()
  self._pasv_busy = true
  
  if type(cmd) == "function" then
    return pasv_exec_impl(self, cmd)
  end
  return pasv_command_impl(self, cmd, arg, cb, chunk_cb)
end

pasv_command_impl = function(self, cmd, arg, cb, chunk_cb)
  return self:pasv(function(self, err, cli)
    if err then
      if cli then cli:close() end
      return ocall(cb, self, err)
    end

    local result = chunk_cb and true or {}
    local done   = false
    local result_code

    cli:start_read(function(cli, err, data)
      if err then
        cli:close()

        if err:name() == "EOF" then
          if done then return ocall(cb, self, nil, result_code, result) end
          done = true
          return
        end

        return ocall(cb, self, err)
      end

      if chunk_cb then
        local ok, err = pcall(chunk_cb, self, data)
      else result[#result + 1] = data end
    end)

    self:_command(cmd, arg, function(self, err, code, reply)
      if err then
        cli:close()
        return ocall(cb, self, err)
      end

      if is_1xx(code) then return end

      if not is_2xx(code) then
        cli:close()
        return ocall(cb, self, nil, code, reply)
      end

      result_code = code

      if done then return ocall(cb, self, nil, result_code, result) end
      done = true
    end)
  end)
end

pasv_exec_impl = function(self, cmd)
  return self:pasv(function(self, err, cli)
    if err then
      if cli then cli:close() end
      return cmd(self, err)
    end

    local ctx = {} do -- pasv context

    local ftp = self

    function ctx:data_done(err)
      cli:close()

      -- we already had control done
      if self._ctr_done then
        return self:_return(err, self._code, self._result)
      end

      -- indicate io done
      self._io_done, self._io_err = true, err
    end

    function ctx:control_done(err, code, reply)
      -- we had data_done
      if self._io_done then
        return self:_return(err or self._io_err or nil, code, self._result or reply)
      end

      -- indicate control done
      self._ctr_done, self._code, self._result = true, code, self._result or reply

      -- we get error via control channel
      if err then self:data_done(err) end
    end

    function ctx:get_cli() return cli end

    function ctx:_append(data)
      if not self._result then self._result = {} end
      self._result[#self._result + 1] = data
    end

    function ctx:_data()
      return self._result or true
    end

    function ctx:_return(...)
      ftp._pasv_busy = false
      pasv_dispatch_impl(ftp)
      return ocall(self.cb, ftp, ...)
    end

    end

    cli:start_read(function(cli, err, data)
      if err then
        if err:name() == "EOF" then
          return ctx:data_done()
        end
        return ctx:data_done(err)
      end

      if ctx.chunk_cb then
        -- @todo check error
        local ok, err = pcall(ctx.chunk_cb, self, data)
      else ctx:_append(data) end
    end)

    cmd(self, nil, ctx)
  end)
end

local function pasv_command_(self, cmd, arg, cb, chunk_cb)
  -- passive mode require create send one extra req/rep and new connection
  -- so I think overhead to enqueue/dequeue is not too much.

  local callback = function(...)
    self._pasv_busy = false
    pasv_dispatch_impl(self)
    return ocall(cb, ...)
  end

  local args = va(cmd, arg, callback, chunk_cb)

  self._pasv_pending:push(args)

  return pasv_dispatch_impl(self)
end

function Connection:pasv_command(cmd, ...)
  if type(...) == "function" then
    pasv_command_(self, cmd, nil, ...)
  else
    pasv_command_(self, cmd, ...)
  end
end

function Connection:pasv_exec(cmd)
  local args = va(cmd)

  self._pasv_pending:push(args)

  return pasv_dispatch_impl(self)
end

function Connection:pasv(cb)
  assert(cb)

  self:_command("PASV", function(self, err, code, reply)

    if err then return ocall(cb, self, err) end

    if not is_2xx(code) then
      return ocall(cb, self, ErrorState(code, reply))
    end

    local pattern = "(%d+)%D(%d+)%D(%d+)%D(%d+)%D(%d+)%D(%d+)"
    local _, _, a, b, c, d, p1, p2 = va.map(tonumber, string.find(reply, pattern))
    if not a then
      self:close()
      return ocall(cb, self, Error(EPROTO, data))
    end

    local ip, port = string.format("%d.%d.%d.%d", a, b, c, d), p1*256 + p2
    uv.tcp():connect(ip, port, function(cli, err)
      if err then
        cli:close()
        return ocall(cb, self, err)
      end
      return ocall(cb, self, nil, cli)
    end)

  end)
end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
do -- Implement FTP open

function Connection:on_greet(code, data, cb)
  if code == 220 and self._user then
    return self:auth(self._user, self._pass, cb)
  end
  return ocall(cb, self, code, data)
end

function Connection:open(cb)
  return self:_connect(function(self, err, code, greet)
    if err then return ocall(cb, self, err) end
    self:on_greet(code, data, cb)
  end)
end

function Connection:close()
  return self._disconnect()
end

end
-------------------------------------------------------------------

-------------------------------------------------------------------
do -- Implement FTP commands

local trim_code = function(cb)
  return function(self, err, code, data)
    if not err then return cb(self, nil, data) end
    return cb(self, err, code, data)
  end
end

local ret_true = function(cb)
  return function(self, err, code, data)
    if err then return cb(self, err, code, data) end
    return cb(self, nil, true)
  end
end

local file_not_found = function (err)
  return err:no() == Error.ESTATE and err:code() == 550
end

local list_cb = function(cb)
  return function(self, err, code, data)
    if err then
      if file_not_found(err) then return cb(self, nil, {}, err) end
      return cb(self, err)
    end
    cb(self, nil, ut.split(table.concat(data), EOL, true))
  end
end

-- This is Low Level commands

function Connection:command(...)
  return self:_command(...)
end

function Connection:auth(uid, pwd, cb)
  self:_command("USER", uid, function(self, err, code, reply)
    if err then return ocall(cb, self, err) end
    if not is_3xx(code) then return ocall(cb, self, nil, code, reply) end
    self:_command("PASS", pwd, cb)
  end)
end

function Connection:help(arg, cb)
  if not cb then arg, cb = nil, arg end
  assert(cb)
  self._command(self, "HELP", arg, function(self, err, code, data)
    if err then
      if arg then
        -- check if command not supported
        if err:no() == Error.ESTATE and err:code() == 502 then
          return cb(self, nil, false, err)
        end
      end
      return cb(self, err)
    end
    if type(data) == "table" then
      if #data > 1 then table.remove(data, 1) end
      if #data > 1 then table.remove(data, #data) end
      if not arg then -- return list of commands
        local t = {}
        data = ut.split(trim(table.concat(data, " ")), "%s+")
      else
        if #data == 1 then data = data[1] end
      end
    end
    cb(self, nil, data)
  end)
end

function Connection:noop(cb)
  self._command(self, "NOOP", cb)
end

function Connection:cwd(arg, cb)
  assert(arg)
  self._command(self, "CWD", arg, cb and ret_true(cb))
end

function Connection:pwd(cb)
  assert(cb)
  self._command(self, "PWD", trim_code(cb))
end

function Connection:mdtm(arg, cb)
  assert(arg)
  assert(cb)
  self._command(self, "MDTM", arg, trim_code(cb))
end

function Connection:mkd(arg, cb)
  assert(arg)
  self._command(self, "MKD", arg, cb and trim_code(cb))
end

function Connection:hash(arg, cb)
  assert(arg)
  assert(cb)
  self._command(self, "HASH", arg, cb)
end

function Connection:rename(fr, to, cb)
  assert(fr)
  assert(to)
  self._command(self, "RNFR", fr, function(self, err, code, data)
    if err then return cb(self, err, code, data) end
    assert(code == 350)
    self._command(self, "RNTO", to, cb and ret_true(cb))
  end)
end

function Connection:rmd(arg, cb)
  assert(arg)
  self._command(self, "RMD", arg, cb and ret_true(cb))
end

function Connection:dele(arg, cb)
  assert(arg)
  self._command(self, "DELE", arg, cb and ret_true(cb))
end

function Connection:size(arg, cb)
  assert(arg)
  assert(cb)
  self._command(self, "SIZE", arg, function(self, err, code, data)
    if err then return cb(self, err) end
    return cb(self, nil, tonumber(data) or data)
  end)
end

function Connection:stat(arg, cb)
  if not cb then arg, cb = nil, arg end
  assert(cb)
  self._command(self, "STAT", arg, function(self, err, code, list)
    if err then
      if file_not_found(err) then return cb(self, nil, {}, err) end
      return cb(self, err)
    end
    if #list > 1 then table.remove(list, 1) end
    if #list > 1 then table.remove(list, #list) end
    cb(self, err, list)
  end)
end

function Connection:list(arg, cb)
  if not cb then arg, cb = nil, arg end
  assert(cb)
  return self:pasv_command("LIST", arg, list_cb(cb))
end

function Connection:nlst(arg, cb)
  if not cb then arg, cb = nil, arg end
  assert(cb)
  return self:pasv_command("NLST", arg, list_cb(cb))
end

function Connection:retr(fname, ...)
  assert(type(fname) == "string")

  local opt, cb = ...
  if type(opt) ~= "table" then
    return self:pasv_command("RETR", fname, ...)
  end

  return self:pasv_exec(function(self, err, ctx)
    if err then return ocall(cb, self, err) end
    ctx.cb = cb
    if opt.sink then
      ctx.chunk_cb = function(self, chunk) return opt.sink(chunk) end
      ctx.cb       = function(...) opt.sink() return ocall(cb, ...) end
    elseif opt.reader then
      ctx.chunk_cb = opt.reader
    end

    -- @todo check result of command
    if opt.type then self:_command("TYPE", opt.type) end

    -- @todo check result of command
    if opt.rest then self:_command("REST", opt.rest) end

    self:_command("RETR", fname, function(self, err, code, data)
      return ctx:control_done(err, code, data)
    end)
  end)
end

function Connection:stor(fname, opt, cb)
  self:pasv_exec(function(self, err, ctx)

    local write_cb, data
    if type(opt) == "table" then
      if opt.source then

        local on_write = function(cli, err)
          if err then return ctx:data_done(err) end
          return write_cb(self, cli)
        end

        write_cb = function(self, cli)
          local chunk = opt.source()
          if chunk then return cli:write(chunk, on_write) end
          return ctx:data_done()
        end

      else
        write_cb = assert(opt.writer)
      end
    else
      assert(type(opt) == "string")
      local data data, opt = opt, {}
      write_cb = function(self, cli)
        cli:write(data, function(cli, err)
          ctx:data_done(err)
        end)
      end
    end

    if err then return ocall(cb, err) end

    local cli = ctx:get_cli()
    ctx.cb = cb

    -- @todo check result of command
    if opt.type then self:_command("TYPE", opt.type) end

    self:_command("STOR", fname, 
      -- command
      function(self, err, code, data)
        return ctx:control_done(err, code, data)
      end,
  
    -- write
    function(self, code, reply)
      write_cb(self, cli)
    end)
  end)
end

end
-------------------------------------------------------------------

local function self_test(server, user, pass)
  local ltn12 = require "ltn12"

  local ftp = Connection.new(server, {
    uid = user,
    pwd = pass,
  })

  function ftp:on_error(err)
    print("<ERROR>", err)
  end

  -- function ftp:on_trace_control(line, send)
  --   print(send and "> " or "< ", trim(line))
  --   print("**************************")
  -- end

  -- function ftp:on_trace_req(req, code, reply)
  --   print("+", req.data, " GET ", code, reply)
  -- end

  ftp:open(function(self, err, code, data)
    if err then
      print("OPEN FAIL: ", err)
      return self:destroy()
    end

    local T
    local cur_test = 0
    local function next_test()
      if cur_test > 0 then
        print("Test #" .. cur_test .. " - pass")
      end
      cur_test = cur_test + 1
      ocall(T[cur_test])
    end

    local fname  = "testx.dat"
    local fname2 = "testxx.dat"
    
    local DATA  = "01234567890123456789"
    T = {
      function()
        self:stor(fname, DATA, function(self, err)
          assert(not err, tostring(err))
          self:mdtm(fname, function(self, err, data)
            assert(not err, tostring(err))
            assert(#data == 14, data)
            assert(data:find("^%d+"), data)
            self:retr(fname, function(self, err, code, data)
              assert(not err, tostring(err))
              assert(type(code) == "number", code)
              assert(type(data) == "table", data)
              data = table.concat(data)
              assert(data == DATA, data)
              next_test()
            end)
          end)
        end)
      end;

      function()
        self:stor(fname, DATA, function(self, err)
          assert(not err, tostring(err))
          self:retr(fname, {rest = 4}, function(self, err, code, data)
            assert(not err, tostring(err))
            assert(type(code) == "number", code)
            assert(type(data) == "table", data)
            data = table.concat(data)
            assert(data == DATA:sub(5), data)
            next_test()
          end)
        end)
      end;

      function()
        self:dele(fname)

        self:stor(fname, {source = ltn12.source.string(DATA)}, function(self, err)
          assert(not err, tostring(err))
        end)

        local t = {}
        self:retr(fname, {sink = ltn12.sink.table(t)}, function(self, err, code, data)
          assert(not err, tostring(err))
          assert(type(data) == "string", data) -- transferred successfully.
          data = table.concat(t)
          assert(data == DATA, data)

          next_test()
        end)
      end;

      function()
        self:stor(fname, DATA, function(self, err)
          self:dele(fname, function(self, err)
            assert(not err, tostring(err))
            self:dele(fname, function(self, err)
              assert(err)
              assert(err:name() == "ESTATE", tostring(err))
              next_test()
            end)
          end)
        end)
      end;

      function()
        self:dele(fname, function(self, err)
          self:list(fname, function(self, err, list)
            assert(not err, tostring(err))
            assert(type(list) == "table")
            assert(#list == 0)
            next_test()
          end)
        end)
      end;

      function()
        self:stor(fname, DATA, function(self, err)
          assert(not err, tostring(err))
          self:list(fname, function(self, err, list)
            assert(not err, tostring(err))
            assert(type(list) == "table")
            assert(#list == 1)
            next_test()
          end)
        end)
      end;

      function()
        self:dele(fname, function(self, err)
          self:stat(fname, function(self, err, list)
            assert(not err, tostring(err))
            assert(type(list) == "table")
            assert(#list == 0)
            next_test()
          end)
        end)
      end;

      function()
        self:stor(fname, DATA, function(self, err)
          assert(not err, tostring(err))
          self:stat(fname, function(self, err, list)
            assert(not err, tostring(err))
            assert(type(list) == "table")
            assert(#list == 1)
            next_test()
          end)
        end)
      end;

      function()
        self:stor(fname, DATA, function(self, err)
          assert(not err, tostring(err))
          self:dele(fname2)
          self:rename(fname, fname2, function()
            self:stat(fname, function(self, err, list)
              assert(not err, tostring(err))
              assert(type(list) == "table")
              assert(#list == 0)
              self:stat(fname2, function(self, err, list)
                assert(not err, tostring(err))
                assert(type(list) == "table")
                assert(#list == 1)
                next_test()
              end)
            end)
          end)
        end)
      end;

      function()
        local l1, l2

        self:list(function(self, err, list)
          assert(not err, tostring(err))
          assert(type(list) == "table")
          assert(#list > 0)
          l1 = list
        end)

        self:noop()

        self:list(function(self, err, list)
          assert(not err, tostring(err))
          assert(type(list) == "table")
          assert(#list > 0)
          l2 = list
        end)

        self:noop()

        self:list(function(self, err, list)
          assert(l1)
          assert(l2)
          assert(#l1 == #l2)
          table.sort(l1)
          table.sort(l2)
          for k, v in ipairs(l1) do
            assert(v == l2[k])
          end;
          next_test()
        end)

      end;

      function()
        self:dele(fname, function()
          self:dele(fname2, function()
            self:destroy()
          end)
        end)
      end;
    }
    next_test()
  end)

  uv.run(debug.traceback)
end

self_test("127.0.0.1", "moteus", "123456")

return {
  Connection = function(...) return Connection:new(...) end
}