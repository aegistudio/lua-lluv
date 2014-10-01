/******************************************************************************
* Author: Alexey Melnichuk <mimir@newmail.ru>
*
* Copyright (C) 2014 Alexey Melnichuk <mimir@newmail.ru>
*
* Licensed according to the included 'LICENSE' document
*
* This file is part of lua-lluv library.
******************************************************************************/

#include "lluv.h"
#include "lluv_handle.h"
#include "lluv_idle.h"
#include "lluv_loop.h"
#include "lluv_error.h"
#include <assert.h>

#define LLUV_IDLE_NAME LLUV_PREFIX" Idle"
static const char *LLUV_IDLE = LLUV_IDLE_NAME;

LLUV_INTERNAL int lluv_idle_index(lua_State *L){
  return lluv__index(L, LLUV_IDLE, lluv_handle_index);
}

static int lluv_idle_create(lua_State *L){
  lluv_loop_t *loop = lluv_opt_loop_ex(L, 1, LLUV_FLAG_OPEN);
  uv_idle_t *idle   = (uv_idle_t *)lluv_handle_create(L, UV_IDLE, INHERITE_FLAGS(loop));
  int err = uv_idle_init(loop->handle, idle);
  if(err < 0){
    lluv_handle_cleanup(L, (lluv_handle_t*)idle->data);
    return lluv_fail(L, loop->flags, LLUV_ERR_UV, (uv_errno_t)err, NULL);
  }
  return 1;
}

static lluv_handle_t* lluv_check_idle(lua_State *L, int idx, lluv_flags_t flags){
  lluv_handle_t *handle = lluv_check_handle(L, idx, flags);
  luaL_argcheck (L, handle->handle->type == UV_IDLE, idx, LLUV_IDLE_NAME" expected");

  return handle;
}

static void lluv_on_idle_start(uv_idle_t *arg){
  lluv_handle_t *handle = arg->data;
  lua_State *L = handle->L;

  LLUV_CHECK_LOOP_CB_INVARIANT(L);

  lua_rawgeti(L, LLUV_LUA_REGISTRY, LLUV_START_CB(handle));
  assert(!lua_isnil(L, -1)); /* is callble */

  lua_rawgetp(L, LLUV_LUA_REGISTRY, arg);
  lluv_lua_call(L, 1, 0);

  LLUV_CHECK_LOOP_CB_INVARIANT(L);
}

static int lluv_idle_start(lua_State *L){
  lluv_handle_t *handle = lluv_check_idle(L, 1, LLUV_FLAG_OPEN);
  int err;

  lluv_check_args_with_cb(L, 2);
  LLUV_START_CB(handle) = luaL_ref(L, LLUV_LUA_REGISTRY);

  err = uv_idle_start((uv_idle_t*)handle->handle, lluv_on_idle_start);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_idle_stop(lua_State *L){
  lluv_handle_t *handle = lluv_check_idle(L, 1, LLUV_FLAG_OPEN);
  int err = uv_idle_stop((uv_idle_t*)handle->handle);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }
  lua_settop(L, 1);
  return 1;
}

static const struct luaL_Reg lluv_idle_methods[] = {
  { "start",      lluv_idle_start      },
  { "stop",       lluv_idle_stop       },

  {NULL,NULL}
};

static const struct luaL_Reg lluv_idle_functions[] = {
  {"idle", lluv_idle_create},

  {NULL,NULL}
};

LLUV_INTERNAL void lluv_idle_initlib(lua_State *L, int nup){
  lutil_pushnvalues(L, nup);
  if(!lutil_createmetap(L, LLUV_IDLE, lluv_idle_methods, nup))
    lua_pop(L, nup);
  lua_pop(L, 1);

  luaL_setfuncs(L, lluv_idle_functions, nup);
}
