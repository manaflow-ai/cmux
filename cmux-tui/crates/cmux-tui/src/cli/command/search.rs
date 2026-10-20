//! `search <words>... [--scope chat,chief] [--limit <1..200>]` and
//! `search --stats`: the session daemon's search-everything index
//! (`search-v1`, plans/cmux-next/search-everything-DESIGN.md). Private
//! control commands (`search-query`, `search-stats`), so they work with the
//! app quit.

use serde_json::{Map, Value};

use super::{CommandPlan, Flags, UsageError, group_raw_plan};

const SCOPES: &[&str] = &["chat", "chief", "terminal", "scrollback", "file", "workspace", "page"];

pub(super) fn parse_search(words: &[&str], flags: &mut Flags) -> Result<CommandPlan, UsageError> {
    let mut request = Map::new();
    if flags.boolean("stats") {
        if !words.is_empty() {
            return Err(UsageError::new("search --stats takes no words"));
        }
        return Ok(group_raw_plan("search-stats", request));
    }
    let query = words.join(" ");
    let query = query.trim();
    if query.is_empty() {
        return Err(UsageError::new("search needs words: cmux search <words>..."));
    }
    if query.chars().count() > 200 {
        return Err(UsageError::new("search words must be at most 200 characters"));
    }
    request.insert("query".into(), Value::String(query.to_owned()));
    if let Some(scopes) = flags.take("scope") {
        let mut list = Vec::new();
        for scope in scopes.split(',').map(str::trim).filter(|scope| !scope.is_empty()) {
            if !SCOPES.contains(&scope) {
                return Err(UsageError::new(format!(
                    "unknown --scope {scope}; use {}",
                    SCOPES.join(", ")
                )));
            }
            list.push(Value::String(scope.to_owned()));
        }
        request.insert("scopes".into(), Value::Array(list));
    }
    if let Some(limit) = flags.take("limit") {
        let limit = limit
            .parse::<u32>()
            .ok()
            .filter(|limit| (1..=200).contains(limit))
            .ok_or_else(|| UsageError::new("--limit must be 1-200"))?;
        request.insert("limit".into(), Value::from(limit));
    }
    Ok(group_raw_plan("search-query", request))
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::super::{CommandPlan, parse};
    use crate::cli::Surface;

    fn request(args: &[&str], surface: Surface) -> Option<Value> {
        let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
        match parse(&args, surface) {
            Ok(CommandPlan::RawCommand(plan)) => Some(plan.request),
            _ => None,
        }
    }

    #[test]
    fn search_everything_cli_parses_words_scopes_limit_and_stats() {
        for surface in [Surface::Cmux, Surface::CmuxTui] {
            let query = request(
                &["search", "cargo", "test", "--scope", "chat,chief", "--limit", "5"],
                surface,
            );
            assert_eq!(
                query,
                Some(json!({"id": 1, "cmd": "search-query", "query": "cargo test",
                    "scopes": ["chat", "chief"], "limit": 5}))
            );
            let stats = request(&["search", "--stats"], surface);
            assert_eq!(stats, Some(json!({"id": 1, "cmd": "search-stats"})));
        }
        let plain = request(&["search", "migration"], Surface::Cmux);
        assert_eq!(plain, Some(json!({"id": 1, "cmd": "search-query", "query": "migration"})));
        assert_eq!(request(&["search"], Surface::Cmux), None);
        assert_eq!(request(&["search", "x", "--scope", "mail"], Surface::Cmux), None);
        assert_eq!(request(&["search", "x", "--limit", "0"], Surface::Cmux), None);
    }
}
