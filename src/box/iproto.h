#ifndef TARANTOOL_IPROTO_H_INCLUDED
#define TARANTOOL_IPROTO_H_INCLUDED
/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <stddef.h>

#include "box/box.h"

struct uri_set;
struct session;

#if defined(__cplusplus)
extern "C" {
#endif /* defined(__cplusplus) */

enum {
	/** The minimal value for net_msg_max. */
	IPROTO_MSG_MAX_MIN = 2,
	/**
	 * The size of tx fiber pool for iproto requests is
	 * limited by the number of concurrent iproto messages,
	 * with the ratio defined in this constant.
	 * The ratio is not 1:1 because of long-polling requests.
	 * Ideally we should not account long polling requests in
	 * the ratio, but currently we can not separate them from
	 * short-living requests, all requests are handled by the
	 * same pool. When the pool size is exhausted, message
	 * processing stops until some new fibers are freed up.
	 */
	IPROTO_FIBER_POOL_SIZE_FACTOR = 5,
	/** Maximum count of iproto threads. */
	IPROTO_THREADS_MAX = 1000,
};

struct iproto_stats {
	/** Size of memory used for storing network buffers. */
	size_t mem_used;
	/** Number of active iproto connections. */
	size_t connections;
	/** Number of active iproto streams. */
	size_t streams;
	/** Number of iproto requests in flight. */
	size_t requests;
	/** Count of requests currently processing in tx thread. */
	size_t requests_in_progress;
	/** Count of requests currently pending in stream queue. */
	size_t requests_in_stream_queue;
};

extern unsigned iproto_readahead;
extern int iproto_threads_count;

/**
 * Return total iproto statistic.
 */
void
iproto_stats_get(struct iproto_stats *stats);

/**
 * Return total iproto statistic for
 * the thread with the given id.
 */
void
iproto_thread_stats_get(struct iproto_stats *stats, int thread_id);

/**
 * Reset network statistics.
 */
void
iproto_reset_stat(void);

/**
 * Return count of the addresses currently served by iproto.
 */
int
iproto_addr_count(void);

/**
 * Return representation of the address served by iproto by
 * it's @a idx. @a buf should have at least SERVICE_NAME_MAXLEN
 * size.
 */
const char *
iproto_addr_str(char *buf, int idx);

int
iproto_rmean_foreach(void *cb, void *cb_ctx);

/**
 * Same as iproto_rmean_foreach, but reports stats
 * only for the thread with the given id.
 */
int
iproto_thread_rmean_foreach(int thread_id, void *cb, void *cb_ctx);

/**
 * Sets an IPROTO request handler with the provided callback, destructor and
 * context for the given request type.
 * Passing a NULL callback resets the corresponding request handler.
 * Returns 0 on success, a non-zero value on error (diagnostic is set).
 */
int
iproto_override(uint32_t req_type, iproto_handler_t cb,
		iproto_handler_destroy_t destroy, void *ctx);

#if defined(__cplusplus)
} /* extern "C" */

void
iproto_init(int threads_count);

int
iproto_listen(const struct uri_set *uri_set);

void
iproto_set_msg_max(int iproto_msg_max);

/**
 * Sends a packet with the given header and body over the IPROTO session's
 * socket.
 * On success, a packet is written to the session's output buffer, which is
 * flushed asynchronously using Kharon.
 * Returns 0 on success, a non-zero value otherwise (diagnostic is set).
 */
int
iproto_session_send(struct session *session,
		    const char *header, const char *header_end,
		    const char *body, const char *body_end);

void
iproto_free(void);

#endif /* defined(__cplusplus) */

#endif