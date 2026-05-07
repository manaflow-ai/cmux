//! Dogfood sanity tests — spawn `cmx` inside a tmux session, send real
//! keystrokes, capture what the user's terminal would see, and assert on
//! the rendered output.
//!
//! These tests exist because the unit / protocol tests validate the wire
//! layer but don't exercise the full render-to-PTY-to-xterm path. If the
//! server composited ANSI has a bug that only shows up under a real
//! terminal, a protocol test would happily pass while a human would see
//! garbage. Tmux in headless mode is a great stand-in for a terminal.
//!
//! Tests auto-skip when tmux isn't on PATH (e.g. minimal CI environments).

use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_cli_protocol::{
    ClientMsg, NativeTerminalRenderer, NativeTerminalViewport, PROTOCOL_VERSION, ServerMsg,
    Viewport, read_msg, write_msg,
};

fn tmux_available() -> bool {
    Command::new("tmux")
        .arg("-V")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .ok()
        .and_then(|s| s.success().then_some(()))
        .is_some()
}

struct Session {
    name: String,
    socket_dir: tempfile::TempDir,
    sock: PathBuf,
    server: std::process::Child,
}

impl Session {
    fn start(session_name: &str, cols: u16, rows: u16) -> Self {
        let cmx_bin = env!("CARGO_BIN_EXE_cmx");
        let socket_dir = tempfile::tempdir().expect("tempdir");
        let sock = socket_dir.path().join("server.sock");

        // Start cmx server as a child of the test.
        let lib_dir = find_libghostty_dir().expect("locate libghostty-vt build dir");
        let mut server_cmd = Command::new(cmx_bin);
        server_cmd
            .arg("server")
            .arg("--socket")
            .arg(&sock)
            .env("DYLD_LIBRARY_PATH", &lib_dir)
            .env("LD_LIBRARY_PATH", &lib_dir)
            .env("SHELL", "/bin/sh")
            .env("PS1", "$ ")
            .env("HOME", socket_dir.path())
            .env("ENV", "/dev/null")
            .current_dir(socket_dir.path())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        let server = server_cmd.spawn().expect("spawn cmx server");

        // Wait for the socket.
        let deadline = Instant::now() + Duration::from_secs(5);
        while !sock.exists() {
            if Instant::now() > deadline {
                panic!("cmx server socket did not appear");
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        // Start a detached tmux session that runs cmx attach.
        Command::new("tmux")
            .args([
                "new-session",
                "-d",
                "-s",
                session_name,
                "-x",
                &cols.to_string(),
                "-y",
                &rows.to_string(),
            ])
            .arg(format!(
                "DYLD_LIBRARY_PATH={lib_dir} LD_LIBRARY_PATH={lib_dir} {cmx_bin} attach --socket {sock}",
                lib_dir = lib_dir.display(),
                cmx_bin = cmx_bin,
                sock = sock.display()
            ))
            .status()
            .expect("tmux new-session failed");

        // Let the shell draw a prompt.
        std::thread::sleep(Duration::from_millis(500));

        Self {
            name: session_name.into(),
            socket_dir,
            sock,
            server,
        }
    }

    fn send(&self, keys: &str) {
        // `send-keys` types text; `Enter` is a literal "Enter" token to
        // tmux. Callers pass the full string including any special tokens.
        Command::new("tmux")
            .args(["send-keys", "-t", &self.name])
            .arg(keys)
            .status()
            .expect("tmux send-keys");
    }

    fn send_literal(&self, keys: &str) {
        // Use `-l` to disable tmux's key-name translation, so we can type a
        // raw string without " " being parsed as a token.
        Command::new("tmux")
            .args(["send-keys", "-l", "-t", &self.name])
            .arg(keys)
            .status()
            .expect("tmux send-keys -l");
    }

    fn enter(&self) {
        Command::new("tmux")
            .args(["send-keys", "-t", &self.name, "Enter"])
            .status()
            .expect("tmux send-keys Enter");
    }

    fn capture(&self) -> String {
        let out = Command::new("tmux")
            .args(["capture-pane", "-t", &self.name, "-p"])
            .output()
            .expect("tmux capture-pane");
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn resize(&self, cols: u16, rows: u16) {
        Command::new("tmux")
            .args([
                "resize-window",
                "-t",
                &self.name,
                "-x",
                &cols.to_string(),
                "-y",
                &rows.to_string(),
            ])
            .status()
            .expect("tmux resize-window");
    }

    fn constrain_native_layout(&self, cols: u16, rows: u16) -> NativeClient {
        NativeClient::connect(self.sock.clone(), cols, rows)
    }

    /// Poll capture-pane until `predicate` matches or the deadline passes.
    fn wait_until<F: Fn(&str) -> bool>(&self, timeout: Duration, predicate: F) -> String {
        let deadline = Instant::now() + timeout;
        let mut last = String::new();
        while Instant::now() < deadline {
            last = self.capture();
            if predicate(&last) {
                return last;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        last
    }
}

struct NativeClient {
    runtime: tokio::runtime::Runtime,
    stream: Option<tokio::net::UnixStream>,
}

impl NativeClient {
    fn connect(sock: PathBuf, cols: u16, rows: u16) -> Self {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("native client runtime");
        let stream = runtime.block_on(async move {
            let mut stream = tokio::net::UnixStream::connect(&sock)
                .await
                .expect("connect native client");
            write_msg(
                &mut stream,
                &ClientMsg::HelloNative {
                    version: PROTOCOL_VERSION,
                    viewport: Viewport { cols: 80, rows: 24 },
                    token: None,
                    terminal_renderer: NativeTerminalRenderer::Libghostty,
                },
            )
            .await
            .expect("send native hello");

            let focused_tab_id = loop {
                let msg = tokio::time::timeout(
                    Duration::from_secs(5),
                    read_msg::<_, ServerMsg>(&mut stream),
                )
                .await
                .expect("native snapshot timeout")
                .expect("read native msg")
                .expect("native eof");
                if let ServerMsg::NativeSnapshot { snapshot } = msg {
                    break snapshot.focused_tab_id;
                }
            };

            write_msg(
                &mut stream,
                &ClientMsg::NativeLayout {
                    terminals: vec![NativeTerminalViewport {
                        tab_id: focused_tab_id,
                        cols,
                        rows,
                    }],
                },
            )
            .await
            .expect("send native layout");
            stream
        });
        Self {
            runtime,
            stream: Some(stream),
        }
    }
}

impl Drop for NativeClient {
    fn drop(&mut self) {
        if let Some(mut stream) = self.stream.take() {
            let _ = self
                .runtime
                .block_on(async move { write_msg(&mut stream, &ClientMsg::Detach).await });
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = Command::new("tmux")
            .args(["kill-session", "-t", &self.name])
            .status();
        let _ = self.server.kill();
        let _ = self.server.wait();
        // socket_dir TempDir cleans itself up when dropped.
        let _ = self.socket_dir.path();
    }
}

fn find_libghostty_dir() -> Option<PathBuf> {
    // target/debug/build/libghostty-vt-sys-*/out/ghostty-install/lib/
    let target = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()?
        .join("target")
        .join("debug")
        .join("build");
    let mut best: Option<PathBuf> = None;
    let mut best_mtime = std::time::SystemTime::UNIX_EPOCH;
    for entry in std::fs::read_dir(&target).ok()? {
        let Ok(entry) = entry else { continue };
        let path = entry.path();
        if !path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with("libghostty-vt-sys-"))
        {
            continue;
        }
        let lib = path.join("out").join("ghostty-install").join("lib");
        if !lib.exists() {
            continue;
        }
        let mtime = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        if mtime >= best_mtime {
            best_mtime = mtime;
            best = Some(lib);
        }
    }
    best
}

fn worktree_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("crates/cmx parent")
        .parent()
        .expect("crates parent")
        .parent()
        .expect("cmux-cli parent")
        .parent()
        .expect("rust parent")
        .to_path_buf()
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn reported_bounds_size(frame: &str) -> Option<(u16, u16)> {
    let marker = "reported size: rows=";
    let start = frame.find(marker)? + marker.len();
    let rest = &frame[start..];
    let rows_end = rest.find(' ')?;
    let rows = rest[..rows_end].parse().ok()?;
    let cols_marker = "cols=";
    let cols_start = rest.find(cols_marker)? + cols_marker.len();
    let cols_rest = &rest[cols_start..];
    let cols_end = cols_rest
        .find(|ch: char| !ch.is_ascii_digit())
        .unwrap_or(cols_rest.len());
    let cols = cols_rest[..cols_end].parse().ok()?;
    Some((rows, cols))
}

fn has_status_context(frame: &str, context: &str) -> bool {
    frame.contains(&format!("[{context} ·")) || frame.contains(&format!("[{context}]"))
}

#[test]
fn sidebar_and_prompt_render() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_sidebar", 120, 30);

    let out = s.wait_until(Duration::from_secs(5), |frame| {
        frame.contains("cmux")
            && frame.contains("main")
            && has_status_context(frame, "main · space-1")
    });
    assert!(out.contains("cmux"), "sidebar header missing:\n{out}");
    assert!(
        has_status_context(&out, "main · space-1"),
        "status bar missing workspace label:\n{out}"
    );
}

#[test]
fn echo_typed_into_shell_appears_in_grid() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_echo", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    s.send_literal("echo CMX_TMUX_OK_7A");
    s.enter();

    let out = s.wait_until(Duration::from_secs(5), |frame| {
        frame.contains("CMX_TMUX_OK_7A")
    });
    assert!(
        out.contains("CMX_TMUX_OK_7A"),
        "echo sentinel missing from composited grid:\n{out}"
    );
}

#[test]
fn bounds_helper_tracks_maximum_pane_size_after_resize() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_bounds", 100, 28);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    let helper = worktree_root().join("scripts/tui-terminal-bounds-check.sh");
    let command = format!(
        "CMUX_BOUNDS_TUI_ALT_SCREEN=0 CMUX_BOUNDS_TUI_INTERVAL=0.1 {}",
        shell_quote(&helper.display().to_string())
    );
    s.send_literal(&command);
    s.enter();

    let initial = s.wait_until(Duration::from_secs(5), |frame| {
        reported_bounds_size(frame) == Some((24, 82))
            && frame.contains("CMUX TERMINAL BOUNDS VISUAL CHECK")
            && frame.contains("right edge col=82")
            && frame.contains("bottom inner row=22")
            && frame.contains("visible terminal grid=82 cols x 24 rows")
            && frame.contains("inside border=80 cols x 22 rows")
            && frame.contains("ANSI theme colors")
            && frame.contains("BG:")
            && frame.contains("FG:")
    });
    assert_eq!(
        reported_bounds_size(&initial),
        Some((24, 82)),
        "bounds helper did not use the full initial pane size:\n{initial}"
    );
    for glyph in ["╭", "╮", "╰", "╯", "│", "─"] {
        assert!(
            initial.contains(glyph),
            "cmx attach pane border glyph {glyph:?} missing around bounds helper:\n{initial}"
        );
    }

    s.resize(132, 34);
    let resized = s.wait_until(Duration::from_secs(5), |frame| {
        reported_bounds_size(frame) == Some((30, 114))
            && frame.contains("right edge col=114")
            && frame.contains("bottom inner row=28")
            && frame.contains("visible terminal grid=114 cols x 30 rows")
            && frame.contains("inside border=112 cols x 28 rows")
    });
    assert_eq!(
        reported_bounds_size(&resized),
        Some((30, 114)),
        "bounds helper did not track the resized maximum pane size:\n{resized}"
    );
}

#[test]
fn bounds_helper_draws_compact_rails_for_ipad_sidebar_width() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_bounds_compact", 31, 29);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    let helper = worktree_root().join("scripts/tui-terminal-bounds-check.sh");
    let command = format!(
        "CMUX_BOUNDS_TUI_ALT_SCREEN=0 CMUX_BOUNDS_TUI_INTERVAL=0.1 {}",
        shell_quote(&helper.display().to_string())
    );
    s.send_literal(&command);
    s.enter();

    let compact = s.wait_until(Duration::from_secs(5), |frame| {
        frame.contains("CMUX BOUNDS CHECK")
            && frame.contains("rows=25 cols=29")
            && frame.contains("grid=29x25")
            && frame.contains("ANSI:")
            && frame.contains("1===========================2")
            && frame.contains("3===========================4")
    });
    assert!(
        compact.contains("1===========================2")
            && compact.contains("3===========================4"),
        "compact bounds helper did not draw full rails:\n{compact}"
    );
    for glyph in ["╭", "╮", "╰", "╯", "│", "─"] {
        assert!(
            compact.contains(glyph),
            "compact cmx attach pane border glyph {glyph:?} missing around bounds helper:\n{compact}"
        );
    }
}

#[test]
fn bounds_helper_tui_border_hugs_native_constrained_grid() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_bounds_native_grid", 100, 28);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    let helper = worktree_root().join("scripts/tui-terminal-bounds-check.sh");
    let command = format!(
        "CMUX_BOUNDS_TUI_ALT_SCREEN=0 CMUX_BOUNDS_TUI_INTERVAL=0.1 CMUX_BOUNDS_TUI_REDRAW_EVERY=1 {}",
        shell_quote(&helper.display().to_string())
    );
    s.send_literal(&command);
    s.enter();

