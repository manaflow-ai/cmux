use super::*;

fn proc(pid: u32, ppid: u32, argv: &[&str]) -> ProcArgs {
    ProcArgs { pid, ppid, argv: argv.iter().map(|a| (*a).to_owned()).collect() }
}

fn of(table: &[ProcArgs]) -> impl Fn(u32) -> Option<ProcArgs> + '_ {
    move |pid| table.iter().find(|p| p.pid == pid).cloned()
}

const AUTOLAND: &str = "/Users/cmux/Projects/leo-workspace/tools/next-autoland";

#[test]
fn a_fleet_scripts_send_names_that_script() {
    // launchd -> python3 next-autoland -> acpmux send
    let table = [
        proc(30, 20, &["/opt/homebrew/bin/acpmux", "send", "lane-a", "hi"]),
        proc(20, 1, &["/opt/homebrew/bin/python3", AUTOLAND, "--once"]),
    ];
    assert_eq!(find(of(&table), 30), Some(json!({"name": "next-autoland", "path": AUTOLAND})));
}

#[test]
fn shells_wrappers_and_inline_code_are_passed_over() {
    // stall-reconciler (bash) -> timeout -> bash -c "acpmux send ..." -> acpmux
    let table = [
        proc(40, 31, &["acpmux", "send"]),
        proc(31, 30, &["bash", "-c", "acpmux send x hi"]),
        proc(30, 20, &["timeout", "60", "bash", "-c", "..."]),
        proc(20, 1, &["/bin/bash", "-e", "/home/cmux/tools/stall-reconciler", "--pass"]),
    ];
    assert_eq!(find(of(&table), 40).unwrap()["name"], "stall-reconciler");
    // A relative script keeps its name and no path.
    let table = [proc(5, 4, &["acpmux"]), proc(4, 1, &["python3", "tools/leo-forward"])];
    assert_eq!(find(of(&table), 5), Some(json!({"name": "leo-forward"})));
    // `python3 -m tools.asks_router`: the module.
    let table = [proc(5, 4, &["acpmux"]), proc(4, 1, &["python3.12", "-m", "tools.asks_router"])];
    assert_eq!(find(of(&table), 5), Some(json!({"name": "tools.asks_router"})));
}

#[test]
fn a_raw_socket_client_is_its_own_program() {
    let table = [proc(9, 1, &["/usr/bin/python3", "/srv/tools/next-ship-bot.py"])];
    assert_eq!(find(of(&table), 9).unwrap()["name"], "next-ship-bot.py");
    let table = [proc(9, 8, &["/usr/local/bin/glaeda", "notify"]), proc(8, 1, &["zsh"])];
    assert_eq!(find(of(&table), 9).unwrap()["name"], "glaeda");
}

#[test]
fn a_persons_shell_or_an_agents_names_no_program() {
    // Typed in a terminal over ssh.
    let table = [
        proc(9, 8, &["acpmux", "send"]),
        proc(8, 7, &["-zsh"]),
        proc(7, 1, &["sshd-session: cmux@pts/0"]),
    ];
    assert_eq!(find(of(&table), 9), None, "sshd's argv[0] is no program name");
    let table = [proc(9, 8, &["acpmux"]), proc(8, 7, &["-zsh"]), proc(7, 1, &["sshd"])];
    assert_eq!(find(of(&table), 9), None);
    // An agent harness's shell: its own claim says that.
    let table =
        [proc(9, 8, &["acpmux"]), proc(8, 7, &["bash", "-c", "x"]), proc(7, 1, &["claude"])];
    assert_eq!(find(of(&table), 9), None);
    // Inside a terminal app's bundle.
    let table = [
        proc(9, 8, &["acpmux"]),
        proc(8, 7, &["zsh"]),
        proc(7, 1, &["/Applications/Ghostty.app/Contents/MacOS/ghostty"]),
    ];
    assert_eq!(find(of(&table), 9), None);
}

