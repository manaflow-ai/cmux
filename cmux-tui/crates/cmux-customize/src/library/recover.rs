//! Which layers are on, said in one line for a bug report, and the way out
//! when one of them broke cmux (Leo, 2026-11-14: "I want people to not
//! accidentally soft lock themselves and like have good recovery options").
//!
//! ```text
//! cmux customize library status            customize: 2 on: pr-43496 @dbb1e3e (web), theme-dusk
//! cmux customize library off --code --reason TEXT   every pr-N entry off, TEXT as its note
//! cmux customize library off --all         every entry off: what was there before any layer
//! cmux customize library reset             the same as off --all
//! ```
//!
//! None of this needs the app. Each verb first tries the library's own
//! change (one applied generation, exact base). When the library or the
//! store does not read, it still gets web-dev.json off a layer: it reads
//! library.json as plain JSON for the base it kept, turns the code entries
//! off in that JSON, and writes the base back; with no base to read, it
//! removes only an `overlay` that is a library layer folder and keeps every
//! other key.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use super::code::{CodeKind, WebBase, WebTarget, read_object};
use super::overlay::{Overlay, now_ms};
use super::text::one_line;
use super::{Changed, Entry, web_top};
use crate::{Customize, Error};

/// One entry that is on, as a diagnostics report names it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ActiveLayer {
    pub name: String,
    /// A code layer's kind (`pr`, `branch`, `sha`, `dir`, `fork`: code not in
    /// your build), else what it sets: `settings`, `files`, `settings+files`,
    /// or `empty`.
    pub kind: &'static str,
    /// The pull request a `pr` entry is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr: Option<u64>,
    /// Where a code layer comes from, as a person says it: `#43496`, `branch
    /// feat-x`, `commit dbb1e3e`, `folder /Users/me/cmux`, `fork me/cmux@main`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    /// Its head, short (7).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    /// A code entry's web layer is the one web-dev.json serves (`false`: a
    /// higher code entry's wins, or it has no web part).
    pub web: bool,
    /// The entry's last note (a refresh's word, the reason it was turned off).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub note: String,
}

/// The layers that are on, for `cmux version` and bug reports.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Layers {
    /// Top first.
    pub on: Vec<ActiveLayer>,
    /// `customize: 2 on: pr-43496 @dbb1e3e (web), theme-dusk`.
    pub line: String,
    /// web-dev.json's `overlay` now, when it has one.
    pub overlay: Option<String>,
    /// That overlay is a library layer folder no entry that is on serves:
    /// a write cut short left it; `cmux customize library off --code` clears it.
    pub stray_overlay: bool,
    /// Why the library did not read; `cmux customize library reset` gets out.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub problem: Option<String>,
    /// The overlay web-dev.json names, as the app judges it: a hand-installed
    /// one is no library entry, so this is where it shows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub web_dev: Option<Overlay>,
}

/// What a recovery verb did.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Recovered {
    /// The entries it turned off, top first.
    pub turned_off: Vec<String>,
    /// The library's own change, when the library could make it (its
    /// generation is what `rollback` undoes).
    pub change: Option<Changed>,
    /// web-dev.json's `overlay` afterwards; `None`: it has none.
    pub overlay: Option<String>,
    /// Everything was put back as the library had it. `false`: `notes` says
    /// what was left and why.
    pub complete: bool,
    /// What could not go the usual way and what was done instead.
    pub notes: Vec<String>,
}

impl Customize {
    /// The entries that are on, with the one-line form a bug report carries.
    /// Never fails: a library that does not read is the `problem`. The app's
    /// web ABI is not known here; [`Customize::layers_at`] takes it.
    pub fn layers(&self) -> Layers {
        self.layers_at(None, now_ms())
    }

    /// [`Customize::layers`] for an app whose pages need web ABI `app_abi`
    /// (so a refused overlay says so), at `now_ms` (for an overlay's age).
    pub fn layers_at(&self, app_abi: Option<u32>, now_ms: u64) -> Layers {
        let overlay = self.overlay_now();
        let library = self.read_library();
        let (on, problem) = match &library {
            Ok(library) => (active(&library.entries), None),
            Err(error) => (Vec::new(), Some(error.to_string())),
        };
        let stray_overlay = overlay.as_deref().is_some_and(|path| self.is_layer_path(path))
            && match &library {
                Ok(library) => web_top(&library.entries).is_none_or(|code| {
                    Some(self.layer_dir(&code.web)) != overlay.as_deref().map(PathBuf::from)
                }),
                Err(_) => true,
            };
        let mut line = summary_line(&on, problem.is_some(), stray_overlay);
        let web_dev = self.overlay(app_abi);
        if let Some(words) = web_dev.as_ref().and_then(|overlay| overlay.words(now_ms)) {
            line.push_str("; ");
            line.push_str(&words);
        }
        Layers { on, line, overlay, stray_overlay, problem, web_dev }
    }

