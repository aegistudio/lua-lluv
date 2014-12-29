/******************************************************************************
* Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
*
* Copyright (C) 2014 Alexey Melnichuk <alexeymelnichuck@gmail.com>
*
* Licensed according to the included 'LICENSE' document
*
* This file is part of lua-lluv library.
******************************************************************************/

#ifndef _LLUV_UTILS_H_
#define _LLUV_UTILS_H_

#include <uv.h>
#include <lua.h>
#include "l52util.h"

typedef struct lluv_req_tag lluv_req_t;

typedef struct lluv_handle_tag lluv_handle_t;

typedef struct lluv_loop_tag lluv_loop_t;

#ifdef _WIN32
#  include <malloc.h>
#else
#  include <alloca.h>
#endif

#ifdef _MSC_VER
#  define lluv_alloca _malloca
#else
#  define lluv_alloca alloca
#endif

#define LLUV_LUA_REGISTRY        lua_upvalueindex(1)
#define LLUV_LUA_HANDLES         lua_upvalueindex(2)
#define LLUV_LOOP_INDEX          lua_upvalueindex(3)
#define LLUV_ERROR_HANDLER_INDEX lua_upvalueindex(4)
#define LLUV_ERROR_MARK_INDEX    lua_upvalueindex(5)
#define LLUV_NONE_MARK_INDEX     lua_upvalueindex(6)

extern const char *LLUV_MEMORY_ERROR_MARK;

typedef struct lluv_uv_const_tag{
  ssize_t     code;
  const char *name;
}lluv_uv_const_t;

LLUV_INTERNAL void* lluv_alloc(lua_State* L, size_t size);

LLUV_INTERNAL void lluv_free(lua_State* L, void *ptr);

#define lluv_alloc_t(L, T) (T*)lluv_alloc(L, sizeof(T))

#define lluv_free_t(L, T, ptr) lluv_free(L, ptr)

LLUV_INTERNAL int lluv_lua_call(lua_State* L, int narg, int nret);

LLUV_INTERNAL int lluv__index(lua_State *L, const char *meta, lua_CFunction inherit);

LLUV_INTERNAL void lluv_check_callable(lua_State *L, int idx);

LLUV_INTERNAL void lluv_check_none(lua_State *L, int idx);

/*
 Check if last argument is callback 
 and maximum number of arguments
*/
LLUV_INTERNAL void lluv_check_args_with_cb(lua_State *L, int n);

LLUV_INTERNAL void lluv_alloc_buffer_cb(uv_handle_t* handle, size_t suggested_size, uv_buf_t *buf);

LLUV_INTERNAL void lluv_free_buffer(uv_handle_t* handle, const uv_buf_t *buf);

LLUV_INTERNAL int lluv_to_addr(lua_State *L, const char *addr, int port, struct sockaddr_storage *sa);

LLUV_INTERNAL int lluv_check_addr(lua_State *L, int i, struct sockaddr_storage *sa);

LLUV_INTERNAL int lluv_push_addr(lua_State *L, const struct sockaddr_storage *addr);

LLUV_INTERNAL void lluv_push_stat(lua_State* L, const uv_stat_t* s);

LLUV_INTERNAL void lluv_stack_dump(lua_State* L, int top, const char* name);

LLUV_INTERNAL void lluv_value_dump(lua_State* L, int i, const char* prefix);

LLUV_INTERNAL void lluv_register_constants(lua_State* L, const lluv_uv_const_t* cons);

LLUV_INTERNAL unsigned int lluv_opt_flags_ui(lua_State *L, int idx, unsigned int d, const lluv_uv_const_t* names);

LLUV_INTERNAL ssize_t lluv_opt_named_const(lua_State *L, int idx, unsigned int d, const lluv_uv_const_t* names);

LLUV_INTERNAL void lluv_push_status(lua_State *L, int status);

