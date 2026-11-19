//! MEASURE, NOT FOR A MERGE. The commit time of one journal row in a fixture
//! store of 1,000,000 journal rows with 7 subjects each.
//!
//! The same file runs at 2 commits: one that writes a journal row's subject
//! rows in the row's own commit, and one that writes them late, in the commit
//! of each journal row whose sequence is a multiple of 100. It uses only what
//! both commits have. Each line that it prints starts with
//! `commit row measure:`.
//!
//! The store's folder has one name ([`FOLDER`]) under the temp folder: the
//! test removes a folder of that name at its start (what a killed run left)
//! and at its end, in a pass and in a fail.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::json;

use super::kind_read_tests::TestJournalRecord;
use super::*;

/// The journal rows of the store before the measure.
const STORE_ROWS: u64 = 1_000_000;
/// The journal rows of one transaction while the store is made.
const FILL_ROWS: u64 = 50_000;
/// The measured commits, one journal row each.
const MEASURED: u64 = 3_000;
/// The commits of one block. With the late write, the last commit of a block
/// (a sequence that is a multiple of 100) writes the block's subject rows.
const BLOCK: u64 = 100;
/// The longest time of the store's making before a new transaction starts.
const FILL_LIMIT: Duration = Duration::from_secs(1_200);
const FOLDER: &str = "cmux-commit-row-measure";

fn line(text: &str) {
    println!("commit row measure: fixture, a debug test build: {text}");
}

fn ms(time: Duration) -> f64 {
    time.as_secs_f64() * 1000.0
}

/// Removes the store's folder when the test ends.
struct Folder(PathBuf);

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The journal row `row` of the fixture, with its 7 subjects: the one
/// session, and a workspace, a screen, a pane, a tab, a terminal and an
/// agent. The fixture has 100 workspaces with 1 screen and 4 terminals each.
/// 9 of 10 journal rows are of 40 terminals in turn; each tenth row is of
/// the other 360 in turn.
fn record(row: u64) -> TestJournalRecord {
    let terminal = if row % 10 == 9 { 40 + (row / 10) % 360 } else { (row - (row + 1) / 10) % 40 };
    let workspace = terminal / 4;
    let subject = |kind: &str, index: u64| JournalSubject {
        kind: kind.into(),
        id: format!("{kind}_{:08x}{index:024x}", index.wrapping_mul(2_654_435_761) & 0xffff_ffff),
    };
    TestJournalRecord {
        kind: "agent.turn.started".into(),
        producer: JournalProducer {
            kind: "agent_adapter".into(),
            id: crate::AGENT_HOOK_PRODUCER_ID.into(),
        },
        subjects: vec![
            subject("session", 0),
            subject("workspace", workspace),
            subject("screen", workspace),
            subject("pane", terminal),
            subject("tab", terminal),
            subject("terminal", terminal),
            subject("agent", terminal),
        ],
        payload: json!({"turn": row}),
    }
}

fn median(times: &[Duration]) -> Duration {
    let mut sorted = times.to_vec();
    sorted.sort();
    sorted[sorted.len() / 2]
}

/// The mean, the median, the p99 (the sample at 99 percent of the sorted
/// count) and the slowest of `times` in ms, with their count.
fn times_of(times: &[Duration]) -> String {
    let mut sorted = times.to_vec();
    sorted.sort();
    let count = sorted.len();
    if count == 0 {
        return "no sample".to_string();
    }
    let mean = sorted.iter().sum::<Duration>() / u32::try_from(count).unwrap();
    format!(
        "mean {:.4} ms, median {:.4} ms, p99 {:.4} ms, slowest {:.4} ms of {count} samples",
        ms(mean),
        ms(sorted[count / 2]),
        ms(sorted[(count * 99 / 100).min(count - 1)]),
        ms(sorted[count - 1])
    )
}

/// Each of `times` in ms.
fn each(times: &[Duration]) -> String {
    times.iter().map(|time| format!("{:.4}", ms(*time))).collect::<Vec<_>>().join(", ")
}

