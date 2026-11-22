//! C ABI of the viewer's bulk flow control (`CmuxRdBulkSender` and
//! `CmuxRdBulkReceiver` in `include/cmux_rd_ffi.h`, rd change C5): the same
//! cmux-rd-core `BulkSender` and `BulkReceiver` the host runs, so an upload
//! never sends past the host's credit and never more than one 64 KiB chunk
//! per media frame interval, and a download grants credit only as the app
//! takes its bytes. Same rules as the other handles: no I/O, no threads,
//! panics caught, a panic poisons only that handle.

use std::collections::BTreeSet;
use std::panic::{AssertUnwindSafe, catch_unwind};

use cmux_rd_core::bulk::{BulkCredit, BulkReceiver, BulkSender};
use cmux_rd_proto::{BulkFrame, MAX_BULK_CHUNK, STREAM_BULK, STREAM_CONTROL, encode_stream_frame};

use crate::{
    CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_ERR_PANIC, CMUX_RD_OK, bytes_in, copy_out,
};

/// The bulk queue or the open transfer limit is full (`CMUX_RD_ERR_FULL`).
pub const CMUX_RD_ERR_FULL: i32 = -9;
/// Bytes of queued upload data a sender holds (`CMUX_RD_BULK_MAX_QUEUED`).
pub const CMUX_RD_BULK_MAX_QUEUED: usize = 64 << 20;
/// Transfers a receiver tracks at once (`CMUX_RD_BULK_MAX_TRANSFERS`).
pub const CMUX_RD_BULK_MAX_TRANSFERS: usize = 64;
/// The largest framed chunk: 5-byte stream prefix, 16-byte bulk prefix,
/// 65520 bytes (`CMUX_RD_BULK_FRAME_MAX`).
pub const CMUX_RD_BULK_FRAME_MAX: usize = 5 + cmux_rd_proto::BULK_PREFIX_LEN + MAX_BULK_CHUNK;
/// A buffer this large always holds a framed `bulk_credit` (`CMUX_RD_BULK_CREDIT_MAX`).
pub const CMUX_RD_BULK_CREDIT_MAX: usize = 128;

/// The opaque upload handle (`CmuxRdBulkSender`).
#[derive(Debug)]
pub struct CmuxRdBulkSender {
    inner: BulkSender,
    /// Transfer id and unsent bytes of every queued transfer (the core keeps
    /// the data; this mirrors the sizes for the queue bound).
    queued: Vec<(u64, usize, usize)>,
    /// A framed chunk taken from the core that the caller has not taken yet.
    pending: Option<Vec<u8>>,
    poisoned: bool,
}

impl CmuxRdBulkSender {
    fn queued_bytes(&self) -> usize {
        self.queued.iter().map(|&(_, len, sent)| len - sent).sum()
    }

    fn sent(&mut self, frame: &BulkFrame) {
        if let Some(entry) = self.queued.iter_mut().find(|e| e.0 == frame.transfer) {
            entry.2 += frame.bytes.len();
        }
        self.queued.retain(|&(_, len, sent)| sent < len);
    }
}

/// The opaque download handle (`CmuxRdBulkReceiver`).
#[derive(Debug, Default)]
pub struct CmuxRdBulkReceiver {
    inner: BulkReceiver,
    /// Transfers with at least one chunk and not yet finished.
    open: BTreeSet<u64>,
    poisoned: bool,
}

/// One chunk the receiver accepted (`CmuxRdBulkChunk`). `bytes` points into
/// the caller's payload and lives as long as it.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CmuxRdBulkChunk {
    pub transfer: u64,
    pub offset: u64,
    pub bytes: *const u8,
    pub len: usize,
}

trait Poison {
    fn poisoned(&mut self) -> &mut bool;
}

impl Poison for CmuxRdBulkSender {
    fn poisoned(&mut self) -> &mut bool {
        &mut self.poisoned
    }
}

impl Poison for CmuxRdBulkReceiver {
    fn poisoned(&mut self) -> &mut bool {
        &mut self.poisoned
    }
}

