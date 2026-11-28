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
#[path = "default_harness_auto_default_tests.rs"]
mod auto_default_tests;