#[test]
fn a_name_that_breaks_the_line_or_runs_long_names_nothing() {
    let long = format!("/t/{}", "x".repeat(65));
    let table = [proc(5, 4, &["acpmux"]), proc(4, 1, &["python3", &long])];
    assert_eq!(find(of(&table), 5), None);
    let table = [proc(5, 4, &["acpmux"]), proc(4, 1, &["python3", "/t/a\u{202E}b"])];
    assert_eq!(find(of(&table), 5), None);
    // A path past the limit is left out, the name kept.
    let deep = format!("/{}/tool", "d".repeat(300));
    let table = [proc(5, 4, &["acpmux"]), proc(4, 1, &["python3", &deep])];
    assert_eq!(find(of(&table), 5), Some(json!({"name": "tool"})));
}

#[test]
fn a_carried_program_is_checked_again_and_lands_on_the_unverified_provenance() {
    let params = json!({"_meta": {"acpmux": {KEY: {"name": "next-autoland", "path": AUTOLAND,
        "verified": true}}}});
    let provenance = crate::prompt_provenance::unverified("s1", "peer", Map::new());
    let stamped = on_unverified(provenance, &params);
    assert_eq!(stamped[PROVENANCE_KEY], json!({"name": "next-autoland", "path": AUTOLAND}));
    assert_eq!(stamped["kind"], "unverified");
    let bad = json!({"_meta": {"acpmux": {KEY: {"name": "a\nb"}}}});
    let provenance = crate::prompt_provenance::unverified("s1", "unix", Map::new());
    assert!(on_unverified(provenance, &bad).get(PROVENANCE_KEY).is_none());
}

#[tokio::test]
async fn a_clients_own_program_is_dropped_unless_the_daemon_carried_it() {
    let sent = json!({"_meta": {"acpmux": {KEY: {"name": "trusted-tool"}}}});
    let mut prompt = sent.clone();
    stamp(&mut prompt, None, false, true).await;
    assert!(of_params(&prompt).is_none(), "a client wrote it");
    let mut prompt = sent.clone();
    stamp(&mut prompt, None, true, true).await;
    assert_eq!(of_params(&prompt).unwrap()["name"], "trusted-tool", "the outbox or a peer daemon");
}

#[test]
fn inline_code_is_told_from_a_shells_options() {
    let up = |argv: &[&str]| {
        matches!(program_of(&argv.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>()), Step::Up)
    };
    assert!(up(&["node", "-e", "require('x')"]));
    assert!(up(&["python3", "-c", "print(1)"]));
    assert!(up(&["bash", "-c", "acpmux send"]));
    let table = [proc(5, 4, &["acpmux"]), proc(4, 1, &["bash", "-o", "pipefail", "/t/sweep"])];
    assert_eq!(find(of(&table), 5).unwrap()["name"], "sweep");
}

#[test]
fn a_cluster_with_inline_code_names_nothing_and_its_parent_is_read() {
    // Codex runs a command as `bash -lc CODE`; the code is never taken for a script.
    let table = [
        proc(9, 8, &["acpmux", "send"]),
        proc(8, 7, &["bash", "-lc", "cd /repo && acpmux send x hi"]),
        proc(7, 1, &["codex"]),
    ];
    assert_eq!(find(of(&table), 9), None);
    let table = [
        proc(9, 8, &["acpmux"]),
        proc(8, 7, &["sh", "-euc", "acpmux send x hi"]),
        proc(7, 1, &["/usr/bin/python3", "/t/stall-reconciler"]),
    ];
    assert_eq!(find(of(&table), 9).unwrap()["name"], "stall-reconciler");
    let table = [proc(9, 8, &["acpmux"]), proc(8, 1, &["perl", "-le", "system 'acpmux'"])];
    assert_eq!(find(of(&table), 9), None);
}

#[test]
fn a_carried_host_is_one_plain_label() {
    let program = |host: &str| sanitized(&json!({"name": "t", "host": host}));
    assert_eq!(program("cosmic-gray.local").unwrap()["host"], "cosmic-gray");
    assert!(program("a b").unwrap().get("host").is_none());
    assert!(program("").unwrap().get("host").is_none());
}
