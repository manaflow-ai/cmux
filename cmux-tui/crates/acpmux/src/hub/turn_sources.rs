//! Sources actually read during this turn, recorded once beside its final reply.
//!
//! Tool starts and successful completions supply provenance; answer text, search results,
//! shell commands and tool output are never mined for guessed citations. The bounds apply
//! to retained calls and strings, independently of transcript length and output volume.

use super::*;
use std::collections::VecDeque;

const MAX_SOURCES: usize = 64;
const MAX_PENDING: usize = 32;
const MAX_FINISHED: usize = 128;
const MAX_ID: usize = 256;
const MAX_URI: usize = 4096;
const MAX_TITLE: usize = 256;

#[derive(Clone, Debug)]
struct Source {
    kind: String,
    uri: String,
    title: String,
    tool_call_id: String,
    revision: Option<String>,
    backlink: Option<String>,
}

impl Source {
    fn json(&self) -> Value {
        let mut value = json!({
            "kind": self.kind, "uri": self.uri, "title": self.title,
            "toolCallId": self.tool_call_id,
        });
        if let Some(revision) = &self.revision {
            value["revision"] = json!(revision);
        }
        if let Some(backlink) = &self.backlink {
            value["backlink"] = json!(backlink);
        }
        value
    }
}

#[derive(Debug, Default)]
pub(super) struct TurnSources {
    pending: VecDeque<Source>,
    sources: VecDeque<Source>,
    finished: VecDeque<String>,
}

impl TurnSources {
    pub(super) fn reset(&mut self) {
        self.pending.clear();
        self.sources.clear();
        self.finished.clear();
    }

    pub(super) fn observe(&mut self, update: &Value) {
        if !matches!(update["sessionUpdate"].as_str(), Some("tool_call" | "tool_call_update")) {
            return;
        }
        let Some(id) = bounded(&update["toolCallId"], MAX_ID) else { return };
        if self.finished.iter().any(|done| done == id) {
            return;
        }
        let terminal =
            matches!(update["status"].as_str(), Some("completed" | "failed")) || failed(update);
        let source = source(update, id);
        if !terminal {
            if let Some(source) = source {
                self.pending.retain(|pending| pending.tool_call_id != id);
                if self.pending.len() == MAX_PENDING {
                    self.pending.pop_front();
                }
                self.pending.push_back(source);
            }
            return;
        }
        let started = self
            .pending
            .iter()
            .position(|s| s.tool_call_id == id)
            .and_then(|at| self.pending.remove(at));
        if self.finished.len() == MAX_FINISHED {
            self.finished.pop_front();
        }
        self.finished.push_back(id.to_owned());
        if update["status"] != "completed" || failed(update) {
            return;
        }
        let Some(mut source) = source.or(started) else { return };
        // A completion may carry a revision unavailable when the read started. This does
        // not invent a backlink: a wiki service must index the recorded source-use edge.
        enrich(&mut source, update);
        if self.sources.iter().any(|s| s.uri == source.uri && s.revision == source.revision) {
            return;
        }
        if self.sources.len() == MAX_SOURCES {
            self.sources.pop_front();
        }
        self.sources.push_back(source);
    }
}

impl Hub {
    pub(super) fn note_turn_source(&self, session: &Session, update: &Value) {
        session.turn_sources.lock().unwrap_or_else(|e| e.into_inner()).observe(update);
    }

    pub(super) fn reset_turn_sources(&self, session: &Session) {
        session.turn_sources.lock().unwrap_or_else(|e| e.into_inner()).reset();
    }

    /// Bind to the exact final reply row, never the last row of an unrelated turn.
    pub(super) fn append_turn_sources(&self, session: &Session, turn_id: &str) {
        let reply_id = {
            let stream = session.stream.lock().unwrap_or_else(|e| e.into_inner());
            if stream.segment_turn.as_deref() != Some(turn_id) || stream.trailing_text.is_empty() {
                return;
            }
            let Some(reply_id) = stream.reply_segment.clone() else { return };
            reply_id
        };
        let sources: Vec<Value> = {
            let state = session.turn_sources.lock().unwrap_or_else(|e| e.into_inner());
            state.sources.iter().map(Source::json).collect()
        };
        if !sources.is_empty() {
            self.append(
                session,
                "mux",
                "turn_sources",
                json!({
                    "turnId": turn_id, "replyId": reply_id, "sources": sources,
                }),
            );
        }
    }
}

