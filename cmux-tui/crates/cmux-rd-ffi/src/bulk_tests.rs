//! The viewer's bulk flow control through the C ABI (rd change C5): an
//! upload never passes the host's credit or one chunk per interval, and a
//! download grants credit back as the golden `bulk_credit` message.

use super::*;
use cmux_rd_core::bulk::{BulkSender, INITIAL_CREDIT};
use cmux_rd_proto::{BulkFrame, MAX_BULK_CHUNK, STREAM_BULK, STREAM_CONTROL, StreamDeframer};

const INTERVAL: u64 = 16_667;

struct Tx(*mut CmuxRdBulkSender);
impl Drop for Tx {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_bulk_sender_new and freed once here.
        unsafe { cmux_rd_bulk_sender_free(self.0) };
    }
}

struct Rx(*mut CmuxRdBulkReceiver);
impl Drop for Rx {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_bulk_receiver_new and freed once here.
        unsafe { cmux_rd_bulk_receiver_free(self.0) };
    }
}

fn sender() -> Tx {
    let h = cmux_rd_bulk_sender_new(INTERVAL);
    assert!(!h.is_null());
    Tx(h)
}

fn queue(tx: &Tx, transfer: u64, data: &[u8]) -> i32 {
    // SAFETY: live handle; `data` is valid for its length.
    unsafe { cmux_rd_bulk_sender_queue(tx.0, transfer, data.as_ptr(), data.len()) }
}

/// One pop: Ok(Some(frame payload)) when a chunk was written.
fn pop(tx: &Tx, now: u64, media_waiting: bool) -> Option<BulkFrame> {
    let mut buf = vec![0u8; CMUX_RD_BULK_FRAME_MAX];
    let mut len = 0usize;
    // SAFETY: live handle; `buf` holds `buf.len()` bytes.
    let rc = unsafe {
        cmux_rd_bulk_sender_pop_frame(
            tx.0,
            now,
            media_waiting,
            buf.as_mut_ptr(),
            buf.len(),
            &mut len,
        )
    };
    assert!(rc == 0 || rc == 1, "pop rc {rc}");
    if rc == 0 {
        assert_eq!(len, 0);
        return None;
    }
    let mut d = StreamDeframer::default();
    d.extend(&buf[..len]);
    let (kind, payload) = d.next_frame().expect("frame").expect("complete");
    assert_eq!(kind, STREAM_BULK);
    Some(BulkFrame::decode(&payload).expect("bulk frame"))
}

fn deadline(tx: &Tx) -> u64 {
    // SAFETY: live handle.
    unsafe { cmux_rd_bulk_sender_next_deadline_us(tx.0) }
}

#[test]
fn an_upload_stops_at_the_credit_and_resumes_with_more() {
    let tx = sender();
    let data: Vec<u8> = (0..(INITIAL_CREDIT as usize + 100_000)).map(|i| i as u8).collect();
    assert_eq!(queue(&tx, 7, &data), CMUX_RD_OK);
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_sender_queued_bytes(tx.0) }, data.len() as u64);
    let mut got = Vec::new();
    let mut now = 0;
    // A media frame waiting holds the chunk back.
    assert!(pop(&tx, now, true).is_none());
    while let Some(f) = pop(&tx, now, false) {
        assert_eq!((f.transfer, f.offset as usize), (7, got.len()));
        assert!(f.bytes.len() <= MAX_BULK_CHUNK);
        got.extend_from_slice(&f.bytes);
        // At most one chunk per interval.
        assert!(pop(&tx, now + INTERVAL - 1, false).is_none());
        now += INTERVAL;
    }
    assert_eq!(got.len() as u64, INITIAL_CREDIT, "blocked at the initial credit");
    assert_eq!(deadline(&tx), u64::MAX, "no wakeup while waiting for credit");
    // The host's bulk_credit message, offered as a control message.
    let credit = br#"{"t":"bulk_credit","transfer":7,"offset":2097152}"#;
    // SAFETY: live handle; `credit` is valid for its length.
    assert_eq!(unsafe { cmux_rd_bulk_sender_on_control(tx.0, credit.as_ptr(), credit.len()) }, 1);
    let other = br#"{"t":"stats","kbps":1}"#;
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_bulk_sender_on_control(tx.0, other.as_ptr(), other.len()) }, 0);
    assert_ne!(deadline(&tx), u64::MAX);
    while let Some(f) = pop(&tx, now, false) {
        got.extend_from_slice(&f.bytes);
        now += INTERVAL;
    }
    assert_eq!(got, data);
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_sender_queued_bytes(tx.0) }, 0);
    assert_eq!(deadline(&tx), u64::MAX, "idle: no wakeup");
}

