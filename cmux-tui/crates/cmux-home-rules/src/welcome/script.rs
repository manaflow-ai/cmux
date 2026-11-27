//! The Chief's welcome (`ChiefWelcome`, `ChiefWelcome+Shortcuts`, the steps `ChiefWelcomePlayer` runs).
//!
//! Three messages land one after another, each after a short quiet and a typing indicator sized to its
//! text. Swift localizes the strings and passes them in; English is the default.

use super::text::{format, grapheme_count, iso8601_millis};
use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const HELLO_CLIENT_ID: &str = "chief-welcome-hello-v2";
pub const ABOUT_CLIENT_ID: &str = "chief-welcome-about-v2";
pub const BACKGROUND_CLIENT_ID: &str = "chief-welcome-background-v1";
pub const BACKGROUND_LINK: &str = "cmux://settings/background";
pub const ANY_APP_LINK: &str = "cmux://settings/start-agent-from-any-app";
pub const ANY_APP_ACTION: &str = "palette.startAgentFromAnyApp";
pub const LEAD_IN_MS: u64 = 600;
pub const DEFAULT_AUTHOR: &str = "agent_mux";

pub const HELLO_TEXT: &str = "Welcome to cmux! 👋 I'm Chief.";
pub const ABOUT_TEXT: &str = "I can make new workspaces, start agents for you, and set up or customize cmux however you like.\nJust tell me what you want done.";
pub const BACKGROUND_FORMAT: &str = "Want to make it yours? [Pick a background](%@) from the built-in art or one of your own pictures. Or skip it and just say hi.";
pub const CHORD_FORMAT: &str = "`%1$@` then `%2$@`";
pub const ANY_APP_FORMAT: &str = "%1$@ %2$@ (off until you [turn it on](%3$@))";
pub const SHORTCUTS_HEADING: &str = "More shortcuts:";

/// The actions whose shortcuts the about message lists, in order.
pub const SHORTCUT_ACTIONS: &[&str] = &[
    "newTab",
    "newTab.default",
    "splitRight",
    "splitDown",
    "focusLocation",
    "openBrowser",
    "goToWorkspace",
    "commandPalette",
];

/// `ChiefWelcome.typingTime(for:)` in milliseconds.
pub fn typing_time(text: &str) -> u64 {
    (1000 + 4 * grapheme_count(text) as u64).clamp(1200, 2000)
}

