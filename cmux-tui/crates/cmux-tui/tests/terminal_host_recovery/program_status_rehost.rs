//! cx-6so.36.10: OSC 7501 program status records survive a host replacement
//! followed by a daemon restart. The daemon seeds the replacement host with
//! its records, so the next daemon adopts them from that host: a tab that
//! showed "blocked" before both still shows it, with the same `updated_seq`.

use super::host_replacement::{wait_for_daemon_custody, wait_for_replacement};
use super::pty_custody::{signal_pid, wait_for_dead_host};
use super::*;
use crate::program_status_restart::{program_status, wait_for_program_status, without_since};

#[test]
fn program_status_records_survive_a_host_replacement_then_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("program-status-rehost");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    // "Plan" asks "Apply?"; a finished build sits beside it.
                    "printf '\\033]7501;state=blocked:kind=permission:id=plan:app=terraform:title=UGxhbg==:msg=QXBwbHk/\\033\\\\'; ",
                    "printf '\\033]7501;state=done:id=build:app=make\\033\\\\'; ",
                    "printf 'reported\\r\\n'; sleep 600",
                ),
            ],
            "new_workspace": true,
            "name": "program-status-rehosted",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "reported").contains("reported"));
    let before = wait_for_program_status(&harness, 2);
    assert_eq!(before[1]["state"], "blocked", "{before}");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    wait_for_daemon_custody(&harness, true);

    // The host dies under the running daemon, which replaces it on the
    // same shell; the program reports nothing more.
    let kill_ms = crate::giveup_probe::now_ms();
    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    let replacement = wait_for_replacement(&harness, &record);
    assert_eq!(
        replacement.incarnation,
        incarnation,
        "{}",
        crate::giveup_probe::report(&harness.dir, &harness.host_root(), kill_ms)
    );

    harness.sigkill();
    harness.restart();
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");

    let after = wait_for_program_status(&harness, 2);
    assert_eq!(
        without_since(after),
        without_since(before),
        "program status changed across the replacement and restart"
    );

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

/// cx-6so.36.11: the reconnect to the replacement host replays its screen
/// into the daemon's mirror, through the parser that feeds the live records.
/// The screen held a prompt mark (OSC 133;A) before the program's report;
/// the replay must not end the record: the program still waits. (The VT
/// replay carries no OSC 133 marks today; this keeps it so.)
#[test]
fn a_prompt_mark_in_the_reconnect_replay_keeps_a_waiting_programs_record() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("program-status-reconnect-replay");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    // A shell prompt (OSC 133;A), then a program it ran asks
                    // "Apply?" and waits.
                    "printf '\\033]133;A\\007$ apply\\r\\n'; ",
                    "printf '\\033]7501;state=blocked:kind=permission:id=plan:app=terraform\\033\\\\'; ",
                    "printf 'reported\\r\\n'; sleep 600",
                ),
            ],
            "new_workspace": true,
            "name": "program-status-replayed",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, "reported").contains("reported"));
    let before = wait_for_program_status(&harness, 1);
    assert_eq!(before[0]["state"], "blocked", "{before}");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    wait_for_daemon_custody(&harness, true);

    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    wait_for_replacement(&harness, &record);
    // Typed text the terminal echoes back reaches the daemon only through
    // the replacement host: the reconnect, and its replay, are done.
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"reconnected"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "reconnected").contains("reconnected"));

    let after = program_status(&harness);
    assert_eq!(after, before, "the reconnect replay ended the waiting program's record");

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

// PROBE, a proof branch only (never for a merge): one hundred more passes of
// the test of the host replacement with program status records. Each name is
// one test process.
macro_rules! giveup_probe_status_copies {
    ($($name:ident)*) => {
        $(
            #[test]
            fn $name() {
                program_status_records_survive_a_host_replacement_then_a_daemon_restart();
            }
        )*
    };
}

giveup_probe_status_copies!(
    giveup_probe_status_001 giveup_probe_status_002 giveup_probe_status_003 giveup_probe_status_004
    giveup_probe_status_005 giveup_probe_status_006 giveup_probe_status_007 giveup_probe_status_008
    giveup_probe_status_009 giveup_probe_status_010 giveup_probe_status_011 giveup_probe_status_012
    giveup_probe_status_013 giveup_probe_status_014 giveup_probe_status_015 giveup_probe_status_016
    giveup_probe_status_017 giveup_probe_status_018 giveup_probe_status_019 giveup_probe_status_020
    giveup_probe_status_021 giveup_probe_status_022 giveup_probe_status_023 giveup_probe_status_024
    giveup_probe_status_025 giveup_probe_status_026 giveup_probe_status_027 giveup_probe_status_028
    giveup_probe_status_029 giveup_probe_status_030 giveup_probe_status_031 giveup_probe_status_032
    giveup_probe_status_033 giveup_probe_status_034 giveup_probe_status_035 giveup_probe_status_036
    giveup_probe_status_037 giveup_probe_status_038 giveup_probe_status_039 giveup_probe_status_040
    giveup_probe_status_041 giveup_probe_status_042 giveup_probe_status_043 giveup_probe_status_044
    giveup_probe_status_045 giveup_probe_status_046 giveup_probe_status_047 giveup_probe_status_048
    giveup_probe_status_049 giveup_probe_status_050 giveup_probe_status_051 giveup_probe_status_052
    giveup_probe_status_053 giveup_probe_status_054 giveup_probe_status_055 giveup_probe_status_056
    giveup_probe_status_057 giveup_probe_status_058 giveup_probe_status_059 giveup_probe_status_060
    giveup_probe_status_061 giveup_probe_status_062 giveup_probe_status_063 giveup_probe_status_064
    giveup_probe_status_065 giveup_probe_status_066 giveup_probe_status_067 giveup_probe_status_068
    giveup_probe_status_069 giveup_probe_status_070 giveup_probe_status_071 giveup_probe_status_072
    giveup_probe_status_073 giveup_probe_status_074 giveup_probe_status_075 giveup_probe_status_076
    giveup_probe_status_077 giveup_probe_status_078 giveup_probe_status_079 giveup_probe_status_080
    giveup_probe_status_081 giveup_probe_status_082 giveup_probe_status_083 giveup_probe_status_084
    giveup_probe_status_085 giveup_probe_status_086 giveup_probe_status_087 giveup_probe_status_088
    giveup_probe_status_089 giveup_probe_status_090 giveup_probe_status_091 giveup_probe_status_092
    giveup_probe_status_093 giveup_probe_status_094 giveup_probe_status_095 giveup_probe_status_096
    giveup_probe_status_097 giveup_probe_status_098 giveup_probe_status_099 giveup_probe_status_100
);
