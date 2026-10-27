//! `mux2-wrapcheck [FILE...]`: exactness gate for the ghostty-vt wrapper's
//! skipping fast path. Feeds the same bytes, in many chunkings, to one
//! terminal through `vt_write_with_normalized` and to another through the
//! original byte-at-a-time `vt_write_with_normalized_reference`, and requires
//! identical results: every accepted (normalized) chunk, and at the end the
//! replay, screen text, title, pwd, cursor, screen, modes and every tracker
//! revision the wrapper exposes. Inputs: the given files plus a seeded
//! adversarial corpus. Prints one JSON line per case; exits 1 on any
//! difference.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

use std::process::ExitCode;

use ghostty_vt::{Callbacks, Terminal};

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
    /// A random item; `None` only when `items` is empty.
    fn pick<'a>(&mut self, items: &'a [&'a [u8]]) -> Option<&'a [u8]> {
        if items.is_empty() {
            return None;
        }
        items.get(self.below(items.len() as u64) as usize).copied()
    }
}

/// Text, UTF-8 (valid and invalid), C0/C1 controls, and every sequence
/// family a tracker watches, concatenated at random.
fn adversarial(seed: u64, len: usize) -> Vec<u8> {
    let pieces: &[&[u8]] = &[
        b"plain ascii words ",
        b"\r\n",
        b"\n",
        b"\x0b",
        b"\x0c",
        b"\t",
        b"\x07",
        b"\x18",
        b"\x1a",
        b"\x05",
        b"\x00",
        "é".as_bytes(),
        "中文".as_bytes(),
        "😀".as_bytes(),
        "e\u{301}".as_bytes(),
        b"\xc3",
        b"\xe4\xb8",
        b"\xf0\x9f\x98",
        b"\x80",
        b"\x9b",
        b"\x9d",
        b"\x90",
        b"\x9f",
        b"\x9c",
        b"\xff",
        b"\xc0\xaf",
        b"\xed\xa0\x80",
        b"\x1b",
        b"\x1b[",
        b"\x1b[0m",
        b"\x1b[1;31m",
        b"\x1b[38;5;200m",
        b"\x1b[48;2;1;2;3m",
        b"\x1b[2J",
        b"\x1b[H",
        b"\x1b[5;10H",
        b"\x1b[?1049h",
        b"\x1b[?1049l",
        b"\x1b[?1000h",
        b"\x1b[?1002h",
        b"\x1b[?1003h",
        b"\x1b[?1006h",
        b"\x1b[?1015h",
        b"\x1b[?1016h",
        b"\x1b[?1000l",
        b"\x1b[?1006l",
        b"\x1b[2 q",
        b"\x1b[5 q",
        b"\x1b[0 q",
        b"\x1b[6n",
        b"\x1b[c",
        b"\x1b[>c",
        b"\x1b[?2004h",
        b"\x1b[?25l",
        b"\x1b[?25h",
        b"\x1bc",
        b"\x1b7",
        b"\x1b8",
        b"\x1bD",
        b"\x1bE",
        b"\x1bM",
        b"\x1b(0",
        b"\x1b(B",
        b"\x1b[3;20r",
        b"\x1b[r",
        b"\x1b]0;title one\x07",
        b"\x1b]2;title two\x1b\\",
        b"\x1b]7;file://host/tmp/dir\x07",
        b"\x1b]4;1;rgb:ff/00/00\x07",
        b"\x1b]4;1;?\x07",
        b"\x1b]104;1\x07",
        b"\x1b]104\x07",
        b"\x1b]10;#123456\x07",
        b"\x1b]11;rgb:01/02/03\x1b\\",
        b"\x1b]12;red\x07",
        b"\x1b]110\x07",
        b"\x1b]111\x07",
        b"\x1b]112\x07",
        b"\x1b]10;?\x07",
        b"\x1b]52;c;aGVsbG8=\x07",
        b"\x1b]133;A\x07",
        b"\x1b]133;B\x07",
        b"\x1b]133;C\x07",
        b"\x1b]133;D;0\x07",
        b"\x1b]133;I\x07",
        b"\x1b]133;P;k=i\x07",
        b"\x1b]8;;https://x.y\x07link\x1b]8;;\x07",
        b"\x1b]7501;state=working\x07",
        b"\x1bP+q544e\x1b\\",
        b"\x1bP$qm\x1b\\",
        b"\x1bPtmux;\x1b\x1b[1m\x1b\\",
        b"\x1b_Ga=q,i=1;AAAA\x1b\\",
        b"\x1b_G\x1b\\",
        b"\x1b_Gf=24,s=1,v=1,a=T;AAAA\x1b\\",
        b"\x1b^pm\x1b\\",
        b"\x1bXsos\x1b\\",
        b"\x1b[?u",
        b"\x1b[>1u",
        b"\x1b[<u",
        b"\x1b[18t",
        b"\x1b[8;30;100t",
        b"\x9b0m",
        b"\x9d0;c1 title\x9c",
        b"\x1b]0;unterminated",
        b"\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16m",
    ];
    let mut rng = Rng(seed | 1);
    let mut out = Vec::with_capacity(len + 64);
    while out.len() < len {
        let Some(piece) = rng.pick(pieces) else { break };
        out.extend_from_slice(piece);
        if rng.below(4) == 0 {
            // Raw noise bytes, any value.
            for _ in 0..rng.below(6) {
                out.push(rng.next() as u8);
            }
        }
    }
    out
}

