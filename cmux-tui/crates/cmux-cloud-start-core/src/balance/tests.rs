use super::*;

const MB: u64 = 1_000_000;

fn repo() -> Facts {
    Facts {
        folder_bytes: 500 * MB,
        head_bytes: 5 * MB,
        first_read_bytes: 2 * MB,
        upload_bytes_per_sec: Some(5 * MB),
        wake_ms: Some(8_000),
        ..Facts::default()
    }
}

fn outcome(report: &Report, place: Place) -> Outcome {
    *report.places.iter().find(|o| o.place == place).unwrap()
}

#[test]
fn a_chat_nothing_asks_to_keep_running_stays_here_for_free() {
    let report = simulate(&repo());
    assert_eq!((report.best, report.why), (Place::Local, Why::LocalIsFree));
    let local = outcome(&report, Place::Local);
    assert_eq!((local.first_tool_ms, local.awake_hours, local.outlives_lid), (0, 0.0, false));
}

#[test]
fn a_kept_chat_answers_here_while_the_machine_wakes_and_fills() {
    let report = simulate(&Facts { keep_running: true, ..repo() });
    assert_eq!((report.best, report.why), (Place::Hybrid, Why::AnswerHereWhileItWakes));
    let hybrid = outcome(&report, Place::Hybrid);
    assert_eq!(hybrid.first_tool_ms, 0);
    assert!(hybrid.outlives_lid);
    // 500 MB at 5 MB/s is 100 s, longer than the 8 s wake.
    assert_eq!(hybrid.machine_whole_ms, 100_000);
    assert!(report.upload_bound);
}

#[test]
fn with_no_local_harness_the_head_first_seed_beats_the_whole_copy() {
    let report = simulate(&Facts { keep_running: true, local_unavailable: true, ..repo() });
    assert_eq!((report.best, report.why), (Place::CloudHeadFirst, Why::HeadFirstStartsSoonest));
    let head = outcome(&report, Place::CloudHeadFirst);
    let whole = outcome(&report, Place::CloudWhole);
    // The 5 MB head takes 1 s, hidden behind the 8 s wake; the first reads add 0.4 s.
    assert_eq!((head.first_tool_ms, head.first_turn_ms), (8_000, 8_400));
    assert_eq!(whole.first_tool_ms, 100_000);
    assert_eq!(report.head_first_saves_ms, 92_000);
    assert!(!outcome(&report, Place::Local).possible);
    assert!(!outcome(&report, Place::Hybrid).possible);
}

#[test]
fn a_machine_that_has_the_folder_has_nothing_to_fill() {
    let facts = Facts {
        keep_running: true,
        local_unavailable: true,
        machine_has_folder: true,
        awake: true,
        ..repo()
    };
    let report = simulate(&facts);
    assert_eq!((report.best, report.why), (Place::CloudHeadFirst, Why::NothingToFill));
    assert_eq!(outcome(&report, Place::CloudWhole).first_tool_ms, 0);
    assert_eq!(report.head_first_saves_ms, 0);
    assert!(!report.upload_bound);
}

#[test]
fn a_fast_uplink_makes_the_wake_what_the_person_waits_on() {
    let report = simulate(&Facts { upload_bytes_per_sec: Some(100 * MB), ..repo() });
    assert!(!report.upload_bound);
    assert_eq!(outcome(&report, Place::CloudWhole).first_tool_ms, 8_000);
}

#[test]
fn first_reads_never_finish_after_the_whole_copy() {
    let facts = Facts { first_read_bytes: 10_000 * MB, ..repo() };
    let head = outcome(&simulate(&facts), Place::CloudHeadFirst);
    assert_eq!(head.first_turn_ms, head.machine_whole_ms);
}

#[test]
fn an_empty_question_uses_the_defaults_and_never_divides_by_zero() {
    let report = simulate(&Facts { upload_bytes_per_sec: Some(0), ..Facts::default() });
    assert_eq!(report.best, Place::Local);
    let whole = outcome(&report, Place::CloudWhole);
    assert_eq!((whole.first_tool_ms, whole.awake_hours), (DEFAULT_WAKE_MS, 1.0));
}

#[test]
fn the_head_that_hides_behind_the_wake_is_what_the_wake_can_send() {
    // 8 s at 5 MB/s is 40 MB; an awake machine hides nothing; never more than the folder.
    assert_eq!(head_that_hides_behind_wake(&repo()), 40 * MB);
    assert_eq!(head_that_hides_behind_wake(&Facts { awake: true, ..repo() }), 0);
    assert_eq!(head_that_hides_behind_wake(&Facts { folder_bytes: MB, ..repo() }), MB);
}

#[test]
fn the_answer_reads_in_camel_case() {
    let value = serde_json::to_value(simulate(&Facts { keep_running: true, ..repo() })).unwrap();
    assert_eq!(value["best"], "hybrid");
    assert_eq!(value["why"], "answerHereWhileItWakes");
    assert_eq!(value["places"][1]["place"], "cloudWhole");
    assert!(value["places"][0]["firstToolMs"].is_u64());
}
