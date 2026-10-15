//! cx-6so.42: the host's parser is the only replier for its terminal (the
//! daemon and app mirrors never answer), so it must answer size queries the
//! way Ghostty does: XTWINOPS CSI 14/16/18 t and in-band reports (mode 2048).

use super::*;
use crate::terminal_host_runtime::shared::clipboard_read::{ClipboardReads, SystemClock};

const REPLY_BOUND: Duration = Duration::from_secs(10);

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
        let term = Terminal::new(80, 24, 0, signals.callbacks(&clipboard)).unwrap();
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
