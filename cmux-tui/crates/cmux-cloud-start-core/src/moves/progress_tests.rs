use super::*;

fn facts(stage: Stage, stage_ms: u64) -> Facts {
    Facts { stage, stage_ms, name: Some("dev".to_owned()), ..Facts::default() }
}

fn copy(files_done: i64, files_total: i64) -> seed::Progress {
    seed::Progress {
        phase: "copy".to_owned(),
        files_done: Some(files_done),
        files_total: Some(files_total),
        ..seed::Progress::default()
    }
}

#[test]
fn every_step_names_itself_and_counts_its_seconds() {
    let texts: Vec<String> = STAGES.iter().map(|stage| line(&facts(*stage, 12_400)).text).collect();
    assert_eq!(
        texts,
        [
            "1 of 5 · Checking the folder · 12s",
            "2 of 5 · Connecting to dev · 12s",
            "3 of 5 · Copying the folder · 12s",
            "4 of 5 · Handing the agent to dev · 12s",
            "5 of 5 · Opening its tab · 12s",
        ]
    );
}

#[test]
fn no_line_ever_guesses_how_long_a_step_usually_takes() {
    for stage in STAGES {
        for ms in [0, 2_999, 3_001, 10_001, 30_000, 185_000, 7_200_000] {
            let mut moving = facts(stage, ms);
            moving.copy = (stage == Stage::Copy).then(|| copy(99, 100));
            moving.copy_ms = Some(1_000);
            let text = line(&moving).text;
            for word in ["usually", "left", "longer than", "about", "so far"] {
                assert!(!text.contains(word), "{text:?} says {word:?}");
            }
        }
    }
}

#[test]
fn the_clock_reads_seconds_then_minutes_and_seconds() {
    assert_eq!(
        [0, 999, 1_000, 59_999, 60_000, 65_000, 609_000, 3_599_999, 3_723_000].map(clock),
        ["0s", "0s", "1s", "59s", "1:00", "1:05", "10:09", "59:59", "1:02:03"]
    );
    assert_eq!(
        line(&facts(Stage::Agent, 185_000)).text,
        "4 of 5 · Handing the agent to dev · 3:05"
    );
}

#[test]
fn the_app_asks_again_at_each_whole_second() {
    assert_eq!(line(&facts(Stage::Agent, 0)).next_ms, Some(1_000));
    assert_eq!(line(&facts(Stage::Agent, 10_001)).next_ms, Some(999));
    assert_eq!(line(&facts(Stage::Tab, 3_500)).next_ms, Some(500));
    // Every wake lands on a change, for two hours of every step.
    for stage in STAGES {
        let mut ms = 0;
        while ms < 7_200_000 {
            let read = line(&facts(stage, ms));
            let next = read.next_ms.expect("a running step always wakes");
            assert_eq!(line(&facts(stage, ms + next - 1)).text, read.text);
            ms += next;
            assert_ne!(line(&facts(stage, ms)).text, read.text, "{stage:?} at {ms} ms");
        }
    }
}

#[test]
fn a_move_names_a_step_from_the_click_and_bring_back_has_no_folder_check() {
    let checking = line(&facts(Stage::Folder, 0));
    assert_eq!((checking.step, checking.steps), (1, 5));
    assert_eq!(checking.eta_ms, Some(36_000), "its own 3 s and the four steps after it");
    let mut back = facts(Stage::Machine, 0);
    back.direction = Direction::BringBack;
    assert_eq!((line(&back).step, line(&back).steps), (1, 4));
}

#[test]
fn bring_back_says_where_it_goes() {
    let mut back = facts(Stage::Copy, 4_000);
    back.direction = Direction::BringBack;
    back.copy = Some(copy(0, 1));
    assert_eq!(line(&back).text, "2 of 4 · Copying the folder back (1 file) · 4s");
    back.stage = Stage::Agent;
    assert_eq!(line(&back).text, "3 of 4 · Bringing the agent to this Mac · 4s");
    back.stage = Stage::Tab;
    assert_eq!(line(&back).text, "4 of 4 · Opening its tab here · 4s");
}

