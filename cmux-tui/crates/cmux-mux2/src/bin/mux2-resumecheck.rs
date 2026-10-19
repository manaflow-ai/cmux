//! `mux2-resumecheck FILE [STEP]`: does a snapshot taken at any byte resume
//! the stream exactly? For split points p every STEP bytes (and at every
//! byte of the 4 KiB around each point that fails), it builds a terminal
//! from `parse(file[..p]).vt_replay_bytes()`, feeds `file[p..]`, and
//! compares screen text and canonical replay with `parse(file)`. Reports the
//! first failing split and the parser state there. One JSON line.

use ghostty_vt::{Callbacks, Terminal};

const COLS: u16 = 120;
const ROWS: u16 = 40;

fn parse(bytes: &[u8]) -> Terminal {
    let mut t = Terminal::new(COLS, ROWS, 10_000_000, Callbacks::default()).expect("terminal");
    t.vt_write(bytes);
    t
}

fn onlcr(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + data.len() / 16);
    for &b in data {
        if b == b'\n' {
            out.push(b'\r');
        }
        out.push(b);
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let data = onlcr(
        &std::fs::read(args.first().expect("usage: mux2-resumecheck FILE [STEP]")).expect("read"),
    );
    let step: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(1 << 16);
    let mut whole = parse(&data);
    let want_screen = whole.viewport_text().expect("screen");
    let want_rt = parse(&whole.vt_replay_bytes().expect("replay")).vt_replay_bytes().expect("rt");

    let mut checked = 0u64;
    let mut failures = 0u64;
    let mut first: Option<String> = None;
    let mut p = step;
    while p < data.len() {
        let mut head = parse(&data[..p]);
        let ground = head.vt_stream_is_ground();
        let resumes = head.vt_replay_resumes_stream();
        let replay = head.vt_replay_bytes().expect("replay");
        let mut resumed = parse(&replay);
        resumed.vt_write(&data[p..]);
        let screen_ok = resumed.viewport_text().expect("screen") == want_screen;
        let rt_ok =
            parse(&resumed.vt_replay_bytes().expect("replay")).vt_replay_bytes().expect("rt")
                == want_rt;
        checked += 1;
        if !(screen_ok && rt_ok) {
            failures += 1;
            if first.is_none() {
                if let Some(dir) = std::env::var_os("MUX2_RESUME_DUMP") {
                    let dir = std::path::PathBuf::from(dir);
                    let _ = std::fs::create_dir_all(&dir);
                    let _ = std::fs::write(dir.join("snapshot.vt"), &replay);
                    let _ = std::fs::write(
                        dir.join("resumed.vt"),
                        resumed.vt_replay_bytes().expect("replay"),
                    );
                    let _ = std::fs::write(
                        dir.join("whole.vt"),
                        whole.vt_replay_bytes().expect("replay"),
                    );
                }
                let lo = p.saturating_sub(48);
                first = Some(format!(
                    "{{\"split\":{p},\"ground\":{ground},\"resumes\":{resumes},\"screen_ok\":{screen_ok},\"rt_ok\":{rt_ok},\"before\":{:?},\"after\":{:?}}}",
                    String::from_utf8_lossy(&data[lo..p]),
                    String::from_utf8_lossy(&data[p..(p + 48).min(data.len())])
                ));
            }
        }
        p += step;
    }
    println!(
        "{{\"resumecheck\":{:?},\"bytes\":{},\"splits\":{checked},\"failures\":{failures},\"first\":{}}}",
        args[0],
        data.len(),
        first.unwrap_or_else(|| "null".into())
    );
}
