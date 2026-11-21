//! The app lines of `cmux rd serve|connect` (`app_line::AppLine`) against the
//! golden vectors in tests/vectors/app_lines.json. cmux-rd-ffi's line reader
//! reads the same file in its tests, and so does the Mac Screen's
//! MacScreenRdLineTests, so the host, the C ABI and the app cannot drift.
#![cfg(feature = "serde")]

use cmux_rd_proto::app_line::{AppLine, LineSplitter};

fn vectors() -> Vec<serde_json::Value> {
    serde_json::from_str(include_str!("vectors/app_lines.json")).expect("vectors")
}

#[test]
fn every_vector_reads_as_its_want() {
    for v in vectors() {
        let name = v["name"].as_str().expect("name");
        let line = v["line"].as_str().expect("line");
        let want: Option<AppLine> =
            serde_json::from_value(v["want"].clone()).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(AppLine::decode(line.as_bytes()), want, "{name}");
    }
}

#[test]
fn every_vector_line_split_byte_by_byte_reads_the_same() {
    let mut all = Vec::new();
    for v in vectors() {
        all.extend_from_slice(v["line"].as_str().expect("line").as_bytes());
        all.push(b'\n');
    }
    let mut splitter = LineSplitter::default();
    let mut lines = Vec::new();
    for byte in all {
        lines.extend(splitter.push(&[byte]));
    }
    let want: Vec<Vec<u8>> =
        vectors().iter().map(|v| v["line"].as_str().expect("line").as_bytes().to_vec()).collect();
    assert_eq!(lines, want);
}

#[test]
fn what_decodes_prints_back_to_the_same_line() {
    for v in vectors() {
        let name = v["name"].as_str().expect("name");
        let Some(line) = AppLine::decode(v["line"].as_str().expect("line").as_bytes()) else {
            continue;
        };
        assert_eq!(AppLine::decode(line.to_json().as_bytes()), Some(line), "{name}");
    }
}
