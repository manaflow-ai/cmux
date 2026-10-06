//! `optchat-chief memory ...`: the memory database from the command line.
//! Export, search and stats open a read-only connection, so they work while
//! the host runs; import needs the host stopped (it takes the chat's lock).

use std::path::{Path, PathBuf};

use optchat_host::db::{Hit, MIGRATION_KEY, ReadOnly, SCHEMA_VERSION};

use crate::cli::Flags;
use crate::paths::Paths;

pub const USAGE: &str = "optchat-chief memory export --text DIR [--mux-home DIR]   the memory as JSONL day files (main/, tree/; the old store's format)
optchat-chief memory import [--mux-home DIR] DIR          an old JSONL home or an export into an empty memory (host stopped)
optchat-chief memory search [--mux-home DIR] [--limit N] QUERY  full-text search: messages and summaries holding every word
optchat-chief memory stats [--mux-home DIR]               counts, schema version, migration record, file size";

/// Runs `memory <verb>`; returns what to print.
pub fn run(flags: &Flags, home: &Path) -> Result<String, String> {
    let paths = Paths::new(home);
    let words: Vec<&str> = flags.words.iter().skip(2).map(String::as_str).collect();
    match flags.words.get(1).map(String::as_str) {
        Some("export") => {
            let dir = flags
                .value("text")
                .map(PathBuf::from)
                .ok_or_else(|| format!("memory export needs --text DIR\n{USAGE}"))?;
            let stats = read_only(&paths)?
                .export_text(&dir)
                .map_err(|e| format!("exporting into {}: {e}", dir.display()))?;
            Ok(format!(
                "exported {} messages and {} nodes into {} ({} day files written)",
                stats.messages,
                stats.nodes,
                dir.display(),
                stats.files_written
            ))
        }
        Some("import") => {
            let [from] = words.as_slice() else {
                return Err(format!("memory import needs one directory\n{USAGE}"));
            };
            let chat = crate::browse::open_offline(&paths.chat, &paths.memory_db)?;
            let result = chat.import_jsonl(Path::new(from));
            chat.shutdown();
            let imported = result.map_err(|e| format!("importing {from}: {e}"))?;
            Ok(format!(
                "imported {} messages and {} nodes (hash {}, {} lines skipped)",
                imported.messages, imported.nodes, imported.hash, imported.skipped
            ))
        }
        Some("search") => {
            if words.is_empty() {
                return Err(format!("memory search needs a query\n{USAGE}"));
            }
            let limit = flags
                .value("limit")
                .map(|v| v.parse::<usize>().map_err(|e| format!("--limit {v}: {e}")))
                .transpose()?
                .unwrap_or(20);
            let hits = read_only(&paths)?
                .search(&words.join(" "), limit)
                .map_err(|e| format!("searching: {e}"))?;
            Ok(hits
                .iter()
                .map(|h| match h {
                    Hit::Message { id, kind, snippet } => format!("{id} {kind}: {snippet}"),
                    Hit::Node { node, snippet } => format!("{} (summary): {snippet}", node.name()),
                })
                .collect::<Vec<_>>()
                .join("\n"))
        }
        Some("stats") => {
            let db = read_only(&paths)?;
            let counts = db.counts().map_err(|e| e.to_string())?;
            let migration = db
                .state(MIGRATION_KEY)
                .map_err(|e| e.to_string())?
                .unwrap_or_else(|| "none".to_owned());
            let bytes = std::fs::metadata(&paths.memory_db).map_or(0, |m| m.len());
            Ok(format!(
                "{}: {} messages, {} nodes, schema {SCHEMA_VERSION}, {bytes} bytes\nmigration: {migration}",
                paths.memory_db.display(),
                counts.messages,
                counts.nodes
            ))
        }
        _ => Err(USAGE.to_owned()),
    }
}

fn read_only(paths: &Paths) -> Result<ReadOnly, String> {
    ReadOnly::open(&paths.memory_db).map_err(|e| format!("{}: {e}", paths.memory_db.display()))
}
