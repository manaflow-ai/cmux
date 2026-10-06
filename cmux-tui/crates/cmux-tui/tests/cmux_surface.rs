//! The binary run as `cmux` shows and accepts only the curated scopes; run as
//! `cmux-tui` it keeps the full grammar its own tooling uses
//! (plans/cmux-next/state-ownership.md, section 5).
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Names {
    dir: PathBuf,
}

impl Names {
    fn new(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-surface-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        for name in ["cmux", "cmux-tui"] {
            symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join(name)).unwrap();
        }
        Self { dir }
    }

    fn run(&self, name: &str, args: &[&str]) -> Output {
        Command::new(self.dir.join(name))
            .args(args)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .output()
            .unwrap()
    }

    fn missing(&self, name: &str) -> String {
        self.dir.join(name).display().to_string()
    }
}

impl Drop for Names {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn cmux_help_lists_only_the_curated_scopes() {
    let names = Names::new("help");
    let output = names.run("cmux", &["--help"]);
    assert!(output.status.success(), "{}", text(&output.stderr));
    let help = text(&output.stdout);
    for scope in ["workspace", "terminal", "notification", "acp", "window", "settings", "events"] {
        assert!(help.contains(&format!("  {scope} ")), "{scope} missing:\n{help}");
    }
    for hidden in ["raw", "provider", "pairing", "projection", "sidebar", "client", "machine"] {
        assert!(!help.contains(&format!("  {hidden} ")), "{hidden} listed:\n{help}");
    }
    assert!(help.contains("--idempotency-key"), "{help}");
    // `cmux-tui` still documents its full grammar.
    let full = text(&names.run("cmux-tui", &["--help"]).stdout);
    assert!(full.contains("  raw "), "{full}");
}

#[test]
fn cmux_refuses_hidden_scopes_before_touching_a_socket() {
    let names = Names::new("refuse");
    let socket = names.missing("mux.sock");
    for args in [
        vec!["raw", "command", "--request-json", "{\"cmd\":\"identify\"}"],
        vec!["session", "current", "snapshot"],
        vec!["projection", "show"],
        vec!["provider", "authority", "install"],
    ] {
        let mut argv = vec!["--socket", socket.as_str(), "--app-socket", socket.as_str()];
        argv.extend(&args);
        let output = names.run("cmux", &argv);
        assert_eq!(output.status.code(), Some(2), "{args:?}: {}", text(&output.stderr));
        assert!(text(&output.stderr).contains("is not part of cmux"), "{}", text(&output.stderr));
    }
}

#[test]
fn cmux_tui_still_sends_the_cloud_guest_spellings() {
    let names = Names::new("guest");
    let socket = names.missing("mux.sock");
    // Parsing succeeds; only the missing socket fails (exit 3, not usage 2).
    for args in [
        vec!["raw", "command", "--request-json", "{\"cmd\":\"url-open\"}"],
        vec!["--json", "session", "current", "snapshot"],
    ] {
        let mut argv = vec!["--socket", socket.as_str()];
        argv.extend(&args);
        let output = names.run("cmux-tui", &argv);
        assert_eq!(output.status.code(), Some(3), "{args:?}: {}", text(&output.stderr));
    }
}

/// Workspace groups, rooms and closed history are daemon resources: the
/// `cmux` name sends them to the session socket, never to the app.
#[test]
fn cmux_state_scopes_go_to_the_session_daemon() {
    let names = Names::new("group");
    let socket = names.missing("mux.sock");
    for args in [
        vec!["workspace", "group", "list"],
        vec!["room", "list"],
        vec!["closed", "list"],
        vec!["tab", "group", "list"],
    ] {
        let mut full = vec!["--socket", socket.as_str()];
        full.extend(args.iter().copied());
        let output = names.run("cmux", &full);
        let stderr = text(&output.stderr);
        assert_eq!(output.status.code(), Some(3), "{args:?}: {stderr}");
        assert!(stderr.contains("no cmux session is running"), "{args:?}: {stderr}");
    }
}

#[test]
fn private_process_modes_run_under_the_cmux_name() {
    let names = Names::new("process");
    for args in [
        ["machine-agent", "--help"],
        ["relay", "--help"],
        ["wg", "--help"],
        ["remote-probe", "--help"],
        ["remote-link", "--help"],
        ["install-self", "--help"],
    ] {
        let output = names.run("cmux", &args);
        let stderr = text(&output.stderr);
        assert!(
            !stderr.contains("not part of cmux") && !stderr.contains("unknown resource scope"),
            "{args:?}: {stderr}"
        );
        assert!(!output.stdout.is_empty() || !stderr.is_empty(), "{args:?} printed nothing");
    }
}

/// A one-connection app socket that answers every request with `result`.
/// The socket lives in a short directory from the shared helper, so its path
/// fits sun_path whatever $TMPDIR is. The returned guard removes it.
fn fake_app(
    result: serde_json::Value,
) -> (cmux_unix_socket::TestDir, PathBuf, std::thread::JoinHandle<()>) {
    use std::io::{BufRead, BufReader, Write};
    let dir = cmux_unix_socket::short_test_dir("cmux-sfc");
    let socket = dir.path().join("app.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            let request: serde_json::Value = serde_json::from_str(&line).unwrap();
            line.clear();
            let reply = serde_json::json!({"id": request["id"], "ok": true, "result": result});
            writeln!(writer, "{reply}").unwrap();
        }
    });
    (dir, socket, handle)
}

