#[path = "../benches/v2/mod.rs"]
#[allow(dead_code)]
mod home;

use std::collections::HashSet;
use std::io::Write;

fn measure_file(name: &str, small_p95: f64, god_p95: f64) -> tempfile::NamedTempFile {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    writeln!(
        file,
        "{{\"name\":\"{name}\",\"small_p95\":{small_p95},\"god_p95\":{god_p95},\"unit\":\"ns\"}}"
    )
    .unwrap();
    file
}

/// A line for every measured row, as a nightly run writes them: `name` gets the given numbers and
/// every other row 1 against 1. `report` refuses a run that leaves a measured row out.
fn every_measure(name: &str, small_p95: f64, god_p95: f64) -> tempfile::NamedTempFile {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    for row in home::GATE_ROWS.iter().filter(|row| row.measured) {
        let (small, god) = if row.name == name { (small_p95, god_p95) } else { (1.0, 1.0) };
        let line = serde_json::json!({ "name": row.name, "small_p95": small, "god_p95": god,
            "god_p95_all": god, "unit": "ns" });
        writeln!(file, "{line}").unwrap();
    }
    file
}

#[test]
fn skipped_placeholder_passes() {
    let file = every_measure("", 1.0, 1.0);
    let report = home::report(&[file.path().to_path_buf()]).unwrap();
    let rows = report["rows"].as_array().unwrap();
    let ids = rows.iter().map(|row| row["pr"].as_str().unwrap()).collect::<HashSet<_>>();
    for pr in [
        "1", "1b", "2", "2b", "3", "4", "5", "5b", "5g", "6", "7", "8", "9", "10", "11", "12", "13",
    ] {
        assert!(ids.contains(pr), "missing placeholder for PR {pr}");
    }
    assert_eq!(rows.len(), home::GATE_ROWS.len());
    assert!(home::GATE_ROWS.iter().any(|gate| !gate.measured));
    for (row, gate) in rows.iter().zip(home::GATE_ROWS) {
        let status = if gate.measured { "ok" } else { "skipped" };
        assert_eq!(row["status"], status, "{}", gate.name);
    }
    assert_eq!(report["fixtures"]["god"]["chats"], 527);
    assert_eq!(report["fixtures"]["god"]["peers"], 30);
}

#[test]
fn unknown_name_is_refused() {
    let file = measure_file("v2.pr99.unknown", 10.0, 11.0);
    let error = home::report(&[file.path().to_path_buf()]).unwrap_err();
    assert!(error.contains("unknown v2 gate row"));
}

#[test]
fn duplicate_name_is_refused() {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    writeln!(
        file,
        "{{\"name\":\"v2.pr01.append_time\",\"small_p95\":10,\"god_p95\":11,\"unit\":\"ns\"}}"
    )
    .unwrap();
    writeln!(
        file,
        "{{\"name\":\"v2.pr01.append_time\",\"small_p95\":10,\"god_p95\":11,\"unit\":\"ns\"}}"
    )
    .unwrap();
    let error = home::report(&[file.path().to_path_buf()]).unwrap_err();
    assert!(error.contains("duplicate v2 gate row"));
}

#[test]
fn over_limit_measure_is_red() {
    let file = every_measure("v2.pr01.append_time", 10.0, 13.0);
    let report = home::report(&[file.path().to_path_buf()]).unwrap();
    let rows = report["rows"].as_array().unwrap();
    let row = rows.iter().find(|row| row["name"] == "v2.pr01.append_time").unwrap();
    assert_eq!(row["status"], "red");
    assert_eq!(row["ratio"], 1.3);
    assert_eq!(rows.iter().filter(|row| row["status"] == "red").count(), 1);
}

#[test]
fn a_run_that_leaves_a_measured_row_out_is_refused() {
    let file = measure_file("v2.pr01.append_time", 10.0, 11.0);
    let error = home::report(&[file.path().to_path_buf()]).unwrap_err();
    assert!(error.contains("did not report a measure"));
    assert!(home::report(&[]).is_err());
}

#[test]
fn missing_measured_row_is_refused() {
    let error = home::validate_measure_files(&[], &["v2.pr01.append_time"]).unwrap_err();
    assert!(error.contains("was not reported"));
}