    /// Turns every code entry off and records `reason` (one line) as
    /// the note of each one that was on. What the app runs when a layer's
    /// pages fail to load: `cmux customize library off --code --reason TEXT`.
    pub fn library_off_code(
        &self,
        reason: Option<&str>,
        origin: &str,
        now_ms: u64,
    ) -> Result<Recovered, Error> {
        let reason = reason.map(one_line).filter(|reason| !reason.is_empty());
        let mut turned_off = Vec::new();
        let mut notes = Vec::new();
        let label = "library: every code layer off";
        let change = match self.library_change(label, origin, now_ms, |library| {
            for entry in library.entries.iter_mut() {
                let Some(code) = entry.code.as_mut() else { continue };
                if entry.on {
                    turned_off.push(entry.profile.name.clone());
                    if let Some(reason) = &reason {
                        code.note = reason.clone();
                    }
                }
                entry.on = false;
            }
            Ok(())
        }) {
            Ok(change) => Some(change),
            Err(error) => {
                turned_off.clear();
                notes.push(format!("the library could not make the change ({error})"));
                self.force_code_off(reason.as_deref(), &mut turned_off, &mut notes)?;
                None
            }
        };
        self.clear_stray_overlay(&mut notes)?;
        let complete = notes.is_empty();
        Ok(Recovered { turned_off, change, overlay: self.overlay_now(), complete, notes })
    }

    /// Turns every entry off: the settings, files and web-dev.json keys the
    /// library manages go back to what they were before any layer. Pull
    /// request entries go first, so a preview that is open or a settings file
    /// that does not parse never keeps a broken web layer on.
    /// `cmux customize library off --all`, and `reset`.
    pub fn library_off_all(&self, origin: &str, now_ms: u64) -> Result<Recovered, Error> {
        let mut out = self.library_off_code(None, origin, now_ms)?;
        if let Err(error) = self.read_library() {
            // The entries cannot be read, so neither can what they set or
            // what was under it. Keep the file beside, so the next verb starts
            // from an empty library, and say what stays.
            let path = self.library_path();
            if path.exists() {
                let kept = path.with_file_name(format!("library.json.unreadable-{now_ms}"));
                std::fs::rename(&path, &kept)?;
                out.notes.push(format!(
                    "{error}; it is kept as {} and the library starts empty; settings and files its entries set stay as they are (`cmux customize rollback` steps back through them)",
                    kept.display()
                ));
            }
            out.complete = false;
            return Ok(out);
        }
        let mut turned_off = Vec::new();
        match self.library_change("library: every entry off", origin, now_ms, |library| {
            for entry in library.entries.iter_mut().filter(|entry| entry.on) {
                turned_off.push(entry.profile.name.clone());
                entry.on = false;
            }
            Ok(())
        }) {
            Ok(change) => {
                out.turned_off.extend(turned_off);
                if let Some(code) = out.change.take() {
                    let mut change = change;
                    for key in code.changed {
                        if !change.changed.contains(&key) {
                            change.changed.push(key);
                        }
                    }
                    change.generation = change.generation.or(code.generation);
                    change.by_hand = change.by_hand.or(code.by_hand);
                    out.change = Some(change);
                } else {
                    out.change = Some(change);
                }
            }
            Err(error) => {
                out.notes.push(format!(
                    "every code layer is off, but the other entries are still on: {error}"
                ));
                out.complete = false;
            }
        }
        out.overlay = self.overlay_now();
        Ok(out)
    }