fn new_terminal() -> Result<Terminal, String> {
    Terminal::new(97, 31, 2_000_000, Callbacks::default()).map_err(|e| format!("terminal: {e}"))
}

fn observe(t: &mut Terminal) -> Vec<String> {
    let mut v = vec![
        format!("replay={:?}", t.vt_replay_bytes().ok()),
        format!("viewport={:?}", t.viewport_text().ok()),
        format!("plain={:?}", t.plain_text().ok()),
        format!("title={:?} pwd={:?}", t.title(), t.pwd()),
        format!(
            "cursor={:?} screen={:?} at_prompt={}",
            t.cursor_position(),
            t.active_screen(),
            t.cursor_is_at_prompt()
        ),
        format!("history_rows={} scrollback_rows={}", t.history_rows(), t.scrollback_rows()),
        format!(
            "prompt_rev={} color_rev={} color_reapply_rev={}",
            t.prompt_semantic_revision(),
            t.color_revision(),
            t.color_reapply_revision()
        ),
        format!("mouse={:?} tracking={}", t.active_mouse_format(), t.mouse_tracking()),
        format!("colors={:?} cursor_overridden={}", t.effective_colors(), t.cursor_overridden()),
        format!("ground={} resumes={}", t.vt_stream_is_ground(), t.vt_replay_resumes_stream()),
    ];
    for mode in [1u16, 7, 25, 47, 1000, 1002, 1003, 1004, 1006, 1015, 1016, 1047, 1049, 2004, 2026]
    {
        v.push(format!("mode{mode}={}", t.mode(mode, false)));
    }
    v.push(format!("palette1={}", t.palette_overridden(1)));
    v
}

fn check(
    name: &str,
    data: &[u8],
    chunking: &str,
    sizes: &mut dyn FnMut() -> usize,
) -> Result<bool, String> {
    let (mut fast, mut slow) = (new_terminal()?, new_terminal()?);
    let mut at = 0;
    let mut writes = 0u64;
    let mut rest = data;
    while !rest.is_empty() {
        // A size past the end takes what is left.
        let (chunk, tail) = rest.split_at_checked(sizes().max(1)).unwrap_or((rest, &[]));
        let a = fast.vt_write_with_normalized(chunk).into_owned();
        let b = slow.vt_write_with_normalized_reference(chunk).into_owned();
        if a != b {
            println!(
                "{{\"wrapcheck\":\"{name}\",\"chunking\":\"{chunking}\",\"ok\":false,\"diff\":\"normalized chunk at byte {at}\"}}"
            );
            return Ok(false);
        }
        writes += 1;
        at += chunk.len();
        rest = tail;
    }
    let (oa, ob) = (observe(&mut fast), observe(&mut slow));
    let first = oa.iter().zip(&ob).find(|(x, y)| x != y).map(|(x, _)| x);
    let ok = first.is_none();
    let what = first.map_or(String::new(), |x| x.split('=').next().unwrap_or("").to_string());
    println!(
        "{{\"wrapcheck\":\"{name}\",\"chunking\":\"{chunking}\",\"bytes\":{},\"writes\":{writes},\"ok\":{ok},\"diff\":\"{what}\"}}",
        data.len()
    );
    Ok(ok)
}

fn main() -> ExitCode {
    match run() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(why) => {
            eprintln!("mux2-wrapcheck: {why}");
            ExitCode::from(2)
        }
    }
}

/// True when every case matched.
fn run() -> Result<bool, String> {
    let mut inputs: Vec<(String, Vec<u8>)> = std::env::args()
        .skip(1)
        .map(|p| {
            let data = std::fs::read(&p).map_err(|e| format!("read {p}: {e}"))?;
            // Bound real files so the 1-byte chunking stays quick.
            Ok((p, data.into_iter().take(8 << 20).collect()))
        })
        .collect::<Result<_, String>>()?;
    for seed in 1..=24u64 {
        inputs.push((
            format!("adversarial-{seed}"),
            adversarial(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15), 1 << 18),
        ));
    }
    let mut all_ok = true;
    for (name, data) in &inputs {
        for fixed in [1usize, 2, 3, 7, 64, 4096, 16384, 1 << 20] {
            all_ok &= check(name, data, &format!("fixed-{fixed}"), &mut || fixed)?;
        }
        let mut rng = Rng(0x5eed ^ data.len() as u64);
        all_ok &= check(name, data, "random", &mut || 1 + rng.below(9000) as usize)?;
    }
    println!("{{\"wrapcheck_all_ok\":{all_ok}}}");
    Ok(all_ok)
}
