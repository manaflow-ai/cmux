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
    if name_trimmed.len() > MAX_NAME_BYTES || name_trimmed.chars().count() > MAX_NAME {
        return None;
    }
    let wanted: Vec<char> = name_trimmed.to_lowercase().chars().collect();
    if wanted.is_empty() {
        return None;
    }
    let limit = if wanted.len() <= 3 { 1 } else { wanted.len().checked_div(3).unwrap_or(0).max(2) };
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
/// [`MAX_NAME`] characters of at most 4 bytes each.
const MAX_NAME_BYTES: usize = MAX_NAME * 4;

/// Optimal string alignment distance: insertions, deletions, substitutions and swaps of two
/// neighbouring characters. Three rows of the table, read with `get` and added with saturating
/// arithmetic, so no input can make it panic.
fn distance(a: &[char], b: &[char]) -> usize {
    let width = b.len().saturating_add(1);
    // The rows two above, one above, and this one; the first row is the distance from "".
    let mut above2 = vec![0; width];
    let mut above: Vec<usize> = (0..width).collect();
    let mut row = vec![0; width];
    for (i, &ac) in a.iter().enumerate() {
        if let Some(first) = row.first_mut() {
            *first = i.saturating_add(1);
        }
        for (j, &bc) in b.iter().enumerate() {
            let at = |cells: &[usize], k: usize| cells.get(k).copied().unwrap_or(usize::MAX);
            let cost = usize::from(ac != bc);
            let mut best = at(&above, j.saturating_add(1))
                .saturating_add(1)
                .min(at(&row, j).saturating_add(1))
                .min(at(&above, j).saturating_add(cost));
            // A swap of two neighbouring characters (`ab` for `ba`) is one edit.
            if let (Some(pi), Some(pj)) = (i.checked_sub(1), j.checked_sub(1))
                && a.get(pi) == Some(&bc)
                && b.get(pj) == Some(&ac)
            {
                best = best.min(at(&above2, pj).saturating_add(1));
            }
            if let Some(cell) = row.get_mut(j.saturating_add(1)) {
                *cell = best;
            }
        }
        std::mem::swap(&mut above2, &mut above);
        std::mem::swap(&mut above, &mut row);
    }
    above.last().copied().unwrap_or(0)
}

#[cfg(test)]
mod tests;