#[test]
fn a_small_buffer_keeps_the_chunk_pending() {
    let tx = sender();
    assert_eq!(queue(&tx, 1, &[9u8; 3_000]), CMUX_RD_OK);
    let mut small = [0u8; 16];
    let mut len = 0usize;
    // SAFETY: live handle; `small` holds 16 bytes.
    let rc =
        unsafe { cmux_rd_bulk_sender_pop_frame(tx.0, 0, false, small.as_mut_ptr(), 16, &mut len) };
    assert_eq!(rc, CMUX_RD_ERR_BUFFER);
    assert_eq!(len, 5 + 16 + 3_000);
    assert_eq!(deadline(&tx), 0, "the pending chunk is due now");
    // The same chunk comes out, even inside the interval.
    let f = pop(&tx, 1, false).expect("pending chunk");
    assert_eq!((f.offset, f.bytes.len()), (0, 3_000));
}

#[test]
fn cancelling_a_pending_chunk_drops_it() {
    let tx = sender();
    assert_eq!(queue(&tx, 1, &[9u8; 3_000]), CMUX_RD_OK);
    let mut small = [0u8; 16];
    let mut len = 0usize;
    // SAFETY: live handle; `small` holds 16 bytes.
    assert_eq!(
        unsafe { cmux_rd_bulk_sender_pop_frame(tx.0, 0, false, small.as_mut_ptr(), 16, &mut len) },
        CMUX_RD_ERR_BUFFER
    );
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_sender_cancel(tx.0, 1) }, CMUX_RD_OK);
    assert!(pop(&tx, 1, false).is_none(), "cancelled pending frame escaped");
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_sender_queued_bytes(tx.0) }, 0);
}

#[test]
fn the_queue_is_bounded_and_transfers_are_unique() {
    let tx = sender();
    let big = vec![0u8; CMUX_RD_BULK_MAX_QUEUED];
    assert_eq!(queue(&tx, 1, &big), CMUX_RD_OK);
    assert_eq!(queue(&tx, 2, &[1]), CMUX_RD_ERR_FULL);
    assert_eq!(queue(&tx, 1, &[1]), CMUX_RD_ERR_INVALID, "duplicate transfer");
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_sender_cancel(tx.0, 1) }, CMUX_RD_OK);
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_sender_queued_bytes(tx.0) }, 0);
    assert_eq!(queue(&tx, 2, &[1]), CMUX_RD_OK);
    assert!(cmux_rd_bulk_sender_new(0).is_null());
    // SAFETY: NULL is allowed.
    assert_eq!(
        unsafe { cmux_rd_bulk_sender_queue(std::ptr::null_mut(), 1, [1u8].as_ptr(), 1) },
        CMUX_RD_ERR_NULL
    );
}

/// Accepts one framed-out chunk payload; returns the credit JSON if one was due.
fn accept(rx: &Rx, payload: &[u8]) -> Result<(CmuxRdBulkChunk, Option<serde_json::Value>), i32> {
    let mut chunk = CmuxRdBulkChunk { transfer: 0, offset: 0, bytes: std::ptr::null(), len: 0 };
    let mut credit = [0u8; CMUX_RD_BULK_CREDIT_MAX];
    let mut credit_len = 0usize;
    // SAFETY: live handle; every buffer is valid for its length.
    let rc = unsafe {
        cmux_rd_bulk_receiver_accept(
            rx.0,
            payload.as_ptr(),
            payload.len(),
            &mut chunk,
            credit.as_mut_ptr(),
            credit.len(),
            &mut credit_len,
        )
    };
    if rc != CMUX_RD_OK {
        return Err(rc);
    }
    if credit_len == 0 {
        return Ok((chunk, None));
    }
    let mut d = StreamDeframer::default();
    d.extend(&credit[..credit_len]);
    let (kind, json) = d.next_frame().expect("frame").expect("complete");
    assert_eq!(kind, STREAM_CONTROL);
    Ok((chunk, Some(serde_json::from_slice(&json).expect("json"))))
}

