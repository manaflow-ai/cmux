use super::*;
use std::ffi::CString;
use std::sync::mpsc::{Receiver, sync_channel};
use std::time::Duration;

type Replies = Receiver<Option<String>>;

unsafe extern "C" fn deliver(context: *mut c_void, reply: *const u8, len: usize) {
    // SAFETY: a boxed sender from `send`, taken once.
    let sender =
        unsafe { Box::from_raw(context.cast::<std::sync::mpsc::SyncSender<Option<String>>>()) };
    let text = (!reply.is_null())
        // SAFETY: `len` readable bytes during the call.
        .then(|| {
            String::from_utf8(unsafe { std::slice::from_raw_parts(reply, len) }.to_vec()).unwrap()
        });
    let _ = sender.send(text);
}

struct Lister(*mut CmuxFilesLister);

impl Lister {
    fn new(argv: &[&str]) -> Self {
        let owned: Vec<CString> = argv.iter().map(|a| CString::new(*a).unwrap()).collect();
        let ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        // SAFETY: valid strings for the call.
        Lister(unsafe { cmux_files_lister_new(ptrs.as_ptr(), ptrs.len()) })
    }

    /// The request's id (0 when refused) and where its reply arrives.
    fn send(&self, op: &str, path: &str) -> (u64, Replies) {
        let (tx, rx) = sync_channel(1);
        let context = Box::into_raw(Box::new(tx)).cast::<c_void>();
        let (op, path) = (CString::new(op).unwrap(), CString::new(path).unwrap());
        // SAFETY: a live lister and valid strings.
        let id = unsafe {
            cmux_files_lister_request(self.0, op.as_ptr(), path.as_ptr(), Some(deliver), context)
        };
        if id == 0 {
            // SAFETY: never handed to a callback.
            drop(unsafe {
                Box::from_raw(context.cast::<std::sync::mpsc::SyncSender<Option<String>>>())
            });
        }
        (id, rx)
    }

    fn ask(&self, path: &str) -> Option<Option<String>> {
        let (id, rx) = self.send("list", path);
        (id != 0).then(|| rx.recv_timeout(Duration::from_secs(10)).expect("a callback"))
    }
}

impl Drop for Lister {
    fn drop(&mut self) {
        // SAFETY: from `cmux_files_lister_new`, freed once.
        unsafe { cmux_files_lister_free(self.0) };
    }
}

/// A child that answers each request line with the next of `replies`
/// (`ID` becomes the request's id), then reads to the end.
fn child(replies: &[&str]) -> (Scratch, Lister) {
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let file = std::env::temp_dir().join(format!("cmux-files-lister-{}-{n}", std::process::id()));
    std::fs::write(&file, replies.join("\n") + "\n").unwrap();
    let script = format!(
        "exec 3<'{}'\nwhile IFS= read -r line; do IFS= read -r reply <&3 || exit 0; \
             id=${{line#*\\\"id\\\":}}; id=${{id%%,*}}; printf '%s\\n' \"$(printf '%s' \"$reply\" | sed \"s/ID/$id/\")\"; done",
        file.display()
    );
    let lister = Lister::new(&["/bin/sh", "-c", &script]);
    (Scratch(file), lister)
}

/// A replies file, removed with the test.
struct Scratch(std::path::PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

#[test]
fn replies_reach_their_requests_in_order() {
    let replies: Vec<String> = (1..=20)
        .map(|n| format!(r#"{{"id":ID,"entries":[{{"n":"item-{n}","k":"file"}}]}}"#))
        .collect();
    let refs: Vec<&str> = replies.iter().map(String::as_str).collect();
    let (_dir, lister) = child(&refs);
    for n in 1..=20 {
        let reply = lister.ask(&format!("/f{n}")).unwrap().unwrap();
        let value: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(value["id"], n);
        assert_eq!(value["entries"][0]["n"], format!("item-{n}"));
    }
}

#[test]
fn errno_and_entry_replies_pass_through() {
    let (_dir, lister) = child(&[r#"{"id":ID,"errno":13}"#, r#"{"id":ID,"entry":null}"#]);
    assert_eq!(lister.ask("/a").unwrap().as_deref(), Some(r#"{"id":1,"errno":13}"#));
    let (_, rx) = lister.send("entry", "/b");
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().as_deref(),
        Some(r#"{"id":2,"entry":null}"#)
    );
}

#[test]
fn a_child_that_cannot_answer_gives_no_reply_then_is_refused() {
    // Exits at once: each request gets no reply, and after three the lister stops trying.
    let lister = Lister::new(&["/bin/sh", "-c", "exit 0"]);
    for _ in 0..MAX_CONSECUTIVE_FAILURES {
        assert_eq!(lister.ask("/x"), Some(None));
    }
    assert_eq!(lister.ask("/x"), None);

    let missing = Lister::new(&["/nonexistent/cmux-files-lister"]);
    for _ in 0..MAX_CONSECUTIVE_FAILURES {
        assert_eq!(missing.ask("/x"), None);
    }
}

#[test]
fn an_error_reply_reads_in_process() {
    let (_dir, lister) =
        child(&[r#"{"id":ID,"error":"unknown op list"}"#, r#"{"id":ID,"entries":[]}"#]);
    assert_eq!(lister.ask("/a"), Some(None));
    assert_eq!(lister.ask("/b").unwrap().as_deref(), Some(r#"{"id":2,"entries":[]}"#));
}

#[test]
fn cancel_and_free_answer_pending_requests() {
    // Reads requests and never answers.
    let lister = Lister::new(&["/bin/sh", "-c", "cat >/dev/null"]);
    let (id, rx) = lister.send("list", "/a");
    assert_ne!(id, 0);
    // SAFETY: a live lister.
    assert!(unsafe { cmux_files_lister_cancel(lister.0, id) });
    assert_eq!(rx.try_recv().unwrap(), None);
    // SAFETY: a live lister.
    assert!(!unsafe { cmux_files_lister_cancel(lister.0, id) });
    let (id, rx) = lister.send("list", "/b");
    assert_ne!(id, 0);
    drop(lister);
    assert_eq!(rx.try_recv().unwrap(), None);
}

#[test]
fn a_line_past_the_limit_is_skipped() {
    let mut input = std::io::Cursor::new(b"abc\nlast".to_vec());
    let mut line = Vec::new();
    assert!(matches!(read_line(&mut input, &mut line).unwrap(), Line::Complete));
    assert_eq!(line, b"abc");
    line.clear();
    assert!(matches!(read_line(&mut input, &mut line).unwrap(), Line::End));
}

#[test]
fn null_arguments_are_refused() {
    // SAFETY: null pointers are allowed.
    unsafe {
        assert!(cmux_files_lister_new(std::ptr::null(), 0).is_null());
        assert_eq!(
            cmux_files_lister_request(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                None,
                std::ptr::null_mut()
            ),
            0
        );
        assert!(!cmux_files_lister_cancel(std::ptr::null(), 1));
        cmux_files_lister_free(std::ptr::null_mut());
    }
}