    /// The code entries off without the store: library.json read as
    /// plain JSON, its code entries turned off in place and its web base
    /// written back to web-dev.json.
    fn force_code_off(
        &self,
        reason: Option<&str>,
        turned_off: &mut Vec<String>,
        notes: &mut Vec<String>,
    ) -> Result<(), Error> {
        let path = self.library_path();
        let parsed = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<Value>(&text).ok());
        let Some(Value::Object(mut root)) = parsed else {
            notes.push(format!(
                "{} does not read, so what web-dev.json had before is not known; only an overlay that is a library layer is removed",
                path.display()
            ));
            return Ok(());
        };
        let mut changed = false;
        if let Some(Value::Array(entries)) = root.get_mut("entries") {
            for entry in entries.iter_mut().filter_map(Value::as_object_mut) {
                if !entry.get("code").is_some_and(Value::is_object) {
                    continue;
                }
                if entry.get("on").and_then(Value::as_bool) == Some(true) {
                    let name = entry
                        .get("profile")
                        .and_then(|profile| profile.get("name"))
                        .and_then(Value::as_str)
                        .unwrap_or("?")
                        .to_owned();
                    turned_off.push(name);
                    if let (Some(reason), Some(Value::Object(code))) =
                        (reason, entry.get_mut("code"))
                    {
                        code.insert("note".to_owned(), Value::String(reason.to_owned()));
                    }
                    entry.insert("on".to_owned(), Value::Bool(false));
                    changed = true;
                }
            }
        }
        let base = root
            .get_mut("base")
            .and_then(Value::as_object_mut)
            .and_then(|base| base.remove("web"))
            .map(|web| serde_json::from_value::<WebBase>(web).unwrap_or_default());
        if let Some(base) = &base {
            self.write_web_dev(&WebTarget::Base, base)?;
            changed = true;
        }
        if changed {
            let mut text = serde_json::to_string_pretty(&Value::Object(root))
                .map_err(std::io::Error::other)?;
            text.push('\n');
            cmux_config::fsio::write_atomic(&path, text.as_bytes())?;
        }
        Ok(())
    }

    /// Removes web-dev.json's `overlay` when it is a library layer folder
    /// that no entry that is on serves (a write cut short, a library that
    /// does not read). Every other key stays.
    fn clear_stray_overlay(&self, notes: &mut Vec<String>) -> Result<(), Error> {
        let layers = self.layers();
        if !layers.stray_overlay {
            return Ok(());
        }
        let (now, _) = read_object(&self.roots().config_dir.join(super::code::WEB_DEV))?;
        let keep = WebBase { overlay: None, enabled: now.get("enabled").cloned(), no_file: false };
        self.write_web_dev(&WebTarget::Base, &keep)?;
        notes.push(format!(
            "web-dev.json still served layer {}; its overlay is removed",
            layers.overlay.unwrap_or_default()
        ));
        Ok(())
    }

    /// web-dev.json's `overlay` as text, when it has one.
    fn overlay_now(&self) -> Option<String> {
        let (object, _) = read_object(&self.roots().config_dir.join(super::code::WEB_DEV)).ok()?;
        object.get("overlay").and_then(Value::as_str).map(str::to_owned)
    }

    /// `path` is inside the library's layers folder.
    pub(crate) fn is_layer_path(&self, path: &str) -> bool {
        Path::new(path).starts_with(self.roots().state_dir.join("layers"))
    }
}

fn active(entries: &[Entry]) -> Vec<ActiveLayer> {
    let serving = web_top(entries);
    entries
        .iter()
        .filter(|entry| entry.on)
        .map(|entry| match &entry.code {
            Some(code) => ActiveLayer {
                name: entry.name().to_owned(),
                kind: code.kind.as_str(),
                pr: (code.kind == CodeKind::Pr).then_some(code.pr),
                source: Some(code.source_label()),
                head: Some(code.head.chars().take(7).collect()),
                web: code.has_web() && serving.is_some_and(|top| top.same_source(code)),
                note: code.note.clone(),
            },
            None => ActiveLayer {
                name: entry.name().to_owned(),
                kind: match (entry.profile.settings.is_empty(), entry.profile.files.is_empty()) {
                    (false, false) => "settings+files",
                    (false, true) => "settings",
                    (true, false) => "files",
                    (true, true) => "empty",
                },
                pr: None,
                source: None,
                head: None,
                web: false,
                note: String::new(),
            },
        })
        .collect()
}

/// `customize: 2 on: pr-43496 @dbb1e3e (web), theme-dusk`.
pub fn summary_line(on: &[ActiveLayer], unreadable: bool, stray_overlay: bool) -> String {
    let mut line = if unreadable {
        "customize: library unreadable (`cmux customize library reset`)".to_owned()
    } else if on.is_empty() {
        "customize: 0 on".to_owned()
    } else {
        let names: Vec<String> = on
            .iter()
            .map(|layer| match (&layer.head, layer.kind) {
                (Some(head), _) => {
                    format!(
                        "{} @{head} ({})",
                        layer.name,
                        if layer.web { "web" } else { "overridden" }
                    )
                }
                _ => layer.name.clone(),
            })
            .collect();
        format!("customize: {} on: {}", on.len(), names.join(", "))
    };
    if stray_overlay {
        line.push_str(
            "; web-dev.json serves a layer no entry has on (`cmux customize library off --code`)",
        );
    }
    line
}