#[test]
fn a_new_or_paused_machine_names_itself() {
    let mut new = facts(Stage::Machine, 0);
    new.machine = Machine::New;
    let line_new = line(&new);
    assert_eq!(line_new.text, "2 of 5 · Starting a new Cloud machine · 0s");
    assert_eq!(line_new.eta_ms, Some(88_000));
    let mut paused = facts(Stage::Machine, 10_000);
    paused.machine = Machine::Paused;
    assert_eq!(line(&paused).text, "2 of 5 · Resuming dev · 10s");
}

#[test]
fn the_fraction_fills_step_by_step() {
    let start = line(&facts(Stage::Folder, 0)).fraction;
    let copying = line(&facts(Stage::Copy, 0)).fraction;
    let half_agent = line(&facts(Stage::Agent, 5_000)).fraction;
    let tab = line(&facts(Stage::Tab, 0)).fraction;
    assert!(start.abs() < f64::EPSILON, "{start}");
    assert!(
        start < copying && copying < half_agent && half_agent < tab && tab < 1.0,
        "{copying} {half_agent} {tab}"
    );
    // Folder 3 s, live machine 5 s, copy 15 s, agent 10 s, tab 3 s: the copy starts 8 of 36 s in.
    assert!((copying - 8.0 / 36.0).abs() < 1e-9, "{copying}");
    // A step past its estimate holds just under its end, never past it.
    let overrun = line(&facts(Stage::Agent, 60_000)).fraction;
    let end = line(&facts(Stage::Tab, 0)).fraction;
    assert!(overrun < 1.0 && overrun > half_agent, "{overrun} {end}");
}

#[test]
fn the_estimate_runs_with_the_step_and_ends_past_its_usual_time() {
    let early = line(&facts(Stage::Agent, 0)).eta_ms;
    let later = line(&facts(Stage::Agent, 6_000)).eta_ms;
    assert_eq!((early, later), (Some(13_000), Some(7_000)));
    assert_eq!(line(&facts(Stage::Agent, 30_000)).eta_ms, None);
}

#[test]
fn the_copy_counts_its_files_and_measures_its_rate() {
    let mut copying = facts(Stage::Copy, 1_000);
    copying.copy = Some(copy(0, 1_204));
    assert_eq!(copy_typical_ms(copying.copy.as_ref()), 8_816);
    assert_eq!(line(&copying).text, "3 of 5 · Copying the folder (1,204 files) · 1s");
    // A quarter done in 10 s: 30 s more, plus 13 s after it.
    copying.stage_ms = 10_000;
    copying.copy = Some(copy(301, 1_204));
    assert_eq!(line(&copying).eta_ms, Some(43_000));
    copying.stage_ms = 600_000;
    assert!(line(&copying).eta_ms.is_some());
}

#[test]
fn a_measured_estimate_goes_stale_when_progress_stops() {
    let mut copying = facts(Stage::Copy, 10_000);
    (copying.copy, copying.copy_ms) = (Some(copy(99, 100)), Some(10_000));
    assert_eq!(line(&copying).eta_ms, Some(13_101));
    copying.stage_ms = 15_101;
    assert_eq!(line(&copying).eta_ms, Some(13_000));
    copying.stage_ms = 15_102;
    assert_eq!(line(&copying).eta_ms, None);
    copying.copy_ms = Some(15_102);
    assert!(line(&copying).eta_ms.is_some());
}

#[test]
fn a_copy_by_bytes_measures_too_and_bad_numbers_fall_back() {
    let mut copying = facts(Stage::Copy, 4_000);
    copying.copy = Some(seed::Progress {
        phase: "upload".to_owned(),
        bytes_done: Some(50),
        bytes_total: Some(100),
        ..seed::Progress::default()
    });
    assert_eq!(line(&copying).eta_ms, Some(17_000));
    copying.copy = Some(copy(-1, -5));
    assert_eq!(line(&copying).text, "3 of 5 · Copying the folder · 4s");
}

#[test]
fn huge_numbers_saturate() {
    let mut copying = facts(Stage::Copy, u64::MAX);
    copying.copy = Some(copy(1, i64::MAX));
    let read = line(&copying);
    assert_eq!((read.step, read.eta_ms), (3, None), "a rate past u64 is no rate");
    assert_eq!(
        [0, 7, 999, 1_000, 12_345, 1_234_567].map(grouped),
        ["0", "7", "999", "1,000", "12,345", "1,234,567"]
    );
}
