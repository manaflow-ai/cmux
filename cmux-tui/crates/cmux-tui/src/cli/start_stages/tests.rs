//! The start marks `cmux vm new` and `cmux chat --on vm:new` answer, by cloud-journey.ts's names.

use std::time::{Duration, Instant};

use serde_json::json;

use super::super::GlobalArgs;
use super::super::cloud_start_chat::{Ran, caller_globals};
use super::{Marks, chat, claim_to_bound, create_answer, table, take_flag, with_create_stages};

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn timings_is_taken_out_before_a_double_dash_only() {
    assert_eq!(
        take_flag(&strings(&["--name", "dev", "--timings", "--json"])),
        (strings(&["--name", "dev", "--json"]), true)
    );
    assert_eq!(take_flag(&strings(&["--name", "dev"])), (strings(&["--name", "dev"]), false));
    assert_eq!(take_flag(&strings(&["--", "--timings"])), (strings(&["--", "--timings"]), false));
}

/// The same split as cloud-journey.ts's `claimToBoundSplit`: a list or `{steps}`, `step` or `name`, each named
/// stage the running sum of every stage up to it (an unnamed one counts toward the sum).
#[test]
fn the_claim_split_is_the_journeys() {
    let listed = json!({"stages_ms": [{"step": "machine", "ms": 100}, {"step": "join", "ms": 20.4},
                                      {"name": "bind", "ms": 300}, {"step": "connect", "ms": 50},
                                      {"step": "bound", "ms": 0}]});
    assert_eq!(
        claim_to_bound(&listed),
        Some(json!({"claim_answer_ms": 100, "join_ms": 120, "guest_bind_ms": 420,
                    "connect_info_ms": 470, "bound_ms": 470}))
    );
    let nested = json!({"claim_to_bound": {"steps": [{"step": "claim", "ms": 7}, {"step": "x", "ms": 3},
                                                     {"step": "bound", "ms": 1}]}});
    assert_eq!(claim_to_bound(&nested), Some(json!({"claim_answer_ms": 7, "bound_ms": 11})));
    assert_eq!(claim_to_bound(&json!({"machine_id": "vm-1"})), None);
    assert_eq!(claim_to_bound(&json!({"stages_ms": [{"step": "other", "ms": 4}]})), None);
}

/// The agent's first output is the turn's own clock past `send`; a mark taken first keeps its time.
#[test]
fn first_text_is_the_turns_first_output_past_the_send() {
    let began = Instant::now();
    let mut taken = Marks::new(began);
    taken.mark("send", began + Duration::from_millis(9_000));
    taken.mark("send", began + Duration::from_millis(12_000));
    let trace = json!({"steps": [
        {"step": "cloud start-session", "at": 1_000, "ms": 7_000, "code": 1},
        {"step": "cloud start-session", "at": 2_000, "ms": 6_000, "code": 0},
    ]});
    let answer = json!({"turn_ms": {"first_output": 1_500, "end": 4_000}});
    let stages = chat(&trace, &taken, &answer).finish(began + Duration::from_millis(14_000));
    // A start with no parts is ready when it answered; the given-up start before it is not read.
    assert_eq!(
        stages,
        json!({"send": 9_000, "session_ready": 8_000, "first_text": 10_500, "total": 14_000})
    );
}

#[test]
fn the_table_lists_each_mark_reached_with_the_time_since_the_one_before() {
    let answer = json!({"stages": {"created": 800, "running": 30_000, "total": 31_000},
                        "claim_to_bound": {"claim_answer_ms": 120, "bound_ms": 600}});
    assert_eq!(
        table(&answer),
        "stage            at ms     +ms\n\
         created             800     800\n\
         running           30000   29200\n\
         total             31000    1000\n\
         claim to bound (the broker's own times)\n\
         \x20 claim_answer      120     120\n\
         \x20 bound             600     480\n"
    );
}

#[test]
fn a_create_answer_gets_created_and_total() {
    let began = Instant::now();
    let answer = with_create_stages(
        json!({"machine_id": "vm-1"}),
        began,
        began + Duration::from_millis(2_345),
    );
    assert_eq!(answer["stages"], json!({"created": 2_345, "total": 2_345}));
    assert!(answer.get("claim_to_bound").is_none());
}

