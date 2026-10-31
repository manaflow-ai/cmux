//! The answer an MCP server gives a call to a tool it does not have: `unknown tool: NAME`, and
//! `; did you mean TOOL?` when one of its tools is a close match, so an agent that mistyped a
//! name can correct it without listing the tools again. Each server passes the names it lists,
//! so the hint cannot drift from its tools. Used by acpmux's MCP servers and `cmux mcp`.

use serde_json::Value;

/// `unknown tool: NAME`, with `; did you mean TOOL?` when [`nearest`] finds one in `known`.
pub fn unknown_tool<'a>(name: &str, known: impl IntoIterator<Item = &'a str>) -> String {
    match nearest(name, known) {
        Some(tool) => format!("unknown tool: {name}; did you mean {tool}?"),
        None => format!("unknown tool: {name}"),
    }
}

/// The `name` of each tool in a `tools/list` array.
pub fn names(tools: &Value) -> impl Iterator<Item = &str> {
    tools.as_array().into_iter().flatten().filter_map(|tool| tool["name"].as_str())
}

/// The known name closest to `name`, ignoring case: within an edit distance (a swap of two
/// neighbouring letters counts as one edit) of 1 for a name of up to 3 letters and of
/// `max(2, len / 3)` for a longer one, or a known name `name` begins (when it has at least 3
/// letters). The closest wins and a tie goes to the first in `known`. `None` when nothing is
/// that close, or `name` is longer than [`MAX_NAME`] characters (no tool's name is: a caller's
/// name of any size costs at most that much work); `name` itself is never its own hint.
pub fn nearest<'a>(name: &str, known: impl IntoIterator<Item = &'a str>) -> Option<&'a str> {
    let name_trimmed = name.trim();
    // A char is at most 4 bytes: a longer name is refused before it is read again.
    if name_trimmed.len() > MAX_NAME * 4 || name_trimmed.chars().count() > MAX_NAME {
        return None;
    }
    let wanted: Vec<char> = name_trimmed.to_lowercase().chars().collect();
    if wanted.is_empty() {
        return None;
    }
    let limit = if wanted.len() <= 3 { 1 } else { (wanted.len() / 3).max(2) };
    let mut best: Option<(usize, &str)> = None;
    for candidate in known {
        if candidate == name || candidate.chars().count() > MAX_NAME {
            continue;
        }
        let lower: Vec<char> = candidate.to_lowercase().chars().collect();
        // The distance is at least the length difference: too far apart to be a typo, unless
        // `name` is the start of it.
        let prefix = wanted.len() >= 3 && lower.starts_with(&wanted);
        if !prefix && lower.len().abs_diff(wanted.len()) > limit {
            continue;
        }
        let mut score = distance(&wanted, &lower);
        if prefix {
            score = score.min(limit);
        }
        if score <= limit && best.is_none_or(|(least, _)| score < least) {
            best = Some((score, candidate));
        }
    }
    best.map(|(_, candidate)| candidate)
}

/// The longest tool name a hint is looked for (tool names are short identifiers).
pub const MAX_NAME: usize = 128;

/// Optimal string alignment distance: insertions, deletions, substitutions and swaps of two
/// neighbouring characters.
fn distance(a: &[char], b: &[char]) -> usize {
    let mut d = vec![vec![0; b.len() + 1]; a.len() + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            let mut best = (d[i - 1][j] + 1).min(d[i][j - 1] + 1).min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                best = best.min(d[i - 2][j - 2] + 1);
            }
            d[i][j] = best;
        }
    }
    d[a.len()][b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const TOOLS: [&str; 6] = ["send", "team_send", "team_inbox", "ls", "last", "info"];

    #[test]
    fn a_typo_names_the_nearest_tool() {
        assert_eq!(
            unknown_tool("team_sned", TOOLS),
            "unknown tool: team_sned; did you mean team_send?"
        );
        assert_eq!(unknown_tool("snd", TOOLS), "unknown tool: snd; did you mean send?");
        assert_eq!(unknown_tool("lats", TOOLS), "unknown tool: lats; did you mean last?");
        assert_eq!(
            unknown_tool("team_inbx", TOOLS),
            "unknown tool: team_inbx; did you mean team_inbox?"
        );
    }

    #[test]
    fn an_oversized_name_is_answered_at_once_without_a_hint() {
        // Megabytes of name: no matrix is built for it (it used to allocate about name x tool cells).
        let huge = "team_send".repeat(800_000);
        let started = std::time::Instant::now();
        assert_eq!(nearest(&huge, TOOLS), None);
        assert_eq!(nearest(&"x".repeat(MAX_NAME + 1), TOOLS), None);
        assert!(started.elapsed() < std::time::Duration::from_secs(1), "{:?}", started.elapsed());
        // Names far apart in length are not compared; a typo still is.
        assert_eq!(nearest("team_send_with_a_long_tail", TOOLS), None);
        assert_eq!(nearest("team_sendd", TOOLS), Some("team_send"));
    }

    #[test]
    fn a_name_in_another_case_or_a_prefix_names_the_tool() {
        assert_eq!(nearest("Team_Send", TOOLS), Some("team_send"));
        assert_eq!(nearest("INFO", TOOLS), Some("info"));
        assert_eq!(nearest("team_in", TOOLS), Some("team_inbox"));
    }

    #[test]
    fn nothing_close_keeps_the_bare_answer() {
        assert_eq!(unknown_tool("nope", TOOLS), "unknown tool: nope");
        assert_eq!(unknown_tool("", TOOLS), "unknown tool: ");
        assert_eq!(unknown_tool("xy", TOOLS), "unknown tool: xy");
        assert_eq!(unknown_tool("start_session", TOOLS), "unknown tool: start_session");
        assert_eq!(unknown_tool("anything", []), "unknown tool: anything");
        // A known name is never its own hint.
        assert_eq!(nearest("send", ["send"]), None);
    }

    #[test]
    fn a_tie_goes_to_the_first_in_list_order() {
        assert_eq!(nearest("bg_lst", ["bg_list", "bg_last"]), Some("bg_list"));
        assert_eq!(nearest("bg_lst", ["bg_last", "bg_list"]), Some("bg_last"));
        // The closest wins over an earlier, farther one.
        assert_eq!(nearest("bg_sto", ["bg_star", "bg_stop"]), Some("bg_stop"));
        assert_eq!(nearest("team", ["team_send", "team_inbox"]), Some("team_send"));
    }

    #[test]
    fn names_reads_a_tools_list() {
        let tools = json!([{"name": "announce"}, {"description": "no name"}, {"name": "ack"}]);
        assert_eq!(names(&tools).collect::<Vec<_>>(), ["announce", "ack"]);
        assert_eq!(names(&json!({})).count(), 0);
        assert_eq!(
            unknown_tool("anounce", names(&tools)),
            "unknown tool: anounce; did you mean announce?"
        );
    }

    #[test]
    fn distance_counts_a_swap_as_one_edit() {
        let d = |a: &str, b: &str| {
            distance(&a.chars().collect::<Vec<_>>(), &b.chars().collect::<Vec<_>>())
        };
        assert_eq!(d("kitten", "sitting"), 3);
        assert_eq!(d("ab", "ba"), 1);
        assert_eq!(d("", "abc"), 3);
        assert_eq!(d("same", "same"), 0);
    }
}
