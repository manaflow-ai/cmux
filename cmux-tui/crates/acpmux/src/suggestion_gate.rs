//! Which predicted next prompts reach the composer (`prompt_suggestion` updates, from Claude
//! Code's prompt suggestions in `claude_stdio/prompt_suggestions.rs` or any other source): only
//! those likely to be taken, the lesson of Cursor Tab (a suggestion people keep passing over is
//! noise; Leo, 2026-11-03: "that suggested prompting from Codex, we need to have that as well").
//!
//! The hub keeps one tally per harness and source of how often a shown suggestion was taken. A
//! suggestion counts as taken when the person's next prompt is that suggestion (as sent, or
//! marked taken by the client that filled it in: `_meta.acpmux.promptSuggestion: "taken"`, so a
//! taken suggestion edited before sending still counts), and as passed over when the next prompt
//! is anything else. The estimate is the smoothed rate (a Beta prior, so a new install still
//! sees suggestions), with older outcomes fading so a change of habit shows. Below
//! [`THRESHOLD`] the suggestion is withheld: the update goes on with no suggestion, so the
//! composer clears the old one. While withheld, every [`EXPLORE_EVERY`]th suggestion is shown
//! anyway, or a source that fell below once could never climb back.
//!
//! The tallies live in `~/.acpmux/prompt-suggestions.json` (rewritten after each outcome); a
//! missing or unreadable file starts from the prior.

use cmux_json::JsonSet as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

/// Predicted acceptance under which a suggestion is withheld.
pub const THRESHOLD: f64 = 0.25;
/// Prior takes and passes: a 50% start worth six outcomes, so about seven straight passes on a
/// new install withhold suggestions, and a single pass never does.
const PRIOR_TAKEN: f64 = 3.0;
const PRIOR_PASSED: f64 = 3.0;
/// Each new outcome scales the earlier ones by this, so roughly the last 30 outcomes count.
const DECAY: f64 = 0.97;
/// While withheld, one suggestion in this many is shown so its rate can recover.
pub const EXPLORE_EVERY: u32 = 8;
/// The file name under the acpmux home.
const FILE: &str = "prompt-suggestions.json";
/// Source of a suggestion whose update names none: the harness's own (Claude Code's).
pub const HARNESS_SOURCE: &str = "harness";

/// One harness and source's record.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tally {
    /// Decayed count of suggestions taken.
    pub taken: f64,
    /// Decayed count of suggestions passed over.
    pub passed: f64,
    /// Suggestions withheld in a row since the last one shown.
    #[serde(default)]
    pub withheld: u32,
}

impl Tally {
    /// The smoothed chance the next suggestion is taken.
    pub fn estimate(&self) -> f64 {
        (self.taken + PRIOR_TAKEN) / (self.taken + self.passed + PRIOR_TAKEN + PRIOR_PASSED)
    }

    /// Records one outcome, fading the earlier ones.
    pub fn record(&mut self, taken: bool) {
        self.taken *= DECAY;
        self.passed *= DECAY;
        if taken {
            self.taken += 1.0;
        } else {
            self.passed += 1.0;
        }
    }

    /// Whether a new suggestion is shown, counting the ones withheld.
    pub fn admit(&mut self) -> bool {
        if self.estimate() >= THRESHOLD || self.withheld + 1 >= EXPLORE_EVERY {
            self.withheld = 0;
            true
        } else {
            self.withheld += 1;
            false
        }
    }
}

/// A suggestion shown in a chat and not yet answered by its next prompt.
#[derive(Clone, Debug, PartialEq)]
struct Shown {
    key: String,
    text: String,
}

/// Every tally and each chat's shown suggestion.
#[derive(Debug, Default)]
pub struct Gate {
    tallies: HashMap<String, Tally>,
    shown: HashMap<String, Shown>,
    path: Option<PathBuf>,
}

/// The tally key: harness, then source.
pub fn key(harness: &str, source: &str) -> String {
    format!("{harness}/{source}")
}

