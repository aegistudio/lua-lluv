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
#include "lluv_error.h"
#include "lluv_loop.h"
#include "lluv_handle.h"
#include "lluv_loop.h"
#include <assert.h>

const char *LLUV_MEMORY_ERROR_MARK = LLUV_PREFIX" Error mark";

LLUV_INTERNAL void* lluv_alloc(lua_State* L, size_t size){
  (void)L;
  return malloc(size);
}

LLUV_INTERNAL void lluv_free(lua_State* L, void *ptr){
  (void)L;
  free(ptr);
}

LLUV_INTERNAL int lluv_lua_call(lua_State* L, int narg, int nret){
  int error_handler = lua_isnil(L, LLUV_ERROR_HANDLER_INDEX) ? 0 : LLUV_ERROR_HANDLER_INDEX;
  int ret = lua_pcall(L, narg, nret, error_handler);
 
  if(!ret) return 0;

  if(ret == LUA_ERRMEM) lua_pushlightuserdata(L, (void*)LLUV_MEMORY_ERROR_MARK);
  lua_replace(L, LLUV_ERROR_MARK_INDEX);
  {
    lluv_loop_t* loop = lluv_opt_loop(L, LLUV_LOOP_INDEX, 0);
    uv_stop(loop->handle);
  }
  return ret;
}

LLUV_INTERNAL int lluv__index(lua_State *L, const char *meta, lua_CFunction inherit){
  assert(lua_gettop(L) == 2);

  lutil_getmetatablep(L, meta);
  lua_pushvalue(L, 2); lua_rawget(L, -2);
  if(!lua_isnil(L, -1)) return 1;
  lua_settop(L, 2);
  if(inherit) return inherit(L);
  return 0;
}

LLUV_INTERNAL void lluv_check_callable(lua_State *L, int idx){
  idx = lua_absindex(L, idx);
  luaL_checktype(L, idx, LUA_TFUNCTION);
}

LLUV_INTERNAL void lluv_check_none(lua_State *L, int idx){
  idx = lua_absindex(L, idx);
  luaL_argcheck (L, lua_isnone(L, idx), idx, "too many parameters");
}

LLUV_INTERNAL void lluv_check_args_with_cb(lua_State *L, int n){
  lluv_check_none(L, n + 1);
  lluv_check_callable(L, -1);
}

static lluv_loop_t* lluv_loop_by_handle(uv_handle_t* h){
  lluv_handle_t *handle = h->data;
  lluv_loop_t *loop;
  lua_rawgetp(handle->L, LLUV_LUA_REGISTRY, handle->handle->loop);
  loop = lluv_check_loop(handle->L, -1, LLUV_FLAG_OPEN);
  lua_pop(handle->L, 1);

  return loop;
}

LLUV_INTERNAL void lluv_alloc_buffer_cb(uv_handle_t* h, size_t suggested_size, uv_buf_t *buf){
  lluv_loop_t* loop     = lluv_loop_by_handle(h);
  lluv_handle_t *handle = h->data;

  if(!IS_(loop, BUFFER_BUSY)){
    SET_(loop, BUFFER_BUSY);
    buf->base = loop->buffer; buf->len = loop->buffer_size;
  }
  else{
    *buf = uv_buf_init(lluv_alloc(handle->L, suggested_size), suggested_size);
  }
}

LLUV_INTERNAL void lluv_free_buffer(uv_handle_t* h, const uv_buf_t *buf){
  if(buf->base){
    lluv_loop_t* loop     = lluv_loop_by_handle(h);
    lluv_handle_t *handle = h->data;
    if(buf->base == loop->buffer){
      assert(IS_(loop, BUFFER_BUSY));
      UNSET_(loop, BUFFER_BUSY);
    }
    else{
      lluv_free(handle->L, &buf->base[0]);
    }
  }
}

LLUV_INTERNAL int lluv_to_addr(lua_State *L, const char *addr, int port, struct sockaddr_storage *sa){
  int err;

  UNUSED_ARG(L);

  memset(sa, 0, sizeof(*sa));

  err = uv_ip4_addr(addr, port, (struct sockaddr_in*)sa);
  if(err < 0){
    err = uv_ip6_addr(addr, port, (struct sockaddr_in6*)sa);
  }
  return err;
}

LLUV_INTERNAL int lluv_push_addr(lua_State *L, struct sockaddr_storage *addr){
  char buf[INET6_ADDRSTRLEN + 1];

  switch (((struct sockaddr*)addr)->sa_family){
    case AF_INET:{
      struct sockaddr_in *sa = (struct sockaddr_in*)addr;
      uv_ip4_name(sa, buf, sizeof(buf));
      lua_pushstring(L, buf);
      lua_pushinteger(L, ntohs(sa->sin_port));
      return 2;
    }

    case AF_INET6:{
      struct sockaddr_in6 *sa = (struct sockaddr_in6*)addr;
      uv_ip6_name(sa, buf, sizeof(buf));
      lua_pushstring(L, buf);
      lua_pushinteger(L, ntohs(sa->sin6_port));
      lutil_pushint64(L, ntohl(sa->sin6_flowinfo));
      lutil_pushint64(L, sa->sin6_scope_id);
      return 4;
    }
  }

  return 0;
}

static const char* lluv_to_string(lua_State *L, int idx){
  idx = lua_absindex(L, idx);
  lua_getglobal(L, "tostring");
  lua_pushvalue(L, idx);
  lua_call(L, 1, 1);
  return lua_tostring(L, -1);
}

LLUV_INTERNAL void lluv_value_dump(lua_State* L, int i, const char* prefix) {
  const char* tname = lua_typename(L, lua_type(L, i));
  if(!prefix){
    static const char *tab = "  ";
    prefix = tab;
  }
  switch (lua_type(L, i)) {
    case LUA_TNIL:
      printf("%s%d: %s\n",     prefix, i, tname);
      break;
    case LUA_TNUMBER:
      printf("%s%d: %s\t%f\n", prefix, i, tname, lua_tonumber(L, i));
      break;
    case LUA_TBOOLEAN:
      printf("%s%d: %s\n\t%s", prefix, i, tname, lua_toboolean(L, i) ? "true" : "false");
      break;
    case LUA_TSTRING:
      printf("%s%d: %s\t%s\n", prefix, i, tname, lua_tostring(L, i));
      break;
    case LUA_TTABLE:
      printf("%s%d: %s\n",     prefix, i, lluv_to_string(L, i)); lua_pop(L, 1);
      break;
    case LUA_TFUNCTION:
      printf("%s%d: %s\t%p\n", prefix, i, tname, lua_tocfunction(L, i));
      break;
    case LUA_TUSERDATA:
      printf("%s%d: %s\t%s\n", prefix, i, tname, lluv_to_string(L, i)); lua_pop(L, 1);
      break;
    case LUA_TTHREAD:
      printf("%s%d: %s\t%p\n", prefix, i, tname, lua_tothread(L, i));
      break;
    case LUA_TLIGHTUSERDATA:
      printf("%s%d: %s\t%p\n", prefix, i, tname, lua_touserdata(L, i));
      break;
  }
}

LLUV_INTERNAL void lluv_stack_dump(lua_State* L, int top, const char* name) {
  int i, l;
  printf("\n" LLUV_PREFIX " API STACK DUMP: %s\n", name);
  for (i = top, l = lua_gettop(L); i <= l; i++) {
    lluv_value_dump(L, i, "  ");
  }
  printf("\n");
}