fn bounded(value: &Value, limit: usize) -> Option<&str> {
    value.as_str().filter(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
}

fn source(update: &Value, id: &str) -> Option<Source> {
    // ACP kind=read also includes Glob/Grep, and fetch includes WebSearch. Only a known
    // concrete read/fetch input establishes a source; kind/title alone establish none.
    let (kind, uri, title) = match update.pointer("/_meta/claude/tool")?.as_str()? {
        "Read" => {
            let path = bounded(&update["rawInput"]["file_path"], MAX_URI)?;
            // Relative paths are ambiguous across remote hosts. The adapter's absolute
            // path is retained without local filesystem canonicalization or symlink IO.
            if !path.starts_with('/') {
                return None;
            }
            ("file", file_uri(path), path.to_owned())
        }
        "WebFetch" => {
            let uri = bounded(&update["rawInput"]["url"], MAX_URI)?;
            if !(uri.starts_with("https://") || uri.starts_with("http://")) {
                return None;
            }
            ("web", uri.to_owned(), uri.to_owned())
        }
        _ => return None,
    };
    if uri.len() > MAX_URI {
        return None;
    }
    let mut source = Source {
        kind: kind.to_owned(),
        uri,
        title: short_title(&title),
        tool_call_id: id.to_owned(),
        revision: None,
        backlink: None,
    };
    enrich(&mut source, update);
    Some(source)
}

/// Explicit structured metadata can classify a known read as wiki/RFD. It cannot replace
/// its observed target with an arbitrary link or make a search/edit count as a read.
fn enrich(source: &mut Source, update: &Value) {
    let Some(meta) = update.pointer("/_meta/acpmux/source") else { return };
    if meta.get("uri").is_some_and(|uri| uri.as_str() != Some(source.uri.as_str())) {
        return;
    }
    if let Some(kind @ ("wiki" | "rfd")) = meta["kind"].as_str() {
        source.kind = kind.to_owned();
    }
    if let Some(title) = bounded(&meta["title"], MAX_TITLE) {
        source.title = title.to_owned();
    }
    if let Some(revision) = bounded(&meta["revision"], MAX_ID) {
        source.revision = Some(revision.to_owned());
    }
    if let Some(backlink) = bounded(&meta["backlink"], MAX_URI)
        .filter(|uri| uri.starts_with("https://") || uri.starts_with("http://"))
    {
        source.backlink = Some(backlink.to_owned());
    }
}

fn short_title(value: &str) -> String {
    let mut end = value.len().min(MAX_TITLE);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn file_uri(path: &str) -> String {
    let mut out = String::from("file://");
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
            out.push(char::from(byte));
        } else {
            out.push('%');
            out.push(char::from(HEX[(byte >> 4) as usize]));
            out.push(char::from(HEX[(byte & 15) as usize]));
        }
    }
    out
}

