//! Search All Windows (`cmux_palette_ranker::global_search`) against the scan it replaced.
//!
//! The oracle is the Swift `GlobalSearchCorpus.hits` loop, line for line: every tab, every text,
//! every line newest first, `allSatisfy { line.contains(word) }`. Every narrowed answer must equal
//! it, whatever was typed, deleted or pasted before and whichever reads landed between keys.
//!
//! `extending_keystrokes_scan_only_previous_matches` types a 12-key query over 50 tabs x 24,000
//! lines (the 4,000 terminal rows plus 20,000 transcript lines the window reads per agent tab)
//! and fails when key 12 tests more than 2% of the lines. The timing sweep (1x and 10x tabs, the
//! old scan and the narrowed one in one harness) runs only when asked:
//!
//!   env CMUX_STRESS=1 cargo test -p cmux-palette-ranker --release --test global_search -- --nocapture

use cmux_palette_ranker::global_search::{Answer, Corpus, Hit, Text, words};
use proptest::prelude::*;
use std::time::Instant;

/// One tab as the oracle sees it.
#[derive(Debug, Clone)]
struct Tab {
    title: String,
    texts: Vec<Vec<String>>,
}

/// `tabs` with every title and line lowercased once, as the Swift corpus held them (`lowered`).
fn lowered(tabs: &[Tab]) -> Vec<Tab> {
    tabs.iter()
        .map(|tab| Tab {
            title: tab.title.to_lowercase(),
            texts: tab
                .texts
                .iter()
                .map(|text| text.iter().map(|line| line.to_lowercase()).collect())
                .collect(),
        })
        .collect()
}

/// The Swift scan: `GlobalSearchCorpus.hits` before RFD 0199, over `lowered` tabs.
fn oracle(tabs: &[Tab], words: &[String], limit: usize) -> (Vec<Hit>, bool) {
    if words.is_empty() {
        return (Vec::new(), false);
    }
    let mut titled = Vec::new();
    let mut others = Vec::new();
    for (document, tab) in tabs.iter().enumerate() {
        let title = &tab.title;
        let remaining: Vec<&String> =
            words.iter().filter(|word| !title.contains(word.as_str())).collect();
        let needs: Vec<&String> =
            if remaining.is_empty() { words.iter().collect() } else { remaining.clone() };
        let mut best = None;
        let mut count = 0;
        for (text_index, text) in tab.texts.iter().enumerate() {
            for (line_index, line) in text.iter().enumerate().rev() {
                if needs.iter().all(|word| line.contains(word.as_str())) {
                    best.get_or_insert((text_index, line_index));
                    count += 1;
                }
            }
        }
        let hit = Hit {
            document,
            text: best.map(|b| b.0),
            line: best.map(|b| b.1),
            count,
            title_matched: remaining.is_empty(),
        };
        if remaining.is_empty() {
            titled.push(hit);
        } else if best.is_some() {
            others.push(hit);
        }
    }
    titled.extend(others);
    let limited = titled.len() > limit;
    titled.truncate(limit);
    (titled, limited)
}

fn corpus(tabs: &[Tab]) -> Corpus {
    let titles: Vec<&str> = tabs.iter().map(|tab| tab.title.as_str()).collect();
    let mut corpus = Corpus::new(&titles);
    for (index, tab) in tabs.iter().enumerate() {
        corpus.apply(index, tab.texts.iter().map(|lines| Text::new(lines)).collect());
    }
    corpus
}

/// `lowered`: the tabs as `lowered` gives them.
fn check(corpus: &mut Corpus, lowered: &[Tab], query: &str, limit: usize) -> Answer {
    let words = words(query);
    let answer = corpus.hits(&words, limit);
    let (hits, limited) = oracle(lowered, &words, limit);
    assert_eq!((&answer.hits, answer.limited), (&hits, limited), "query {query:?}");
    answer
}

const VOCAB: &[&str] = &[
    "cargo",
    "build",
    "error",
    "warning",
    "test",
    "passed",
    "Ünïcode",
    "日本語",
    "ok",
    "git",
    "push",
    "err",
    "rro",
];

fn line_strategy() -> impl Strategy<Value = String> {
    prop::collection::vec(prop::sample::select(VOCAB), 0..5).prop_map(|parts| parts.join(" "))
}

fn tab_strategy() -> impl Strategy<Value = Tab> {
    (line_strategy(), prop::collection::vec(prop::collection::vec(line_strategy(), 0..12), 0..3))
        .prop_map(|(title, texts)| Tab { title, texts })
}

/// One step of typing in the window.
#[derive(Debug, Clone)]
enum Step {
    Key(char),
    Backspace,
    Paste(String),
    Clear,
    /// A tab's read landing between keys.
    Read(usize, Vec<Vec<String>>),
}

