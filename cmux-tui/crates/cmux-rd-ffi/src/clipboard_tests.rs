//! The clipboard handle through the C ABI: a viewer text out as framed parts the host's
//! deframer and `Control` parse, the host's text in, no echo, the size bound, refusals.

use super::*;
use cmux_rd_proto::control::Control;
use cmux_rd_proto::{STREAM_CONTROL, StreamDeframer};

struct Handle(*mut CmuxRdClipboard);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_clipboard_new and freed once here.
        unsafe { cmux_rd_clipboard_free(self.0) };
    }
}

fn new() -> Handle {
    let h = cmux_rd_clipboard_new();
    assert!(!h.is_null());
    Handle(h)
}

fn offer(h: &Handle, text: &[u8]) -> i32 {
    // SAFETY: a live handle and a readable slice.
    unsafe { cmux_rd_clipboard_offer(h.0, text.as_ptr(), text.len()) }
}

/// Every frame the handle gives until it is idle, parsed as the host does.
fn drain(h: &Handle) -> Vec<Control> {
    let mut deframer = StreamDeframer::default();
    let mut buf = vec![0u8; CMUX_RD_CLIPBOARD_FRAME_MAX];
    let mut now = 0;
    loop {
        // SAFETY: a live handle.
        let due = unsafe { cmux_rd_clipboard_next_deadline_us(h.0) };
        if due == u64::MAX {
            break;
        }
        now = now.max(due);
        let mut len = 0;
        // SAFETY: a live handle; `buf` is writable for its length.
        let code =
            unsafe { cmux_rd_clipboard_pop_frame(h.0, now, buf.as_mut_ptr(), buf.len(), &mut len) };
        assert!(code >= 0, "{code}");
        if code == 1 {
            deframer.extend(&buf[..len]);
        }
    }
    let mut out = Vec::new();
    while let Some((kind, payload)) = deframer.next_frame().expect("frame") {
        assert_eq!(kind, STREAM_CONTROL);
        out.push(serde_json::from_slice(&payload).expect("control"));
    }
    out
}

fn on_control(h: &Handle, json: &[u8]) -> (i32, Option<String>) {
    let mut text = std::ptr::null();
    let mut len = 0;
    // SAFETY: a live handle, a readable slice and writable outputs.
    let code = unsafe {
        cmux_rd_clipboard_on_control(h.0, json.as_ptr(), json.len(), &mut text, &mut len)
    };
    let got = (code == 1).then(|| {
        // SAFETY: valid until the next call on this handle.
        String::from_utf8(unsafe { std::slice::from_raw_parts(text, len) }.to_vec()).expect("utf-8")
    });
    (code, got)
}

#[test]
fn a_viewer_text_goes_out_as_parts_the_host_joins() {
    let h = new();
    let text = "clipboard ".repeat(10_000);
    assert_eq!(offer(&h, text.as_bytes()), 1);
    let parts = drain(&h);
    assert!(parts.len() > 1);
    let mut host = cmux_rd_proto::clipboard::ClipboardSync::new();
    let mut joined = None;
    for control in parts {
        let part = control.into_clipboard_part().expect("clipboard");
        if let Some(done) = host.receive(part).expect("part") {
            joined = Some(done.1);
        }
    }
    assert_eq!(joined.as_deref(), Some(text.as_str()));
}

#[test]
fn the_hosts_text_comes_in_and_is_not_sent_back() {
    let h = new();
    let json = br#"{"t":"clipboard","seq":1,"text":"from host"}"#;
    assert_eq!(on_control(&h, json), (1, Some("from host".into())));
    // The viewer's pasteboard now holds it: offering it again sends nothing.
    assert_eq!(offer(&h, b"from host"), 0);
    assert!(drain(&h).is_empty());
    // Other messages are not the clipboard's.
    assert_eq!(on_control(&h, br#"{"t":"stats","kbps":1}"#), (0, None));
    assert_eq!(on_control(&h, b"not json"), (0, None));
}

#[test]
fn over_the_bound_is_refused_and_counted() {
    let h = new();
    let big = vec![b'x'; CMUX_RD_CLIPBOARD_MAX_TEXT + 1];
    assert_eq!(offer(&h, &big), CMUX_RD_ERR_TOO_LARGE);
    assert!(drain(&h).is_empty());
    let json = format!(
        r#"{{"t":"clipboard","seq":1,"text":"x","offset":0,"total":{}}}"#,
        CMUX_RD_CLIPBOARD_MAX_TEXT + 1
    );
    assert_eq!(on_control(&h, json.as_bytes()).0, CMUX_RD_ERR_TOO_LARGE);
    assert_eq!(on_control(&h, br#"{"t":"clipboard","seq":"x"}"#).0, CMUX_RD_ERR_INVALID);
    assert_eq!(offer(&h, &[0xff, 0xfe]), CMUX_RD_ERR_INVALID);
    // SAFETY: a live handle.
    assert_eq!(unsafe { cmux_rd_clipboard_dropped(h.0) }, 3);
}

#[test]
fn a_small_buffer_keeps_the_part_pending() {
    let h = new();
    assert_eq!(offer(&h, b"hello"), 1);
    let mut len = 0;
    let mut small = [0u8; 4];
    // SAFETY: a live handle; `small` is writable for its length.
    let code = unsafe { cmux_rd_clipboard_pop_frame(h.0, 0, small.as_mut_ptr(), 4, &mut len) };
    assert_eq!(code, CMUX_RD_ERR_BUFFER);
    assert!(len > 4);
    // SAFETY: a live handle.
    assert_eq!(unsafe { cmux_rd_clipboard_next_deadline_us(h.0) }, 0);
    assert_eq!(drain(&h).len(), 1);
}

#[test]
fn null_handles_are_refused() {
    let mut len = 0;
    assert_eq!(
        // SAFETY: NULL is allowed.
        unsafe { cmux_rd_clipboard_offer(std::ptr::null_mut(), std::ptr::null(), 0) },
        CMUX_RD_ERR_NULL
    );
    assert_eq!(
        // SAFETY: NULL handle, writable length.
        unsafe {
            cmux_rd_clipboard_pop_frame(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0, &mut len)
        },
        CMUX_RD_ERR_NULL
    );
    // SAFETY: NULL is allowed.
    assert_eq!(unsafe { cmux_rd_clipboard_next_deadline_us(std::ptr::null()) }, u64::MAX);
    // SAFETY: NULL is allowed.
    assert_eq!(unsafe { cmux_rd_clipboard_dropped(std::ptr::null()) }, 0);
    // SAFETY: NULL is ignored.
    unsafe { cmux_rd_clipboard_free(std::ptr::null_mut()) };
}
