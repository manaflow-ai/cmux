//! Session name rules. Names are what people type, so keep them safe for
//! shells, paths, and URLs.

pub fn validate(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 80 {
        return Err("session name must be 1 to 80 characters".into());
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')) {
        return Err("session name may contain letters, digits, '-', '_' and '.'".into());
    }
    if name.starts_with('.') || name.starts_with('-') {
        return Err("session name may not start with '.' or '-'".into());
    }
    Ok(())
}

/// Why `name` reads as an id or a counter rather than its task, or None when it reads fine.
/// Only its last `/` segment counts (a peer or parent prefix is routing): a trailing counter
/// (`cloud-item-14`, the `-14`) or a hex run of 6 or more with a digit in it
/// (`optchat-sub-6b68ac4a-a26`, the `6b68ac4a`). A slug of words (`session-info-drag-handles`)
/// reads fine, and so does a number inside one (`fix-27310-crash`). A hint, never a refusal:
/// such a name still works as an address (Leo, 2026-11-02, on `cloud-item-14` and
/// `optchat-sub-6b68ac4a-a26` in his sidebar: "idk if we should suggest that they make more
/// readable ones as a bit of guidance").
pub fn opaque_reason(name: &str) -> Option<String> {
    let bare = name.rsplit('/').next().unwrap_or(name);
    let parts: Vec<&str> = bare.split(['-', '_', '.']).filter(|p| !p.is_empty()).collect();
    let is_digits = |p: &str| p.bytes().all(|b| b.is_ascii_digit());
    if parts.len() > 1 && parts.last().is_some_and(|p| is_digits(p)) {
        return Some(format!("ends in a counter (-{})", parts.last().copied().unwrap_or_default()));
    }
    parts
        .iter()
        .find(|p| {
            p.len() >= 6
                && p.bytes().all(|b| b.is_ascii_hexdigit())
                && p.bytes().any(|b| b.is_ascii_digit())
        })
        .map(|p| format!("has an id in it ({p})"))
}

/// The one-line hint `acpmux new` and `ensure` print for a name that reads as an
/// id (`opaque_reason`): name a session after its task in 2-5 words, ids in a tag.
pub fn naming_hint(name: &str) -> Option<String> {
    opaque_reason(name).map(|why| {
        format!(
            "hint: session name {name:?} {why}, so it reads as an id where people see it (the \
             cmux sidebar, acpmux ls). Name a session after its task in 2-5 words \
             (-n session-info-drag-handles) and keep ids in a tag (--tag item=14); the name \
             still works as an address."
        )
    })
}

/// Whether `key` is `name`'s last `/`-separated segments: `mac-ci-3` and `sr2/mac-ci-3` name
/// the sub-session `claude-sr2/mac-ci-3` (a child is named `PARENT/SHORT`, `hub/subsessions.rs`),
/// `ci-3` does not. The one rule every resolver applies after an exact id or name misses
/// (`Hub::resolve`, `Hub::resolve_remote`, `hub/locate.rs`), so a coordinator's lane is found
/// by the short name `acpmux ls` shows under its parent.
pub fn ends_with_segments(name: &str, key: &str) -> bool {
    !key.is_empty()
        && !key.starts_with('/')
        && name.strip_suffix(key).is_some_and(|head| head.ends_with('/'))
}

/// Whether `name` contains `lower` (already lowercase ASCII) in any ASCII case, as
/// `name.to_ascii_lowercase().contains(lower)` answers, without a copy of `name`.
pub fn contains_ignore_case(name: &str, lower: &str) -> bool {
    lower.is_empty()
        || name.as_bytes().windows(lower.len()).any(|w| w.eq_ignore_ascii_case(lower.as_bytes()))
}

/// How many candidates a refusal lists before it says how many more there were.
pub const CANDIDATES_SHOWN: usize = 8;

/// The names a key's refusal lists: those that are `key` by its last segments or that start
/// with or contain it, any case, best first, each once.
pub fn candidates<'a>(names: impl IntoIterator<Item = &'a str>, key: &str) -> Vec<String> {
    let lower = key.to_ascii_lowercase();
    if lower.is_empty() {
        return Vec::new();
    }
    let mut ranked: Vec<(u8, &str)> = names
        .into_iter()
        .filter_map(|name| {
            let n = name.to_ascii_lowercase();
            let rank = if ends_with_segments(&n, &lower) {
                0
            } else if n.starts_with(&lower) {
                1
            } else if n.contains(&lower) {
                2
            } else {
                return None;
            };
            Some((rank, name))
        })
        .collect();
    ranked.sort();
    ranked.dedup_by(|a, b| a.1 == b.1);
    ranked.into_iter().map(|(_, name)| name.to_owned()).collect()
}

