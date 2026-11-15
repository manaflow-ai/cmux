//! What each verb answers: the JSON an agent reads and the lines a person
//! reads. Every human answer ends with what to run next, so no one has to
//! remember the verbs.

use cmux_customize::profile::{Listed, Saved};
use cmux_customize::schema::{Schema, Section};
use cmux_customize::{
    Applied, Begun, Change, FileDiff, Generation, History, Restored, Roots, Settled, Status,
    TriedOn, TryOn, count,
};
use serde_json::{Value, json};

pub(in crate::cli) enum Answer {
    Status(Status),
    Diff(Vec<FileDiff>),
    Show(u32, Vec<FileDiff>),
    Brief {
        brief: String,
        begun: Begun,
        status: Status,
    },
    Asked {
        session: Option<String>,
        reply: Option<String>,
        waited: bool,
        begun: Begun,
        status: Status,
    },
    Applied(Applied),
    Discarded(Restored),
    RolledBack(Restored),
    Generations(History),
    Saved(Saved),
    Using {
        name: String,
        begun: Begun,
        status: Status,
    },
    Profiles(Vec<Listed>),
    Paths(Roots),
    TriedOn(TriedOn),
    /// How try-ons ended, and the verb that asked (`keep`, `revert`,
    /// `settle`).
    Settled(Vec<Settled>, &'static str),
    Schema(Schema, Option<Section>, super::SchemaFormat),
    /// A `library` verb, rendered by `library.rs`.
    Library {
        json: Value,
        human: String,
    },
    /// `library off --code`, `off --all`, `reset`: exits 1 when something
    /// could not be put back as the library had it (`notes` says what).
    Recovery {
        json: Value,
        human: String,
        complete: bool,
    },
}

fn value(of: &impl serde::Serialize) -> Value {
    serde_json::to_value(of).unwrap_or(Value::Null)
}

/// A status with the two facts every reader wants first.
fn status_json(status: &Status) -> Value {
    let mut out = value(status);
    if let Some(object) = out.as_object_mut() {
        object.insert("previewing".to_owned(), json!(status.dirty()));
        object.insert("can_apply".to_owned(), json!(status.problems.is_empty()));
    }
    out
}

impl Answer {
    pub(in crate::cli) fn exit(&self) -> i32 {
        match self {
            Answer::Recovery { complete: false, .. } => 1,
            _ => 0,
        }
    }

    pub(in crate::cli) fn json(&self) -> Value {
        match self {
            Answer::Status(status) => status_json(status),
            Answer::Diff(diffs) => json!({ "files": diffs }),
            Answer::Show(n, diffs) => json!({ "generation": n, "files": diffs }),
            Answer::Brief { brief, begun, status } => {
                json!({ "brief": brief, "begun": begun, "status": status_json(status) })
            }
            Answer::Asked { session, reply, waited, begun, status } => json!({
                "session_id": session,
                "reply": reply,
                "waited": waited,
                "begun": begun,
                "status": status_json(status),
            }),
            Answer::Applied(applied) => value(applied),
            Answer::Discarded(restored) | Answer::RolledBack(restored) => value(restored),
            Answer::Generations(history) => value(history),
            Answer::Saved(saved) => value(saved),
            Answer::Using { name, begun, status } => {
                json!({ "profile": name, "begun": begun, "status": status_json(status) })
            }
            Answer::Profiles(profiles) => json!({ "profiles": profiles }),
            Answer::TriedOn(tried) => value(tried),
            Answer::Settled(settled, _) => json!({ "settled": settled }),
            Answer::Schema(schema, section, super::SchemaFormat::Schema) => {
                schema.to_json(*section)
            }
            Answer::Schema(schema, _, super::SchemaFormat::TypeScript) => json!({
                "language": "typescript",
                "source": cmux_customize::schema::typescript(schema),
            }),
            Answer::Schema(schema, _, super::SchemaFormat::Rust) => json!({
                "language": "rust",
                "source": cmux_customize::schema::rust(schema),
            }),
            Answer::Library { json, .. } | Answer::Recovery { json, .. } => json.clone(),
            Answer::Paths(roots) => json!({
                "settings": roots.settings_file,
                "keybindings": cmux_config::keybindings_path(&roots.settings_file),
                "themes": roots.config_dir.join("themes"),
                "views": roots.customize_dir,
                "styles": roots.config_dir.join("agent-pane/theme.css"),
                "automations": roots.config_dir.join("automations"),
                "profiles": roots.profiles_dir(),
                "generations": roots.state_dir,
            }),
        }
    }