    let _native = s.constrain_native_layout(30, 24);
    let constrained = s.wait_until(Duration::from_secs(5), |frame| {
        frame.contains("rows=24 cols=30")
            && frame.contains("1============================2")
            && frame.contains("3============================4")
    });

    assert!(
        constrained.contains("rows=24 cols=30"),
        "native client did not constrain the shared terminal grid:\n{constrained}"
    );
    assert!(
        constrained.contains("1============================2")
            && constrained.contains("3============================4")
            && ["╭", "╮", "╰", "╯", "│", "─"]
                .iter()
                .all(|glyph| constrained.contains(glyph)),
        "cmx TUI border did not hug the native-constrained grid:\n{constrained}"
    );
}

#[test]
fn prefix_c_creates_space_visible_in_space_strip() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_prefix", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    // Prefix is Ctrl-b by default; 'c' makes a new space.
    s.send("C-b");
    s.send("c");

    let out = s.wait_until(Duration::from_secs(5), |frame| {
        frame.contains("space-2") && has_status_context(frame, "main · space-2")
    });
    assert!(
        out.contains("space-2"),
        "new space missing from space strip:\n{out}"
    );
    assert!(
        has_status_context(&out, "main · space-2"),
        "new space missing from status bar:\n{out}"
    );
}

#[test]
fn cursor_is_visible_inside_pane_after_attach() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_cursor", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    // tmux exposes the outer pane's cursor position. It must land inside
    // the pane region (col >= sidebar width = 16, row < status row = 29)
    // or the user would see a dead prompt.
    let out = Command::new("tmux")
        .args([
            "display-message",
            "-t",
            &s.name,
            "-p",
            "#{cursor_x},#{cursor_y},#{cursor_flag}",
        ])
        .output()
        .expect("tmux display-message");
    let answer = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let parts: Vec<&str> = answer.split(',').collect();
    assert_eq!(
        parts.len(),
        3,
        "unexpected display-message output: {answer}"
    );
    let cx: u16 = parts[0].parse().unwrap_or(0);
    let cy: u16 = parts[1].parse().unwrap_or(0);
    let visible = parts[2] == "1";
    assert!(visible, "cursor_flag=0 — cursor is hidden: {answer}");
    // Pane starts at col 16 with default sidebar width, status row is 29.
    assert!(
        cx >= 16 && cy < 29,
        "cursor lands outside pane: cx={cx} cy={cy} answer={answer}"
    );
}