#[test]
fn the_commit_time_of_a_journal_row_in_a_fixture_store_of_1_000_000_journal_rows() {
    let test_started = Instant::now();
    let root = std::env::temp_dir().join(FOLDER);
    let left = root.exists();
    if left {
        std::fs::remove_dir_all(&root).unwrap();
    }
    let _folder = Folder(root.clone());
    let registry = WorkspaceRegistry::open(&root, "commit-row-measure").unwrap();
    line(&format!(
        "the store's folder is {}; a folder of that name from an earlier run: {}",
        root.display(),
        if left { "removed" } else { "none" }
    ));

    // The store.
    let started = Instant::now();
    let (mut appends, mut syncer_waits) = (Duration::ZERO, Duration::ZERO);
    let (mut first, mut last) = (0, 0);
    for from in (0..STORE_ROWS).step_by(usize::try_from(FILL_ROWS).unwrap()) {
        assert!(
            started.elapsed() < FILL_LIMIT,
            "ENDED BY ITS LIMIT: {from} journal rows of {STORE_ROWS} are made after {:.1} s (the \
             appends {:.1} s, the waits for the syncer {:.1} s)",
            started.elapsed().as_secs_f64(),
            appends.as_secs_f64(),
            syncer_waits.as_secs_f64()
        );
        let batch = (from..from + FILL_ROWS).map(record).collect::<Vec<_>>();
        let append_started = Instant::now();
        let sequences = registry.append_journal_records_for_test(&batch);
        registry.connection.request_flush();
        appends += append_started.elapsed();
        // The syncer ends its work for this transaction before the next one.
        let wait_started = Instant::now();
        registry.connection.checkpoints_after_flush_for_test();
        syncer_waits += wait_started.elapsed();
        if from == 0 {
            first = sequences[0];
        }
        last = *sequences.last().unwrap();
    }
    line(&format!(
        "THE STORE: {STORE_ROWS} journal rows with 7 subjects each (the sequences {first} to \
         {last}), made by the registry's append with {FILL_ROWS} journal rows in a transaction, \
         each with a flush request and a wait for the syncer after it, in {:.1} s (the appends \
         {:.1} s, the waits for the syncer {:.1} s)",
        started.elapsed().as_secs_f64(),
        appends.as_secs_f64(),
        syncer_waits.as_secs_f64()
    ));

    // The measured commits: one journal row each, a flush request after each
    // and no wait, as the journal writer makes one after a batch that no
    // request waits for.
    let mut times = Vec::new();
    for row in STORE_ROWS..STORE_ROWS + MEASURED {
        let one = [record(row)];
        let commit_started = Instant::now();
        let sequences = registry.append_journal_records_for_test(&one);
        let took = commit_started.elapsed();
        registry.connection.request_flush();
        times.push((sequences[0], took));
    }
    assert_eq!(times.len(), usize::try_from(MEASURED).unwrap());
    let all = times.iter().map(|(_, took)| *took).collect::<Vec<_>>();
    let pick = |ends: bool| {
        times
            .iter()
            .filter(|(sequence, _)| (sequence % BLOCK == 0) == ends)
            .map(|(_, took)| *took)
            .collect::<Vec<_>>()
    };
    let (ends, others) = (pick(true), pick(false));
    line(&format!(
        "THE COMMITS: {MEASURED} commits of one journal row each (the sequences {} to {}), a \
         flush request after each and no wait: ALL: {}; THE {} COMMITS WHOSE SEQUENCE IS A \
         MULTIPLE OF {BLOCK}: {}; each of them in ms: {}; THE {} OTHER COMMITS: {}",
        times[0].0,
        times[times.len() - 1].0,
        times_of(&all),
        ends.len(),
        times_of(&ends),
        each(&ends),
        others.len(),
        times_of(&others)
    ));

    // A block ends with the commit whose sequence is a multiple of BLOCK.
    let mut blocks = BTreeMap::<u64, Vec<Duration>>::new();
    for (sequence, took) in &times {
        blocks.entry((sequence - 1) / BLOCK).or_default().push(*took);
    }
    let sizes = blocks.values().map(Vec::len).collect::<Vec<_>>();
    let mut medians = blocks.values().map(|block| median(block)).collect::<Vec<_>>();
    let in_order = each(&medians);
    medians.sort();
    line(&format!(
        "THE BLOCKS: the median of each block of {BLOCK} commits, in ms, in the commits' order \
         ({} blocks; the commits in a block: {} to {}): {in_order}; the smallest, the median \
         and the largest of these medians: {:.4}, {:.4}, {:.4} ms",
        medians.len(),
        sizes.iter().min().unwrap(),
        sizes.iter().max().unwrap(),
        ms(medians[0]),
        ms(medians[medians.len() / 2]),
        ms(medians[medians.len() - 1])
    ));
    line(&format!("the test took {:.1} s", test_started.elapsed().as_secs_f64()));
}
