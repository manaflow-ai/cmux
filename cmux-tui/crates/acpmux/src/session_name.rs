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
}
