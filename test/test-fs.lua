local RUN = lunit and function()end or function ()
  local res = lunit.run()
  if res.errors + res.failed > 0 then
    os.exit(-1)
  end
  return os.exit(0)
end

local lunit      = require "lunit"
local TEST_CASE  = assert(lunit.TEST_CASE)
local skip       = lunit.skip or function() end

local uv   = require "lluv"
local ut   = require "lluv.utils"
local fs   = require "lluv.cofs"
local path = require "path"
local io   = require "io"

local tostring = tostring

local TEST_FILE = "./test.txt"
local BAD_FILE  = "./test.bad"
local TEST_DATA = "0123456789"

local function mkfile(P, data)
  P = path.fullpath(P)
  path.mkdir(path.dirname(P))
  local f, e = io.open(P, "w+b")
  if not f then return nil, err end
  if data then assert(f:write(data)) end
  f:close()
  return P
end

local function rmfile(P)
  path.remove(P)
end

local function gc_collect(n)
  for i = 1, n or 5 do collectgarbage('collect') end
end

local select = select

local ENABLE = true

local _ENV = TEST_CASE'fs' if ENABLE then

local it = setmetatable(_ENV or _M, {__call = function(self, describe, fn)
  self["test " .. describe] = fn
end})

function setup()
  mkfile(TEST_FILE, TEST_DATA)
end

function teardown()
  rmfile(TEST_FILE)
end

it("stat sync", function()
  local t, err = assert_table(uv.fs_stat(TEST_FILE))
end)

it("stat async", function()
  local run_flag = false

  assert_true(uv.fs_stat(TEST_FILE, function(...)
    run_flag = true
    assert_equal(4, select("#", ...))
    local loop, err, stat, path = ...
    assert_userdata(loop)
    assert_nil(err)
    assert_table(stat)
    assert_string(path)
  end))

  assert_equal(0, uv.run())

  assert_true(run_flag)
end)

it("stat sync bad file", function()
  local _, err = assert_nil(uv.fs_stat(BAD_FILE))
end)

it("stat async bad file", function()
  local run_flag = false

  assert_true(uv.fs_stat(BAD_FILE, function(...)
    run_flag = true
    assert_equal(2, select("#", ...))
    local loop, err = ...
    assert_userdata(loop)
    assert_not_nil(err)
  end))

  assert_equal(0, uv.run())

  assert_true(run_flag)
end)

it("unlink sync", function()
  assert(path.exists(TEST_FILE))
  local t, err = assert_string(uv.fs_unlink(TEST_FILE))
  assert(not path.exists(TEST_FILE))
end)

it("unlink async", function()
  local run_flag = false

  assert(path.exists(TEST_FILE))

  assert_true(uv.fs_unlink(TEST_FILE, function(...)
    run_flag = true
    assert_equal(3, select("#", ...))
    local loop, err, path = ...
    assert_userdata(loop)
    assert_nil(err)
    assert_string(path)
  end))

  assert_equal(0, uv.run())

  assert_true(run_flag)
  assert(not path.exists(TEST_FILE))
end)

it("unlink sync bad file", function()
  local _, err = assert_nil(uv.fs_unlink(BAD_FILE))
end)

it("unlink async bad file", function()
  local run_flag = false

  assert_true(uv.fs_unlink(BAD_FILE, function(...)
    run_flag = true
    assert_equal(2, select("#", ...))
    local loop, err = ...
    assert_userdata(loop)
    assert_not_nil(err)
  end))

  assert_equal(0, uv.run())

  assert_true(run_flag)
end)

it("access without flag", function()
  assert(path.exists(TEST_FILE))
  assert_true(uv.fs_access(TEST_FILE))
  assert_equal(0, uv.run())
end)

it("access with string flag", function()
  assert(path.exists(TEST_FILE))
  assert_true(uv.fs_access(TEST_FILE, 'read'))
  assert_equal(0, uv.run())
end)

it("access with array flag", function()
  assert(path.exists(TEST_FILE))
  assert_true(uv.fs_access(TEST_FILE, {'read', 'write'}))
  assert_equal(0, uv.run())
end)

end

local _ENV = TEST_CASE'cofs' if ENABLE then

local it = setmetatable(_ENV or _M, {__call = function(self, describe, fn)
  self["test " .. describe] = fn
end})

local file, err

function setup()
  mkfile(TEST_FILE, TEST_DATA)
end

function teardown()
  if file and file._fd then file._fd:close() end
  file, err = nil

  gc_collect()

  rmfile(TEST_FILE)
end

it('open file', function()
  ut.corun(function()
    run_flag = true
    file, err = assert(fs.open(TEST_FILE, 'rb'))
    local data = assert_equal(TEST_DATA, file:read('*a'))
    assert(file:close())
  end)

  assert_equal(0, uv.run())
end)

it('type function', function()
  ut.corun(function()
    file, err = assert(fs.open(TEST_FILE, 'rb'))
    assert_equal('file', fs.type(file))
    assert(file:close())
    assert_equal('closed file', fs.type(file))
  end)

  assert_function(fs.type)
  assert_nil(fs.type(1))
  assert_nil(fs.type(' '))
  assert_nil(fs.type(nil))
  assert_nil(fs.type({}))
  local f = assert(io.open(TEST_FILE, 'rb'))
  f:close()
  assert_nil(fs.type(f))

  assert_equal(0, uv.run())
end)

it('file object to string', function()
  ut.corun(function()
    file, err = assert(fs.open(TEST_FILE, 'rb'))
    assert_match('file %([%xx]+%)$', tostring(file))
    assert(file:close())
    assert_match('file %(closed%)$', tostring(file))
  end)

  assert_equal(0, uv.run())
end)

end

RUN()
