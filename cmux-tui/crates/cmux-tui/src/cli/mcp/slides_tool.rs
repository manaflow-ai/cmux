//! `slides`: a deck the agent writes as Markdown, shown beside the chat as slides, and
//! updated in place as the agent rewrites it.
//!
//! One call writes the deck (`markdown`, optional: a deck already on disk is shown as it
//! is) and opens it through `open` as a Markdown deck (`md_deck`, served by `pptx_view`),
//! whatever its file is named. A later call for a deck this server already shows only
//! writes the file: the open tab's watch reloads it, so the person keeps their place.
//! The page has the slide strip, Present (full screen where the page may go full screen, else its pane) and Export PDF / .pptx.

use serde_json::{Map, Value, json};

use super::{Backend, Server, envelope, md_deck, pptx_view, tool_error, v2_tools};

pub(super) const NAME: &str = "slides";
/// The largest deck the tool writes, in UTF-8 bytes.
const MAX_MARKDOWN_BYTES: usize = 1 << 20;

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Make or update a slide deck",
        "description": "Write a slide deck as Markdown and show it beside the chat as slides: a slide strip, Present (F, Esc exits), Export PDF (one slide per page) and Export .pptx (editable text). path: the deck's .md file (absolute, or relative to this chat's folder), for example slides/topic.slides.md. markdown: the whole deck; it replaces the file (leave it out to show a deck already on disk). Format: optional front matter with title:, then slides separated by a line of ---. A slide with only headings is a title slide; <!-- _class: center --> centers a quote or one number; any other <!-- comment --> (or a Notes: line) is speaker notes. Raw HTML works: <div class=\"cols\"><div>left</div><div>right</div></div> for two columns, inline <svg> for a chart (currentColor follows the theme), <img src=\"picture.png\"> for a picture in the deck's folder. A slide is 1280 x 720: one idea, about 40 words, 3 to 5 bullets. Call again with the same path to change the deck: the open tab updates in place. open: true opens another tab (after the person closed it).",
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "required": ["path"],
            "properties": {
                "path": {"type": "string", "minLength": 1, "description": "The deck's Markdown file: absolute, or relative to this chat's folder. Folders are made as needed."},
                "markdown": {"type": "string", "description": "The whole deck, at most 1 MiB. Replaces the file."},
                "where": {"type": "string", "enum": ["right", "left", "below", "above", "here", "sticky", "pane", "workspace"], "description": "Where a new tab opens, as in open. Default right."},
                "pane": {"type": "string", "description": "As in open."},
                "workspace": {"type": "string", "description": "As in open."},
                "edge": {"type": "string", "enum": ["right", "left", "top", "bottom"], "description": "As in open."},
                "focus": {"type": "boolean", "description": "A new deck tab is shown and takes the person's view, since showing it is what they asked for; false opens it behind the tab its pane shows. An update in place never moves their view. Default true."},
                "open": {"type": "boolean", "description": "Open a tab even when this deck is already shown. Default: open only when it is not."}
            }
        },
        "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
    })
}

fn invalid(message: impl Into<String>) -> Value {
    tool_error(envelope(v2_tools::invalid(message), "not_run", None))
}

impl<B: Backend> Server<B> {
    pub(super) fn call_slides(&self, arguments: &Map<String, Value>) -> Value {
        let known = ["path", "markdown", "where", "pane", "workspace", "edge", "focus", "open"];
        if let Some(name) = arguments.keys().find(|name| !known.contains(&name.as_str())) {
            return invalid(format!("slides has no argument {name:?}"));
        }
        let Some(path) =
            arguments.get("path").and_then(Value::as_str).filter(|path| !path.is_empty())
        else {
            return invalid("slides needs path: the deck's .md file");
        };
        let lower = path.to_ascii_lowercase();
        if !(lower.ends_with(".md") || lower.ends_with(".markdown")) {
            return invalid("slides path must be a Markdown file (.md)");
        }
        let reopen = match arguments.get("open") {
            None => false,
            Some(Value::Bool(open)) => *open,
            Some(_) => return invalid("slides open must be true or false"),
        };
        // A new deck tab is shown: opened behind a pane's terminal, the person asked for a deck
        // and saw none.
        let focus = match arguments.get("focus") {
            None => true,
            Some(Value::Bool(focus)) => *focus,
            Some(_) => return invalid("slides focus must be true or false"),
        };
        let path = self.chat_path(path);
        let file = std::path::Path::new(&path);
        // What the file held before this call writes it, so a deck that then fails to open
        // is put back: the person never saw the replacement. `None`: there was no file.
        let mut previous: Option<Option<Vec<u8>>> = None;
        match arguments.get("markdown") {
            None => {
                if !file.is_file() {
                    return invalid(format!(
                        "slides: there is no deck at {path}; pass markdown to write one"
                    ));
                }
            }
            Some(Value::String(markdown)) => {
                if markdown.len() > MAX_MARKDOWN_BYTES {
                    return invalid("slides markdown is larger than 1 MiB");
                }
                if let Some(folder) = file.parent()
                    && let Err(error) = std::fs::create_dir_all(folder)
                {
                    return invalid(format!("slides cannot make {}: {error}", folder.display()));
                }
                previous = Some(std::fs::read(file).ok());
                // Through a temporary file, so the open tab never reloads a half-written deck.
                let temporary = file.with_extension("md.cmux-slides-tmp");
                if let Err(error) = std::fs::write(&temporary, markdown)
                    .and_then(|()| std::fs::rename(&temporary, file))
                {
                    let _ = std::fs::remove_file(&temporary);
                    return invalid(format!("slides cannot write {path}: {error}"));
                }
            }
            Some(_) => return invalid("slides markdown must be text"),
        }
        let source = std::fs::read_to_string(file).unwrap_or_default();
        let count = md_deck::slide_count(&source);
        let shown = self.live_files.borrow().as_ref().and_then(|live| live.browser_for(file));
        if let (Some(browser), false) = (&shown, reopen) {
            return super::success(
                json!({
                    "path": path,
                    "slides": count,
                    "shown": "updated in place",
                    "live_browser": browser,
                }),
                true,
            );
        }
        let mut open = Map::new();
        open.insert("kind".into(), json!("file"));
        open.insert("path".into(), json!(path));
        open.insert("live".into(), json!(true));
        for key in ["where", "pane", "workspace", "edge"] {
            if let Some(value) = arguments.get(key) {
                open.insert(key.into(), value.clone());
            }
        }
        open.insert("focus".into(), json!(focus));
        let mut answer = self.open_as(&open, Some(pptx_view::Kind::Markdown));
        let opened = answer.get("isError").and_then(Value::as_bool) != Some(true);
        if !opened && let Some(before) = previous {
            // The open failed: the deck is as it was before this call.
            let _ = match before {
                Some(bytes) => std::fs::write(file, bytes),
                None => std::fs::remove_file(file),
            };
        }
        if let Some(receipt) = answer.get_mut("structuredContent").and_then(Value::as_object_mut)
            && opened
        {
            receipt.insert("path".into(), json!(path));
            receipt.insert("slides".into(), json!(count));
            receipt.insert(
                "next".into(),
                json!("Tell the person the deck is open beside the chat: Present (F) shows one slide at a time, Export PDF and Export .pptx are in its bar. Call slides again with the same path to change it."),
            );
        }
        answer
    }
}
