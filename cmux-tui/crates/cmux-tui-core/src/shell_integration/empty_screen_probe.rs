//! EXPERIMENT, not for merge (EMPTY FRESH SCREEN probe): with real zsh and
//! the injected Ghostty integration, does a grid change the shell never
//! answers clear its prompt for good? The terminal here applies each resize
//! at the stream point a terminal host publishes it: every chunk read before
//! the resize, then the grid resize, then the PTY resize (SIGWINCH).

use super::test_pty::{TestPty, shell_path};
use super::*;
use std::fmt::Write as _;
use std::time::{Duration, Instant};

fn temp_base(name: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "cmux-tui-empty-probe-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    fs::create_dir_all(&base).unwrap();
    fs::canonicalize(&base).unwrap()
}

fn launch_zsh(base: &Path) -> ShellLaunch {
    let user = base.join("user");
    fs::create_dir_all(&user).unwrap();
    fs::write(user.join(".zshrc"), "PS1='$ '\n").unwrap();
    let env = vec![
        ("HOME".to_string(), base.to_string_lossy().into_owned()),
        ("ZDOTDIR".to_string(), user.to_string_lossy().into_owned()),
    ];
    let root = materialize(&base.join("shell-integration").join(content_digest())).unwrap();
    let lookup = {
        let env = env.clone();
        move |key: &str| env.iter().rev().find(|(name, _)| name == key).map(|(_, v)| v.clone())
    };
    apply(Shell::Zsh, &root, vec!["/bin/zsh".into()], env, &lookup, &ghostty_files::read(&lookup))
}

struct Run {
    pty: TestPty,
    term: ghostty_vt::Terminal,
    bytes: Vec<u8>,
}

impl Run {
    fn start(launched: &ShellLaunch, cols: u16, rows: u16) -> Self {
        let size = cmux_pty::PtySize { rows, cols, pixel_width: 0, pixel_height: 0 };
        let mut command = cmux_pty::PtyCommand::new(&launched.command[0]);
        command.args(launched.command[1..].iter().cloned());
        command.env("TERM", "xterm-256color");
        for (key, value) in &launched.env {
            command.env(key.clone(), value.clone());
        }
        let pty = TestPty::spawn(size, command);
        let mut term =
            ghostty_vt::Terminal::new(cols, rows, 10_000, ghostty_vt::Callbacks::default())
                .unwrap();
        term.resize(cols, rows, 8, 17).unwrap();
        Self { pty, term, bytes: Vec::new() }
    }

    /// Applies every chunk already read (published before what comes next).
    fn drain(&mut self) -> usize {
        let mut total = 0;
        while let Ok(chunk) = self.pty.recv_timeout(Duration::ZERO) {
            total += chunk.len();
            self.term.vt_write(&chunk);
            self.bytes.extend_from_slice(&chunk);
        }
        total
    }

    /// Reads until `quiet` passes with no output (after `needle`, if any).
    fn pump(&mut self, needle: Option<&[u8]>, quiet: Duration) -> usize {
        let deadline = Instant::now() + Duration::from_secs(15);
        let start = self.bytes.len();
        loop {
            let found = needle.is_none_or(|needle| {
                self.bytes[start..].windows(needle.len()).any(|window| window == needle)
            });
            let wait = if found { quiet } else { Duration::from_millis(50) };
            match self.pty.recv_timeout(wait) {
                Ok(chunk) => {
                    self.term.vt_write(&chunk);
                    self.bytes.extend_from_slice(&chunk);
                }
                Err(_) if found => return self.bytes.len() - start,
                Err(_) => {}
            }
            if Instant::now() > deadline {
                return self.bytes.len() - start;
            }
        }
    }

    /// The host's order: chunks read so far, the grid, then the PTY.
    fn resize(&mut self, cols: u16, rows: u16) {
        self.drain();
        self.term.resize(cols, rows, 8, 17).unwrap();
        self.pty
            .spawned
            .master
            .resize(cmux_pty::PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .unwrap();
    }

    fn screen(&mut self) -> (String, (u16, u16)) {
        let text = self.term.active_text().unwrap();
        let cursor = self.term.cursor_position().unwrap_or((0, 0));
        (text.trim().to_string(), cursor)
    }
}

fn record(out: &mut String, label: &str, run: &mut Run, after: usize) -> bool {
    let (text, cursor) = run.screen();
    let blank = text.is_empty();
    let _ = writeln!(
        out,
        "{label}: blank={blank} cursor={cursor:?} bytes_after_last_resize={after} text={:?}",
        text.chars().take(60).collect::<String>()
    );
    blank
}

fn finish(out: String) {
    eprintln!("{out}");
    panic!("PROBE RESULT (not a test failure):\n{out}");
}

#[test]
fn empty_screen_probe_bounce_after_prompt() {
    let Some(_) = shell_path(Shell::Zsh) else { return };
    let base = temp_base("bounce");
    let launched = launch_zsh(&base);
    let mut out = String::new();
    let mut blanks = 0;
    for i in 0..8 {
        let mut run = Run::start(&launched, 34, 37);
        run.pump(Some(b"$ "), Duration::from_millis(400));
        run.resize(35, 37);
        run.resize(34, 37);
        let after = run.pump(None, Duration::from_millis(700));
        blanks += usize::from(record(&mut out, &format!("A bounce {i}"), &mut run, after));
    }
    let _ = writeln!(out, "A: {blanks}/8 blank");
    let mut blanks = 0;
    for i in 0..4 {
        let mut run = Run::start(&launched, 34, 37);
        run.pump(Some(b"$ "), Duration::from_millis(400));
        run.resize(35, 37);
        let after = run.pump(None, Duration::from_millis(700));
        blanks += usize::from(record(&mut out, &format!("C single {i}"), &mut run, after));
    }
    let _ = writeln!(out, "C: {blanks}/4 blank");
    let _ = fs::remove_dir_all(&base);
    finish(out);
}

fn early_then_back(delays: &[u64], per: usize, label: &str) {
    let Some(_) = shell_path(Shell::Zsh) else { return };
    let base = temp_base(label);
    let launched = launch_zsh(&base);
    let mut out = String::new();
    for &delay in delays {
        let mut blanks = 0;
        for i in 0..per {
            let mut run = Run::start(&launched, 34, 37);
            std::thread::sleep(Duration::from_millis(delay));
            run.resize(50, 37);
            run.pump(Some(b"$ "), Duration::from_millis(400));
            run.resize(34, 37);
            let after = run.pump(None, Duration::from_millis(700));
            blanks += usize::from(record(
                &mut out,
                &format!("{label} early {delay}ms {i}"),
                &mut run,
                after,
            ));
        }
        let _ = writeln!(out, "{label} delay {delay}ms: {blanks}/{per} blank");
    }
    let _ = fs::remove_dir_all(&base);
    finish(out);
}

#[test]
fn empty_screen_probe_early_resize_then_back_fast() {
    early_then_back(&[0, 1, 2, 5], 5, "B1");
}

#[test]
fn empty_screen_probe_early_resize_then_back_slow() {
    early_then_back(&[10, 20, 40, 80], 5, "B2");
}