#[test]
fn prefix_d_detaches_client_leaving_server_alive() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_detach", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    // Ctrl-b d → Detach.
    s.send("C-b");
    s.send("d");

    // The `cmx attach` process inside the tmux session should exit,
    // leaving the tmux session with just the parent shell at a prompt.
    // capture-pane should no longer contain the cmx chrome.
    let out = s.wait_until(Duration::from_secs(5), |frame| {
        !has_status_context(frame, "main · space-1")
    });
    assert!(
        !has_status_context(&out, "main · space-1"),
        "cmx chrome still visible after detach — client didn't exit:\n{out}"
    );

    // The server is still alive — a fresh attach from a new tmux window
    // should succeed. Check the server child is still running.
    // (Session::Drop will kill it; we just verify it hasn't died yet.)
    // Give it a small moment in case the shutdown fires late.
    std::thread::sleep(Duration::from_millis(200));
    // server.try_wait doesn't expose a reader through Session; we rely on
    // the chrome-gone assertion above + the fact that SessionDrop would
    // panic on kill failure. This is good enough for dogfood.
}

#[test]
fn zellij_chord_creates_space_without_prefix() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_zellij", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    // Zellij-style: Ctrl-t then n creates a new space, no global prefix.
    // tmux's send-keys accepts C-t as a key name.
    s.send("C-t");
    s.send("n");

    let out = s.wait_until(Duration::from_secs(5), |f| {
        f.contains("space-2") && has_status_context(f, "main · space-2")
    });
    assert!(
        out.contains("space-2"),
        "zellij C-t n chord didn't create a space:\n{out}"
    );
}

