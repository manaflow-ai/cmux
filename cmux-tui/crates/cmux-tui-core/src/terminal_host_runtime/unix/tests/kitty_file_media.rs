//! Kitty file-medium images through the terminal host: the PTY reader's
//! rewrite turns `t=f` into chunked direct data that the host's own
//! terminal (file media off) and every viewer load, and its output reaches
//! the parser in frames no larger than one read.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_kitty_media::KittyMediaRewriter;

use super::super::super::shared::host_start::publish_pty_output;
use super::host_fixture::test_host_shared_with_budget;
use super::*;

const PNG_1X1_RED: &str = concat!(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA",
    "DUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
);

struct ScratchDir(PathBuf);

impl ScratchDir {
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "cmux-kitty-file-media-{name}-{}-{}",
            std::process::id(),
            RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn file(&self, name: &str, data: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, data).unwrap();
        path
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn file_command(control: &str, path: &Path) -> Vec<u8> {
    let encoded = STANDARD.encode(path.as_os_str().as_encoded_bytes());
    format!("\x1b_G{control};{encoded}\x1b\\").into_bytes()
}

fn host_terminal() -> Terminal {
    let mut terminal = Terminal::new(20, 8, 100, Callbacks::default()).unwrap();
    terminal.resize(20, 8, 10, 20).unwrap();
    terminal
}

fn rewrite(input: &[u8]) -> Vec<u8> {
    let mut rewriter = KittyMediaRewriter::new();
    let mut out = Vec::new();
    rewriter.rewrite(input, &mut out);
    rewriter.finish(&mut out);
    out
}

#[test]
fn file_medium_png_loads_in_the_host_terminal_only_after_rewrite() {
    let dir = ScratchDir::new("png");
    let png = STANDARD.decode(PNG_1X1_RED).unwrap();
    let path = dir.file("red.png", &png);
    let command = file_command("a=t,f=100,i=7,t=f", &path);

    // The host keeps file media off, so the raw command loads nothing:
    // a viewer on another machine could not open the path either.
    let mut raw = host_terminal();
    raw.vt_write(&command);
    assert!(raw.kitty_graphics_snapshot().unwrap().image(7).is_none());

    let mut term = host_terminal();
    term.vt_write(&rewrite(&command));
    let snapshot = term.kitty_graphics_snapshot().unwrap();
    let image = snapshot.image(7).expect("the rewritten PNG loads");
    assert_eq!((image.width, image.height), (1, 1));
}

#[test]
fn chunked_raw_pixels_load_exactly_across_split_reads() {
    let dir = ScratchDir::new("rgb");
    let pixels: Vec<u8> = (0..64 * 64 * 3).map(|index| (index % 251) as u8).collect();
    let path = dir.file("pixels.rgb", &pixels);
    let mut input = b"text before ".to_vec();
    input.extend(file_command("a=t,f=24,s=64,v=64,i=9,t=f", &path));
    input.extend_from_slice(b" after");

    let mut rewriter = KittyMediaRewriter::new();
    let mut term = host_terminal();
    for read in input.chunks(7) {
        let mut out = Vec::new();
        rewriter.rewrite(read, &mut out);
        term.vt_write(&out);
    }
    let snapshot = term.kitty_graphics_snapshot().unwrap();
    let image = snapshot.image(9).expect("the chunked upload completes");
    assert_eq!(&*image.data, &pixels[..]);
    assert!(term.viewport_text().unwrap().contains("text before  after"));
}

#[test]
fn rewritten_output_reaches_the_parser_in_read_sized_frames() {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        MAX_HOST_PARSER_QUEUED_BYTES,
    );
    assert!(publish_pty_output(&host, &[]), "a fully held read publishes nothing");
    assert!(receiver.try_recv().is_err());

    let output: Vec<u8> = (0..200_000).map(|index| (index % 253) as u8).collect();
    assert!(publish_pty_output(&host, &output));
    let mut received = Vec::new();
    let mut last_cursor = 0;
    while let Ok(ParserCommand::Output { bytes, source_cursor, accounted_bytes }) =
        receiver.try_recv()
    {
        assert!(bytes.len() <= 64 * 1024);
        assert_eq!(accounted_bytes, bytes.len());
        assert!(source_cursor > last_cursor);
        last_cursor = source_cursor;
        received.extend(bytes);
    }
    assert_eq!(received, output);
}
