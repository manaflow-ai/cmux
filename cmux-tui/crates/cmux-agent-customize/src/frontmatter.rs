//! The YAML frontmatter of a SKILL.md or a slash command file: the `---` block at the top.
//!
//! Both CLIs read it as YAML, so a `description: >-` block scalar, a quoted value or a value
//! continued on the next lines all count (48 of the 88 skills on Leo's Mac use a block scalar,
//! which a one-line reader turns into the text `>-`).

use yaml_rust::{Yaml, YamlLoader};

/// The string fields of one frontmatter block that cmux shows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Frontmatter {
    pub name: Option<String>,
    pub description: Option<String>,
    /// Claude Code: `disable-model-invocation: true` keeps the skill out of the model's list.
    pub disable_model_invocation: bool,
    /// A Claude Code subagent's `model` (`sonnet`, `opus`, `inherit`, a full id).
    pub model: Option<String>,
    /// A Claude Code subagent's `color`.
    pub color: Option<String>,
    /// A Claude Code subagent's `tools`: a comma-separated string or a YAML list; empty is every tool.
    pub tools: Vec<String>,
}

/// `text`'s `---` block (without its fences) and what follows its closing line, or `None` when it
/// has none.
fn split(text: &str) -> Option<(&str, &str)> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let body = text.strip_prefix("---\n").or_else(|| text.strip_prefix("---\r\n"))?;
    let end = body
        .match_indices("\n---")
        .map(|(at, _)| at)
        .find(|&at| {
            matches!(
                body.get(at + 4..).unwrap_or_default().chars().next(),
                None | Some('\n' | '\r' | ' ' | '\t')
            )
        })
        .or_else(|| body.starts_with("---").then_some(0))?;
    let close = if end == 0 && body.starts_with("---") { 3 } else { end + 4 };
    let rest = body.get(close.min(body.len())..).unwrap_or_default();
    let rest = rest.split_once('\n').map_or("", |(_, after)| after);
    Some((body.get(..end)?, rest))
}

/// What follows the frontmatter of `text` (the prompt of a slash command file); all of `text`
/// when it has no `---` block.
pub fn body(text: &str) -> &str {
    split(text).map_or(text, |(_, rest)| rest)
}

/// The frontmatter of `text`, or `None` when it has no `---` block or the block is not a YAML map.
pub fn parse(text: &str) -> Option<Frontmatter> {
    let (block, _) = split(text)?;
    let docs = YamlLoader::load_from_str(block).ok()?;
    let map = match docs.into_iter().next() {
        Some(Yaml::Hash(map)) => map,
        // An empty block is a map with nothing in it.
        None | Some(Yaml::Null) => Default::default(),
        Some(_) => return None,
    };
    let field = |key: &str| {
        map.get(&Yaml::String(key.to_owned()))
            .and_then(|value| match value {
                Yaml::String(text) => Some(text.trim().to_owned()),
                Yaml::Integer(n) => Some(n.to_string()),
                Yaml::Real(text) => Some(text.clone()),
                Yaml::Boolean(b) => Some(b.to_string()),
                _ => None,
            })
            .filter(|text| !text.is_empty())
    };
    let tools = match map.get(&Yaml::String("tools".to_owned())) {
        Some(Yaml::Array(items)) => items
            .iter()
            .filter_map(|item| item.as_str().map(|t| t.trim().to_owned()))
            .filter(|t| !t.is_empty())
            .collect(),
        _ => field("tools")
            .map(|text| {
                text.split(',')
                    .map(str::trim)
                    .filter(|t| !t.is_empty())
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default(),
    };
    Some(Frontmatter {
        name: field("name"),
        description: field("description"),
        disable_model_invocation: field("disable-model-invocation").as_deref() == Some("true"),
        model: field("model"),
        color: field("color"),
        tools,
    })
}

/// `name` and `description`, both present: the one rule cmux's own skills folder keeps.
pub fn name_and_description(text: &str) -> Option<(String, String)> {
    let front = parse(text)?;
    Some((front.name?, front.description?))
}

#[cfg(test)]
#[path = "frontmatter_tests.rs"]
mod tests;
