//! The palette ranking eval (plans/cmux-next/palette-ranking.md section 3): real root-palette
//! entries, 114 queries with expected rows (2 guard cases, 2 for the agent harness actions) and
//! 17 learning (replay) cases. A ranking change must not lower these floors; raise them when a
//! change improves the numbers, and paste the report (`cargo run -p cmux-palette-eval
//! --example eval`) into the landing.

#[path = "support/eval.rs"]
mod eval;

use eval::{Case, evaluate, fixture_ids, format_report, load};

// Recorded 2026-10-09 with the tiered scorer and commands-first ties (palette-ranking.md
// section 6, step 2b).
const FLOOR_TOP1: f64 = 0.69;
const FLOOR_TOP3: f64 = 0.81;
const FLOOR_MRR: f64 = 0.765;

fn failures(report: &eval::Report, pass: impl Fn(Option<usize>) -> bool) -> Vec<String> {
    report
        .results
        .iter()
        .filter(|result| !pass(result.rank))
        .map(|result| format!("{:?}: {}", result.query, result.top.join(", ")))
        .collect()
}

#[test]
fn every_expected_row_exists_in_the_fixture() -> Result<(), String> {
    let (fixture, cases) = load(None)?;
    let ids: std::collections::HashSet<&str> =
        fixture.entries.iter().map(|row| row.id.as_str()).collect();
    let has = |id: &Option<String>| id.as_deref().is_some_and(|id| ids.contains(id));
    let missing: Vec<&str> = cases
        .cases
        .iter()
        .filter(|case| {
            !(case.expect.iter().any(|id| ids.contains(id.as_str()))
                || has(&case.not_first)
                || has(&case.absent))
        })
        .map(|case| case.query.as_str())
        .collect();
    assert!(missing.is_empty(), "no expected row in the fixture: {missing:?}");
    assert!(!fixture_ids()?.is_empty());
    Ok(())
}

#[test]
fn guard_cases_keep_their_row_in_the_top_3() -> Result<(), String> {
    let (fixture, cases) = load(None)?;
    let report = evaluate(&fixture, &cases.profiles, cases.cases.iter().filter(|case| case.guard))?;
    let pushed_out = failures(&report, |rank| rank.is_some_and(|rank| rank <= 3));
    assert!(pushed_out.is_empty(), "{pushed_out:#?}");
    Ok(())
}

/// The user's own settings (cmux.json palette.aliases and palette.pins): every case holds, always.
#[test]
fn every_alias_and_pin_case_ranks_as_expected() -> Result<(), String> {
    let (fixture, cases) = load(None)?;
    let settings = |case: &&Case| case.aliases.is_some() || case.pins.is_some();
    let report = evaluate(&fixture, &cases.profiles, cases.cases.iter().filter(settings))?;
    assert!(report.summary.cases >= 12, "only {} alias and pin cases", report.summary.cases);
    let failed = failures(&report, |rank| rank == Some(1));
    assert!(failed.is_empty(), "{failed:#?}");
    Ok(())
}

/// Learned picks (palette-ranking.md 5.2): every learning case holds, always.
#[test]
fn every_learning_case_ranks_as_expected() -> Result<(), String> {
    let (fixture, cases) = load(None)?;
    let learning =
        |case: &&Case| case.replay.is_some() && case.aliases.is_none() && case.pins.is_none();
    let report = evaluate(&fixture, &cases.profiles, cases.cases.iter().filter(learning))?;
    assert!(report.summary.cases >= 17, "only {} learning cases", report.summary.cases);
    let failed = failures(&report, |rank| rank == Some(1));
    assert!(failed.is_empty(), "{failed:#?}");
    Ok(())
}

#[test]
fn ranking_quality_stays_at_or_above_the_recorded_floors() -> Result<(), String> {
    let (fixture, cases) = load(None)?;
    // The static floors measure text matching; learning cases have their own 100% floor above.
    let text =
        |case: &&Case| case.replay.is_none() && case.aliases.is_none() && case.pins.is_none();
    let report = evaluate(&fixture, &cases.profiles, cases.cases.iter().filter(text))?;
    println!("{}", format_report(&report, "palette eval"));
    let total = report.summary;
    assert!(total.top1 >= FLOOR_TOP1, "top-1 {:.3} under {FLOOR_TOP1}", total.top1);
    assert!(total.top3 >= FLOOR_TOP3, "top-3 {:.3} under {FLOOR_TOP3}", total.top3);
    assert!(total.mrr >= FLOOR_MRR, "MRR {:.3} under {FLOOR_MRR}", total.mrr);
    Ok(())
}