/// Runs `f` on a live handle; maps NULL, a poisoned handle and panics to codes.
///
/// # Safety
/// `ptr` is NULL or a live pointer from this module's `new` that no other
/// call uses at the same time.
unsafe fn with<T: Poison>(ptr: *mut T, f: impl FnOnce(&mut T) -> i32) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(handle) = (unsafe { ptr.as_mut() }) else { return CMUX_RD_ERR_NULL };
    if *handle.poisoned() {
        return CMUX_RD_ERR_PANIC;
    }
    match catch_unwind(AssertUnwindSafe(|| f(handle))) {
        Ok(code) => code,
        Err(_) => {
            // SAFETY: as above; the closure's borrow ended when it unwound.
            if let Some(handle) = unsafe { ptr.as_mut() } {
                *handle.poisoned() = true;
            }
            CMUX_RD_ERR_PANIC
        }
    }
}

/// The `bulk_credit` control message (the golden vector's shape), framed
/// for the stream carrier.
fn credit_frame(credit: BulkCredit) -> Vec<u8> {
    let json = format!(
        r#"{{"t":"bulk_credit","transfer":{},"offset":{}}}"#,
        credit.transfer, credit.offset
    );
    let mut out = Vec::with_capacity(json.len() + 5);
    // A credit is far below the stream frame limit.
    let _ = encode_stream_frame(STREAM_CONTROL, json.as_bytes(), &mut out);
    out
}

/// Creates an upload sender that sends at most one chunk per `interval_us`
/// (the media frame interval); NULL for 0.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_bulk_sender_new(interval_us: u64) -> *mut CmuxRdBulkSender {
    if interval_us == 0 {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(CmuxRdBulkSender {
        inner: BulkSender::new(interval_us),
        queued: Vec::new(),
        pending: None,
        poisoned: false,
    }))
}

/// Frees a sender (NULL is ignored).
///
/// # Safety
/// `sender` is NULL or a pointer from [`cmux_rd_bulk_sender_new`] not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_free(sender: *mut CmuxRdBulkSender) {
    if !sender.is_null() {
        // SAFETY: guaranteed by the caller.
        drop(unsafe { Box::from_raw(sender) });
    }
}

/// Queues transfer `transfer`'s bytes (copied).
///
/// # Safety
/// `sender` is NULL or live; `data` is valid for `len` bytes (or `len` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_queue(
    sender: *mut CmuxRdBulkSender,
    transfer: u64,
    data: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(data, len) }) else { return CMUX_RD_ERR_NULL };
    let queue = |s: &mut CmuxRdBulkSender| {
        if s.queued.iter().any(|e| e.0 == transfer) {
            return CMUX_RD_ERR_INVALID;
        }
        if s.queued_bytes().saturating_add(len) > CMUX_RD_BULK_MAX_QUEUED {
            return CMUX_RD_ERR_FULL;
        }
        if bytes.is_empty() {
            // Nothing to send; the transfer's end is the service's message.
            return CMUX_RD_OK;
        }
        match s.inner.queue(transfer, bytes.to_vec()) {
            Ok(()) => {
                s.queued.push((transfer, len, 0));
                CMUX_RD_OK
            }
            Err(_) => CMUX_RD_ERR_INVALID,
        }
    };
    // SAFETY: `sender` is NULL or live (this function's contract).
    unsafe { with(sender, queue) }
}

/// Applies the host's credit for `transfer` (credit only grows).
///
/// # Safety
/// `sender` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_on_credit(
    sender: *mut CmuxRdBulkSender,
    transfer: u64,
    offset: u64,
) -> i32 {
    // SAFETY: `sender` is NULL or live (this function's contract).
    unsafe {
        with(sender, |s| {
            s.inner.on_credit(transfer, offset);
            CMUX_RD_OK
        })
    }
}

