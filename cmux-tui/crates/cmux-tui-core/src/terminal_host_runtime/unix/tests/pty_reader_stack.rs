//! The PTY reader's memory (HOST-MEM cut 2): a terminal's reader thread keeps
//! resident only the stack pages its reads use. A PTY read returns at most
//! 1 KiB on macOS and 4 KiB on Linux, so a 64 KiB zero-filled read buffer on
//! the stack made 48 KiB or more of every idle host's memory dirty for no
//! read.

use super::super::super::shared::host_start::read_pty_output;
use super::*;
use std::os::unix::thread::JoinHandleExt;

/// The most stack the reader of a quiet terminal keeps resident: its frames
/// and one read buffer, a few pages (macOS pages are 16 KiB).
const QUIET_READER_STACK_BYTES: usize = 48 * 1024;

#[test]
fn a_quiet_terminals_pty_reader_keeps_no_large_read_buffer_resident() {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, parsed) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = host_fixture::test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        1 << 20,
    );
    host.mark_launch_owner_stream_ready();
    // A socket stands in for the PTY master: the reader polls and reads a
    // descriptor either way.
    let (pty, mut program) = UnixStream::pair().unwrap();
    let pty_fd = pty.as_raw_fd();
    let (drain_waker, drain_waiter) = HostStream::pair().unwrap();
    let reader = thread::Builder::new()
        .name("terminal-host-pty".into())
        .spawn(move || read_pty_output(&host, Box::new(pty), pty_fd, drain_waiter))
        .unwrap();

    program.write_all(b"$ ").unwrap();
    // The reader read the prompt and published it: its frame is queued for
    // the parser, and the reader waits in its loop for the next read.
    match parsed.recv_timeout(Duration::from_secs(10)).unwrap() {
        ParserCommand::Output { frame, .. } => assert_eq!(frame.payload.as_slice(), b"$ "),
        _ => panic!("the reader's first command is not the prompt's Output"),
    }
    let resident = resident_stack_bytes(reader.as_pthread_t());

    drop(program);
    reader.join().unwrap();
    drop(drain_waker);
    assert!(
        resident <= QUIET_READER_STACK_BYTES,
        "the PTY reader of a quiet terminal keeps {resident} bytes of stack resident \
         (at most {QUIET_READER_STACK_BYTES})"
    );
}

/// Bytes of `thread`'s stack that are resident (mincore over its range).
fn resident_stack_bytes(thread: libc::pthread_t) -> usize {
    let (low, size) = stack_range(thread);
    // SAFETY: sysconf takes no pointer.
    let page = usize::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap();
    let mut pages = vec![0; size.div_ceil(page)];
    // SAFETY: [low, low + size) is the mapped stack of `thread`, which waits
    // in its read loop until the test closes its PTY; `pages` holds one byte
    // for each page of it.
    let status = unsafe { libc::mincore(low as _, size, pages.as_mut_ptr()) };
    assert_eq!(status, 0, "mincore: {}", std::io::Error::last_os_error());
    // mincore fills c_char on macOS (i8) and c_uchar on Linux (u8); bit 0
    // (MINCORE_INCORE) is set for a resident page either way.
    pages.iter().filter(|&&state| state & 1 != 0).count() * page
}

#[cfg(target_vendor = "apple")]
fn stack_range(thread: libc::pthread_t) -> (usize, usize) {
    // SAFETY: `thread` is a live thread of this process.
    let (top, size) = unsafe {
        (libc::pthread_get_stackaddr_np(thread) as usize, libc::pthread_get_stacksize_np(thread))
    };
    (top - size, size)
}

#[cfg(not(target_vendor = "apple"))]
fn stack_range(thread: libc::pthread_t) -> (usize, usize) {
    let mut attr = std::mem::MaybeUninit::<libc::pthread_attr_t>::uninit();
    let mut low = std::ptr::null_mut();
    let mut size = 0;
    // SAFETY: `thread` is a live thread of this process; `attr` is
    // initialized by pthread_getattr_np before it is read and destroyed after.
    unsafe {
        assert_eq!(libc::pthread_getattr_np(thread, attr.as_mut_ptr()), 0);
        assert_eq!(libc::pthread_attr_getstack(attr.as_ptr(), &mut low, &mut size), 0);
        libc::pthread_attr_destroy(attr.as_mut_ptr());
    }
    (low as usize, size)
}
