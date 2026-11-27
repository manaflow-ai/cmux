use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::super::{AppCommand, parse};
use super::{Command, FILE_NAME, MAX_BYTES, default_path, phase_line, read, table};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// A line exactly as the app's `LaunchTimesFile.append` writes it (sorted keys, CmuxNextControl's
/// LaunchTimesFileTests write the same record).
const LINE: &str = r#"{"build":"200","commit":"31583607abcdef","first_launch_of_build":true,"first_window_frame_ms":512,"home_first_page_ms":830.7,"home_revealed_by":"mark","main_ms":470.8,"pre_main_ms":41.3,"prewarm_reason":"main","prewarmed":true,"started_at":"2027-01-15T08:00:00Z","version":"1.0.0"}"#;

#[test]
fn launch_times_parses_its_options() {
    assert_eq!(
        parse(&args(&["app", "launch-times"])).unwrap(),
        Some(AppCommand::LaunchTimes(Command { limit: None, file: None, phases: false }))
    );
    assert_eq!(
        parse(&args(&["app", "launch-times", "--limit", "5", "--file", "/tmp/x.jsonl"])).unwrap(),
        Some(AppCommand::LaunchTimes(Command {
            limit: Some(5),
            file: Some(PathBuf::from("/tmp/x.jsonl")),
            phases: false,
        }))
    );
    assert!(parse(&args(&["app", "launch-times", "--limit", "0"])).is_err());
    assert!(parse(&args(&["app", "launch-times", "--limit", "soon"])).is_err());
    assert!(parse(&args(&["app", "launch-times", "extra"])).is_err());
    assert_eq!(
        parse(&args(&["app", "launch-times", "--phases"])).unwrap(),
        Some(AppCommand::LaunchTimes(Command { limit: None, file: None, phases: true }))
    );
}

/// A row with phases (the app's `phases` object, sorted keys as it writes them) reads back with the
/// object whole, for the JSON view; `--phases` prints them under the row in the order they came, each
/// with its step from the one before. A row written before phases has no line.
#[test]
fn launch_times_prints_each_rows_phases() {
    let with: Value = serde_json::from_str(&LINE.replace(
        r#""pre_main_ms""#,
        r#""phases":{"cef.ready":900,"dfl.menu":130.6,"did_finish_launching_start":60,"reveal.home":830.7},"pre_main_ms""#,
    ))
    .unwrap();
    let without: Value = serde_json::from_str(LINE).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE_NAME);
    std::fs::write(&path, format!("{}\n{LINE}\n", serde_json::to_string(&with).unwrap())).unwrap();
    let records = read(&path, None).unwrap();
    assert_eq!(records, [with.clone(), without.clone()]);
    assert_eq!(records[0]["phases"]["dfl.menu"], json!(130.6));
    assert!(records[1].get("phases").is_none());

    assert_eq!(
        phase_line(&with).unwrap(),
        "  phases: did_finish_launching_start=60 (+60)  dfl.menu=130.6 (+70.6)  reveal.home=830.7 (+700.1)  cef.ready=900 (+69.3)"
    );
    assert_eq!(phase_line(&without), None);

    let plain = table(&records, false);
    assert_eq!(plain.lines().count(), 3, "no phases without --phases: {plain}");
    let text = table(&records, true);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 4, "{text}");
    assert!(lines[1].starts_with("2027-01-15"), "{text}");
    assert!(lines[2].starts_with("  phases: did_finish_launching_start=60"), "{text}");
    assert!(lines[3].starts_with("2027-01-15"), "the row without phases has no line: {text}");
}

/// NIGHTLY's CLI with `CMUX_BUNDLE_ID=com.cmuxterm.app.nightly` reads NIGHTLY's own file.
#[test]
fn launch_times_default_path_is_the_apps_support_folder() {
    let env = |key: &str| (key == "CMUX_BUNDLE_ID").then(|| "com.cmuxterm.app.nightly".to_owned());
    assert_eq!(
        default_path(env, None, Path::new("/Users/me")),
        Some(PathBuf::from(format!(
            "/Users/me/Library/Application Support/com.cmuxterm.app.nightly/{FILE_NAME}"
        )))
    );
    assert_eq!(default_path(|_| None, None, Path::new("/Users/me")), None);
}

/// The app's record reads back with every field, and the table shows it.
#[test]
fn launch_times_reads_the_apps_record_back() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE_NAME);
    std::fs::write(&path, format!("{LINE}\nnot json\n")).unwrap();
    let records = read(&path, None).unwrap();
    assert_eq!(records.len(), 1, "the line that is not JSON is skipped");
    let record = &records[0];
    assert_eq!(record["build"], "200");
    assert_eq!(record["pre_main_ms"], json!(41.3));
    assert_eq!(record["main_ms"], json!(470.8));
    assert_eq!(record["first_window_frame_ms"], json!(512));
    assert_eq!(record["home_first_page_ms"], json!(830.7));
    assert_eq!(record["home_revealed_by"], "mark");
    assert_eq!(record["prewarmed"], true);
    assert_eq!(record["prewarm_reason"], "main");
    assert_eq!(record["first_launch_of_build"], true);
    let text = table(&records, false);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2);
    assert!(lines[0].starts_with("started_at"), "{text}");
    for cell in ["1.0.0 (200)", "31583607 ", "41.3", "470.8", "512", "830.7", "mark", "yes", "main"]
    {
        assert!(lines[1].contains(cell), "{cell} missing from {text}");
    }
    assert!(!lines[1].contains("31583607a"), "the commit is shortened: {text}");
}

