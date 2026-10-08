//! ARCHIVE-1 (cx-gzh.4.1): closing a terminal that still runs a program
//! archives it. The daemon keeps its screen and the name of the program the
//! close stopped, then ends it. Reopen Closed starts a new shell in the same
//! directory with the old screen above one dim line that names the stopped
//! program. Both stop paths are covered: a closed tab that the reaper ends
//! (Cmd-W in the app) and a workspace closed with `end_terminals`.

use super::pty_custody::send_line;
use super::*;

/// The dim line under the archived screen names the stopped program.
const STOPPED: &str = "sleep was stopped";

fn tree(harness: &RecoveryHarness) -> serde_json::Value {
    request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}))
}

fn tabs(tree: &serde_json::Value) -> Vec<serde_json::Value> {
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .cloned()
        .collect()
}

fn tab_of_surface(harness: &RecoveryHarness, surface: u64) -> serde_json::Value {
    let tree = tree(harness);
    tabs(&tree)
        .into_iter()
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .unwrap_or_else(|| panic!("no tab shows surface {surface}: {tree}"))
}

/// The surface of the tab whose public id is `tab_id`.
fn surface_of_tab(harness: &RecoveryHarness, tab_id: &str) -> u64 {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = tree(harness);
        if let Some(surface) = tabs(&tree)
            .into_iter()
            .find(|tab| tab["tab_resource_id"] == tab_id)
            .and_then(|tab| tab["surface"].as_u64())
        {
            return surface;
        }
        assert!(Instant::now() < deadline, "no tab {tab_id}: {tree}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn screen(harness: &RecoveryHarness, surface: u64) -> String {
    request(&harness.socket, serde_json::json!({"cmd":"read-screen","surface":surface}))["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

/// A short directory the shell can `cd` into (an 80-column `echo` of it
/// never wraps).
fn scratch_dir(tag: &str) -> (PathBuf, String) {
    let dir = PathBuf::from(format!("/tmp/cmux-arc-{tag}-{}", std::process::id()));
    fs::create_dir_all(&dir).expect("create the shell's directory");
    let dir = fs::canonicalize(&dir).expect("canonical directory");
    let text = dir.to_string_lossy().into_owned();
    (dir, text)
}

/// `cd` the shell of `surface` into `dir`, print a marker, then start a
/// program that runs until something stops it.
fn run_sleep_in(harness: &RecoveryHarness, surface: u64, dir: &str, marker: &str) {
    send_line(&harness.socket, surface, &format!("cd '{dir}'"));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while tab_of_surface(harness, surface)["cwd"].as_str() != Some(dir) {
        assert!(Instant::now() < deadline, "the shell never reported {dir}");
        std::thread::sleep(Duration::from_millis(50));
    }
    send_line(&harness.socket, surface, &format!("echo {marker}-printed"));
    wait_for_screen(&harness.socket, surface, &format!("{marker}-printed\n"));
    send_line(&harness.socket, surface, "sleep 1000");
    // The program, not the shell, is the terminal's foreground job.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let info =
            request(&harness.socket, serde_json::json!({"cmd":"process-info","surface":surface}));
        if info["foreground_executable"].as_str().is_some_and(|name| name.ends_with("sleep")) {
            break;
        }
        assert!(Instant::now() < deadline, "sleep never became the foreground job: {info}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Wait until the close ended `terminal_id` (its row is tombstoned or gone).
fn wait_for_end(harness: &RecoveryHarness, terminal_id: &str) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request_response(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["ok"] != true || resolved["data"]["lifecycle"] == "tombstoned" {
            return;
        }
        assert!(Instant::now() < deadline, "the close never ended {terminal_id}: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn reopen_newest(harness: &RecoveryHarness, key: &str) -> serde_json::Value {
    let closed = resource_request(
        &harness.socket,
        &format!("{key}-list"),
        "closed.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let id = closed[0]["id"].as_str().unwrap_or_else(|| panic!("nothing was closed: {closed}"));
    let reopened = resource_request(
        &harness.socket,
        &format!("{key}-reopen"),
        "closed.reopen",
        serde_json::json!({"machine":"current","session":"current","closed":id}),
        Some(&format!("{key}-reopen")),
    );
    reopened["value"].clone()
}

/// The shell's answer to `echo <tag>-$PWD-end`.
fn shell_pwd(harness: &RecoveryHarness, surface: u64, tag: &str) -> String {
    send_line(&harness.socket, surface, &format!("echo {tag}-$PWD-end"));
    let needle = format!("{tag}-");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let text = screen(harness, surface);
        let value = text.match_indices(&needle).find_map(|(at, _)| {
            let value = text[at + needle.len()..].split("-end").next()?;
            (!value.contains("$PWD") && !value.is_empty()).then(|| value.to_string())
        });
        if let Some(value) = value {
            return value;
        }
        assert!(Instant::now() < deadline, "the shell printed no {needle}: {text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The reopened terminal shows the archived screen, then the stopped
/// program's line, and its new shell runs in the archived directory.
fn assert_restored(harness: &RecoveryHarness, surface: u64, marker: &str, dir: &str) {
    let text = wait_for_screen(&harness.socket, surface, STOPPED);
    assert!(text.contains(STOPPED), "the reopened tab names no stopped program: {text}");
    let screen_at = text.find(&format!("{marker}-printed")).unwrap_or(usize::MAX);
    let stopped_at = text.find(STOPPED).unwrap_or(0);
    assert!(screen_at < stopped_at, "the archived screen is not above the stop line: {text}");
    assert_eq!(shell_pwd(harness, surface, "dir"), dir);
}

/// a. Cmd-W on a running terminal (the app's close: no `end_terminals`, the
/// reaper ends it) then Reopen Closed.
#[test]
fn a_closed_running_tab_reopens_with_its_screen_directory_and_stopped_program() {
    let _exclusive = exclusive_process_test();
    let harness =
        RecoveryHarness::start_with_args("archive-tab", &["--terminal-reap-grace-seconds", "0"]);
    let created =
        request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":"arc"}));
    let first = created["surface"].as_u64().expect("new-workspace returned no surface");
    let pane = tree(&harness)["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "arc")
        .and_then(|workspace| workspace["screens"][0]["panes"][0]["id"].as_u64())
        .expect("the workspace has a pane");
    let added = request(&harness.socket, serde_json::json!({"id":2,"cmd":"new-tab","pane":pane}));
    let surface = added["surface"].as_u64().expect("new-tab returned no surface");
    let terminal_id = tab_of_surface(&harness, surface)["terminal_id"]
        .as_str()
        .expect("tab has no terminal id")
        .to_string();
    let (dir, dir_text) = scratch_dir("tab");
    run_sleep_in(&harness, surface, &dir_text, "tab-archive");

    request(
        &harness.socket,
        serde_json::json!({"id":3,"cmd":"close-tabs","surfaces":[surface],"end_terminals":false}),
    );
    wait_for_end(&harness, &terminal_id);

    let reopened = reopen_newest(&harness, "tab");
    let tab_id = reopened["tab_ids"][0].as_str().expect("reopen returned no tab").to_string();
    let surface = surface_of_tab(&harness, &tab_id);
    assert_ne!(surface, first);
    assert_restored(&harness, surface, "tab-archive", &dir_text);
    let _ = fs::remove_dir_all(&dir);
}

/// b. Close Workspace (`end_terminals` ends its terminals in the close
/// commit) then Reopen Closed: the workspace's first terminal is restored.
#[test]
fn a_closed_workspace_reopens_its_running_terminal_with_screen_directory_and_stopped_program() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("archive-workspace");
    let created =
        request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":"arcw"}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let tab = tab_of_surface(&harness, surface);
    let terminal_id = tab["terminal_id"].as_str().expect("tab has no terminal id").to_string();
    let key = tree(&harness)["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "arcw")
        .and_then(|workspace| workspace["key"].as_str().map(str::to_string))
        .expect("the workspace has a key");
    let (dir, dir_text) = scratch_dir("ws");
    run_sleep_in(&harness, surface, &dir_text, "ws-archive");

    request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"close-workspace","key":key,"end_terminals":true}),
    );
    wait_for_end(&harness, &terminal_id);

    let reopened = reopen_newest(&harness, "workspace");
    let tab_id = reopened["tab_ids"][0].as_str().expect("reopen returned no tab").to_string();
    let surface = surface_of_tab(&harness, &tab_id);
    assert_restored(&harness, surface, "ws-archive", &dir_text);
    let _ = fs::remove_dir_all(&dir);
}