#[test]
fn a_download_grants_credit_as_the_golden_message() {
    let rx = Rx(cmux_rd_bulk_receiver_new());
    // The host's side of the flow control, from cmux-rd-core.
    let mut host = BulkSender::new(1);
    let data: Vec<u8> = (0..(3 * INITIAL_CREDIT as usize)).map(|i| (i * 7) as u8).collect();
    host.queue(4, data.clone()).expect("queue");
    let mut got = Vec::new();
    let mut credits = 0;
    let mut now = 0;
    while let Some(frame) = host.next_frame(now, false) {
        now += 1;
        let payload = frame.encode();
        let (chunk, credit) = accept(&rx, &payload).expect("in-order chunk");
        assert_eq!((chunk.transfer, chunk.offset as usize), (4, got.len()));
        // SAFETY: `chunk.bytes` points into `payload` for `chunk.len` bytes.
        got.extend_from_slice(unsafe { std::slice::from_raw_parts(chunk.bytes, chunk.len) });
        if let Some(json) = credit {
            // Exactly the golden vector's fields (cmux-rd-proto control.json `bulk_credit`).
            let keys: Vec<&str> =
                json.as_object().expect("object").keys().map(String::as_str).collect();
            assert_eq!(keys.len(), 3, "{json}");
            assert_eq!(json["t"], "bulk_credit");
            assert_eq!(json["transfer"], 4);
            host.on_credit(4, json["offset"].as_u64().expect("offset"));
            credits += 1;
        }
    }
    assert_eq!(got, data, "the credits carried the whole transfer");
    assert!(credits >= 4, "{credits}");
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_receiver_finish(rx.0, 4) }, CMUX_RD_OK);
    let late = BulkFrame { transfer: 4, offset: data.len() as u64, bytes: vec![1] }.encode();
    assert_eq!(accept(&rx, &late).map(|_| ()), Err(CMUX_RD_ERR_INVALID), "finished transfer");
}

#[test]
fn a_gap_an_overlap_or_garbage_is_a_protocol_error() {
    let rx = Rx(cmux_rd_bulk_receiver_new());
    let gap = BulkFrame { transfer: 1, offset: 10, bytes: vec![0; 10] }.encode();
    assert_eq!(accept(&rx, &gap).map(|_| ()), Err(CMUX_RD_ERR_INVALID));
    assert_eq!(accept(&rx, &[1, 2, 3]).map(|_| ()), Err(CMUX_RD_ERR_INVALID));
    // An overlap: the same chunk twice (the stream is reliable, so a repeat
    // is a protocol error, never a retransmission).
    let first = BulkFrame { transfer: 2, offset: 0, bytes: vec![0; 100] }.encode();
    assert!(accept(&rx, &first).is_ok());
    assert_eq!(accept(&rx, &first).map(|_| ()), Err(CMUX_RD_ERR_INVALID));
    // A too-small credit buffer takes nothing.
    let next = BulkFrame { transfer: 3, offset: 0, bytes: vec![1; 5] }.encode();
    let mut chunk = CmuxRdBulkChunk { transfer: 0, offset: 0, bytes: std::ptr::null(), len: 0 };
    let mut credit_len = 0usize;
    // SAFETY: live handle; a 0-byte credit buffer is allowed with cap 0.
    let rc = unsafe {
        cmux_rd_bulk_receiver_accept(
            rx.0,
            next.as_ptr(),
            next.len(),
            &mut chunk,
            std::ptr::null_mut(),
            0,
            &mut credit_len,
        )
    };
    assert_eq!((rc, credit_len), (CMUX_RD_ERR_BUFFER, CMUX_RD_BULK_CREDIT_MAX));
    assert!(accept(&rx, &next).is_ok(), "the chunk was not taken before");
}

#[test]
fn open_transfers_are_bounded() {
    let rx = Rx(cmux_rd_bulk_receiver_new());
    for t in 0..CMUX_RD_BULK_MAX_TRANSFERS as u64 {
        accept(&rx, &BulkFrame { transfer: t, offset: 0, bytes: vec![1] }.encode()).expect("open");
    }
    let one_more = BulkFrame { transfer: 999, offset: 0, bytes: vec![1] }.encode();
    assert_eq!(accept(&rx, &one_more).map(|_| ()), Err(CMUX_RD_ERR_FULL));
    // An open transfer continues; finishing one frees a slot.
    accept(&rx, &BulkFrame { transfer: 0, offset: 1, bytes: vec![1] }.encode()).expect("continues");
    // SAFETY: live handle.
    assert_eq!(unsafe { cmux_rd_bulk_receiver_finish(rx.0, 0) }, CMUX_RD_OK);
    assert!(accept(&rx, &one_more).is_ok());
}

#[test]
fn the_bulk_objects_are_abi_4() {
    assert_eq!(cmux_rd_ffi_abi_version(), 4);
}