/// `candidates` as a refusal's tail: `a, b, c` or `a, b, … and 4 more`.
pub fn candidate_list(candidates: &[String]) -> String {
    let shown = candidates.iter().take(CANDIDATES_SHOWN).cloned().collect::<Vec<_>>().join(", ");
    match candidates.len().saturating_sub(CANDIDATES_SHOWN) {
        0 => shown,
        more => format!("{shown}, … and {more} more"),
    }
}

/// The not-found refusal for `key`: the `no session matches` text every client reads (keep that
/// start; `cmux-tui-core` matches it), the names it nearly matched, and `data.candidates` for a
/// program. No `reason`: the CLI still reads it as no session (exit 4, `cli/errors.rs`).
pub fn not_found(key: &str, candidates: &[String]) -> crate::rpc::RpcError {
    let e = crate::rpc::RpcError::not_found(format!("no session matches {key:?}"));
    if candidates.is_empty() {
        return e;
    }
    let shown: Vec<&String> = candidates.iter().take(CANDIDATES_SHOWN).collect();
    crate::rpc::RpcError::not_found(format!(
        "{}; close matches: {}",
        e.message,
        candidate_list(candidates)
    ))
    .with_data(serde_json::json!({"candidates": shown}))
}

/// The refusal for a key several sessions match, with them, so the caller can pick one.
pub fn ambiguous(key: &str, matched: &[String]) -> crate::rpc::RpcError {
    let shown: Vec<&String> = matched.iter().take(CANDIDATES_SHOWN).collect();
    crate::rpc::RpcError::invalid_params(format!(
        "{key:?} matches {} sessions; use the full name or the id: {}",
        matched.len(),
        candidate_list(matched)
    ))
    .with_data(serde_json::json!({"reason": "ambiguous_session", "candidates": shown}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_names_a_sub_session_by_its_last_segments_only() {
        assert!(ends_with_segments("claude-sr2/mac-ci-3", "mac-ci-3"));
        assert!(ends_with_segments("a/claude-sr2/mac-ci-3", "claude-sr2/mac-ci-3"));
        assert!(!ends_with_segments("claude-sr2/mac-ci-3", "ci-3"), "not a segment boundary");
        assert!(!ends_with_segments("mac-ci-3", "mac-ci-3"), "the whole name is the exact match");
        assert!(!ends_with_segments("claude-sr2/mac-ci-3", ""));
        assert!(!ends_with_segments("claude-sr2/mac-ci-3", "/mac-ci-3"));
    }

    #[test]
    fn candidates_put_segment_matches_first_and_list_each_once() {
        let names =
            ["mac-ci-30", "x/mac-ci-3-old", "claude-sr2/mac-ci-3", "other", "claude-sr2/mac-ci-3"];
        assert_eq!(
            candidates(names, "MAC-CI-3"),
            ["claude-sr2/mac-ci-3", "mac-ci-30", "x/mac-ci-3-old"],
        );
        assert!(candidates(names, "").is_empty());
    }

    #[test]
    fn refusals_keep_the_text_clients_read_and_carry_the_candidates() {
        let e = not_found("lane", &["a/lane".into()]);
        assert!(e.message.starts_with("no session matches \"lane\""), "{}", e.message);
        assert!(e.message.ends_with("close matches: a/lane"), "{}", e.message);
        assert_eq!(e.data.unwrap()["candidates"][0], "a/lane");
        let plain = not_found("lane", &[]);
        assert_eq!(plain.message, "no session matches \"lane\"");
        assert!(plain.data.is_none());
        let many: Vec<String> = (0..10).map(|i| format!("p{i}/lane")).collect();
        let e = ambiguous("lane", &many);
        assert!(e.message.starts_with("\"lane\" matches 10 sessions"), "{}", e.message);
        assert!(e.message.ends_with("p7/lane, … and 2 more"), "{}", e.message);
        assert_eq!(e.data.unwrap()["candidates"].as_array().unwrap().len(), CANDIDATES_SHOWN);
    }

    #[test]
    fn opaque_names_get_a_hint_and_task_names_do_not() {
        for (name, why) in [
            ("cloud-item-14", "ends in a counter (-14)"),
            ("gcp-codex-lane-12/cloud-item-11", "ends in a counter (-11)"),
            ("optchat-sub-6b68ac4a-a26", "has an id in it (6b68ac4a)"),
            ("dispatch-019a3f2e", "has an id in it (019a3f2e)"),
        ] {
            assert_eq!(opaque_reason(name).as_deref(), Some(why), "{name}");
            assert!(naming_hint(name).is_some_and(|h| h.contains("2-5 words")), "{name}");
        }
        for name in [
            "session-info-drag-handles",
            "drain-cx-b-cloud-ios",
            "fix-27310-crash",
            "tests",
            "deadbeef-notes",
            "123",
            "facade-cleanup",
        ] {
            assert_eq!(opaque_reason(name), None, "{name}");
            assert_eq!(naming_hint(name), None, "{name}");
        }
    }
}