impl Gate {
    /// A gate with the tallies saved at `path` (none when missing or unreadable).
    pub fn load(path: PathBuf) -> Self {
        let tallies = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<HashMap<String, Tally>>(&bytes).ok())
            .unwrap_or_default();
        Self { tallies, shown: HashMap::new(), path: Some(path) }
    }

    /// The tally for `key`, as the prior when it has none.
    pub fn tally(&self, key: &str) -> Tally {
        self.tallies.get(key).cloned().unwrap_or_default()
    }

    /// A live suggestion for `session`: whether it is shown. A shown one is remembered until the
    /// chat's next prompt; a withheld one forgets any earlier one (the composer clears it too).
    pub fn offer(&mut self, session: &str, key: &str, text: &str) -> bool {
        let admitted = self.tallies.entry(key.to_owned()).or_default().admit();
        if admitted {
            self.shown
                .insert(session.to_owned(), Shown { key: key.to_owned(), text: text.to_owned() });
        } else {
            self.shown.remove(session);
        }
        self.save();
        admitted
    }

    /// The agent took its suggestion back (`suggestion: null`): no outcome.
    pub fn withdraw(&mut self, session: &str) {
        self.shown.remove(session);
    }

    /// The person's next prompt in `session`: an outcome for the suggestion it answers, if any.
    /// Returns whether it was taken.
    pub fn prompted(&mut self, session: &str, text: &str, marked_taken: bool) -> Option<bool> {
        let shown = self.shown.remove(session)?;
        let taken = marked_taken || same_prompt(&shown.text, text);
        self.tallies.entry(shown.key).or_default().record(taken);
        self.save();
        Some(taken)
    }

    fn save(&self) {
        let Some(path) = &self.path else { return };
        if let Ok(bytes) = serde_json::to_vec(&self.tallies) {
            let _ = crate::config::write_atomic(path, &bytes);
        }
    }
}

/// Whether a sent prompt is the suggestion, ignoring surrounding and repeated whitespace.
fn same_prompt(suggestion: &str, sent: &str) -> bool {
    let words = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let (a, b) = (words(suggestion), words(sent));
    !a.is_empty() && a == b
}

/// The daemon's gate, its tallies under the acpmux home (in unit tests, none on disk).
static GATE: LazyLock<Mutex<Gate>> = LazyLock::new(|| {
    Mutex::new(if cfg!(test) {
        Gate::default()
    } else {
        Gate::load(file_in(&crate::config::home()))
    })
});

/// The tallies file under an acpmux home.
pub fn file_in(home: &Path) -> PathBuf {
    home.join(FILE)
}

fn gate() -> std::sync::MutexGuard<'static, Gate> {
    GATE.lock().unwrap_or_else(|e| e.into_inner())
}

/// A live `session/update`'s `update` in `session` of `harness`: a `prompt_suggestion` that the
/// gate withholds loses its suggestion (set to null) and says so in
/// `_meta.acpmux.suggestionWithheld`. Any other update is left as it is.
pub fn filter_update(session: &str, harness: &str, update: &mut Value) {
    if update.get("sessionUpdate").and_then(Value::as_str) != Some("prompt_suggestion") {
        return;
    }
    gate_update(&mut gate(), session, harness, update);
}

/// [`filter_update`] against a given gate.
pub fn gate_update(gate: &mut Gate, session: &str, harness: &str, update: &mut Value) {
    let Some(text) = update.get("suggestion").and_then(Value::as_str).map(str::to_owned) else {
        gate.withdraw(session);
        return;
    };
    let source = update
        .pointer("/_meta/acpmux/source")
        .and_then(Value::as_str)
        .unwrap_or(HARNESS_SOURCE)
        .to_owned();
    let key = key(harness, &source);
    if gate.offer(session, &key, &text) {
        return;
    }
    let estimate = gate.tally(&key).estimate();
    update.set("suggestion", Value::Null);
    if !update.get("_meta").is_some_and(Value::is_object) {
        update.set("_meta", serde_json::json!({}));
    }
    let Some(meta) = update.get_mut("_meta") else { return };
    if !meta.get("acpmux").is_some_and(Value::is_object) {
        meta.set("acpmux", serde_json::json!({}));
    }
    if let Some(acpmux) = meta.get_mut("acpmux") {
        acpmux
            .set("suggestionWithheld", serde_json::json!({"source": source, "estimate": estimate}));
    }
}

/// A person's prompt in `session`: its text and whether its client marked the shown suggestion
/// taken (`_meta.acpmux.promptSuggestion: "taken"`).
pub fn note_prompt(session: &str, text: &str, marked_taken: bool) {
    gate().prompted(session, text, marked_taken);
}

/// The prompt's text blocks, joined.
pub fn prompt_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// A prompt in `session` that is not the person's: the shown suggestion is forgotten unanswered.
pub fn withdraw(session: &str) {
    gate().withdraw(session);
}

/// Whether a prompt's client marked it as the taken suggestion.
pub fn marked_taken(params: &Value) -> bool {
    params.pointer("/_meta/acpmux/promptSuggestion").and_then(Value::as_str) == Some("taken")
}

#[cfg(test)]
#[path = "suggestion_gate_tests.rs"]
mod tests;
