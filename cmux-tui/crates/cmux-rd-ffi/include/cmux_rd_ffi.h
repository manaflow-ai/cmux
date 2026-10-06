/*
 * C ABI of the cmux remote desktop viewer core (crate cmux-rd-ffi).
 *
 * One receiver per display stream of a cmux.rd/1 session: the caller feeds
 * received bytes (overlay datagrams, or the bytes of the stream carrier) and
 * takes out complete access units, other messages and feedback datagrams.
 * The library does no I/O, starts no threads and never blocks. Every time is
 * the caller's monotonic clock in microseconds.
 *
 * A receiver is not thread-safe: call it from one thread or actor at a time.
 * Pointers returned in CmuxRdFrame and CmuxRdMessage stay valid only until the
 * next call on the same receiver; copy the bytes out first.
 *
 * Keep in sync with src/lib.rs (the crate's tests and the xcframework build
 * check that both declare the same functions and layouts).
 */
#ifndef CMUX_RD_FFI_H
#define CMUX_RD_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version of this ABI; bumped on every incompatible change. */
#define CMUX_RD_FFI_ABI_VERSION 1u

/* Carriers. */
#define CMUX_RD_CARRIER_DATAGRAM 0u
#define CMUX_RD_CARRIER_STREAM 1u

/* Message kinds (the stream carrier's frame types). */
#define CMUX_RD_MESSAGE_CONTROL 1u
#define CMUX_RD_MESSAGE_DATAGRAM 2u

/* Frame flags (the datagram header's flags). */
#define CMUX_RD_FLAG_KEYFRAME 0x01u
#define CMUX_RD_FLAG_REFINE 0x02u
#define CMUX_RD_FLAG_RECOVERY 0x04u

/* Return codes. Non-negative values are results. */
#define CMUX_RD_OK 0
#define CMUX_RD_ERR_NULL (-1)        /* a required pointer is NULL */
#define CMUX_RD_ERR_INVALID (-2)     /* the bytes are not valid cmux.rd/1 */
#define CMUX_RD_ERR_BUFFER (-3)      /* the output buffer is too small; *out_len holds the size needed */
#define CMUX_RD_ERR_CARRIER (-4)     /* the call does not match the receiver's carrier */
#define CMUX_RD_ERR_FAILED (-5)      /* the stream broke or the peer flooded; end the session */
#define CMUX_RD_ERR_PANIC (-6)       /* internal error; the receiver is unusable */
#define CMUX_RD_ERR_STREAM (-7)      /* the stream is not open, or the stream limit is reached */

/* Input event kinds (the wire tags). */
#define CMUX_RD_INPUT_KEY 1u
#define CMUX_RD_INPUT_POINTER 2u
#define CMUX_RD_INPUT_BUTTON 3u
#define CMUX_RD_INPUT_SCROLL 4u
#define CMUX_RD_INPUT_TEXT 5u
/* A service-defined event (0x80): text and text_len carry its opaque bytes,
   1 to CMUX_RD_INPUT_MAX_SERVICE. Send only when welcome lists "input.service". */
#define CMUX_RD_INPUT_SERVICE 128u
/* service_flags bit: repeat until acknowledged (like a key release). */
#define CMUX_RD_INPUT_MUST_DELIVER 1u
#define CMUX_RD_INPUT_MAX_SERVICE 1127u
/* Largest UTF-8 text of one text event, in bytes. */
#define CMUX_RD_INPUT_MAX_TEXT 256u
/* A buffer of this size holds every input packet on either carrier. */
#define CMUX_RD_INPUT_PACKET_MAX 1157u

typedef struct CmuxRdReceiver CmuxRdReceiver;
typedef struct CmuxRdInput CmuxRdInput;
typedef struct CmuxRdSession CmuxRdSession;

/* Most open streams per session. */
#define CMUX_RD_SESSION_MAX_STREAMS 16u

/* One complete access unit (Annex-B), ready to decode. */
typedef struct CmuxRdFrame {
    uint64_t t_capture_us;   /* host monotonic capture time */
    const uint8_t *data;     /* access unit bytes, valid until the next call */
    size_t len;
    uint32_t frame;          /* host frame number */
    uint32_t ref_frame;      /* referenced frame, UINT32_MAX for none */
    uint8_t flags;           /* CMUX_RD_FLAG_* */
} CmuxRdFrame;

/* A control message (JSON) or a non-video datagram (header included). */
typedef struct CmuxRdMessage {
    const uint8_t *data;     /* valid until the next call */
    size_t len;
    uint8_t kind;            /* CMUX_RD_MESSAGE_* */
} CmuxRdMessage;

