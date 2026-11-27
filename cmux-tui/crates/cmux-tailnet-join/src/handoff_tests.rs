use super::*;

const STATE: &str = "eyJfbWFjaGluZWtleSI6Im1rZXk6YWJjIn0=";

#[test]
fn release_hands_over_state_and_clock() {
    let out = format!(
        "cmux-tailnet-stopped-at 1764115200123\ncmux-tailnet-state {STATE}\ncmux-tailnet-released\n"
    );
    let released = parse_released(&out).expect("released");
    assert_eq!(released.state.expose(), STATE);
    assert_eq!(released.stopped_at_ms, Some(1_764_115_200_123));
    assert_eq!(released.staged_contents(), format!("{STATE}\n"));
}

#[test]
fn release_state_never_shows_in_debug() {
    let out = format!("cmux-tailnet-state {STATE}\ncmux-tailnet-released\n");
    let released = parse_released(&out).expect("released");
    assert!(!format!("{released:?}").contains(STATE));
}

#[test]
fn release_refuses_missing_empty_oversized_or_odd_state() {
    assert!(parse_released("cmux-tailnet-state abc=\n").is_err(), "no released line");
    assert!(parse_released("cmux-tailnet-state \ncmux-tailnet-released\n").is_err());
    let big = "A".repeat(MAX_STATE_BYTES + 1);
    assert!(parse_released(&format!("cmux-tailnet-state {big}\ncmux-tailnet-released\n")).is_err());
    assert!(parse_released("cmux-tailnet-state a;rm -rf /\ncmux-tailnet-released\n").is_err());
    // No clock is fine (an old `date`): the move still goes.
    let ok = parse_released(&format!("cmux-tailnet-state {STATE}\ncmux-tailnet-released\n"))
        .expect("ok");
    assert_eq!(ok.stopped_at_ms, None);
}

#[test]
fn release_stops_before_the_state_leaves() {
    let cmd = release_command();
    let stop = cmd.find("pkill -x tailscaled").expect("stops");
    let print = cmd.find("base64 -w0").expect("prints");
    assert!(stop < print, "tailscaled stops before its state is read");
    assert!(cmd.contains(STATE_FILE));
    assert!(cmd.contains("test -L"), "refuses a symlinked state");
    // The state is never deleted by the release: a failed move restores it.
    assert!(!cmd.contains("rm -f"));
}

#[test]
fn adopt_script_takes_no_key_and_cleans_up() {
    let s = vm_adopt_script();
    assert!(s.contains(STAGED_STATE_FILE));
    assert!(s.contains("trap 'rm -f"), "staged state is deleted on every exit");
    assert!(!s.contains("auth-key"), "the state is already signed in");
    assert!(!s.contains("tailscale login") && !s.contains("tailscale up"));
    let stop = s.find("pkill -x tailscaled").expect("stops a fresh tailscaled");
    let swap = s.find("mv -f").expect("swaps the state in");
    let start = s.find("setsid tailscaled").expect("starts");
    assert!(stop < swap && swap < start);
    assert!(s.contains("umask 077") && s.contains("chmod 600"));
    assert!(s.trim_end().ends_with("echo"), "ends with the join's result line");
    assert!(s.contains("cmux-tailnet-joined "));
}

#[test]
fn adopt_answer_reads_like_a_join() {
    let out = "rc=0\ncmux-tailnet-online-at 1764115201456\ncmux-tailnet-joined {\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"leo-cmux.tail1.ts.net.\",\"TailscaleIPs\":[\"100.64.0.2\"],\"Tags\":[\"tag:cmux\"],\"Online\":true}}\ncmux-tailnet-stderr\n";
    assert_eq!(online_at_ms(out), Some(1_764_115_201_456));
    match crate::read_answer(out) {
        crate::Progress::Ended(crate::Outcome::Joined(node)) => {
            assert_eq!(node.dns_name, "leo-cmux.tail1.ts.net");
            assert_eq!(node.ips, vec!["100.64.0.2".to_owned()]);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn forget_and_restore_say_so() {
    assert!(forget_command().contains(STATE_FILE));
    assert!(forget_command().ends_with("echo cmux-tailnet-forgot"));
    assert!(restore_command().contains("tailscaled"));
    assert!(restore_command().ends_with("echo cmux-tailnet-restored"));
}

#[test]
fn snapshot_reads_state_without_stopping() {
    let cmd = snapshot_command();
    assert!(!cmd.contains("pkill"), "a snapshot never stops the node");
    assert!(!cmd.contains("systemctl"), "a snapshot never stops the node");
    assert!(cmd.contains("test -L"), "refuses a symlinked state");
    let out = format!("cmux-tailnet-state {STATE}\ncmux-tailnet-snapshot\n");
    assert_eq!(parse_snapshot(&out).expect("snapshot").expose(), STATE);
    assert!(parse_snapshot(&format!("cmux-tailnet-state {STATE}\n")).is_err(), "no end line");
    assert!(parse_snapshot("cmux-tailnet-state a;b\ncmux-tailnet-snapshot\n").is_err());
}

#[test]
fn check_state_bounds_what_the_vault_hands_back() {
    assert!(check_state(STATE).is_ok());
    assert!(check_state("").is_err());
    assert!(check_state("not base64!").is_err());
    assert!(check_state(&"A".repeat(MAX_STATE_BYTES + 1)).is_err());
    assert_eq!(staged_contents(&Secret::new(STATE)), format!("{STATE}\n"));
}

#[test]
fn adopt_starts_a_handshake_with_every_online_peer_once_running() {
    let s = vm_adopt_script();
    let online = s.find("cmux-tailnet-online-at").expect("prints online");
    let kick = s.find("tailscale ping --tsmp").expect("kicks the peers");
    let joined = s.find("printf 'cmux-tailnet-joined '").expect("result line");
    assert!(online < kick && kick < joined, "after Running, before the result line");
    // Through WireGuard (a disco ping starts no handshake), detached, bounded, skipping offline peers.
    assert!(s.contains("--self=false") && s.contains("!~ / offline/") && s.contains("head -n 64"));
    assert!(s.contains(" -c 1 --timeout 3s"));
    // Waits (bounded, 2 s) until the node knows its own endpoints, so the first handshake can go direct.
    let wait = s.find("--peers=false").expect("waits for its own endpoints");
    assert!(wait < kick && s.contains("[ $i -gt 20 ] && break"));
    assert!(s.contains("</dev/null >/dev/null 2>&1 &"), "never holds the adopt run's output");
}

#[test]
fn stand_down_stops_the_node_and_deletes_its_state_without_signing_out() {
    let command = stand_down_command();
    assert!(command.contains("pkill -x tailscaled"));
    assert!(command.contains(STATE_FILE));
    assert!(!command.contains("tailscale logout"), "the new holder runs this node");
    assert!(!command.contains("cmux-tailnet-state"), "the state is never printed");
    assert!(command.ends_with("echo cmux-tailnet-stood-down"));
}
