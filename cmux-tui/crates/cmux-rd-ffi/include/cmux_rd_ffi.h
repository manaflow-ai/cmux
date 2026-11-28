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
#define CMUX_RD_FFI_ABI_VERSION 4u

/* Carriers. */
#define CMUX_RD_CARRIER_DATAGRAM 0u
#define CMUX_RD_CARRIER_STREAM 1u

/* Message kinds (the stream carrier's frame types). */
#define CMUX_RD_MESSAGE_CONTROL 1u
#define CMUX_RD_MESSAGE_DATAGRAM 2u
/* A bulk chunk (rd change C5, cap "bulk"): u64 transfer, u64 offset, bytes. */
#define CMUX_RD_MESSAGE_BULK 3u

/* Frame flags (the datagram header's flags). */
#define CMUX_RD_FLAG_KEYFRAME 0x01u
#define CMUX_RD_FLAG_REFINE 0x02u
#define CMUX_RD_FLAG_RECOVERY 0x04u
#define CMUX_RD_FLAG_TILE 0x08u      /* lossless tile top-off (tile streams, cap "tile"); ref_frame names the surface stream's video frame */

/* Return codes. Non-negative values are results. */
#define CMUX_RD_OK 0
#define CMUX_RD_ERR_NULL (-1)        /* a required pointer is NULL */
#define CMUX_RD_ERR_INVALID (-2)     /* the bytes are not valid cmux.rd/1 */
#define CMUX_RD_ERR_BUFFER (-3)      /* the output buffer is too small; *out_len holds the size needed */
#define CMUX_RD_ERR_CARRIER (-4)     /* the call does not match the receiver's carrier */
#define CMUX_RD_ERR_FAILED (-5)      /* the stream broke or the peer flooded; end the session */
#define CMUX_RD_ERR_PANIC (-6)       /* internal error; the receiver is unusable */
#define CMUX_RD_ERR_STREAM (-7)      /* the stream is not open, or the stream limit is reached */
#define CMUX_RD_ERR_CONSENT (-8)     /* the upstream sender has no consent for its media kind */
#define CMUX_RD_ERR_FULL (-9)        /* a bulk queue or the open transfer limit is full */

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
/* Starts session clock probes (rd change C8). Call only when welcome lists
   the "clock" cap: an older host refuses the probe kinds. Pings then leave
   through cmux_rd_session_feedback; pongs are consumed, not queued. */
int32_t cmux_rd_session_enable_clock(CmuxRdSession *session);
/* The offset of the host's clock from this viewer's (host = viewer +
   *offset_us) and the round trip of the best sample: 1 when an estimate
   exists, 0 before the first answer. */
int32_t cmux_rd_session_clock(const CmuxRdSession *session, int64_t *offset_us, uint32_t *rtt_us);

/* ---- Upstream media sender (rd change C4b, cap "up_media", ABI 3) ----
   One sender per upstream stream (microphone, camera, screen share) the host
   registered. Encoded frames go in; UpMedia datagrams come out with adaptive
   FEC. The host's upstream feedback (acked frame, NACKs, arrival times)
   drives delay-based congestion control, a pacing budget at the target
   bitrate, NACK resends and keyframe requests. Nothing is queued to catch
   up: a frame over the budget is dropped and the sender asks for a
   keyframe; dependent frames are then dropped until an independent one.
   Consent: a sender is created for one media kind and sends nothing until
   the app grants that kind's consent with cmux_rd_upstream_set_consent,
   which it calls only after an explicit user action in this session.
   Without consent send_frame and on_datagram return CMUX_RD_ERR_CONSENT and
   emit nothing. Revoking drops untaken datagrams. Consent ends when the
   sender is freed; a new sender (a new session) starts without it.
   Not thread-safe, like a session. */
typedef struct CmuxRdUpstream CmuxRdUpstream;

/* Path classes (transport.md section 4); CMUX_RD_PATH_DO_RELAY caps the rate. */
#define CMUX_RD_PATH_DIRECT_LAN 0u
#define CMUX_RD_PATH_DIRECT_WAN 1u
#define CMUX_RD_PATH_VIA_CLOUD_REGION 2u
#define CMUX_RD_PATH_DO_RELAY 3u
/* Media kinds; each needs its own consent. */
#define CMUX_RD_MEDIA_MIC 1u
#define CMUX_RD_MEDIA_CAMERA 2u
#define CMUX_RD_MEDIA_SCREEN 3u
/* Bytes of untaken datagrams after which new frames are dropped. */
#define CMUX_RD_UPSTREAM_MAX_QUEUED 4194304u

/* Counters for the status line. */
typedef struct CmuxRdUpstreamStats {
    uint64_t frames_sent;
    uint64_t frames_dropped;
    uint32_t acked_frame;    /* newest frame the host completed, 0 for none */
    uint32_t loss_ppm;       /* smoothed loss, parts per million */
    bool keyframe_requested; /* make the next frame independent */
    bool consent;            /* the app granted consent for this kind */
} CmuxRdUpstreamStats;

