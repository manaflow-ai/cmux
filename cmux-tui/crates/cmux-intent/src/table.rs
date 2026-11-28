//! The alias table: the one `intent_aliases.json` format of tools/intent.py, embedded here and
//! optionally replaced by the file `$INTENT_TABLE` names (the Python layer reads the same variable).

use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::OnceLock;

const EMBEDDED: &str = include_str!("../intent_aliases.json");

/// One multi-word alias of a CLI: `from` typed under the subcommand path `under` runs as `to`.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Alias {
    #[serde(default)]
    pub under: Vec<String>,
    #[serde(default)]
    pub from: Vec<String>,
    #[serde(default)]
    pub to: Vec<String>,
}

/// The table's part for one CLI.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct CliEntry {
    #[serde(default)]
    pub aliases: Vec<Alias>,
    /// The verb a missing one is: a word, or `{"path words": "verb"}`.
    #[serde(default)]
    pub default: Option<Value>,
    /// Subcommand paths (`"session stop"`) whose exact form is needed.
    #[serde(default)]
    pub exact: Vec<String>,
    /// Subcommand words never read as unsafe in this CLI.
    #[serde(default)]
    pub safe: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Table {
    #[serde(default)]
    pub synonyms: Vec<Vec<String>>,
    #[serde(default)]
    pub flag_synonyms: Vec<Vec<String>>,
    #[serde(default, rename = "unsafe")]
    pub unsafe_words: Vec<String>,
    #[serde(default)]
    pub reads: Vec<String>,
    #[serde(default)]
    pub cli: HashMap<String, CliEntry>,
}

impl Table {
    /// The table in `json`; an unreadable one is an empty table (the layer never costs a CLI its refusal).
    pub fn parse(json: &str) -> Self {
        serde_json::from_str(json).unwrap_or_default()
    }

    /// The embedded table, or the file `$INTENT_TABLE` names, read once per process.
    pub fn load() -> &'static Table {
        static TABLE: OnceLock<Table> = OnceLock::new();
        TABLE.get_or_init(|| {
            let from_env = std::env::var_os("INTENT_TABLE")
                .filter(|p| !p.is_empty())
                .and_then(|p| std::fs::read_to_string(p).ok());
            Table::parse(from_env.as_deref().unwrap_or(EMBEDDED))
        })
    }

    /// The embedded table alone (tests that must not see `$INTENT_TABLE`).
    pub fn embedded() -> Table {
        Table::parse(EMBEDDED)
    }

    pub fn cli_entry(&self, prog: &str) -> Option<&CliEntry> {
        self.cli.get(prog)
    }

    /// The other members of every synonym group of `kind` (`synonyms` or `flag_synonyms`) holding `word`.
    pub fn mates(&self, word: &str, flags: bool) -> Vec<&str> {
        let groups = if flags { &self.flag_synonyms } else { &self.synonyms };
        groups
            .iter()
            .filter(|g| g.iter().any(|m| m == word))
            .flat_map(|g| g.iter().map(String::as_str).filter(move |m| *m != word))
            .collect()
    }

    /// Whether the subcommand path `path` of `prog` (or a prefix of it) is listed under the CLI's `exact`.
    pub fn exact_path(&self, prog: &str, path: &[String]) -> bool {
        let Some(entry) = self.cli_entry(prog) else { return false };
        (1..=path.len()).any(|n| path.get(..n).is_some_and(|p| entry.exact.contains(&p.join(" "))))
    }

    /// Whether `tok` (a subcommand or flag) is a destructive or outward word: any of its `-`/`_`
    /// parts is in the unsafe list.
    pub fn unsafe_word(&self, tok: &str) -> bool {
        let name = tok.split('=').next().unwrap_or(tok).trim_start_matches('-').to_lowercase();
        let hit = |w: &str| self.unsafe_words.iter().any(|u| u == w);
        !name.is_empty() && (hit(&name) || name.replace('_', "-").split('-').any(hit))
    }
}

/// `INTENT_OFF=1` (any non-empty value but `0`) turns the layer off.
pub fn off() -> bool {
    std::env::var("INTENT_OFF").is_ok_and(|v| !v.is_empty() && v != "0")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_embedded_table_reads() {
        let t = Table::embedded();
        assert!(
            t.synonyms.len() > 5 && t.unsafe_word("--dry-run-push") && !t.unsafe_word("status")
        );
        assert!(t.mates("show", false).contains(&"get"));
        assert!(t.unsafe_word("--rm") && t.unsafe_word("--Force") && !t.unsafe_word("--dry-run"));
    }
}