LLUV_INTERNAL void lluv_push_timeval(lua_State *, const uv_timeval_t *tv);

LLUV_INTERNAL void lluv_push_timespec(lua_State *, const uv_timespec_t *ts);

LLUV_INTERNAL int lluv_return_req(lua_State *L, lluv_handle_t *handle, lluv_req_t *req, int err);

LLUV_INTERNAL int lluv_return_loop_req(lua_State *L, lluv_loop_t *loop, lluv_req_t *req, int err);

LLUV_INTERNAL int lluv_return(lua_State *L, lluv_handle_t *handle, int cb, int err);

LLUV_INTERNAL int lluv_new_weak_table(lua_State*L, const char *mode);

typedef unsigned char lluv_flag_t;

#define lluv_flags_t unsigned char

#define LLUV_FLAG_0  (lluv_flags_t)1<<0
#define LLUV_FLAG_1  (lluv_flags_t)1<<1
#define LLUV_FLAG_2  (lluv_flags_t)1<<2
#define LLUV_FLAG_3  (lluv_flags_t)1<<3
#define LLUV_FLAG_4  (lluv_flags_t)1<<4
#define LLUV_FLAG_5  (lluv_flags_t)1<<5
#define LLUV_FLAG_6  (lluv_flags_t)1<<6
#define LLUV_FLAG_7  (lluv_flags_t)1<<7

/*At least one flag*/
#define FLAG_IS_SET(O, F) (O->flags & (lluv_flags_t)(F))
/*All flags set*/
#define FLAGS_IS_SET(O, F) ((lluv_flags_t)(F) == (O->flags & (lluv_flags_t)(F)))

#define FLAG_SET(O, F)    O->flags |= (lluv_flags_t)(F)
#define FLAG_UNSET(O, F)  O->flags &= ~((lluv_flags_t)(F))

#define IS_(O, F)    FLAG_IS_SET(O, LLUV_FLAG_##F)
#define SET_(O, F)   FLAG_SET(O,    LLUV_FLAG_##F)
#define UNSET_(O, F) FLAG_UNSET(O,  LLUV_FLAG_##F)

#define IS(O, F)     FLAG_IS_SET(O, F)
#define SET(O, F)    FLAG_SET(O, F)
#define UNSET(O, F)  FLAG_UNSET(O, F)

#define LLUV_FLAG_OPEN         LLUV_FLAG_0
#define LLUV_FLAG_NOCLOSE      LLUV_FLAG_1
#define LLUV_FLAG_STREAM       LLUV_FLAG_2
#define LLUV_FLAG_DEFAULT_LOOP LLUV_FLAG_2
#define LLUV_FLAG_RAISE_ERROR  LLUV_FLAG_3
#define LLUV_FLAG_BUFFER_BUSY  LLUV_FLAG_4

#define INHERITE_FLAGS(O) (O->flags & (LLUV_FLAG_RAISE_ERROR))

#define LLUV_IMPL_SAFE(N)                                                                \
  static int N##_impl(lua_State *L, lluv_flags_t safe_flag);                             \
  static int N##_safe(lua_State *L){return N##_impl(L, 0);}                              \
  static int N##_unsafe(lua_State *L){return N##_impl(L, LLUV_FLAG_RAISE_ERROR);}        \
  static int N##_impl(lua_State *L, lluv_flags_t safe_flag)                              \

#define LLUV_IMPL_SAFE_(N)                                                               \
  static int N##_impl(lua_State *L, lluv_flags_t safe_flag);                             \
  LLUV_INTERNAL int N##_safe(lua_State *L){return N##_impl(L, 0);}                       \
  LLUV_INTERNAL int N##_unsafe(lua_State *L){return N##_impl(L, LLUV_FLAG_RAISE_ERROR);} \
  static int N##_impl(lua_State *L, lluv_flags_t safe_flag)                              \

#define UNUSED_ARG(arg) (void)arg

#endif
