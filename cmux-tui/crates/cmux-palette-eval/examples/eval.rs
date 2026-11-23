//! Prints the palette ranking eval report (plans/cmux-next/palette-ranking.md).
//!
//!   cargo run -p cmux-palette-eval --example eval                      # the checked-in fixture
//!   cargo run -p cmux-palette-eval --example eval -- --live FILE       # rows a tagged build returned (palette-eval-live.py)
//!   cargo run -p cmux-palette-eval --example eval -- --fixture F       # another dump
//!   cargo run -p cmux-palette-eval --example eval -- --explain "query" # the top 12 rows with scores and sections

#[path = "../tests/support/eval.rs"]
mod eval;

use serde_json::{Value, json};
use std::collections::HashMap;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let option = |name: &str| {
        args.iter().position(|arg| arg == name).and_then(|index| args.get(index + 1)).cloned()
    };
    let fixture_path = option("--fixture").map(std::path::PathBuf::from);
    let (fixture, cases) = eval::load(fixture_path.as_deref())?;
    if let Some(query) = option("--explain") {
        for section in eval::rank(&fixture, &query, json!({ "entries": {} }), None, None, 0.0)? {
            let name = section
                .section_index
                .and_then(|index| fixture.sections.get(usize::try_from(index).ok()?))
                .map_or("recent", |section| section.id.as_str());
            for row in section.rows.iter().take(12) {
                let entry = &fixture.entries[row.index];
                println!(
                    "{:>6}  {name:<12} {}  {}",
                    row.score,
                    entry.id,
                    Value::from(entry.entry["title"].as_str().unwrap_or(""))
                );
            }
        }
        return Ok(());
    }
    if let Some(path) = option("--live") {
        // Live rows come from a fresh build: no usage, no settings, no overlay rows. Only cases
        // without a profile or settings whose expected rows exist in that build are scored.
        let text = std::fs::read_to_string(&path).map_err(|error| format!("{path}: {error}"))?;
        let live: Value = serde_json::from_str(&text).map_err(|error| error.to_string())?;
        let results = live["results"].as_object().cloned().unwrap_or_default();
        let ids = eval::fixture_ids()?;
        let scored = cases.cases.iter().filter(|case| {
            case.profile.is_none()
                && case.aliases.is_none()
                && case.pins.is_none()
                && !case.query.is_empty()
                && results.contains_key(&case.query)
                && case.expect.iter().any(|id| ids.contains(id))
        });
        let report = eval::score_cases(&HashMap::new(), scored, |case, _| {
            Ok(results[&case.query]
                .as_array()
                .map(|rows| {
                    rows.iter().filter_map(|row| row["id"].as_str().map(str::to_owned)).collect()
                })
                .unwrap_or_default())
        })?;
        let tag = live["tag"].as_str().unwrap_or("?");
        println!("{}", eval::format_report(&report, &format!("live {tag}")));
        return Ok(());
    }
    let report = eval::evaluate(&fixture, &cases.profiles, cases.cases.iter())?;
    println!("{}", eval::format_report(&report, "palette eval"));
    Ok(())
}
