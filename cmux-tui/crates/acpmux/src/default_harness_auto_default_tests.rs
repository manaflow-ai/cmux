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

/// A fresh Mac has only the built-in Chief and UniiChat: neither is the default, so New Tab
/// offers Add harness instead of a chat signed out of UniiChat. Claude, once there, wins.
#[test]
fn built_in_chief_and_uniichat_are_never_the_default() {
    let mut harnesses = std::collections::BTreeMap::new();
    let mut chief = profile(HarnessKind::Acp);
    chief.family = Some(CHIEF_FAMILY.into());
    let mut unii = profile(HarnessKind::Acp);
    unii.family = Some(UNIICHAT_PROFILE.into());
    harnesses.insert("chief".to_owned(), chief);
    harnesses.insert("unii".to_owned(), unii);
    assert_eq!(auto_default_harness(&harnesses), None);
    harnesses.insert("claude".to_owned(), profile(HarnessKind::Acp));
    assert_eq!(auto_default_harness(&harnesses).as_deref(), Some("claude"));
}
