//! The rules that read bytes or the disk: the login shell's output, a
//! child's stderr lines, the launch snapshot lookup and the legacy channel
//! session adopt (each on a temporary directory of its own).

use cmux_daemon_launch_core::legacy::{self, AdoptInput};
use cmux_daemon_launch_core::lines::{Lines, MAX_LINE};
use cmux_daemon_launch_core::login_env;
use std::path::{Path, PathBuf};

#[test]
fn the_login_env_skips_rc_chatter_and_bad_entries() {
    let mut output = b"motd\x00noise\n__CMUX_NEXT_LOGIN_ENV__\nPATH=/a:/b\x00LANG=en=US\x00\xff\xfe=x\x00NOEQUALS\x00=empty\x00".to_vec();
    output.extend_from_slice(b"PATH=/c\x00");
    let env = login_env::parse(&output).expect("an environment");
    assert_eq!(env.get("PATH").map(String::as_str), Some("/c"));
    assert_eq!(env.get("LANG").map(String::as_str), Some("en=US"));
    assert_eq!(env.get("").map(String::as_str), Some("empty"));
    assert_eq!(env.len(), 3);
    assert!(login_env::parse(b"PATH=/a\x00").is_none(), "no marker");
    assert!(login_env::parse(b"\n__CMUX_NEXT_LOGIN_ENV__\n").is_none(), "no entry");
    assert!(login_env::accept(1, &output).is_none(), "a failed shell");
    assert!(login_env::accept(0, b"\n__CMUX_NEXT_LOGIN_ENV__\nLANG=en\x00").is_none(), "no PATH");
    assert!(login_env::accept(0, &output).is_some());
}

#[test]
fn stderr_lines_come_whole_and_the_last_at_exit() {
    let mut lines = Lines::new();
    assert_eq!(lines.push(b"one\ntw"), vec!["one"]);
    assert_eq!(lines.push(b"o\n\nthr"), vec!["two", ""]);
    assert_eq!(lines.finish(), vec!["thr"]);
    assert!(lines.push(b"late\n").is_empty(), "nothing after the exit");
    let mut long = Lines::new();
    let mut bytes = vec![b'x'; MAX_LINE + 10];
    bytes.push(b'\n');
    assert_eq!(long.push(&bytes)[0].len(), MAX_LINE, "a long line is cut");
    assert!(long.finish().is_empty());
}

struct Temp(PathBuf);