#[test]
fn accounts_list_warns_on_stderr_when_handles_are_not_stable() {
    for (stable, warns) in [(false, true), (true, false)] {
        let names = Names::new(&format!("handles-{stable}"));
        let result =
            serde_json::json!({"signed_in": true, "handles_stable": stable, "providers": []});
        let (_socket_dir, socket, app) = fake_app(result);
        let socket = socket.display().to_string();
        let output = names.run("cmux", &["--app-socket", &socket, "accounts", "list"]);
        app.join().unwrap();
        let stderr = text(&output.stderr);
        assert!(output.status.success(), "{stderr}");
        assert_eq!(
            stderr.contains("account handles change after restart: Keychain unavailable"),
            warns,
            "handles_stable {stable}: {stderr}"
        );
    }
}

/// Each scope `cmux --help` lists answers `<scope> --help` and `help <scope>`
/// with its own usage, never the root help (the app scopes route before the
/// resource grammar; `window` is the app's windows, not a screen shorthand).
#[test]
fn every_routed_scope_prints_its_own_help() {
    let names = Names::new("scope-help");
    let cases: &[(&[&str], &str)] = &[
        (&["settings", "--help"], "cmux settings get"),
        (&["help", "settings"], "cmux settings get"),
        (&["window", "--help"], "cmux window list"),
        (&["help", "window"], "cmux window list"),
        (&["events", "--help"], "cmux events [--after"),
        (&["history", "--help"], "cmux history search"),
        (&["bookmark", "--help"], "cmux bookmark search"),
        (&["app", "--help"], "cmux app ping"),
        (&["action", "--help"], "cmux action describe"),
        (&["accounts", "--help"], "cmux accounts list"),
        (&["open", "--help"], "cmux open <path|url>"),
        (&["keybinding", "--help"], "cmux keybinding list"),
        (&["ghostty", "--help"], "cmux ghostty diagnostics"),
        (&["browser", "page", "--help"], "cmux browser <tab_…|page> navigate"),
        (&["browser", "--help"], "cmux browser page|<tab_…>"),
        (&["browser", "--help"], "cmux browser open <url> [--workspace <selector>]"),
        (&["browser", "--help"], "cmux tab create browser --url <url>"),
        (&["notify", "--help"], "cmux notify --clear"),
        (&["help", "notify"], "cmux notify --clear"),
        (&["notification", "--help"], "cmux notification ack --client"),
    ];
    for (args, expected) in cases {
        let output = names.run("cmux", args);
        let stdout = text(&output.stdout);
        assert!(output.status.success(), "{args:?}: {}", text(&output.stderr));
        assert!(stdout.contains(expected), "{args:?} printed:\n{stdout}");
        assert!(!stdout.contains("cmux screen list"), "{args:?} printed screen help:\n{stdout}");
        assert!(!stdout.starts_with("cmux - terminal multiplexer"), "{args:?} printed root help");
    }
}

/// `acp` and `link` take their own options, so a cmux global option before
/// them names the fix instead of calling them unknown scopes.
#[test]
fn global_options_before_acp_or_link_name_the_fix() {
    let names = Names::new("acp-globals");
    for scope in ["acp", "link"] {
        let output = names.run("cmux", &["--json", scope, "list"]);
        assert_eq!(output.status.code(), Some(2));
        let error: serde_json::Value = serde_json::from_slice(&output.stdout)
            .or_else(|_| serde_json::from_slice(&output.stderr))
            .unwrap();
        let message = error["message"].as_str().unwrap();
        assert!(!message.contains("unknown resource scope"), "{scope}: {message}");
        assert!(message.contains(&format!("cmux {scope} --help")), "{scope}: {message}");
    }
}

#[test]
fn link_help_succeeds_on_stdout() {
    let names = Names::new("link-help");
    let output = names.run("cmux", &["link", "--help"]);
    assert!(output.status.success(), "{}", text(&output.stderr));
    assert!(text(&output.stdout).contains("cmux link <init|show"), "{}", text(&output.stdout));
}

#[test]
fn history_and_bookmark_search_without_text_say_what_is_missing() {
    let names = Names::new("search-text");
    for scope in ["history", "bookmark"] {
        let output = names.run("cmux", &[scope, "search"]);
        assert_eq!(output.status.code(), Some(2));
        let stderr = text(&output.stderr);
        assert!(stderr.contains(&format!("cmux {scope} search <text>")), "{scope}: {stderr}");
    }
}