/* Counters for the pane's status line. */
typedef struct CmuxRdStats {
    uint64_t frames_released;
    uint64_t frames_lost;
    uint32_t acked_frame;
    bool need_recovery;
} CmuxRdStats;

/* One viewer input event. Fields the kind does not use are ignored. */
typedef struct CmuxRdInputEvent {
    uint32_t kind;           /* CMUX_RD_INPUT_* */
    uint32_t usage;          /* key: USB HID usage, page << 16 | id */
    int32_t x;               /* pointer: absolute position in stream pixels */
    int32_t y;
    int32_t dx;              /* scroll: hundredths of a line, or of a point when precise */
    int32_t dy;
    const uint8_t *text;     /* text: UTF-8, 1 to CMUX_RD_INPUT_MAX_TEXT bytes; service: its bytes */
    size_t text_len;
    uint8_t button;          /* button: 1 left, 2 middle, 3 right, 8 back, 9 forward */
    uint8_t down;            /* key and button: 1 pressed, 0 released (other values refused) */
    uint8_t precise;         /* scroll: 1 pixel-precise deltas, 0 lines (other values refused) */
    uint8_t service_flags;   /* service: CMUX_RD_INPUT_MUST_DELIVER or 0 (other bits refused) */
} CmuxRdInputEvent;

uint32_t cmux_rd_ffi_abi_version(void);

/* Returns NULL for an unknown carrier. deadline_us: how long a frame may wait
   for missing shards; nack_after_us: how long before its gaps are NACKed. */
CmuxRdReceiver *cmux_rd_receiver_new(uint32_t carrier, uint64_t deadline_us, uint64_t nack_after_us);
void cmux_rd_receiver_free(CmuxRdReceiver *receiver);

/* Datagram carrier: one received datagram. Returns the number of frames ready. */
int32_t cmux_rd_receiver_push_datagram(CmuxRdReceiver *receiver, const uint8_t *bytes, size_t len, uint64_t now_us);
/* Stream carrier: received bytes in any chunks. Returns the number of frames ready. */
int32_t cmux_rd_receiver_push_stream(CmuxRdReceiver *receiver, const uint8_t *bytes, size_t len, uint64_t now_us);
/* Drops frames past their deadline. Returns the number of frames ready. */
int32_t cmux_rd_receiver_tick(CmuxRdReceiver *receiver, uint64_t now_us);

/* Returns 1 and fills *out with the oldest ready frame, or 0 when none is ready. */
int32_t cmux_rd_receiver_pop_frame(CmuxRdReceiver *receiver, CmuxRdFrame *out);
/* Returns 1 and fills *out with the oldest queued message, or 0 when none is queued. */
int32_t cmux_rd_receiver_pop_message(CmuxRdReceiver *receiver, CmuxRdMessage *out);

/* Records one decode time for the feedback. */
int32_t cmux_rd_receiver_note_decode(CmuxRdReceiver *receiver, uint32_t decode_us);
/* Asks the host for a keyframe in every feedback until one is released. */
int32_t cmux_rd_receiver_request_keyframe(CmuxRdReceiver *receiver);

/* Writes the next due feedback datagram (stream-framed on the stream carrier).
   Returns 1 when written, 0 when none is due. Call again until it returns 0. */
int32_t cmux_rd_receiver_feedback(CmuxRdReceiver *receiver, uint64_t now_us, uint8_t *out, size_t cap, size_t *out_len);
/* The time at which tick and feedback must run next (0 = now; UINT64_MAX for
   NULL or an unusable receiver). Arm one timer for it; nothing needs polling. */
uint64_t cmux_rd_receiver_next_deadline_us(const CmuxRdReceiver *receiver);
int32_t cmux_rd_receiver_stats(const CmuxRdReceiver *receiver, CmuxRdStats *out);

/* Frames a payload for the stream carrier (for example the viewer's control
   messages). kind is CMUX_RD_MESSAGE_*. */
int32_t cmux_rd_encode_stream_frame(uint32_t kind, const uint8_t *payload, size_t len, uint8_t *out, size_t cap, size_t *out_len);

/* Input channel: one per session. Events repeat in later packets until the
   host acknowledges them (key and button releases until acknowledged); the
   host applies each exactly once, in order. Not thread-safe, like a receiver. */

/* Returns NULL for an unknown carrier. resend_us: how long unacknowledged
   events wait before they go out again without new input (about one RTT). */
