//! Which harness a new chat starts with when the config names none.

use crate::config::{CHIEF_FAMILY, HarnessKind, HarnessProfile, UNIICHAT_PROFILE};

/// The default harness when the config names none: Claude, then Codex, then the first other
/// installed one. A terminal harness (an installed `muse`, say) runs no ACP session, so it
/// never becomes the default. Chief and UniiChat harnesses also require explicit selection:
/// UniiChat is built in and needs its own sign-in, so on a Mac with no Claude Code or Codex it
/// became every new chat's default and a first tab opened signed out of it (onboarding probe
/// 2026-11-22). With none usable there is no default, and New Tab offers Add harness. Before this,
/// the alphabetically first profile won, so any discovered agent sorting before "claude"
/// silently made new chats start elsewhere
/// (dogfood 2026-10-26: "It was codex? Not claude?").
pub(crate) fn auto_default_harness<'a, I>(harnesses: I) -> Option<String>
where
    I: IntoIterator<Item = (&'a String, &'a HarnessProfile)>,
{
    let usable: Vec<&String> = harnesses
        .into_iter()
        .filter(|(_, profile)| {
            profile.kind != HarnessKind::Terminal
                && profile.family.as_deref() != Some(CHIEF_FAMILY)
                && profile.family.as_deref() != Some(UNIICHAT_PROFILE)
        })
        .map(|(name, _)| name)
        .collect();
    ["claude", "codex"]
        .iter()
        .find_map(|preferred| usable.iter().find(|name| name.as_str() == *preferred))
        .or_else(|| usable.first())
        .map(|name| (*name).clone())
}

#[cfg(test)]
mod auto_default_tests {
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
}