/// Offers one control message (a `CMUX_RD_MESSAGE_CONTROL` payload): 1 when
/// it was a `bulk_credit` and was applied, 0 for any other message.
///
/// # Safety
/// `sender` is NULL or live; `json` is valid for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_on_control(
    sender: *mut CmuxRdBulkSender,
    json: *const u8,
    len: usize,
) -> i32 {
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(json, len) }) else { return CMUX_RD_ERR_NULL };
    let apply = |s: &mut CmuxRdBulkSender| {
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) else { return 0 };
        if value.get("t").and_then(serde_json::Value::as_str) != Some("bulk_credit") {
            return 0;
        }
        let field = |k: &str| value.get(k).and_then(serde_json::Value::as_u64);
        let (Some(transfer), Some(offset)) = (field("transfer"), field("offset")) else {
            return CMUX_RD_ERR_INVALID;
        };
        s.inner.on_credit(transfer, offset);
        1
    };
    // SAFETY: `sender` is NULL or live (this function's contract).
    unsafe { with(sender, apply) }
}

/// Drops a queued transfer (the user cancelled it).
///
/// # Safety
/// `sender` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_cancel(
    sender: *mut CmuxRdBulkSender,
    transfer: u64,
) -> i32 {
    // SAFETY: `sender` is NULL or live (this function's contract).
    unsafe {
        with(sender, |s| {
            s.inner.cancel(transfer);
            s.queued.retain(|e| e.0 != transfer);
            if s.pending.as_ref().is_some_and(|pending| {
                pending.len() >= cmux_rd_proto::STREAM_PREFIX_LEN
                    && pending[0] == STREAM_BULK
                    && BulkFrame::decode(&pending[cmux_rd_proto::STREAM_PREFIX_LEN..])
                        .is_ok_and(|frame| frame.transfer == transfer)
            }) {
                s.pending = None;
            }
            CMUX_RD_OK
        })
    }
}

/// Writes the next chunk as a stream frame (type 3): 1 when written, 0 when
/// none may go now (a media frame waits, the interval has not passed, or
/// every transfer waits for credit), `CMUX_RD_ERR_BUFFER` (*out_len = size
/// needed) when `cap` is too small; the chunk then stays pending.
///
/// # Safety
/// `sender` is NULL or live; `out` is valid for `cap` bytes; `out_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_pop_frame(
    sender: *mut CmuxRdBulkSender,
    now_us: u64,
    media_waiting: bool,
    out: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> i32 {
    if out_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: checked non-NULL; writable by contract.
    unsafe { *out_len = 0 };
    let pop = |s: &mut CmuxRdBulkSender| {
        if s.pending.is_none() {
            let Some(frame) = s.inner.next_frame(now_us, media_waiting) else { return 0 };
            s.sent(&frame);
            let mut framed = Vec::with_capacity(CMUX_RD_BULK_FRAME_MAX);
            // At most 64 KiB, far below the stream frame limit.
            let _ = encode_stream_frame(STREAM_BULK, &frame.encode(), &mut framed);
            s.pending = Some(framed);
        }
        let Some(framed) = s.pending.as_deref() else { return 0 };
        // SAFETY: `out` and `out_len` are writable by this function's contract.
        match unsafe { copy_out(framed, out, cap, out_len) } {
            CMUX_RD_OK => {
                s.pending = None;
                1
            }
            code => code,
        }
    };
    // SAFETY: `sender` is NULL or live (this function's contract).
    unsafe { with(sender, pop) }
}

/// When pop_frame can return a chunk next (0 = now when one is pending);
/// UINT64_MAX when nothing can go (idle, or waiting for credit), for NULL or
/// a poisoned sender.
///
/// # Safety
/// `sender` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_next_deadline_us(
    sender: *const CmuxRdBulkSender,
) -> u64 {
    // SAFETY: guaranteed by the caller.
    let Some(s) = (unsafe { sender.as_ref() }) else { return u64::MAX };
    if s.poisoned {
        return u64::MAX;
    }
    if s.pending.is_some() {
        return 0;
    }
    s.inner.next_deadline_us().unwrap_or(u64::MAX)
}

/// Bytes of queued upload data not yet sent (0 for NULL).
///
/// # Safety
/// `sender` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_sender_queued_bytes(sender: *const CmuxRdBulkSender) -> u64 {
    // SAFETY: guaranteed by the caller.
    unsafe { sender.as_ref() }.map_or(0, |s| s.queued_bytes() as u64)
}

/// Creates a download receiver.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_rd_bulk_receiver_new() -> *mut CmuxRdBulkReceiver {
    Box::into_raw(Box::new(CmuxRdBulkReceiver::default()))
}

