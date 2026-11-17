use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::super::{AppCommand, parse};
use super::{Command, FILE_NAME, MAX_BYTES, default_path, read, table};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// A line exactly as the app's `LaunchTimesFile.append` writes it (sorted keys, CmuxNextControl's
/// LaunchTimesFileTests write the same record).
const LINE: &str = r#"{"build":"200","commit":"31583607abcdef","first_launch_of_build":true,"first_window_frame_ms":512,"home_first_page_ms":830.7,"home_revealed_by":"mark","main_ms":470.8,"pre_main_ms":41.3,"prewarmed":true,"reveal_home_ms":830.7,"started_at":"2027-01-15T08:00:00Z","version":"1.0.0"}"#;

#[test]
fn launch_times_parses_its_options() {
    assert_eq!(
        parse(&args(&["app", "launch-times"])).unwrap(),
        Some(AppCommand::LaunchTimes(Command { limit: None, file: None }))
    );
    assert_eq!(
        parse(&args(&["app", "launch-times", "--limit", "5", "--file", "/tmp/x.jsonl"])).unwrap(),
        Some(AppCommand::LaunchTimes(Command {
            limit: Some(5),
            file: Some(PathBuf::from("/tmp/x.jsonl"))
        }))
    );
    assert!(parse(&args(&["app", "launch-times", "--limit", "0"])).is_err());
    assert!(parse(&args(&["app", "launch-times", "--limit", "soon"])).is_err());
    assert!(parse(&args(&["app", "launch-times", "extra"])).is_err());
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
    assert_eq!(record["reveal_home_ms"], json!(830.7));
    assert_eq!(record["home_revealed_by"], "mark");
    assert_eq!(record["prewarmed"], true);
    assert_eq!(record["first_launch_of_build"], true);
    let text = table(&records);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2);
    assert!(lines[0].starts_with("started_at"), "{text}");
    for cell in ["1.0.0 (200)", "31583607 ", "41.3", "470.8", "512", "830.7", "mark", "yes"] {
        assert!(lines[1].contains(cell), "{cell} missing from {text}");
    }
    assert!(!lines[1].contains("31583607a"), "the commit is shortened: {text}");
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
    let text = table(&[chat, other]);
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
