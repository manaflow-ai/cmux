use super::*;
use std::collections::BTreeMap;

fn profile(kind: HarnessKind) -> HarnessProfile {
    HarnessProfile {
        kind,
        argv: vec![],
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

#[test]
fn claude_then_codex_win_over_the_alphabet() {
    let mut harnesses = std::collections::BTreeMap::new();
    harnesses.insert("amp".to_owned(), profile(HarnessKind::default()));
    harnesses.insert("codex".to_owned(), profile(HarnessKind::default()));
    harnesses.insert("claude".to_owned(), profile(HarnessKind::default()));
    assert_eq!(auto_default_harness(&harnesses).as_deref(), Some("claude"));
    harnesses.remove("claude");
    assert_eq!(auto_default_harness(&harnesses).as_deref(), Some("codex"));
    harnesses.remove("codex");
    harnesses.insert("aaa-shell".to_owned(), profile(HarnessKind::Terminal));
    assert_eq!(auto_default_harness(&harnesses).as_deref(), Some("amp"));
}
