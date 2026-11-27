//! Turns `strings.json` (table, then key, then language) into a sorted static table, so a
//! lookup at launch parses nothing. Every non-ASCII character is written as an escape, so the
//! generated literals carry no invisible characters.

use std::fmt::Write as _;

const LOCALES: &[&str] = &[
    "en", "ja", "ar", "bs", "da", "de", "es", "fr", "it", "km", "ko", "nb", "pl", "pt-BR", "ru",
    "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
];

fn literal(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            ' '..='~' => out.push(c),
            _ => {
                let _ = write!(out, "\\u{{{:x}}}", c as u32);
            }
        }
    }
    out.push('"');
    out
}

fn main() {
    println!("cargo:rerun-if-changed=strings.json");
    let source = std::fs::read_to_string("strings.json").expect("strings.json");
    let root: serde_json::Value = serde_json::from_str(&source).expect("strings.json is JSON");
    let declared: Vec<&str> =
        root["locales"].as_array().expect("locales").iter().filter_map(|v| v.as_str()).collect();
    assert_eq!(declared, LOCALES, "strings.json's locales must be build.rs's LOCALES, in order");
    let mut rows = Vec::new();
    for (table, keys) in root["strings"].as_object().expect("strings") {
        for (key, values) in keys.as_object().expect("a table") {
            let row: Vec<String> =
                LOCALES.iter().map(|l| literal(values[*l].as_str().unwrap_or(""))).collect();
            rows.push((table.clone(), key.clone(), row));
        }
    }
    rows.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    let mut out = String::new();
    let _ = writeln!(out, "pub static STRINGS: &[(&str, &str, [&str; {}])] = &[", LOCALES.len());
    for (table, key, row) in rows {
        let _ =
            writeln!(out, "    ({}, {}, [{}]),", literal(&table), literal(&key), row.join(", "));
    }
    out.push_str("];\n");
    let path = std::path::Path::new(&std::env::var("OUT_DIR").expect("OUT_DIR")).join("strings.rs");
    std::fs::write(path, out).expect("write strings.rs");
}