/* A sender of media kind (CMUX_RD_MEDIA_*), without consent. NULL for an
   unknown carrier, kind or path, max_datagram outside 64..9000 (use
   the link's, 1152 or 1332), or min_bps > max_bps. A bitrate of 0 takes the
   default (start 8, floor 1, ceiling 80 Mbit/s). fec: block FEC on a lossy
   path; pass false for Opus audio, which has in-band FEC. */
CmuxRdUpstream *cmux_rd_upstream_new(uint32_t carrier, uint16_t stream, uint32_t kind, uint32_t max_datagram, uint32_t path,
                                     uint64_t start_bps, uint64_t min_bps, uint64_t max_bps, bool fec);
void cmux_rd_upstream_free(CmuxRdUpstream *upstream);
/* Grants or revokes consent for the sender's own media kind (other kinds:
   CMUX_RD_ERR_INVALID). Revoking drops every datagram not yet taken. */
int32_t cmux_rd_upstream_set_consent(CmuxRdUpstream *upstream, uint32_t kind, bool granted);
/* Sends one encoded frame (an access unit or an Opus packet) captured at
   t_capture_us. independent: references no earlier frame (keyframes, every
   audio packet); other frames reference the previous frame sent. Returns
   the datagrams queued, 0 when the frame was dropped (over the pacing
   budget, dependent on a dropped frame, or CMUX_RD_UPSTREAM_MAX_QUEUED bytes
   are waiting), CMUX_RD_ERR_CONSENT without consent (nothing queued),
   CMUX_RD_ERR_INVALID for a frame too large to send. */
int32_t cmux_rd_upstream_send_frame(CmuxRdUpstream *upstream, const uint8_t *data, size_t len,
                                    uint64_t t_capture_us, bool independent, uint64_t now_us);
/* Offers one datagram from the host (a session's CMUX_RD_MESSAGE_DATAGRAM
   message, header included). Returns the resent datagrams queued
   (CMUX_RD_ERR_CONSENT and none without consent);
   CMUX_RD_ERR_STREAM when it is not feedback for this stream (offer it to
   the next sender; also for a datagram kind this build does not know),
   CMUX_RD_ERR_INVALID for bad bytes. */
int32_t cmux_rd_upstream_on_datagram(CmuxRdUpstream *upstream, const uint8_t *bytes, size_t len, uint64_t now_us);
/* Writes the oldest queued datagram (stream-framed on the stream carrier):
   1 when written, 0 when none is queued, CMUX_RD_ERR_BUFFER (*out_len = size
   needed) when cap is too small; it then stays queued. Call after every
   send_frame and on_datagram until 0. *out_len is written on every path. */
int32_t cmux_rd_upstream_pop_datagram(CmuxRdUpstream *upstream, uint8_t *out, size_t cap, size_t *out_len);
/* The bitrate the encoder should aim for now; the floor while the host has
   been silent for 500 ms with a frame unacknowledged. 0 for NULL. */
uint64_t cmux_rd_upstream_target_bps(const CmuxRdUpstream *upstream, uint64_t now_us);
/* Reports a path change (CMUX_RD_PATH_*); CMUX_RD_ERR_INVALID for others. */
int32_t cmux_rd_upstream_set_path(CmuxRdUpstream *upstream, uint32_t path);
int32_t cmux_rd_upstream_stats(const CmuxRdUpstream *upstream, CmuxRdUpstreamStats *out);

/* ---- Bulk flow control (rd change C5, cap "bulk", ABI 4) ----
   The viewer's side of bulk transfers (a service's file uploads and
   downloads on the stream carrier), the same flow control the host runs.
   Upload: queue a transfer's bytes; pop_frame gives at most one 64 KiB
   chunk per media frame interval, none while a media frame waits for the
   carrier, and never past the host's credit (bulk_credit control messages:
   offer each CMUX_RD_MESSAGE_CONTROL payload to on_control). Download: offer
   each CMUX_RD_MESSAGE_BULK payload to accept; it checks order and credit
   and returns the framed bulk_credit to send back when one is due. Send
   bulk only when welcome lists the "bulk" cap. Not thread-safe; a panic
   poisons only that handle. */
typedef struct CmuxRdBulkSender CmuxRdBulkSender;
typedef struct CmuxRdBulkReceiver CmuxRdBulkReceiver;

/* Bytes of queued, unsent upload data a sender holds. */
#define CMUX_RD_BULK_MAX_QUEUED 67108864u
/* Transfers a receiver tracks at once (finish frees a slot). */
#define CMUX_RD_BULK_MAX_TRANSFERS 64u
/* The largest framed chunk pop_frame writes (5 + 16 + 65520 bytes). */
#define CMUX_RD_BULK_FRAME_MAX 65541u
/* A credit buffer this large always holds a framed bulk_credit. */
#define CMUX_RD_BULK_CREDIT_MAX 128u