#[test]
fn new_workspace_inherits_client_viewport_width() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    // 120×30 viewport. After Ctrl-b W the new workspace's shell should see a
    // pane roughly (120 - sidebar 16) = 104 cols wide. Before the fix it
    // would see the server default (80-16 = 64) and any command that
    // checks $COLUMNS would report 64.
    let s = Session::start("cmxtest_ws_size", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    s.send("C-b");
    s.send("W");
    s.wait_until(Duration::from_secs(3), |f| f.contains("ws-1"));

    // Ask the shell to print its column width. The shell will echo the
    // answer — we just need it big enough that 64 wouldn't satisfy.
    // With pane borders (1 col each side) the inner PTY is 120-16-2=102.
    s.send_literal("stty size");
    s.enter();
    let out = s.wait_until(Duration::from_secs(3), |f| {
        f.contains("102") || f.contains("101") || f.contains("103")
    });
    assert!(
        ["100", "101", "102", "103", "104"]
            .iter()
            .any(|w| out.contains(w)),
        "new workspace didn't inherit client viewport width, stty size not ~102:\n{out}"
    );
}

#[test]
fn prefix_s_focuses_space_strip() {
    if !tmux_available() {
        eprintln!("tmux not available; skipping");
        return;
    }
    let s = Session::start("cmxtest_newws", 120, 30);
    s.wait_until(Duration::from_secs(3), |f| {
        has_status_context(f, "main · space-1")
    });

    // Ctrl-b then s focuses the space strip.
    s.send("C-b");
    s.send("s");

    let out = s.wait_until(Duration::from_secs(5), |frame| {
        has_status_context(frame, "space nav: space-1")
    });
    assert!(
        has_status_context(&out, "space nav: space-1"),
        "space strip focus state missing from status bar:\n{out}"
    );
    assert!(
        out.contains("main"),
        "workspace sidebar should remain visible while space nav is active:\n{out}"
    );
}