    pub(in crate::cli) fn human(&self, now_ms: u64) -> String {
        let mut out = String::new();
        match self {
            Answer::Status(status) => status_lines(&mut out, status, now_ms),
            Answer::Diff(diffs) if diffs.is_empty() => {
                out.push_str("nothing is previewing: what is live is what is applied\n");
            }
            Answer::Diff(diffs) => diff_lines(&mut out, diffs),
            Answer::Show(n, diffs) if diffs.is_empty() => {
                out.push_str(&format!("generation {n} changed nothing from the one before it\n"));
            }
            Answer::Show(_, diffs) => diff_lines(&mut out, diffs),
            Answer::Brief { brief, .. } => {
                out.push_str(brief);
                if !brief.ends_with('\n') {
                    out.push('\n');
                }
            }
            Answer::Asked { session, reply, waited, begun, status } => {
                let wish = begun.draft.asks.last().map(|ask| ask.text.as_str()).unwrap_or_default();
                let chat = session.as_deref().map(|id| format!(" (chat {id})")).unwrap_or_default();
                let verb = if begun.refined { "refining the preview" } else { "asked an agent" };
                out.push_str(&format!("{verb}: {wish}{chat}\n"));
                if let Some(n) = begun.by_hand {
                    out.push_str(&format!(
                        "your edits by hand so far are kept as generation {n}\n"
                    ));
                }
                if *waited {
                    if let Some(reply) = reply.as_deref().filter(|reply| !reply.trim().is_empty()) {
                        out.push_str(&format!("\n{}\n\n", reply.trim()));
                    }
                    status_lines(&mut out, status, now_ms);
                } else {
                    out.push_str(
                        "watch the cmux window: each change shows as the agent saves it. Nothing is applied yet.\n",
                    );
                    next_lines(&mut out, status, true);
                }
            }
            Answer::Applied(applied) if !applied.recorded => {
                out.push_str(&format!(
                    "nothing to apply: what is live is already generation {}\n",
                    applied.generation.n
                ));
            }
            Answer::Applied(applied) => {
                out.push_str(&format!(
                    "applied as generation {}: {} ({})\n",
                    applied.generation.n,
                    applied.generation.label,
                    count(applied.changes.len(), "file")
                ));
                change_lines(&mut out, &applied.changes);
                if let Some(name) = &applied.library {
                    out.push_str(&format!(
                        "saved to your library as {name} (`cmux customize library`)\n"
                    ));
                }
                out.push_str("  cmux customize rollback        go back to how it was\n");
                out.push_str(
                    "  cmux customize save NAME       keep this setup as a profile you can share\n",
                );
            }
            Answer::Discarded(restored) => {
                out.push_str(&format!(
                    "discarded: generation {} is live again",
                    restored.generation.n
                ));
                kept_line(&mut out, restored);
            }
            Answer::RolledBack(restored) => {
                out.push_str(&format!(
                    "rolled back: generation {} is live ({})",
                    restored.generation.n, restored.generation.label
                ));
                kept_line(&mut out, restored);
            }
            Answer::Generations(history) => generation_lines(&mut out, history, now_ms),
            Answer::Saved(saved) => {
                out.push_str(&format!(
                    "saved profile {}: {} and {} in {}\n",
                    saved.name,
                    count(saved.settings, "setting"),
                    count(saved.files.len(), "file"),
                    saved.path.display()
                ));
                for line in &saved.left_out {
                    out.push_str(&format!("  left out: {line}\n"));
                }
                out.push_str(&format!(
                    "  cmux customize use {}    preview it, here or on another machine (send the file)\n",
                    saved.name
                ));
            }
            Answer::Using { name, status, .. } => {
                out.push_str(&format!("previewing profile {name}; nothing is applied yet\n"));
                status_lines(&mut out, status, now_ms);
            }
            Answer::TriedOn(tried) => {
                out.push_str(&format!(
                    "trying on: {} (generation {}), {}\n",
                    tried.try_on.label,
                    tried.applied.generation.n,
                    left(&tried.try_on, now_ms)
                ));
                change_lines(&mut out, &tried.applied.changes);
                try_on_next(&mut out, &tried.try_on);
            }
            Answer::Settled(settled, verb) if settled.is_empty() => {
                let what = match *verb {
                    "settle" => "no try-on is due",
                    _ => "nothing is being tried on",
                };
                out.push_str(what);
                out.push('\n');
            }
            Answer::Settled(settled, _) => {
                for one in settled {
                    match one {
                        Settled::Kept { try_on } => out.push_str(&format!(
                            "kept: {} stays applied (generation {})\n",
                            try_on.label, try_on.generation
                        )),
                        Settled::Ended { try_on } => out.push_str(&format!(
                            "the try-on of {} ended: something else was applied since\n",
                            try_on.label
                        )),
                        Settled::Reverted { try_on, restored } => {
                            out.push_str(&format!(
                                "reverted the try-on of {}: generation {} is live again",
                                try_on.label, restored.generation.n
                            ));
                            kept_line(&mut out, restored);
                        }
                    }
                }
            }
            Answer::Profiles(profiles) if profiles.is_empty() => {
                out.push_str(
                    "no profiles yet; `cmux customize save NAME` saves what is live as one\n",
                );
            }
            Answer::Profiles(profiles) => {
                let width =
                    profiles.iter().map(|profile| profile.name.len()).max().unwrap_or(4).max(4);
                out.push_str(&format!("{:width$}  SETTINGS  FILES  ABOUT\n", "NAME"));
                for profile in profiles {
                    out.push_str(&format!(
                        "{:width$}  {:>8}  {:>5}  {}\n",
                        profile.name, profile.settings, profile.files, profile.description
                    ));
                }
            }
            Answer::Schema(schema, _, super::SchemaFormat::TypeScript) => {
                out.push_str(&cmux_customize::schema::typescript(schema));
            }
            Answer::Schema(schema, _, super::SchemaFormat::Rust) => {
                out.push_str(&cmux_customize::schema::rust(schema));
            }
            Answer::Schema(schema, section, super::SchemaFormat::Schema) => {
                schema_lines(&mut out, schema, *section);
            }
            Answer::Library { human, .. } | Answer::Recovery { human, .. } => out.push_str(human),
            Answer::Paths(_) => {
                if let Some(paths) = self.json().as_object() {
                    for (name, path) in paths {
                        out.push_str(&format!("{name:12} {}\n", path.as_str().unwrap_or_default()));
                    }
                }
            }
        }
        out
    }
}

/// `9 minutes left`, `40 seconds left`.
pub(super) fn left(try_on: &TryOn, now_ms: u64) -> String {
    let seconds = try_on.expires_ms.saturating_sub(now_ms).div_ceil(1000);
    match seconds {
        0 => "reverting now".to_owned(),
        1..=59 => format!("{} left", count(seconds as usize, "second")),
        _ => format!("{} left", count(seconds.div_ceil(60) as usize, "minute")),
    }
}

fn try_on_next(out: &mut String, try_on: &TryOn) {
    let back = try_on.revert_to.map(|n| format!("generation {n}")).unwrap_or("it".to_owned());
    out.push_str("  cmux customize keep            keep it\n");
    out.push_str(&format!("  cmux customize revert          put {back} back now\n"));
}

fn kept_line(out: &mut String, restored: &Restored) {
    match restored.kept_as {
        Some(n) => out.push_str(&format!(
            "\nwhat was live is kept as generation {n}: `cmux customize rollback {n}` brings it back\n"
        )),
        None => out.push('\n'),
    }
}

fn change_lines(out: &mut String, changes: &[Change]) {
    let width = changes.iter().map(|change| change.path.len()).max().unwrap_or(0);
    for change in changes {
        let hand = if change.by_hand { "  edited by hand" } else { "" };
        out.push_str(&format!(
            "  {} {:width$}  {}{hand}\n",
            change.kind.sign(),
            change.path,
            change.part.name()
        ));
    }
}

fn status_lines(out: &mut String, status: &Status, now_ms: u64) {
    match &status.current {
        Some(generation) => out.push_str(&format!(
            "generation {} is applied: {} ({})\n",
            generation.n,
            generation.label,
            ago(now_ms, generation.at_ms)
        )),
        None => out.push_str("no generation yet\n"),
    }
    if let Some(try_on) = &status.try_on {
        out.push_str(&format!(
            "trying on: {}, {}; it reverts by itself unless you keep it\n",
            try_on.label,
            left(try_on, now_ms)
        ));
        try_on_next(out, try_on);
    }
    if !status.dirty() {
        out.push_str("nothing is previewing\n");
    } else {
        let asked = status
            .draft
            .as_ref()
            .and_then(|draft| draft.asks.last())
            .map(|ask| format!(" (asked: {})", ask.text))
            .unwrap_or_default();
        out.push_str(&format!(
            "previewing {}, not applied yet{asked}:\n",
            count(status.changes.len(), "change")
        ));
        change_lines(out, &status.changes);
    }
    if !status.problems.is_empty() {
        out.push_str(&format!(
            "{} to fix before this applies:\n",
            count(status.problems.len(), "problem")
        ));
        for problem in &status.problems {
            out.push_str(&format!("  {}\n", problem.line()));
        }
    }
    for skipped in &status.skipped {
        out.push_str(&format!("  not tracked: {} ({})\n", skipped.path, skipped.reason));
    }
    next_lines(out, status, false);
}

/// The verbs that make sense from here.
fn next_lines(out: &mut String, status: &Status, asked: bool) {
    let current = status.current.as_ref().map_or(1, |generation| generation.n);
    if status.dirty() || asked {
        out.push_str("  cmux customize                 see what changed\n");
        out.push_str("  cmux customize 'and also …'    keep refining\n");
        out.push_str("  cmux customize apply           keep it\n");
        out.push_str(&format!("  cmux customize discard         put generation {current} back\n"));
    } else {
        out.push_str("  cmux customize 'what you want' ask for a change\n");
        if status.current.as_ref().is_some_and(|generation| generation.parent.is_some()) {
            out.push_str("  cmux customize rollback        go back one generation\n");
        }
    }
}

fn diff_lines(out: &mut String, diffs: &[FileDiff]) {
    for file in diffs {
        out.push_str(&format!("{} {}\n", file.kind.sign(), file.path));
        match &file.diff {
            Some(text) => out.push_str(text),
            None => out.push_str("  (not text)\n"),
        }
    }
}

fn generation_lines(out: &mut String, history: &History, now_ms: u64) {
    if history.generations.is_empty() {
        out.push_str("no generation yet\n");
        return;
    }
    out.push_str("     N  WHEN      WHAT       BY    FILES  LABEL\n");
    for generation in &history.generations {
        out.push_str(&generation_line(generation, history.current, now_ms));
    }
    out.push_str("* is live. `cmux customize rollback N` makes any of them live; `show N` says what it changed\n");
}

fn generation_line(generation: &Generation, current: Option<u32>, now_ms: u64) -> String {
    let mark = if current == Some(generation.n) { '*' } else { ' ' };
    format!(
        "{mark} {:>4}  {:8}  {:9}  {:4}  {:>5}  {}\n",
        generation.n,
        ago(now_ms, generation.at_ms),
        generation.kind.word(),
        generation.origin,
        generation.changed,
        generation.label
    )
}

/// `just now`, `5m ago`, `3h ago`, `2d ago`.
pub(super) fn ago(now_ms: u64, at_ms: u64) -> String {
    let seconds = now_ms.saturating_sub(at_ms) / 1000;
    match seconds {
        0..=59 => "just now".to_owned(),
        60..=3599 => format!("{}m ago", seconds / 60),
        3600..=86_399 => format!("{}h ago", seconds / 3600),
        _ => format!("{}d ago", seconds / 86_400),
    }
}

/// At most this many choices on a line; the JSON has them all.
const SHOWN_CHOICES: usize = 6;

/// `cmux customize schema`: one line per key, grouped by part.
fn schema_lines(out: &mut String, schema: &Schema, only: Option<Section>) {
    let shows = |section: Section| only.is_none_or(|only| only == section);
    if shows(Section::Settings) {
        out.push_str(&format!(
            "Settings ({}; `cmux settings set KEY VALUE`, or edit cmux-next.json):\n",
            schema.settings.len()
        ));
        let width = schema.settings.iter().map(|s| s.key.len()).max().unwrap_or(0);
        for setting in &schema.settings {
            let mut what = setting.kind.to_owned();
            if !setting.choices.is_empty() {
                let mut shown: Vec<&str> =
                    setting.choices.iter().take(SHOWN_CHOICES).map(String::as_str).collect();
                let more = setting.choices.len().saturating_sub(SHOWN_CHOICES);
                let more = format!("+{more}");
                if setting.choices.len() > SHOWN_CHOICES {
                    shown.push(&more);
                }
                what.push_str(&format!(" {}", shown.join("|")));
            }
            if let Some(range) = &setting.range {
                what.push_str(&format!(" {}..{}", range.min, range.max));
                if !range.unit.is_empty() {
                    what.push_str(&format!(" {}", range.unit));
                }
            }
            if let Some(default) = &setting.default {
                let default = default.to_string();
                if default.len() <= 40 {
                    what.push_str(&format!("  default {default}"));
                }
            }
            if !setting.agent_settable {
                what.push_str("  (the person sets it)");
            }
            if setting.theme_file {
                what.push_str("  [theme]");
            }
            out.push_str(&format!("  {:width$}  {what}\n", setting.key));
        }
        out.push('\n');
    }
    if shows(Section::Theme) {
        let theme = &schema.theme;
        out.push_str(&format!(
            "Theme files ({}/NAME.json, picked by {}): the settings marked [theme], plus {}\n",
            theme.folder,
            theme.file_setting,
            theme.file_keys.join(", ")
        ));
        out.push_str(&format!("  colors: {}\n", theme.colors.join(" ")));
        out.push_str("Theme tokens (each theme derives them; change the colors they come from):\n");
        let width = theme.tokens.iter().map(|t| t.name.len()).max().unwrap_or(0);
        for token in &theme.tokens {
            let formula = token.formula.split(';').next().unwrap_or_default().trim();
            out.push_str(&format!("  {:width$}  {formula}\n", token.name));
        }
        out.push('\n');
    }
    if shows(Section::Views) {
        out.push_str(
            "View slots (where your view goes; `cmux apps place 'local/customize#cmux.section/1'`):\n",
        );
        let width = schema.views.iter().map(|v| v.interface.len()).max().unwrap_or(0);
        for slot in &schema.views {
            let places = match &slot.place_option {
                Some(option) => format!("{option}: {}", slot.places.join("|")),
                None => String::new(),
            };
            out.push_str(&format!("  {:width$}  {places}\n", slot.interface));
        }
        out.push('\n');
    }
    if shows(Section::ExtensionPoints) {
        out.push_str("Extension points (`implements` in cmux-app.json):\n");
        let width = schema.extension_points.iter().map(|p| p.interface.len()).max().unwrap_or(0);
        for point in &schema.extension_points {
            let docs = point.docs.split(". ").next().unwrap_or_default().trim_end_matches('.');
            out.push_str(&format!("  {:width$}  {docs}\n", point.interface));
        }
        out.push('\n');
    }
    out.push_str(
        "Next:\n  cmux customize schema settings --json   every key with its JSON Schema, range and default\n  cmux customize schema --typescript       the same as TypeScript types (cmux-extension-sdk/customize)\n  cmux customize 'make the sidebar compact'   ask an agent to change it\n",
    );
}