/// Frees a receiver (NULL is ignored).
///
/// # Safety
/// `receiver` is NULL or a pointer from [`cmux_rd_bulk_receiver_new`] not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_receiver_free(receiver: *mut CmuxRdBulkReceiver) {
    if !receiver.is_null() {
        // SAFETY: guaranteed by the caller.
        drop(unsafe { Box::from_raw(receiver) });
    }
}

/// Takes one chunk (a `CMUX_RD_MESSAGE_BULK` payload) and fills `*out`. When
/// a credit is due it writes the framed `bulk_credit` control message to
/// `credit_out` (send it on the stream as is) and sets *credit_len; else
/// *credit_len is 0. `credit_cap` must be at least CMUX_RD_BULK_CREDIT_MAX
/// (`CMUX_RD_ERR_BUFFER`, nothing taken). `CMUX_RD_ERR_INVALID` for bad
/// bytes, a gap, an overlap, a chunk past the credit or a finished transfer
/// (a protocol error: end the session); `CMUX_RD_ERR_FULL` for a new
/// transfer while CMUX_RD_BULK_MAX_TRANSFERS are open.
///
/// # Safety
/// `receiver` is NULL or live; `payload` is valid for `len` bytes; `out` and
/// `credit_len` are writable; `credit_out` is valid for `credit_cap` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_receiver_accept(
    receiver: *mut CmuxRdBulkReceiver,
    payload: *const u8,
    len: usize,
    out: *mut CmuxRdBulkChunk,
    credit_out: *mut u8,
    credit_cap: usize,
    credit_len: *mut usize,
) -> i32 {
    if out.is_null() || credit_len.is_null() {
        return CMUX_RD_ERR_NULL;
    }
    // SAFETY: checked non-NULL; writable by contract.
    unsafe { *credit_len = 0 };
    // SAFETY: guaranteed by the caller.
    let Some(bytes) = (unsafe { bytes_in(payload, len) }) else { return CMUX_RD_ERR_NULL };
    if credit_cap < CMUX_RD_BULK_CREDIT_MAX {
        // SAFETY: checked non-NULL above.
        unsafe { *credit_len = CMUX_RD_BULK_CREDIT_MAX };
        return crate::CMUX_RD_ERR_BUFFER;
    }
    let accept = |r: &mut CmuxRdBulkReceiver| {
        let Ok(frame) = BulkFrame::decode(bytes) else { return CMUX_RD_ERR_INVALID };
        if !r.open.contains(&frame.transfer) && r.open.len() >= CMUX_RD_BULK_MAX_TRANSFERS {
            return CMUX_RD_ERR_FULL;
        }
        let Ok(accepted) = r.inner.accept(&frame) else { return CMUX_RD_ERR_INVALID };
        r.open.insert(frame.transfer);
        let prefix = bytes.len() - frame.bytes.len();
        let chunk = CmuxRdBulkChunk {
            transfer: frame.transfer,
            offset: frame.offset,
            bytes: bytes[prefix..].as_ptr(),
            len: frame.bytes.len(),
        };
        // SAFETY: `out` is non-NULL and writable (checked above, contract).
        unsafe { *out = chunk };
        if let Some(credit) = accepted.credit {
            // SAFETY: `credit_out` holds `credit_cap` writable bytes; `credit_len` is writable.
            return unsafe { copy_out(&credit_frame(credit), credit_out, credit_cap, credit_len) };
        }
        CMUX_RD_OK
    };
    // SAFETY: `receiver` is NULL or live (this function's contract).
    unsafe { with(receiver, accept) }
}

/// Ends a transfer (complete or cancelled): later chunks of it are refused
/// and its slot is free.
///
/// # Safety
/// `receiver` is NULL or live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_rd_bulk_receiver_finish(
    receiver: *mut CmuxRdBulkReceiver,
    transfer: u64,
) -> i32 {
    // SAFETY: `receiver` is NULL or live (this function's contract).
    unsafe {
        with(receiver, |r| {
            r.inner.finish(transfer);
            r.open.remove(&transfer);
            CMUX_RD_OK
        })
    }
}
