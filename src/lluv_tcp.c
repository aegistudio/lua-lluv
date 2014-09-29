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
#include "lluv_stream.h"
#include "lluv_tcp.h"
#include "lluv_loop.h"
#include "lluv_error.h"
#include <assert.h>

LLUV_IMPLEMENT_XXX_REQ(connect)

#define LLUV_TCP_NAME LLUV_PREFIX" tcp"
static const char *LLUV_TCP = LLUV_TCP_NAME;

LLUV_INTERNAL int lluv_tcp_index(lua_State *L){
  return lluv__index(L, LLUV_TCP, lluv_stream_index);
}

static int lluv_tcp_create(lua_State *L){
  uv_tcp_t *tcp = (uv_tcp_t *)lluv_stream_create(L, UV_TCP);
  lluv_loop_t *loop  = lluv_opt_loop(L, 1, LLUV_FLAG_OPEN);
  int err;
  if(!loop) loop = lluv_default_loop(L);
  err = uv_tcp_init(loop->handle, tcp);
  if(err < 0){
    return lluv_fail(L, LLUV_ERROR_RETURN, LLUV_ERR_UV, (uv_errno_t)err, NULL);
  }
  return 1;
}

static lluv_handle_t* lluv_check_tcp(lua_State *L, int idx, lluv_flags_t flags){
  lluv_handle_t *handle = lluv_check_stream(L, idx, LLUV_FLAG_OPEN);
  luaL_argcheck (L, handle->handle->type == UV_TCP, idx, LLUV_TCP_NAME" expected");

  luaL_argcheck (L, FLAGS_IS_SET(handle, flags), idx, LLUV_TCP_NAME" closed");
  return handle;
}

//! @check move callback to handle module
static void lluv_on_tcp_connect_cb(uv_connect_t* arg, int status){
  lluv_connect_t *req = arg->data;
  lluv_handle_t *handle = req->handle;
  lua_State *L = handle->L;

  if(!IS_(handle, OPEN)){
    lluv_connect_free(L, req);
    return;
  }
  lua_rawgeti(L, LLUV_LUA_REGISTRY, req->cb);
  lluv_connect_free(L, req);

  lua_rawgetp(L, LLUV_LUA_REGISTRY, handle->handle);
  if(status >= 0) lua_pushnil(L);
  else lluv_error_create(L, LLUV_ERR_UV, (uv_errno_t)status, NULL);

  lluv_lua_call(L, 2, 0);
}

static int lluv_tcp_connect(lua_State *L){
  lluv_handle_t  *handle = lluv_check_tcp(L, 1, LLUV_FLAG_OPEN);
  const char *addr = luaL_checkstring(L, 2);
  lua_Integer port = luaL_checkint(L, 3);
  lluv_connect_t *req;
  struct sockaddr_storage sa;
  int err = lluv_to_addr(L, addr, port, &sa);
  
  if(err < 0){
    lua_settop(L, 3);
    lua_pushliteral(L, ":");lua_insert(L, -2);lua_concat(L, 3);
    return lluv_fail(L, LLUV_ERROR_RETURN, LLUV_ERR_UV, err, lua_tostring(L, -1));
  }

  lluv_check_args_with_cb(L, 4);

  req = lluv_connect_new(L, handle);
  req->cb = luaL_ref(L, LLUV_LUA_REGISTRY);

  err = uv_tcp_connect(&req->req, (uv_tcp_t*)handle->handle, (struct sockaddr *)&sa, lluv_on_tcp_connect_cb);
  if(err < 0){
    lua_settop(L, 3);
    lua_pushliteral(L, ":");lua_insert(L, -2);lua_concat(L, 3);
    return lluv_fail(L, LLUV_ERROR_RETURN, LLUV_ERR_UV, err, lua_tostring(L, -1));
  }

  lua_settop(L, 1);
  return 1;
}


static const struct luaL_Reg lluv_tcp_methods[] = {
  {"connect", lluv_tcp_connect},

  {NULL,NULL}
};

static const struct luaL_Reg lluv_tcp_functions[] = {
  { "tcp", lluv_tcp_create },

  {NULL,NULL}
};

LLUV_INTERNAL void lluv_tcp_initlib(lua_State *L, int nup){
  lutil_pushnvalues(L, nup);
  if(!lutil_createmetap(L, LLUV_TCP, lluv_tcp_methods, nup))
    lua_pop(L, nup);
  lua_pop(L, 1);

  luaL_setfuncs(L, lluv_tcp_functions, nup);
}