/// `cmux vm new --json` answers the app's whole response as it always printed it (`.result.machine_id`, the
/// `idempotency_key`), with `stages` and the create's own split beside them; a failed create keeps its own error and
/// exit status (3: no app answered).
#[test]
fn a_json_create_keeps_the_whole_answer_and_its_exit_status() {
    let began = Instant::now();
    let created = Ran {
        code: 0,
        stdout: concat!(
            r#"{"idempotency_key":"k-1","result":{"machine_id":"vm-1","#,
            r#""stages_ms":[{"step":"claim","ms":7},{"step":"bound","ms":3}]}}"#,
            "\n"
        )
        .to_owned(),
        stderr: String::new(),
    };
    let answer = create_answer(&created, began, began + Duration::from_millis(500)).unwrap();
    assert_eq!(answer["result"]["machine_id"], "vm-1");
    assert_eq!(answer["idempotency_key"], "k-1");
    assert_eq!(answer["stages"], json!({"created": 500, "total": 500}));
    assert_eq!(answer["claim_to_bound"], json!({"claim_answer_ms": 7, "bound_ms": 10}));

    let unreachable = Ran {
        code: 3,
        stdout: String::new(),
        stderr: r#"{"code":"app.unreachable","message":"no app answered"}"#.to_owned(),
    };
    let (error, code) = create_answer(&unreachable, began, began).unwrap_err();
    assert_eq!((error["code"].as_str(), code), (Some("app.unreachable"), 3));
    let refused = Ran {
        code: 1,
        stdout: String::new(),
        stderr: r#"{"code":"forbidden","message":"not this session's"}"#.to_owned(),
    };
    assert_eq!(create_answer(&refused, began, began).unwrap_err().1, 1);
}

/// The create runs with the caller's own route: `--session` and `--machine` go with the sockets and the key.
#[test]
fn the_create_step_keeps_the_callers_session() {
    let global = GlobalArgs {
        session: Some("S".to_owned()),
        machine: Some("m".to_owned()),
        app_socket: Some(std::path::PathBuf::from("/tmp/app.sock")),
        idempotency_key: Some("k-1".to_owned()),
        ..GlobalArgs::default()
    };
    assert_eq!(
        caller_globals(&global),
        strings(&[
            "--app-socket",
            "/tmp/app.sock",
            "--session",
            "S",
            "--machine",
            "m",
            "--idempotency-key",
            "k-1"
        ])
    );
}

/// One trace id per start: the caller's when it gave a valid one, else a fresh 32-hex id.
#[test]
fn a_start_takes_the_callers_trace_id_or_mints_one() {
    let given = "4bf92f3577b34da6a3ce929d0e0e4736";
    assert_eq!(super::trace_id(Some(given), None), given);
    assert_eq!(super::trace_id(Some(&given.to_uppercase()), None), given);
    assert_eq!(
        super::trace_id(None, Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")),
        given
    );
    let minted =
        super::trace_id(Some("not-an-id"), Some("00-00000000000000000000000000000000-0-01"));
    assert_eq!(minted.len(), 32);
    assert!(minted.bytes().all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()));
    assert_ne!(minted, super::trace_id(None, None));
}

/// The spans run end to end from the tap, by the owner's phases; a mark not reached is left out.
#[test]
fn the_trace_spans_are_the_start_phases() {
    let stages = json!({"created": 900, "running": 3622, "session_start": 4078, "session_ready": 11242,
                        "send": 11250, "sent": 11570, "first_text": 13801, "total": 14000});
    let trace = super::trace("4bf92f3577b34da6a3ce929d0e0e4736", Some(&stages));
    assert_eq!(trace["trace_id"], "4bf92f3577b34da6a3ce929d0e0e4736");
    assert_eq!(
        trace["phases_ms"],
        json!({"select": 0, "vm_running": 3622, "session_start": 456, "session_ready": 7164, "sent": 328,
               "first_text": 2231})
    );
    assert_eq!(
        trace["spans"][4],
        json!({"name": "sent", "start_ms": 11242, "end_ms": 11570, "ms": 328})
    );
    // A machine already running: `vm_running` ends at the create; a start that never sent stops at its last mark.
    let short = super::trace(
        "4bf92f3577b34da6a3ce929d0e0e4736",
        Some(&json!({"created": 50, "session_start": 80})),
    );
    let names: Vec<_> =
        short["spans"].as_array().unwrap().iter().map(|span| span["name"].clone()).collect();
    assert_eq!(names, vec![json!("select"), json!("vm_running"), json!("session_start")]);
}
