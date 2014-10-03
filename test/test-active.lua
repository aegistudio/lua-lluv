local uv = require "lluv"

local close_cb_called = 0;
local timer

local function close_cb(handle)
  close_cb_called = close_cb_called  + 1
  assert(handle == timer)
  assert(timer:closed())
end

local function timer_cb(handle)
  assert(false, "timer_cb should not have been called");
end

timer = assert(uv.timer())

assert(false == timer:is_active());
assert(false == timer:is_closing());
assert(false == timer:closed());

assert(timer:start(1000, 0, timer_cb));

assert(true  == timer:is_active());
assert(false == timer:is_closing());
assert(false == timer:closed());

assert(timer:stop())

assert(false == timer:is_active());
assert(false == timer:is_closing());
assert(false == timer:closed());

assert(timer:start(1000, 0, timer_cb));

assert(true  == timer:is_active());
assert(false == timer:is_closing());
assert(false == timer:closed());

assert(timer:close(close_cb))

assert(false == timer:is_active());
assert(true  == timer:is_closing());
assert(false == timer:closed());

assert(0 == uv.run());

assert(close_cb_called == 1);
assert(true == timer:closed());


