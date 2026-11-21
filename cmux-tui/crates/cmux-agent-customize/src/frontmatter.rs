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
}

/// The frontmatter of `text`, or `None` when it has no `---` block or the block is not a YAML map.
pub fn parse(text: &str) -> Option<Frontmatter> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let body = text.strip_prefix("---\n").or_else(|| text.strip_prefix("---\r\n"))?;
    let end = body
        .match_indices("\n---")
        .map(|(at, _)| at)
        .find(|&at| matches!(body[at + 4..].chars().next(), None | Some('\n' | '\r' | ' ' | '\t')))
        .or_else(|| body.starts_with("---").then_some(0))?;
    let block = &body[..end];
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
    Some(Frontmatter {
        name: field("name"),
        description: field("description"),
        disable_model_invocation: field("disable-model-invocation").as_deref() == Some("true"),
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