fn step_strategy() -> impl Strategy<Value = Step> {
    prop_oneof![
        6 => prop::sample::select(&['e', 'r', 'o', 'c', 'a', 'g', ' ', 't', 'Ü', '日'][..]).prop_map(Step::Key),
        2 => Just(Step::Backspace),
        1 => prop::sample::select(VOCAB).prop_map(|word| Step::Paste(word.to_owned())),
        1 => Just(Step::Clear),
        1 => (0usize..8, prop::collection::vec(prop::collection::vec(line_strategy(), 0..12), 0..3))
            .prop_map(|(tab, texts)| Step::Read(tab, texts)),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 400, ..ProptestConfig::default() })]

    #[test]
    fn narrowed_answers_equal_the_full_scan(
        mut tabs in prop::collection::vec(tab_strategy(), 1..8),
        steps in prop::collection::vec(step_strategy(), 1..30),
        limit in 1usize..6,
    ) {
        let mut corpus = corpus(&tabs);
        let mut query = String::new();
        for step in steps {
            match step {
                Step::Key(key) => query.push(key),
                Step::Backspace => { query.pop(); }
                Step::Paste(text) => query.push_str(&text),
                Step::Clear => query.clear(),
                Step::Read(tab, texts) => {
                    let tab = tab % tabs.len();
                    corpus.apply(tab, texts.iter().map(|lines| Text::new(lines)).collect());
                    if let Some(slot) = tabs.get_mut(tab) { slot.texts = texts; }
                }
            }
            check(&mut corpus, &lowered(&tabs), &query, limit);
        }
    }
}

/// `count` agent tabs: 20,000 transcript lines and 4,000 terminal rows each, a build log's mix.
fn agent_tabs(count: usize) -> Vec<Tab> {
    let words = [
        "cargo",
        "build",
        "compiling",
        "warning",
        "error",
        "test",
        "result",
        "finished",
        "running",
    ];
    (0..count)
        .map(|tab| {
            let line = |i: usize| {
                let a = words[(i * 7 + tab) % words.len()];
                let b = words[(i * 13 + 3) % words.len()];
                format!("{a} {b} crate-{} target/release/deps/{i:x} ({}ms)", i % 97, i % 1000)
            };
            Tab {
                title: format!("agent {tab} ~/src/project-{tab}"),
                texts: vec![
                    (0..20_000).map(line).collect(),
                    (0..4_000).map(|i| line(i + 20_000)).collect(),
                ],
            }
        })
        .collect()
}

const TYPED: &str = "crate-42 tar";

#[test]
fn extending_keystrokes_scan_only_previous_matches() {
    let tabs = agent_tabs(50);
    let total: u64 = tabs.iter().flat_map(|tab| &tab.texts).map(|text| text.len() as u64).sum();
    let mut corpus = corpus(&tabs);
    let tabs = lowered(&tabs);
    let mut query = String::new();
    let mut scanned = Vec::new();
    for key in TYPED.chars() {
        query.push(key);
        scanned.push(check(&mut corpus, &tabs, &query, 200).lines_scanned);
    }
    let last = *scanned.last().unwrap_or(&u64::MAX);
    assert!(last * 50 <= total, "key 12 tested {last} of {total} lines (> 2%): {scanned:?}");
}

/// The old scan and the narrowed corpus, one 12-key query, at `tabs` agent tabs.
fn sweep(tabs: usize) {
    let tabs = agent_tabs(tabs);
    let lines: usize = tabs.iter().flat_map(|tab| &tab.texts).map(Vec::len).sum();
    let mut corpus = corpus(&tabs);
    let tabs = lowered(&tabs);
    let (mut old_ms, mut new_ms, mut old_first, mut new_first) = (0.0, 0.0, 0.0, 0.0);
    let mut query = String::new();
    for (key, ch) in TYPED.chars().enumerate() {
        query.push(ch);
        let words = words(&query);
        let started = Instant::now();
        std::hint::black_box(oracle(&tabs, &words, 200));
        let old = started.elapsed().as_secs_f64() * 1e3;
        let started = Instant::now();
        std::hint::black_box(corpus.hits(&words, 200));
        let new = started.elapsed().as_secs_f64() * 1e3;
        if key == 0 {
            (old_first, new_first) = (old, new);
        }
        old_ms += old;
        new_ms += new;
    }
    println!(
        "STRESS-GLOBAL-SEARCH {{\"tabs\":{},\"lines\":{lines},\"old_query_ms\":{old_ms:.1},\"new_query_ms\":{new_ms:.1},\"old_first_key_ms\":{old_first:.1},\"new_first_key_ms\":{new_first:.1}}}",
        tabs.len()
    );
}

#[test]
fn stress_sweep() {
    let asked = std::env::var_os("CMUX_STRESS").is_some()
        || std::env::args().any(|arg| arg.contains("stress_sweep"));
    if !asked {
        return;
    }
    for tabs in [5, 50] {
        sweep(tabs);
    }
}
