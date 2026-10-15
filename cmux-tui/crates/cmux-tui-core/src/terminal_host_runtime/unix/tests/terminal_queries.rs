//! cx-6so.42: the host's parser is the only replier for its terminal (the
//! daemon and app mirrors never answer), so it must answer size queries the
//! way Ghostty does: XTWINOPS CSI 14/16/18 t, in-band reports (mode 2048),
//! XTVERSION and the XTGETTCAP terminfo name.

use super::*;
use crate::terminal_host_runtime::shared::clipboard_read::{ClipboardReads, SystemClock};
use crate::terminal_host_runtime::shared::host_start::new_host_terminal;

const REPLY_BOUND: Duration = Duration::from_secs(10);
/// The TERM the host's child runs with.
const HOST_TERM: &str = "xterm-ghostty";

struct PtyWriter(Sender<Vec<u8>>);

impl Write for PtyWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let _ = self.0.send(bytes.to_vec());
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A host whose terminal has the production callbacks and runs the
/// production parser worker; its PTY input is captured.
struct QueryHost {
    host: Arc<HostShared>,
    pty: Receiver<Vec<u8>>,
    cursor: u64,
}

impl QueryHost {
    fn new() -> Self {
        let clipboard = ClipboardReads::new(Arc::new(SystemClock));
        let signals = ParserSignals::new();
        let term = new_host_terminal(HOST_TERM, 80, 24, 0, signals.callbacks(&clipboard)).unwrap();
        let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
        // Resizes the terminal to 80x24 with DEFAULT_CELL_PIXELS (8x16).
        let host = test_host_shared_with(term, parser_commands, clipboard);
        let (pty_sender, pty) = mpsc_channel();
        *host.writer.lock().unwrap() = Box::new(PtyWriter(pty_sender));
        let initial_colors = host.term.lock().unwrap().color_overrides();
        let parser_host = host.clone();
        thread::spawn(move || run_host_parser(parser_host, receiver, initial_colors, signals));
        Self { host, pty, cursor: 0 }
    }

    fn reply_to(&mut self, query: &[u8]) -> Vec<u8> {
        self.cursor += 1;
        let command = ParserCommand::Output {
            bytes: query.to_vec(),
            source_cursor: self.cursor,
            accounted_bytes: 0,
        };
        self.host.parser_commands.send(command).unwrap();
        self.pty.recv_timeout(REPLY_BOUND).unwrap_or_else(|_| {
            panic!("the host sent no reply to {query:?} within {REPLY_BOUND:?}")
        })
    }

    fn resize(&self, cols: u16, rows: u16, cell_pixels: (u16, u16)) {
        let (response, resized) = sync_channel(1);
        let command = ParserCommand::Resize {
            cols,
            rows,
            cell_pixels,
            source_cursor: None,
            acknowledge_with_replay: false,
            targeted_ack: None,
            response,
        };
        self.host.parser_commands.send(command).unwrap();
        let _ = resized.recv_timeout(REPLY_BOUND).expect("the parser applied the resize");
    }
}

#[test]
fn host_answers_xtwinops_and_in_band_size_queries() {
    let mut host = QueryHost::new();
    assert_eq!(host.reply_to(b"\x1b[18t"), b"\x1b[8;24;80t");
    assert_eq!(host.reply_to(b"\x1b[16t"), b"\x1b[6;16;8t");
    assert_eq!(host.reply_to(b"\x1b[14t"), b"\x1b[4;384;640t");

    host.resize(100, 30, (9, 18));
    assert_eq!(host.reply_to(b"\x1b[18t"), b"\x1b[8;30;100t", "the reply follows a resize");
    assert_eq!(host.reply_to(b"\x1b[16t"), b"\x1b[6;18;9t");

    // Enabling in-band size reports sends the current size at once.
    assert_eq!(host.reply_to(b"\x1b[?2048h"), b"\x1b[48;30;100;540;900t");
}

#[test]
fn host_answers_xtversion_as_ghostty() {
    let mut host = QueryHost::new();
    for query in [&b"\x1b[>q"[..], b"\x1b[>0q"] {
        let reply = host.reply_to(query);
        let version = reply
            .strip_prefix(b"\x1bP>|ghostty ")
            .and_then(|rest| rest.strip_suffix(b"\x1b\\"))
            .unwrap_or_else(|| {
                panic!("{query:?} got {:?}, not Ghostty's", String::from_utf8_lossy(&reply))
            });
        assert!(
            version.first().is_some_and(u8::is_ascii_digit),
            "the reply carries libghostty's version, got {:?}",
            String::from_utf8_lossy(version)
        );
    }
}

#[test]
fn host_answers_xtgettcap_tn_with_its_term() {
    let mut host = QueryHost::new();
    // XTGETTCAP keys and values are hex: "TN" is 544E, and the reply is
    // HOST_TERM ("xterm-ghostty"), as Ghostty reports its terminfo name.
    let reply = host.reply_to(b"\x1bP+q544E\x1b\\");
    assert_eq!(String::from_utf8_lossy(&reply), "\x1bP1+r544E=787465726D2D67686F73747479\x1b\\");
}