fn failed(update: &Value) -> bool {
    ["/isError", "/is_error", "/rawOutput/isError", "/rawOutput/is_error"]
        .iter()
        .any(|at| update.pointer(at).and_then(Value::as_bool) == Some(true))
        || ["/rawOutput/exit_code", "/rawOutput/exitCode", "/exitCode"]
            .iter()
            .filter_map(|at| update.pointer(at).and_then(Value::as_i64))
            .any(|code| code != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(id: &str, path: &str) -> Value {
        json!({"sessionUpdate":"tool_call", "toolCallId":id, "status":"in_progress",
            "_meta":{"claude":{"tool":"Read"}}, "rawInput":{"file_path":path}})
    }

    fn done(id: &str) -> Value {
        json!({"sessionUpdate":"tool_call_update", "toolCallId":id, "status":"completed"})
    }

    #[test]
    fn turn_sources_require_success_and_preserve_exact_target() {
        let mut state = TurnSources::default();
        state.observe(&read("r", "/docs/a #é.md"));
        assert!(state.sources.is_empty());
        state.observe(&done("r"));
        assert_eq!(state.sources[0].uri, "file:///docs/a%20%23%C3%A9.md");
        assert_eq!(state.sources[0].tool_call_id, "r");
        state.observe(&done("r"));
        assert_eq!(state.sources.len(), 1);
        state.reset();
        state.observe(&done("r"));
        assert!(state.sources.is_empty());
    }

    #[test]
    fn turn_sources_ignore_failed_search_edit_and_shell_calls() {
        let mut state = TurnSources::default();
        for tool in ["Grep", "Glob", "WebSearch", "Edit", "Bash"] {
            let mut update = read(tool, "/docs/readme.md");
            update["_meta"]["claude"]["tool"] = json!(tool);
            update["status"] = json!("completed");
            state.observe(&update);
        }
        for (id, field) in [("a", "isError"), ("b", "is_error")] {
            state.observe(&read(id, "/docs/readme.md"));
            let mut update = done(id);
            update["rawOutput"] = json!({field:true});
            state.observe(&update);
        }
        state.observe(&read("fail", "/docs/readme.md"));
        let mut failed = done("fail");
        failed["status"] = json!("failed");
        state.observe(&failed);
        assert!(state.sources.is_empty());
    }

    #[test]
    fn turn_sources_web_and_explicit_wiki_revision() {
        let mut state = TurnSources::default();
        state.observe(&json!({"sessionUpdate":"tool_call", "toolCallId":"web", "status":"completed",
            "_meta":{"claude":{"tool":"WebFetch"}, "acpmux":{"source":{
                "kind":"wiki", "uri":"https://wiki.example/page", "title":"Design", "revision":"abc"}}},
            "rawInput":{"url":"https://wiki.example/page"}}));
        assert_eq!(
            state.sources[0].json(),
            json!({"kind":"wiki", "uri":"https://wiki.example/page",
            "title":"Design", "revision":"abc", "toolCallId":"web"})
        );
        let mut update = read("rfd", "/docs/rfd.md");
        update["_meta"]["acpmux"] = json!({"source":{"kind":"rfd", "uri":"https://other.example",
            "backlink":"https://other.example/backlinks"}});
        update["status"] = json!("completed");
        state.observe(&update);
        assert_eq!(state.sources[1].kind, "file");
        assert_eq!(state.sources[1].uri, "file:///docs/rfd.md");
        assert!(state.sources[1].backlink.is_none());
    }

    #[test]
    fn turn_sources_storage_is_bounded_and_deduplicates_targets() {
        let mut state = TurnSources::default();
        for n in 0..200 {
            let id = format!("call{n}");
            state.observe(&read(&id, &format!("/docs/{n}.md")));
        }
        assert_eq!(state.pending.len(), MAX_PENDING);
        for n in 0..200 {
            let id = format!("done{n}");
            let mut update = read(&id, &format!("/docs/{n}.md"));
            update["status"] = json!("completed");
            state.observe(&update);
        }
        assert_eq!(state.sources.len(), MAX_SOURCES);
        assert_eq!(state.finished.len(), MAX_FINISHED);
        state.observe(&read("same", "/docs/199.md"));
        state.observe(&done("same"));
        assert_eq!(state.sources.len(), MAX_SOURCES);
        assert_eq!(state.sources.iter().filter(|s| s.uri == "file:///docs/199.md").count(), 1);
    }

    #[test]
    fn turn_sources_reject_ambiguous_and_unsafe_targets() {
        let mut state = TurnSources::default();
        for (id, path) in [("relative", "docs/page.md"), ("control", "/docs/a\n.md")] {
            let mut update = read(id, path);
            update["status"] = json!("completed");
            state.observe(&update);
        }
        state.observe(
            &json!({"sessionUpdate":"tool_call", "toolCallId":"unsafe", "status":"completed",
            "_meta":{"claude":{"tool":"WebFetch"}}, "rawInput":{"url":"javascript:alert(1)"}}),
        );
        assert!(state.sources.is_empty());
    }

    #[test]
    fn turn_sources_completion_metadata_and_failed_updates() {
        let mut state = TurnSources::default();
        state.observe(&read("wiki", "/wiki/design.md"));
        let mut completed = done("wiki");
        completed["_meta"] = json!({"acpmux":{"source":{
            "uri":"file:///wiki/design.md", "kind":"wiki", "revision":"v2",
            "backlink":"https://wiki.example/design/backlinks"}}});
        state.observe(&completed);
        assert_eq!(state.sources[0].kind, "wiki");
        assert_eq!(state.sources[0].revision.as_deref(), Some("v2"));
        assert_eq!(
            state.sources[0].backlink.as_deref(),
            Some("https://wiki.example/design/backlinks")
        );

        state.observe(&read("failed-early", "/wiki/failed.md"));
        state.observe(&json!({"sessionUpdate":"tool_call_update", "toolCallId":"failed-early",
            "rawOutput":{"isError":true}}));
        state.observe(&done("failed-early"));
        assert_eq!(state.sources.len(), 1);
    }
}