/* One accepted download chunk; bytes points into the caller's payload. */
typedef struct CmuxRdBulkChunk {
    uint64_t transfer;
    uint64_t offset;
    const uint8_t *bytes;
    size_t len;
} CmuxRdBulkChunk;

/* A sender with at most one chunk per interval_us (the media frame
   interval); NULL for 0. */
CmuxRdBulkSender *cmux_rd_bulk_sender_new(uint64_t interval_us);
void cmux_rd_bulk_sender_free(CmuxRdBulkSender *sender);
/* Queues a transfer's bytes (copied). CMUX_RD_ERR_INVALID for a transfer id
   already queued, CMUX_RD_ERR_FULL past CMUX_RD_BULK_MAX_QUEUED. */
int32_t cmux_rd_bulk_sender_queue(CmuxRdBulkSender *sender, uint64_t transfer, const uint8_t *data, size_t len);
/* Applies the host's credit (credit only grows). */
int32_t cmux_rd_bulk_sender_on_credit(CmuxRdBulkSender *sender, uint64_t transfer, uint64_t offset);
/* Offers a control message payload: 1 when it was a bulk_credit and was
   applied, 0 for another message, CMUX_RD_ERR_INVALID for a bulk_credit
   without its fields. */
int32_t cmux_rd_bulk_sender_on_control(CmuxRdBulkSender *sender, const uint8_t *json, size_t len);
/* Drops a queued transfer (the user cancelled it). */
int32_t cmux_rd_bulk_sender_cancel(CmuxRdBulkSender *sender, uint64_t transfer);
/* Writes the next chunk as a stream frame (type 3): 1 when written, 0 when
   none may go now, CMUX_RD_ERR_BUFFER (*out_len = size needed) when cap is
   too small; the chunk then stays pending. *out_len is written on every path. */
int32_t cmux_rd_bulk_sender_pop_frame(CmuxRdBulkSender *sender, uint64_t now_us, bool media_waiting,
                                      uint8_t *out, size_t cap, size_t *out_len);
/* When pop_frame can give a chunk next (0 when one is pending); UINT64_MAX
   when idle or waiting for credit, for NULL or an unusable sender. */
uint64_t cmux_rd_bulk_sender_next_deadline_us(const CmuxRdBulkSender *sender);
/* Bytes of queued upload data not yet sent (0 for NULL). */
uint64_t cmux_rd_bulk_sender_queued_bytes(const CmuxRdBulkSender *sender);

CmuxRdBulkReceiver *cmux_rd_bulk_receiver_new(void);
void cmux_rd_bulk_receiver_free(CmuxRdBulkReceiver *receiver);
/* Takes one chunk (a CMUX_RD_MESSAGE_BULK payload) and fills *out. When a
   credit is due it writes the framed bulk_credit control message to
   credit_out (send it as is) and sets *credit_len, else *credit_len = 0.
   credit_cap below CMUX_RD_BULK_CREDIT_MAX: CMUX_RD_ERR_BUFFER, nothing
   taken. CMUX_RD_ERR_INVALID for bad bytes, a gap, an overlap, a chunk past
   the credit or a finished transfer (a protocol error: end the session);
   CMUX_RD_ERR_FULL for a new transfer while CMUX_RD_BULK_MAX_TRANSFERS are open. */
int32_t cmux_rd_bulk_receiver_accept(CmuxRdBulkReceiver *receiver, const uint8_t *payload, size_t len,
                                     CmuxRdBulkChunk *out, uint8_t *credit_out, size_t credit_cap, size_t *credit_len);
/* Ends a transfer (complete or cancelled): later chunks are refused. */
int32_t cmux_rd_bulk_receiver_finish(CmuxRdBulkReceiver *receiver, uint64_t transfer);

/* ---- Remote browser tab client (cmux.rb/1 viewer reducer, ABI 2) ----
   One client per rb session of a remote tab: make a new one for each rb.open
   (tokens and screen seqs restart per session). Inputs and outcomes are JSON in the shapes of
   schemas/remote-tab/client.json: an input is {"op": ...}; the outcome is
   {"effects": [...], "note": null|"...", "reject": null|"..."}. A reject
   leaves the state unchanged. The outcome bytes stay valid until the next
   call on the same client. No I/O, no threads; a panic poisons the client. */
typedef struct CmuxRbClient CmuxRbClient;

/* NULL only when allocation fails. */
CmuxRbClient *cmux_rb_client_new(void);
/* NULL is ignored. */
void cmux_rb_client_free(CmuxRbClient *client);
/* Applies one input. CMUX_RD_OK with *outcome and *outcome_len set;
   CMUX_RD_ERR_INVALID when json is not a client input (state unchanged). */
int32_t cmux_rb_client_apply(CmuxRbClient *client, const uint8_t *json, size_t json_len,
                             const uint8_t **outcome, size_t *outcome_len);

#ifdef __cplusplus
}
#endif

#endif /* CMUX_RD_FFI_H */
