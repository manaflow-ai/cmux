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

fn complete_measure_file(over_limit: Option<&str>) -> tempfile::NamedTempFile {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    for row in home::GATE_ROWS.iter().filter(|row| row.measured) {
        let value = row.god_max.unwrap_or(1.0).min(1.0);
        let (small, god) = if over_limit == Some(row.name) { (10.0, 13.0) } else { (value, value) };
        writeln!(
            file,
            "{}",
            serde_json::json!({
                "name": row.name, "small_p95": small, "god_p95": god,
                "god_p95_all": god, "unit": "ns",
            })
        )
        .unwrap();
    }
    file
}

#[test]
fn skipped_placeholder_passes() {
    let file = complete_measure_file(None);
    let report = home::report(&[file.path().to_path_buf()]).unwrap();
    let rows = report["rows"].as_array().unwrap();
    let ids = rows.iter().map(|row| row["pr"].as_str().unwrap()).collect::<HashSet<_>>();
    for pr in [
        "1", "1b", "2", "2b", "3", "4", "5", "5b", "5g", "6", "7", "8", "9", "10", "11", "12", "13",
    ] {
        assert!(ids.contains(pr), "missing placeholder for PR {pr}");
    }
    let placeholder = home::GATE_ROWS.iter().find(|row| !row.measured).unwrap();
    let row = rows.iter().find(|row| row["name"] == placeholder.name).unwrap();
    assert_eq!(row["status"], "skipped");
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
    let file = complete_measure_file(Some("v2.pr01.append_time"));
    let report = home::report(&[file.path().to_path_buf()]).unwrap();
    let row = report["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["name"] == "v2.pr01.append_time")
        .unwrap();
    assert_eq!(row["status"], "red");
    assert_eq!(row["ratio"], 1.3);
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
