//! What each verb answers: the JSON an agent reads and the lines a person
//! reads. Every human answer ends with what to run next, so no one has to
//! remember the verbs.

use cmux_customize::profile::{Listed, Saved};
use cmux_customize::{
    Applied, Begun, Change, FileDiff, Generation, History, Restored, Roots, Status, count,
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
        0
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