/// `ChiefWelcome.readingPause(after:)` in milliseconds.
pub fn reading_pause(text: &str) -> u64 {
    (400 + 3 * grapheme_count(text) as u64).clamp(600, 1000)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Beat {
    #[serde(rename = "clientID", alias = "clientId")]
    pub client_id: String,
    pub text: String,
    #[serde(default)]
    pub quiet_ms: u64,
    #[serde(default)]
    pub typing_ms: u64,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Texts {
    pub hello: Option<String>,
    pub about: Option<String>,
    /// The finished background message; otherwise `backgroundFormat` (or English) with the link.
    pub background: Option<String>,
    pub background_format: Option<String>,
}

/// The three beats with their pacing (`ChiefWelcome.makeBeats(about:)`).
pub fn beats(texts: &Texts) -> Vec<Beat> {
    let background = texts.background.clone().unwrap_or_else(|| {
        format(texts.background_format.as_deref().unwrap_or(BACKGROUND_FORMAT), &[BACKGROUND_LINK])
    });
    let list = [
        (HELLO_CLIENT_ID, texts.hello.clone().unwrap_or_else(|| HELLO_TEXT.into())),
        (ABOUT_CLIENT_ID, texts.about.clone().unwrap_or_else(|| ABOUT_TEXT.into())),
        (BACKGROUND_CLIENT_ID, background),
    ];
    let mut above: Option<String> = None;
    list.into_iter()
        .map(|(id, text)| {
            let quiet_ms = above.as_deref().map_or(LEAD_IN_MS, reading_pause);
            let typing_ms = typing_time(&text);
            above = Some(text.clone());
            Beat { client_id: id.into(), text, quiet_ms, typing_ms }
        })
        .collect()
}

/// One thing `ChiefWelcome.play` does, in order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Step {
    /// Sleep this long.
    Wait { ms: u64 },
    /// Show or hide the Chief's typing indicator.
    Typing { on: bool },
    /// Import these beats (by index into `beats`); on failure hide typing and stop.
    Import { beats: Vec<usize> },
}

/// `ChiefWelcome.play`: with typing shown, quiet, typing on, typing time, import, typing off per beat;
/// without, one import of every beat.
pub fn play_steps(beats: &[Beat], shows_typing: bool) -> Vec<Step> {
    if !shows_typing {
        return vec![
            Step::Import { beats: (0..beats.len()).collect() },
            Step::Typing { on: false },
        ];
    }
    beats
        .iter()
        .enumerate()
        .flat_map(|(index, beat)| {
            [
                Step::Wait { ms: beat.quiet_ms },
                Step::Typing { on: true },
                Step::Wait { ms: beat.typing_ms },
                Step::Import { beats: vec![index] },
                Step::Typing { on: false },
            ]
        })
        .collect()
}

/// The daemon's `ConversationImportRequest` for these beats, in its wire keys.
pub fn import_request(conversation: &str, author: &str, beats: &[Beat], now_seconds: f64) -> Value {
    let time = iso8601_millis(now_seconds);
    let messages: Vec<Value> = beats
        .iter()
        .map(|beat| {
            json!({
                "id": null,
                "client_msg_id": beat.client_id,
                "author": author,
                "parts": [{"type": "text", "text": beat.text}],
                "created_at": time,
            })
        })
        .collect();
    json!({"conversation": conversation, "messages": messages})
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shortcut {
    pub keys: String,
    #[serde(default)]
    pub then: Option<String>,
    pub title: String,
}

impl Shortcut {
    /// From an action's shortcut steps and title: the first two steps, the title without a closing `…`.
    pub fn from_steps(steps: &[String], title: &str) -> Option<Shortcut> {
        let keys = steps.first()?.clone();
        Some(Shortcut {
            keys,
            then: steps.get(1).cloned(),
            title: title.strip_suffix('…').unwrap_or(title).to_string(),
        })
    }

    pub fn markdown(&self, chord_format: &str) -> String {
        match &self.then {
            None => format!("`{}`", self.keys),
            Some(then) => format(chord_format, &[&self.keys, then]),
        }
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AboutRequest {
    pub about: Option<String>,
    pub shortcuts: Vec<Shortcut>,
    pub any_app: Option<Shortcut>,
    pub any_app_on: bool,
    pub heading: Option<String>,
    pub chord_format: Option<String>,
    pub any_app_format: Option<String>,
}

/// `ChiefWelcome.text(shortcuts:anyApp:anyAppOn:)`.
pub fn about_text(req: &AboutRequest) -> String {
    let chord = req.chord_format.as_deref().unwrap_or(CHORD_FORMAT);
    let mut blocks = vec![req.about.clone().unwrap_or_else(|| ABOUT_TEXT.into())];
    let mut lines: Vec<String> =
        req.shortcuts.iter().map(|s| format!("- {} {}", s.markdown(chord), s.title)).collect();
    if let Some(any) = &req.any_app {
        let md = any.markdown(chord);
        lines.push(if req.any_app_on {
            format!("- {md} {}", any.title)
        } else {
            format!(
                "- {}",
                format(
                    req.any_app_format.as_deref().unwrap_or(ANY_APP_FORMAT),
                    &[&md, &any.title, ANY_APP_LINK]
                )
            )
        });
    }
    if !lines.is_empty() {
        let mut block = vec![req.heading.clone().unwrap_or_else(|| SHORTCUTS_HEADING.into())];
        block.extend(lines);
        blocks.push(block.join("\n"));
    }
    blocks.join("\n\n")
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TextRequest {
    text: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct BeatsRequest {
    #[serde(flatten)]
    texts: Texts,
    beats: Option<Vec<Beat>>,
    shows_typing: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportRequest {
    conversation: String,
    #[serde(default)]
    author: Option<String>,
    #[serde(default)]
    beats: Option<Vec<Beat>>,
    #[serde(default)]
    texts: Option<Value>,
    now: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShortcutRequest {
    steps: Vec<String>,
    title: String,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "beats" => {
            let req: BeatsRequest = parse(request)?;
            reply(&json!({"beats": beats(&req.texts)}))
        }
        "typingTime" => {
            let req: TextRequest = parse(request)?;
            reply(&json!({"ms": typing_time(&req.text)}))
        }
        "readingPause" => {
            let req: TextRequest = parse(request)?;
            reply(&json!({"ms": reading_pause(&req.text)}))
        }
        "playSteps" => {
            let req: BeatsRequest = parse(request)?;
            let list = req.beats.unwrap_or_else(|| beats(&req.texts));
            reply(&json!({"beats": list, "steps": play_steps(&list, req.shows_typing)}))
        }
        "importRequest" => {
            let req: ImportRequest = parse(request)?;
            let list = match req.beats {
                Some(list) => list,
                None => {
                    let texts: Texts = match &req.texts {
                        Some(v) => parse(v)?,
                        None => Texts::default(),
                    };
                    beats(&texts)
                }
            };
            let author = req.author.as_deref().unwrap_or(DEFAULT_AUTHOR);
            reply(&json!({"request": import_request(&req.conversation, author, &list, req.now)}))
        }
        "shortcut" => {
            let req: ShortcutRequest = parse(request)?;
            reply(&json!({"shortcut": Shortcut::from_steps(&req.steps, &req.title).map(|s| json!({
                "keys": s.keys, "then": s.then, "title": s.title,
                "markdown": s.markdown(CHORD_FORMAT),
            }))}))
        }
        "shortcutActions" => reply(&json!({
            "actions": SHORTCUT_ACTIONS,
            "anyAppAction": ANY_APP_ACTION,
            "anyAppLink": ANY_APP_LINK,
        })),
        "aboutText" => {
            let req: AboutRequest = parse(request)?;
            reply(&json!({"text": about_text(&req)}))
        }
        _ => Err(OpError::Unknown),
    }
}
