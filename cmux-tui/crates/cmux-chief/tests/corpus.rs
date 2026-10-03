//! Runs the shared behavior corpus (`cmux-chief-corpus/1`). Until the
//! TypeScript generator lands (plans/cmux-next/chief-mac.md step 2), the
//! cases are a hand-written seed in tests/fixtures/seed-cases.json.

use cmux_chief::corpus::{Corpus, run};

#[test]
fn the_seed_corpus_passes() {
    let corpus: Corpus =
        serde_json::from_str(include_str!("fixtures/seed-cases.json")).expect("corpus JSON");
    assert!(!corpus.cases.is_empty() && !corpus.memory.is_empty());
    let failures = run(&corpus);
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}