CmuxRdInput *cmux_rd_input_new(uint32_t carrier, uint64_t resend_us);
void cmux_rd_input_free(CmuxRdInput *input);
/* Queues one event; *out_seq (may be NULL) gets its sequence number.
   CMUX_RD_ERR_INVALID for an unknown kind or empty, too long or non-UTF-8 text. */
int32_t cmux_rd_input_push(CmuxRdInput *input, const CmuxRdInputEvent *event, uint32_t *out_seq);
/* Applies an InputAck datagram as cmux_rd_receiver_pop_message hands it out
   (kind CMUX_RD_MESSAGE_DATAGRAM, header included). CMUX_RD_ERR_INVALID for
   any other datagram, with no state change: offer every datagram message
   here and ignore that code. */
int32_t cmux_rd_input_ack(CmuxRdInput *input, const uint8_t *datagram, size_t len);
/* Writes the next due Input datagram (stream-framed on the stream carrier).
   Returns 1 when written, 0 when none is due. Call again until it returns 0.
   Every resend_us the window from the oldest unacknowledged event goes out
   again. *out_len is written on every path (0 when nothing was written). */
int32_t cmux_rd_input_packet(CmuxRdInput *input, uint64_t now_us, uint8_t *out, size_t cap, size_t *out_len);
/* The time at which cmux_rd_input_packet must run next (0 = now; UINT64_MAX
   when nothing is queued, for NULL, or for an unusable handle). */
uint64_t cmux_rd_input_next_deadline_us(const CmuxRdInput *input);

/* Session: every display stream of one cmux.rd/1 session (main surface,
   popups, tiles). Video and parity datagrams go to the reassembler of the
   stream their header names; feedback and keyframe requests are per stream.
   Only opened streams are accepted; stream 0 is open from the start. Other
   datagrams (InputAck, cursor, ...) and control messages are queued as
   messages. Use a session instead of a receiver when the host may open more
   than one stream. Not thread-safe. */

/* Returns NULL for an unknown carrier. Arguments as cmux_rd_receiver_new. */
CmuxRdSession *cmux_rd_session_new(uint32_t carrier, uint64_t deadline_us, uint64_t nack_after_us);
void cmux_rd_session_free(CmuxRdSession *session);
/* Accepts datagrams of stream from now on (idempotent). CMUX_RD_ERR_STREAM
   past CMUX_RD_SESSION_MAX_STREAMS open streams. */
int32_t cmux_rd_session_open_stream(CmuxRdSession *session, uint16_t stream);
/* Drops stream and its frames. CMUX_RD_ERR_STREAM when it is not open. */
int32_t cmux_rd_session_close_stream(CmuxRdSession *session, uint16_t stream);
/* Datagram carrier. Returns the frames ready in all streams;
   CMUX_RD_ERR_STREAM for a video datagram of a stream that is not open. */
int32_t cmux_rd_session_push_datagram(CmuxRdSession *session, const uint8_t *bytes, size_t len, uint64_t now_us);
/* Stream carrier: bytes in any chunks. Returns the frames ready. */
int32_t cmux_rd_session_push_stream(CmuxRdSession *session, const uint8_t *bytes, size_t len, uint64_t now_us);
int32_t cmux_rd_session_tick(CmuxRdSession *session, uint64_t now_us);
/* Returns 1 and fills *out and *out_stream with the oldest ready frame of any
   stream, or 0 when none is ready. */
int32_t cmux_rd_session_pop_frame(CmuxRdSession *session, CmuxRdFrame *out, uint16_t *out_stream);
int32_t cmux_rd_session_pop_message(CmuxRdSession *session, CmuxRdMessage *out);
int32_t cmux_rd_session_note_decode(CmuxRdSession *session, uint16_t stream, uint32_t decode_us);
int32_t cmux_rd_session_request_keyframe(CmuxRdSession *session, uint16_t stream);
/* Writes the next due feedback datagram of any stream (its header names the
   stream). Returns 1 when written, 0 when none is due; call again until 0.
   *out_len is written on every path. */
int32_t cmux_rd_session_feedback(CmuxRdSession *session, uint64_t now_us, uint8_t *out, size_t cap, size_t *out_len);
uint64_t cmux_rd_session_next_deadline_us(const CmuxRdSession *session);
int32_t cmux_rd_session_stats(const CmuxRdSession *session, uint16_t stream, CmuxRdStats *out);

#ifdef __cplusplus
}
#endif

#endif /* CMUX_RD_FFI_H */
