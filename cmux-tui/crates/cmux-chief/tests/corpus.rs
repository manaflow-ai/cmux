//! Runs the shared behavior corpus (`cmux-chief-corpus/1`), generated from
//! the TypeScript core by `mux/packages/brain/conformance/generate.ts`. The
//! TypeScript core is the behavior source: when a case fails here, the Rust
//! core changes, never the file.

use cmux_chief::corpus::{Corpus, run};

#[test]
fn the_generated_corpus_passes() {
    let corpus: Corpus = serde_json::from_str(include_str!(
        "../../../../mux/packages/brain/conformance/chief-cases.json"
    ))
    .expect("corpus JSON");
    assert!(!corpus.cases.is_empty() && !corpus.memory.is_empty());
    let failures = run(&corpus);
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}
