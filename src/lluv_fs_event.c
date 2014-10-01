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
#include "lluv_fs_event.h"
#include "lluv_loop.h"
#include "lluv_error.h"
#include <assert.h>

#define LLUV_FS_EVENT_NAME LLUV_PREFIX" FS Event"
static const char *LLUV_FS_EVENT = LLUV_FS_EVENT_NAME;

LLUV_INTERNAL int lluv_fs_event_index(lua_State *L){
  return lluv__index(L, LLUV_FS_EVENT, lluv_handle_index);
}

static int lluv_fs_event_create(lua_State *L){
  lluv_loop_t *loop = lluv_opt_loop_ex(L, 1, LLUV_FLAG_OPEN);
  uv_fs_event_t *fs_event   = (uv_fs_event_t *)lluv_handle_create(L, UV_FS_EVENT, INHERITE_FLAGS(loop));
  int err = uv_fs_event_init(loop->handle, fs_event);
  if(err < 0){
    lluv_handle_cleanup(L, (lluv_handle_t*)fs_event->data);
    return lluv_fail(L, loop->flags, LLUV_ERR_UV, (uv_errno_t)err, NULL);
  }
  return 1;
}

static lluv_handle_t* lluv_check_fs_event(lua_State *L, int idx, lluv_flags_t flags){
  lluv_handle_t *handle = lluv_check_handle(L, idx, flags);
  luaL_argcheck (L, handle->handle->type == UV_FS_EVENT, idx, LLUV_FS_EVENT_NAME" expected");

  return handle;
}

static void lluv_on_fs_event_start(uv_fs_event_t *arg, const char* filename, int events, int status){
  lluv_handle_t *handle = arg->data;
  lua_State *L = handle->L;

  LLUV_CHECK_LOOP_CB_INVARIANT(L);

  lua_rawgeti(L, LLUV_LUA_REGISTRY, LLUV_START_CB(handle));
  assert(!lua_isnil(L, -1)); /* is callble */

  lua_rawgetp(L, LLUV_LUA_REGISTRY, handle->handle);
  if(status >= 0) lua_pushnil(L);
  else lluv_error_create(L, LLUV_ERR_UV, (uv_errno_t)status, NULL);

  if(filename)lua_pushstring(L, filename); else lua_pushnil(L);
  lua_pushinteger(L, events);

  lluv_lua_call(L, 4, 0);

  LLUV_CHECK_LOOP_CB_INVARIANT(L);
}

static int lluv_fs_event_start(lua_State *L){
  lluv_handle_t *handle = lluv_check_fs_event(L, 1, LLUV_FLAG_OPEN);
  const char *path   = luaL_checkstring(L, 2);
  unsigned int flags = 0;
  int err;

  if(lua_gettop(L) > 3) flags = luaL_optint(L, 3, 0);

  lluv_check_args_with_cb(L, 4);
  LLUV_START_CB(handle) = luaL_ref(L, LLUV_LUA_REGISTRY);

  err = uv_fs_event_start((uv_fs_event_t*)handle->handle, lluv_on_fs_event_start, path, flags);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_fs_event_stop(lua_State *L){
  lluv_handle_t *handle = lluv_check_fs_event(L, 1, LLUV_FLAG_OPEN);
  int err = uv_fs_event_stop((uv_fs_event_t*)handle->handle);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }
  lua_settop(L, 1);
  return 1;
}

static int lluv_fs_getpath(lua_State *L){
  lluv_handle_t  *handle = lluv_check_fs_event(L, 1, LLUV_FLAG_OPEN);
  char buf[255]; size_t len = sizeof(buf);
  int err = uv_fs_event_getpath((uv_fs_event_t *)handle->handle, buf, &len);
  if(err >= 0){
    lua_pushlstring(L, buf, len);
    return 1;
  }
  if(err != UV_ENOBUFS){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }
  {
    char *buf = lluv_alloc(L, len);
    if(!buf){
      return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
    }
    err = uv_fs_event_getpath((uv_fs_event_t *)handle->handle, buf, &len);
    if(err < 0){
      lluv_free(L, buf);
      return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
    }
    lua_pushlstring(L, buf, len);
    lluv_free(L, buf);
    return 1;
  }
}

static const struct luaL_Reg lluv_fs_event_methods[] = {
  { "start",      lluv_fs_event_start      },
  { "stop",       lluv_fs_event_stop       },
  { "getpath",    lluv_fs_getpath          },

  {NULL,NULL}
};

static const struct luaL_Reg lluv_fs_event_functions[] = {
  {"fs_event", lluv_fs_event_create},

  {NULL,NULL}
};

static const lluv_uv_const_t lluv_fs_event_constants[] = {
  { UV_RENAME,                "RENAME"                },
  { UV_CHANGE,                "CHANGE"                },
  { UV_FS_EVENT_WATCH_ENTRY,  "FS_EVENT_WATCH_ENTRY"  },
  { UV_FS_EVENT_STAT,         "FS_EVENT_STAT"         },
  { UV_FS_EVENT_RECURSIVE,    "FS_EVENT_RECURSIVE"    },

  { 0, NULL }
};

LLUV_INTERNAL void lluv_fs_event_initlib(lua_State *L, int nup){
  lutil_pushnvalues(L, nup);
  if(!lutil_createmetap(L, LLUV_FS_EVENT, lluv_fs_event_methods, nup))
    lua_pop(L, nup);
  lua_pop(L, 1);

  luaL_setfuncs(L, lluv_fs_event_functions, nup);
  lluv_register_constants(L, lluv_fs_event_constants);
}