/// A bare launch's record (nothing to restore) shows when its window took keys and its first shell went live;
/// an older record without those fields shows `-` for them.
#[test]
fn launch_times_shows_the_bare_launch_fields() {
    let bare = r#"{"build":"201","first_launch_of_build":false,"first_shell_live_ms":512.9,"first_window_frame_ms":150,"no_snapshot":true,"prewarmed":false,"started_at":"2027-01-15T08:00:00Z","version":"1.0.0","window_usable_ms":231}"#;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE_NAME);
    std::fs::write(&path, format!("{LINE}\n{bare}\n")).unwrap();
    let records = read(&path, None).unwrap();
    let text = table(&records, false);
    let lines: Vec<&str> = text.lines().collect();
    for column in ["window_usable_ms", "first_shell_live_ms", "no_snapshot"] {
        assert!(lines[0].contains(column), "{column} missing from {text}");
    }
    for cell in ["231", "512.9", "yes"] {
        assert!(lines[2].contains(cell), "{cell} missing from {text}");
    }
    // The older record shows `-` in the three bare-launch columns (other columns it lacks, such as
    // prior_chat_*, show `-` too, so count by column, not across the row).
    // The table is aligned and a cell may hold a space ("1.0.0 (200)"): read each cell at its
    // header's offset.
    for column in ["window_usable_ms", "first_shell_live_ms", "no_snapshot"] {
        let at = lines[0].find(column).expect(column);
        let cell = lines[1].get(at..).and_then(|rest| rest.split_whitespace().next());
        assert_eq!(cell, Some("-"), "{column} of the older record: {text}");
    }
}

/// A relaunch into a chat (CMUX-119) prints the prior chat's columns; a launch with another tab in
/// front shows `-` there.
#[test]
fn launch_times_table_prints_the_prior_chat_columns() {
    let chat: Value = serde_json::from_str(&LINE.replace(
        r#""prewarmed""#,
        r#""prior_chat_painted_ms":1234.5,"prior_chat_live_ms":1490.2,"prewarmed""#,
    ))
    .unwrap();
    let other: Value = serde_json::from_str(LINE).unwrap();
    let text = table(&[chat, other], false);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 3, "{text}");
    let header: Vec<&str> = lines[0].split_whitespace().collect();
    let column = |name: &str| header.iter().position(|key| *key == name).expect(name);
    let cells = |line: &str| line.split_whitespace().map(str::to_owned).collect::<Vec<_>>();
    // "1.0.0 (200)" is one cell of two words: the row has one more word than the header.
    let (painted, live) = (column("prior_chat_painted_ms") + 1, column("prior_chat_live_ms") + 1);
    assert_eq!(cells(lines[1])[painted], "1234.5", "{text}");
    assert_eq!(cells(lines[1])[live], "1490.2", "{text}");
    assert_eq!(cells(lines[2])[painted], "-", "{text}");
    assert_eq!(cells(lines[2])[live], "-", "{text}");
}

#[test]
fn launch_times_missing_file_has_no_launches() {
    let dir = tempfile::tempdir().unwrap();
    assert!(read(&dir.path().join(FILE_NAME), None).unwrap().is_empty());
}

/// `--limit` keeps the newest; a file larger than the app ever writes is read only up to its cap.
#[test]
fn launch_times_reads_are_bounded() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE_NAME);
    let lines: Vec<String> = (1..=60)
        .map(|build| LINE.replace(r#""build":"200""#, &format!(r#""build":"{build}""#)))
        .collect();
    std::fs::write(&path, lines.join("\n") + "\n").unwrap();
    let newest = read(&path, Some(3)).unwrap();
    let builds: Vec<&str> = newest.iter().filter_map(|record| record["build"].as_str()).collect();
    assert_eq!(builds, ["58", "59", "60"]);

    let huge = dir.path().join("huge.jsonl");
    let many =
        (LINE.to_owned() + "\n").repeat(usize::try_from(MAX_BYTES).unwrap() / LINE.len() * 2);
    std::fs::write(&huge, many).unwrap();
    let records = read(&huge, None).unwrap();
    let most = usize::try_from(MAX_BYTES).unwrap() / (LINE.len() + 1);
    assert!(records.len() <= most + 1, "{} records read past the cap", records.len());
}