impl Temp {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("cmux-daemon-launch-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        Self(dir)
    }
    fn path(&self, rel: &str) -> String {
        self.0.join(rel).to_string_lossy().into_owned()
    }
    fn write(&self, rel: &str, text: &str) {
        let path = self.0.join(rel);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
        std::fs::write(path, text).expect("write");
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const USED: &str = r#"{"tree":{"workspaces":[{"kind":"home"},{"kind":"normal","screens":[{"panes":[{"tabs":[{"kind":"terminal"}]}]}]}]}}"#;
const NEW_TAB_ONLY: &str = r#"{"tree":{"workspaces":[{"kind":"normal","screens":[{"panes":[{"tabs":[{"kind":"conversation","conversation":{"conversation":null,"agent_session":{"session":null}}}]}]}]}]}}"#;

#[test]
fn snapshot_workspaces_count_what_the_person_may_have_used() {
    assert_eq!(legacy::workspaces_in(USED.as_bytes(), false), 1, "home is not counted");
    assert_eq!(legacy::workspaces_in(USED.as_bytes(), true), 1);
    assert_eq!(legacy::workspaces_in(NEW_TAB_ONLY.as_bytes(), false), 1);
    assert_eq!(legacy::workspaces_in(NEW_TAB_ONLY.as_bytes(), true), 0, "an unused New Tab page");
    let bound = r#"{"tree":{"workspaces":[{"screens":[{"panes":[{"tabs":[{"kind":"conversation","conversation":{"conversation":"c1"}}]}]}]}]}}"#;
    assert_eq!(legacy::workspaces_in(bound.as_bytes(), true), 1);
    let unsettled = r#"{"tree":{"workspaces":[{"kind":"normal"}]}}"#;
    assert_eq!(
        legacy::workspaces_in(unsettled.as_bytes(), true),
        1,
        "no tab listed counts as used"
    );
    let ephemeral = r#"{"tree":{"workspaces":[{"ephemeral":true}]}}"#;
    assert_eq!(legacy::workspaces_in(ephemeral.as_bytes(), false), 0);
    assert_eq!(legacy::workspaces_in(b"nope", true), 1, "unreadable counts as touched");
    assert_eq!(legacy::workspaces_in(b"nope", false), 0);
}

#[test]
fn the_snapshot_of_a_session_is_its_own_registrys() {
    let temp = Temp::new("find");
    temp.write("cmux-app-a-1/launch-snapshot.json", USED);
    temp.write("cmux-app-a-b-2/launch-snapshot.json", USED);
    std::fs::create_dir_all(temp.0.join("cmux-app-a-3")).expect("registry without snapshot");
    let found = legacy::find_snapshot("cmux-app-a", &temp.path("")).expect("found");
    assert!(found.ends_with("cmux-app-a-1/launch-snapshot.json"), "{found}");
    assert!(legacy::find_snapshot("cmux-app-c", &temp.path("")).is_none());
}

#[test]
fn a_channel_build_adopts_the_old_session_once_and_records_it() {
    let temp = Temp::new("adopt");
    let support = temp.path("support");
    let state = temp.path("support/cmux-next/tags/nightly/tui");
    let legacy_snapshot = temp.path("support/cmux-tui/sessions/cmux-app-xyz/launch-snapshot.json");
    temp.write("support/cmux-tui/sessions/cmux-app-xyz/launch-snapshot.json", USED);
    let input = |remembered: Option<&str>, bundle: &str| AdoptInput {
        application_support: Box::leak(support.clone().into_boxed_str()),
        bundle_id: Some(Box::leak(bundle.to_string().into_boxed_str())),
        session: "cmux-app-nightly",
        state_directory: Some(Box::leak(state.clone().into_boxed_str())),
        remembered_snapshot: remembered.map(|r| &*Box::leak(r.to_string().into_boxed_str())),
        now: "2026-11-06T00:00:00Z",
    };
    assert!(
        !legacy::adopts(&input(Some(&legacy_snapshot), "com.cmuxterm.app")),
        "release is no channel build"
    );
    assert!(
        !legacy::adopts(&input(None, "com.cmuxterm.app.nightly")),
        "this bundle never ran the old session"
    );
    let elsewhere = temp.path("other/cmux-app-xyz/launch-snapshot.json");
    temp.write("other/cmux-app-xyz/launch-snapshot.json", USED);
    assert!(
        !legacy::adopts(&input(Some(&elsewhere), "com.cmuxterm.app.nightly")),
        "a snapshot outside the old root"
    );

    // The channel's own session was used: never replaced.
    temp.write("support/cmux-next/tags/nightly/tui/cmux-app-nightly-1/launch-snapshot.json", USED);
    assert!(!legacy::adopts(&input(Some(&legacy_snapshot), "com.cmuxterm.app.nightly")));
    // Only the launch's own New Tab page: untouched, so it adopts and records it.
    temp.write(
        "support/cmux-next/tags/nightly/tui/cmux-app-nightly-1/launch-snapshot.json",
        NEW_TAB_ONLY,
    );
    assert!(legacy::adopts(&input(Some(&legacy_snapshot), "com.cmuxterm.app.nightly")));
    let marker = temp.path("support/cmux-next/tags/nightly/legacy-session-adopted");
    assert!(Path::new(&marker).exists());
    // Recorded: kept although the own session now counts as used.
    temp.write("support/cmux-next/tags/nightly/tui/cmux-app-nightly-1/launch-snapshot.json", USED);
    assert!(legacy::adopts(&input(None, "com.cmuxterm.app.nightly")));
}

#[test]
fn only_an_untagged_channel_build_has_a_channel() {
    assert_eq!(legacy::channel(Some("com.cmuxterm.app.rc"), "cmux-app-rc"), Some("rc"));
    assert_eq!(legacy::channel(Some("com.cmuxterm.app.rc"), "cmux-app-mytag"), None);
    assert_eq!(
        legacy::channel(Some("com.cmuxterm.app.nightly.cmux-next"), "cmux-app-nightly"),
        None
    );
}
