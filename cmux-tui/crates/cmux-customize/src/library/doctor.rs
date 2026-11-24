//! The doctor: every file or layer that changes your customization in a way
//! you may not expect, found on its own and said in one place (Leo,
//! 2026-11-19: "cmux for themes customizations and whatnot if there's errant
//! files etc that affect customizations it should be able to automatically
//! tell the user and inform them").
//!
//! ```text
//! layer-on         a pr, branch, sha, dir or fork layer that is on
//! web-dev-overlay  a web-dev.json overlay put there by hand that is on
//! old-build        a layer the app refuses (another web ABI), or one already in your build
//! broken           a file that does not load, or a theme the settings name that is not there
//! ignored          a file or key cmux skips (themes/x.jsonc, a key a theme may not set)
//! shadowed         a value another file or layer overrides
//! leftover         a layer folder no entry uses, or a web-dev.json overlay left by a cut-short write
//! unknown-key      a key no setting or migration recognizes
//! wrong-folder     a customization file where cmux does not look for it
//! override         a file outside the usual settings that still changes cmux (cmux-tui.json, harnesses, ...)
//! ```
//!
//! The doctor only reads. A finding names its fixes (turn off, remove, open)
//! and each runs only when someone asks for it ([`Customize::doctor_fix`]):
//! a removal moves the file into `<state dir>/doctor/removed/<ms>/`, never
//! deletes it. What was already announced, and what the person dismissed,
//! is kept by fingerprint in `<state dir>/doctor.json`, so a finding that
//! changes is new again.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use cmux_config::{Schema, jsonc, theme_file};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::code::{CodeKind, WebBase, WebTarget};
use super::expire::{Expiry, MAX_AGE_MS};
use super::overlay::age;
use super::web_top;
use crate::tree::{self, SETTINGS, STYLE_SURFACES};
use crate::{Customize, Error, validate};

mod defaults;
mod recover;
mod scan;
mod stray;
pub use recover::{RecoverPlan, Recovery};
use scan::{
    dir_bytes, dir_names, display_dir, display_path, file_name, line_of_key, looks_like_theme,
    sentence, size_words, unknown_keys,
};

const STATE: &str = "doctor.json";
const REMOVED: &str = "doctor/removed";
/// The most findings one report holds: past it the rest are one line.
pub const MAX_FINDINGS: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FindingKind {
    LayerOn,
    WebDevOverlay,
    OldBuild,
    Broken,
    Ignored,
    Shadowed,
    Leftover,
    UnknownKey,
    WrongFolder,
    Override,
    NotDefault,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    /// It changes what you see now.
    Warning,
    Info,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FixKind {
    /// Turn the layer or overlay off: `library off`, or web-dev.json's `enabled: false`.
    Off,
    /// Move the file or folder into `<state dir>/doctor/removed/`.
    Remove,
    /// The host opens `path`; no CLI verb.
    Open,
    /// Put back the file's newest version a generation holds that loads
    /// ([`recover`]); the broken one is moved aside first.
    Restore,
    /// Take the setting out of the settings file, so its default applies.
    #[serde(rename = "follow-default")]
    FollowDefault,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fix {
    pub kind: FixKind,
    pub label: &'static str,
    /// Asked first: every removal.
    pub confirm: bool,
}

impl Fix {
    fn off() -> Fix {
        Fix { kind: FixKind::Off, label: "Turn off", confirm: false }
    }
    fn remove() -> Fix {
        Fix { kind: FixKind::Remove, label: "Remove", confirm: true }
    }
    fn open(folder: bool) -> Fix {
        Fix { kind: FixKind::Open, label: if folder { "Show" } else { "Open" }, confirm: false }
    }
    fn restore() -> Fix {
        Fix { kind: FixKind::Restore, label: "Restore last good", confirm: true }
    }
}

/// One thing that changes your customization.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    /// `kind:subject`, stable while the subject is there.
    pub id: String,
    pub kind: FindingKind,
    pub level: Level,
    /// One short line: what it is.
    pub title: String,
    /// What it changes, and what cmux does about it.
    pub detail: String,
    /// Where, as a person says it: `themes/night.json:3`, `Customization Library`.
    pub place: String,
    /// The file or folder on disk, when there is one.
    pub path: Option<String>,
    pub line: Option<u32>,
    /// The first is the main one.
    pub fixes: Vec<Fix>,
    /// Changes when the finding does: a dismissed or announced one comes back.
    pub fingerprint: String,
    pub dismissed: bool,
}

/// What the doctor found.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Report {
    /// Warnings first, then by kind and id.
    pub findings: Vec<Finding>,
    /// `2 customization problems: pr-45206 is still on; ...`; `None` when
    /// nothing that is not dismissed is left.
    pub line: Option<String>,
    /// With `announce`: the line for the findings not announced before.
    pub announce: Option<String>,
    /// Back to a setup that loads, in one step ([`Customize::doctor_recover`]);
    /// `None` when there is nothing to recover from.
    pub recover: Option<RecoverPlan>,
}

/// What a fix did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Fixed {
    pub id: String,
    pub kind: FixKind,
    /// Where a removed file or folder was moved to.
    pub kept: Option<String>,
    pub said: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct State {
    /// id to fingerprint.
    #[serde(default)]
    announced: BTreeMap<String, String>,
    #[serde(default)]
    dismissed: BTreeMap<String, String>,
    /// For each setting the person sets, the default when the doctor first
    /// saw it set: a default that changes since is said ([`defaults`]).
    #[serde(default)]
    seen_defaults: BTreeMap<String, Value>,
}

impl Customize {
    /// Everything that changes your customization in a way you may not
    /// expect. Reads only; `app_abi` is the web ABI of the app's own pages.
    pub fn doctor(&self, expiry: &Expiry) -> Report {
        let mut findings = self.findings(expiry);
        let state = self.read_doctor_state();
        for finding in &mut findings {
            finding.dismissed =
                state.dismissed.get(&finding.id).is_some_and(|print| *print == finding.fingerprint);
        }
        let line = line_of(findings.iter().filter(|finding| !finding.dismissed));
        Report { findings, line, announce: None, recover: self.recover_plan(expiry) }
    }

    /// [`Customize::doctor`], and records every finding as announced:
    /// `announce` says only the ones that are new or changed since.
    pub fn doctor_announce(&self, expiry: &Expiry) -> Result<Report, Error> {
        let mut report = self.doctor(expiry);
        let mut state = self.read_doctor_state();
        report.announce = line_of(report.findings.iter().filter(|finding| {
            !finding.dismissed && state.announced.get(&finding.id) != Some(&finding.fingerprint)
        }));
        let announced: BTreeMap<String, String> = report
            .findings
            .iter()
            .map(|finding| (finding.id.clone(), finding.fingerprint.clone()))
            .collect();
        let seen = self.note_defaults(&state.seen_defaults);
        if announced != state.announced || seen != state.seen_defaults {
            state.announced = announced;
            state.seen_defaults = seen;
            self.write_doctor_state(&state)?;
        }
        Ok(report)
    }

    /// Hides finding `id` until it changes.
    pub fn doctor_dismiss(&self, id: &str, expiry: &Expiry) -> Result<Report, Error> {
        let finding = self.finding(id, expiry)?;
        let mut state = self.read_doctor_state();
        state.dismissed.insert(finding.id, finding.fingerprint);
        // A finding that is gone keeps nothing here.
        let ids: BTreeSet<String> = self.findings(expiry).into_iter().map(|f| f.id).collect();
        state.dismissed.retain(|id, _| ids.contains(id));
        self.write_doctor_state(&state)?;
        Ok(self.doctor(expiry))
    }

    /// Runs finding `id`'s fix `kind` (it must offer it).
    pub fn doctor_fix(
        &self,
        id: &str,
        kind: FixKind,
        expiry: &Expiry,
        origin: &str,
    ) -> Result<Fixed, Error> {
        let finding = self.finding(id, expiry)?;
        if kind == FixKind::Open || !finding.fixes.iter().any(|fix| fix.kind == kind) {
            return Err(Error::Library(format!(
                "{id} has no {} fix; it offers {}",
                kind_word(kind),
                finding.fixes.iter().map(|fix| kind_word(fix.kind)).collect::<Vec<_>>().join(", ")
            )));
        }
        let full = finding.id.clone();
        let (what, subject) = full.split_once(':').unwrap_or((full.as_str(), ""));
        let web_dev = subject == super::code::WEB_DEV;
        match (kind, what) {
            (FixKind::Off, "layer-on" | "old-build") if !web_dev => {
                self.library_set_on(subject, false, origin, expiry.now_ms)?;
                Ok(Fixed {
                    id: finding.id,
                    kind,
                    kept: None,
                    said: format!("{subject} is off; back: cmux customize library on {subject}"),
                })
            }
            (FixKind::Off, "web-dev-overlay" | "old-build" | "broken") if web_dev => {
                let off = WebBase {
                    overlay: self.overlay_value(),
                    enabled: Some(Value::Bool(false)),
                    no_file: false,
                    text: None,
                };
                self.write_web_dev(&WebTarget::Base, &off)?;
                Ok(Fixed {
                    id: finding.id,
                    kind,
                    kept: None,
                    said: "the web-dev.json overlay is off; the app shows its own pages".to_owned(),
                })
            }
            (FixKind::Off, "leftover") if web_dev => {
                let (now, _) =
                    super::code::read_object(&self.roots().config_dir.join(super::code::WEB_DEV))?;
                let keep = WebBase {
                    overlay: None,
                    enabled: now.get("enabled").cloned(),
                    no_file: false,
                    text: None,
                };
                self.write_web_dev(&WebTarget::Base, &keep)?;
                Ok(Fixed {
                    id: finding.id,
                    kind,
                    kept: None,
                    said: "web-dev.json no longer names the leftover layer".to_owned(),
                })
            }
            (FixKind::Remove, _) => {
                let path = finding
                    .path
                    .ok_or_else(|| Error::Library(format!("{id} has no file to remove")))?;
                let kept = self.move_aside(Path::new(&path), expiry.now_ms)?;
                Ok(Fixed {
                    id: finding.id,
                    kind,
                    said: format!("moved {path} to {}", kept.display()),
                    kept: Some(kept.display().to_string()),
                })
            }
            (FixKind::FollowDefault, "not-default") => {
                let said = self.follow_default(subject, expiry.now_ms)?;
                Ok(Fixed { id: finding.id, kind, kept: None, said })
            }
            (FixKind::Restore, "broken") => {
                let (_, said) = self.restore_file(subject, expiry.now_ms)?;
                Ok(Fixed { id: finding.id, kind, kept: None, said })
            }
            _ => Err(Error::Library(format!("{id} has no {} fix", kind_word(kind)))),
        }
    }

    fn finding(&self, id: &str, expiry: &Expiry) -> Result<Finding, Error> {
        self.findings(expiry).into_iter().find(|finding| finding.id == id).ok_or_else(|| {
            Error::Library(format!(
                "no finding {id:?} now; `cmux customize doctor` lists what there is"
            ))
        })
    }

    fn findings(&self, expiry: &Expiry) -> Vec<Finding> {
        let mut out = Found::default();
        self.layer_findings(expiry, &mut out);
        self.file_findings(&mut out);
        self.folder_findings(&mut out);
        self.stray_findings(&mut out);
        self.default_findings(&mut out);
        let mut findings = out.0;
        findings.sort_by(|a, b| (a.level, a.kind, &a.id).cmp(&(b.level, b.kind, &b.id)));
        findings.dedup_by(|a, b| a.id == b.id);
        findings.truncate(MAX_FINDINGS);
        findings
    }

    fn layer_findings(&self, expiry: &Expiry, out: &mut Found) {
        let now = expiry.now_ms;
        let library = match self.read_library() {
            Ok(library) => library,
            Err(error) => {
                let path = self.library_path();
                out.push(
                    FindingKind::Broken,
                    Level::Warning,
                    "library.json",
                    "Your Customization Library does not read".to_owned(),
                    format!(
                        "{error}. Turning entries on and off is refused until it reads; `cmux customize library reset` starts it again."
                    ),
                    "Customization Library".to_owned(),
                    Some(&path),
                    None,
                    vec![Fix::open(false)],
                );
                return;
            }
        };
        let serving = web_top(&library.entries);
        for entry in library.entries.iter().filter(|entry| entry.on) {
            let Some(code) = &entry.code else { continue };
            let name = entry.name();
            let on_for = entry.on_ms.map(|at| age(now.saturating_sub(at)));
            let source = code.source_label();
            let head = code.head.get(..7).unwrap_or(&code.head);
            let serves = serving.is_some_and(|top| top.same(code));
            let refused =
                matches!((code.abi, expiry.app_abi), (Some(want), Some(have)) if want != have);
            let in_build =
                code.note.contains("in your build") || code.note.starts_with("no longer applies");
            if refused || in_build {
                let detail = if refused {
                    format!(
                        "It needs web ABI {} and this app has {}, so the app refuses it and shows its own pages; turning it off ends the mismatch.",
                        code.abi.unwrap_or_default(),
                        expiry.app_abi.unwrap_or_default()
                    )
                } else {
                    format!(
                        "{}: the layer pins {source} @{head} over code your build already has.",
                        code.note
                    )
                };
                out.push(
                    FindingKind::OldBuild,
                    Level::Warning,
                    name,
                    format!("{name} pins an old build"),
                    detail,
                    "Customization Library".to_owned(),
                    None,
                    None,
                    vec![Fix::off()],
                );
                continue;
            }
            let who = match code.kind {
                CodeKind::Pr => format!("PR {source}"),
                _ => source.clone(),
            };
            let pages = if serves {
                format!("It serves {who}'s web pages (@{head}) in place of your build's")
            } else {
                format!("It is on ({source} @{head}) under a higher code layer")
            };
            let mut detail = pages;
            if let Some(on_for) = &on_for {
                detail.push_str(&format!(", on {on_for}"));
            }
            detail.push('.');
            if entry.on_ms.is_some_and(|at| now.saturating_sub(at) > MAX_AGE_MS / 2) {
                detail.push_str(&format!(" It turns off by itself at {}.", age(MAX_AGE_MS)));
            }
            if !code.needs_build.is_empty() {
                detail.push_str(&format!(
                    " Part of it needs a build, so the app runs a mix: {}.",
                    code.needs_build.join("; ")
                ));
            }
            out.push(
                FindingKind::LayerOn,
                Level::Warning,
                name,
                format!("{name} is still on"),
                detail,
                "Customization Library".to_owned(),
                None,
                None,
                vec![Fix::off()],
            );
        }
        // Two entries that are on and set the same key: the lower one's value is not used.
        if let Ok(listing) = self.library() {
            for conflict in listing.conflicts.iter().filter(|conflict| conflict.kind != "code") {
                out.push(
                    FindingKind::Shadowed,
                    Level::Info,
                    &format!("{}:{}", conflict.kind, conflict.key),
                    format!("{} overrides {}", conflict.winner, conflict.losers.join(", ")),
                    format!(
                        "Both set {}; {} is higher in your Customization Library, so its value is the one in use.",
                        conflict.key, conflict.winner
                    ),
                    "Customization Library".to_owned(),
                    None,
                    None,
                    Vec::new(),
                );
            }
        }
        // web-dev.json: a hand-installed overlay, or one a cut-short write left.
        if let Some(overlay) = self.overlay(expiry.app_abi) {
            let path = PathBuf::from(&overlay.path);
            if overlay.library {
                let used = serving.is_some_and(|code| self.layer_dir(&code.web) == path);
                if !used && overlay.enabled {
                    out.push(
                        FindingKind::Leftover,
                        Level::Warning,
                        "web-dev.json",
                        "web-dev.json serves a layer no entry uses".to_owned(),
                        format!(
                            "It names {} from a layer that is off or gone, so the app serves that code in place of your build's.",
                            overlay.path
                        ),
                        "web-dev.json".to_owned(),
                        Some(&self.roots().config_dir.join(super::code::WEB_DEV)),
                        None,
                        vec![Fix::off(), Fix::open(false)],
                    );
                }
            } else if overlay.enabled {
                let commit =
                    overlay.commit.as_deref().map_or("unknown", |c| c.get(..8).unwrap_or(c));
                let installed = overlay
                    .installed_ms
                    .map(|at| format!(", installed {} ago", age(now.saturating_sub(at))))
                    .unwrap_or_default();
                let (kind, title, detail) = if overlay.refused {
                    (
                        FindingKind::OldBuild,
                        "A web-dev overlay pins an old build".to_owned(),
                        format!(
                            "web-dev.json names {} (@{commit}{installed}). It needs web ABI {} and this app has {}, so the app refuses it.",
                            overlay.path,
                            overlay.abi.unwrap_or_default(),
                            overlay.app_abi.unwrap_or_default()
                        ),
                    )
                } else if !overlay.installed {
                    (
                        FindingKind::Broken,
                        "The web-dev overlay is not there".to_owned(),
                        format!(
                            "web-dev.json names {}, which has no manifest.json, so the app cannot serve it.",
                            overlay.path
                        ),
                    )
                } else {
                    (
                        FindingKind::WebDevOverlay,
                        "A web-dev overlay is on".to_owned(),
                        format!(
                            "web-dev.json serves {} (@{commit}{installed}) in place of your build's web pages. It was put there by hand, so it is not in your Customization Library.",
                            overlay.path
                        ),
                    )
                };
                out.push(
                    kind,
                    Level::Warning,
                    "web-dev.json",
                    title,
                    detail,
                    "web-dev.json".to_owned(),
                    Some(&self.roots().config_dir.join(super::code::WEB_DEV)),
                    None,
                    vec![Fix::off(), Fix::open(false)],
                );
            }
        }
        // Layer folders no entry uses: what a removed layer left on disk.
        let used: BTreeSet<String> = library
            .entries
            .iter()
            .filter_map(|entry| entry.code.as_ref())
            .map(|code| code.web.clone())
            .collect();
        let overlay = self.overlay_value().and_then(|value| value.as_str().map(PathBuf::from));
        let layers = self.roots().state_dir.join("layers");
        for name in dir_names(&layers) {
            let path = layers.join(&name);
            if used.contains(&name) || !path.is_dir() || overlay.as_deref() == Some(path.as_path())
            {
                continue;
            }
            let bytes = dir_bytes(&path, 4000);
            out.push(
                FindingKind::Leftover,
                Level::Info,
                &format!("layers/{name}"),
                format!("Layer folder {name} is left over"),
                format!(
                    "No entry in your Customization Library uses it ({}). It changes nothing you see; it takes disk space.",
                    size_words(bytes)
                ),
                format!("layers/{name}"),
                Some(&path),
                None,
                vec![Fix::remove(), Fix::open(true)],
            );
        }
    }

    fn file_findings(&self, out: &mut Found) {
        let roots = self.roots();
        let Ok(scan) = tree::scan(roots) else { return };
        let mut bytes = BTreeMap::new();
        for path in scan.tree.keys() {
            if let Ok(Some(content)) = tree::read(roots, path) {
                bytes.insert(path.clone(), content);
            }
        }
        for problem in validate::problems(&bytes) {
            let place = match problem.line {
                Some(line) => format!("{}:{line}", problem.path),
                None => problem.path.clone(),
            };
            let keeps = match problem.path.as_str() {
                SETTINGS => {
                    "cmux keeps the last settings that loaded, and a refused value its default."
                }
                "keybindings.json" => "cmux keeps the shortcuts that loaded last.",
                _ => "cmux keeps showing the last version that loaded.",
            };
            out.push(
                FindingKind::Broken,
                Level::Warning,
                &problem.path,
                format!("{} does not load", display_path(&problem.path, roots)),
                format!("{}. {keeps}", sentence(&problem.message)),
                place,
                tree::locate(roots, &problem.path).as_deref(),
                problem.line,
                match self.last_good_version(&problem.path) {
                    Some(_) => vec![Fix::restore(), Fix::open(false)],
                    None => vec![Fix::open(false)],
                },
            );
        }
        for skipped in &scan.skipped {
            out.push(
                FindingKind::Ignored,
                Level::Info,
                &skipped.path,
                format!("{} is skipped", skipped.path),
                format!(
                    "cmux keeps no copy of it ({}), so undo and roll back leave it as it is.",
                    skipped.reason
                ),
                skipped.path.clone(),
                tree::locate(roots, &skipped.path).as_deref(),
                None,
                vec![Fix::open(false)],
            );
        }
        let settings_text = bytes
            .get(SETTINGS)
            .and_then(|bytes| std::str::from_utf8(bytes).ok())
            .map(str::to_owned);
        let settings = settings_text.as_deref().and_then(|text| jsonc::parse(text).ok());
        if let (Some(text), Some(Value::Object(object))) = (settings_text.as_deref(), &settings) {
            let file = &roots.settings_file;
            for key in unknown_keys(object) {
                let line = line_of_key(text, &key);
                out.push(
                    FindingKind::UnknownKey,
                    Level::Info,
                    &key,
                    format!("{key} is not a setting"),
                    "cmux ignores this key. Check its spelling in the settings file.".to_owned(),
                    match line {
                        Some(line) => format!("{}:{line}", file_name(file)),
                        None => file_name(file),
                    },
                    Some(file),
                    line,
                    vec![Fix::open(false)],
                );
            }
        }
        // The theme the settings name: missing, keys it may not set, and keys
        // it takes over from the settings file.
        let Some(root) = settings.as_ref() else { return };
        let Some(name) = theme_file::name_in(root) else { return };
        let source = theme_file::source(&roots.config_dir, name, None);
        let theme_path = theme_file::path(&roots.config_dir, name);
        let logical = format!("themes/{name}.json");
        if source.is_none() {
            out.push(
                FindingKind::Broken,
                Level::Warning,
                &logical,
                format!("Theme {name} is not there"),
                format!(
                    "appearance.themeFile names {name}, and {} has no {name}.json, so no theme file applies.",
                    display_dir(&theme_file::folder(&roots.config_dir), roots)
                ),
                file_name(&roots.settings_file),
                Some(&roots.settings_file),
                settings_text.as_deref().and_then(|text| line_of_key(text, theme_file::SETTING_KEY)),
                vec![Fix::open(false)],
            );
            return;
        }
        if !theme_path.is_file() {
            return; // a theme cmux ships: nothing of yours to look at
        }
        let Some(Ok(text)) = source else { return };
        let theme = theme_file::ThemeFile::read(
            name,
            Some(Ok(text.as_str())),
            root,
            Some(&theme_file::folder(&roots.config_dir)),
            Schema::embedded(),
            &Default::default(),
        );
        if theme.is_unparsable {
            return; // validate already said it does not load
        }
        for diagnostic in theme.diagnostics.iter().filter(|d| {
            d.kind == theme_file::ThemeDiagnosticKind::InvalidValue && !d.path.is_empty()
        }) {
            out.push(
                FindingKind::Ignored,
                Level::Info,
                &format!("{logical}#{}", diagnostic.path),
                format!("{logical} sets {} and cmux skips it", diagnostic.path),
                format!("{}. The rest of the theme still applies.", sentence(&diagnostic.message)),
                match diagnostic.line {
                    Some(line) => format!("{logical}:{line}"),
                    None => logical.clone(),
                },
                Some(&theme_path),
                diagnostic.line.map(|line| line as u32),
                vec![Fix::open(false)],
            );
        }
        let theme_keys: BTreeSet<String> = theme.keys().into_iter().collect();
        if let Some(text) = settings_text.as_deref() {
            for key in theme_keys.iter().filter(|key| {
                cmux_config::value::value_at(root, &cmux_config::keypath::key_path(key)).is_some()
            }) {
                out.push(
                    FindingKind::Shadowed,
                    Level::Info,
                    &format!("theme:{key}"),
                    format!("Theme {name} overrides your {key}"),
                    format!(
                        "{} sets {key} and so does {logical}; the theme applies over your settings, so your value is not used.",
                        file_name(&roots.settings_file)
                    ),
                    match line_of_key(text, key) {
                        Some(line) => format!("{}:{line}", file_name(&roots.settings_file)),
                        None => file_name(&roots.settings_file),
                    },
                    Some(&roots.settings_file),
                    line_of_key(text, key),
                    vec![Fix::open(false)],
                );
            }
        }
    }

    fn overlay_value(&self) -> Option<Value> {
        let (object, _) =
            super::code::read_object(&self.roots().config_dir.join(super::code::WEB_DEV)).ok()?;
        object.get("overlay").cloned()
    }

    /// Moves `path` (a file or folder this customization holds) into
    /// `<state dir>/doctor/removed/<ms>/`, keeping its name.
    fn move_aside(&self, path: &Path, now_ms: u64) -> Result<PathBuf, Error> {
        let roots = self.roots();
        let inside = [&roots.config_dir, &roots.customize_dir, &roots.state_dir]
            .iter()
            .any(|root| path.starts_with(root) && path != root.as_path());
        if !inside || path.components().any(|part| part == std::path::Component::ParentDir) {
            return Err(Error::Library(format!("{} is not in your customization", path.display())));
        }
        let kept = self.kept_path(path, now_ms)?;
        std::fs::rename(path, &kept)?;
        Ok(kept)
    }

    /// Writes `bytes` (what `path` holds now) into `<state dir>/doctor/removed/<ms>/`.
    fn keep_copy(&self, path: &Path, bytes: &[u8], now_ms: u64) -> Result<PathBuf, Error> {
        let kept = self.kept_path(path, now_ms)?;
        std::fs::write(&kept, bytes)?;
        Ok(kept)
    }

    /// A new place for `path`'s copy under `<state dir>/doctor/removed/<ms>/`, keeping its name;
    /// a second copy in the same millisecond gets `-2`, `-3`, ... so none overwrites another.
    fn kept_path(&self, path: &Path, now_ms: u64) -> Result<PathBuf, Error> {
        let name = path
            .file_name()
            .ok_or_else(|| Error::Library("nothing to keep".to_owned()))?
            .to_string_lossy()
            .into_owned();
        let folder = self.roots().state_dir.join(REMOVED).join(now_ms.to_string());
        std::fs::create_dir_all(&folder)?;
        let mut kept = folder.join(&name);
        let mut n = 2;
        while std::fs::symlink_metadata(&kept).is_ok() {
            kept = folder.join(format!("{name}-{n}"));
            n += 1;
        }
        Ok(kept)
    }

    fn read_doctor_state(&self) -> State {
        std::fs::read(self.roots().state_dir.join(STATE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn write_doctor_state(&self, state: &State) -> Result<(), Error> {
        std::fs::create_dir_all(&self.roots().state_dir)?;
        let mut text = serde_json::to_string_pretty(state).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&self.roots().state_dir.join(STATE), text.as_bytes())?;
        Ok(())
    }
}

/// Top-level files cmux or its tools read, or that hold credentials: never named stray, and
/// never opened unless the doctor reads them for what they set (cmux-tui.json, cmux.json, ...).
pub(super) const KNOWN_TOP_FILES: &[&str] = &[
    "cmux-next.json",
    "cmux.json",
    "keybindings.json",
    "web-dev.json",
    "web-dev.json.unreadable",
    "settings.json",
    "cmux-tui.json",
    "mux.json",
    "host-budget.json",
    "server.json",
    "cloud-secrets.json",
    "keys.json",
    "auth.json",
    "vm.json",
];

/// A name that may hold a credential: the doctor never opens it.
pub(super) fn secret_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    ["secret", "token", "key", "auth", "credential", "password", "passwd", ".env"]
        .iter()
        .any(|word| lower.contains(word))
}

#[derive(Default)]
struct Found(Vec<Finding>);

impl Found {
    #[allow(clippy::too_many_arguments)]
    fn push(
        &mut self,
        kind: FindingKind,
        level: Level,
        subject: &str,
        title: String,
        detail: String,
        place: String,
        path: Option<&Path>,
        line: Option<u32>,
        fixes: Vec<Fix>,
    ) {
        let id = format!("{}:{subject}", kind_name(kind));
        let path = path.map(|path| path.display().to_string());
        let fingerprint = tree::sha256(format!("{id}\n{title}\n{detail}\n{place}").as_bytes())
            .get(..16)
            .unwrap_or_default()
            .to_owned();
        self.0.push(Finding {
            id,
            kind,
            level,
            title,
            detail,
            place,
            path,
            line,
            fixes,
            fingerprint,
            dismissed: false,
        });
    }
}

fn kind_name(kind: FindingKind) -> &'static str {
    match kind {
        FindingKind::LayerOn => "layer-on",
        FindingKind::WebDevOverlay => "web-dev-overlay",
        FindingKind::OldBuild => "old-build",
        FindingKind::Broken => "broken",
        FindingKind::Ignored => "ignored",
        FindingKind::Shadowed => "shadowed",
        FindingKind::Leftover => "leftover",
        FindingKind::UnknownKey => "unknown-key",
        FindingKind::WrongFolder => "wrong-folder",
        FindingKind::Override => "override",
        FindingKind::NotDefault => "not-default",
    }
}

fn kind_word(kind: FixKind) -> &'static str {
    match kind {
        FixKind::Off => "off",
        FixKind::Remove => "remove",
        FixKind::Open => "open",
        FixKind::Restore => "restore",
        FixKind::FollowDefault => "follow-default",
    }
}

/// `off` or `remove`, as the CLI takes it.
pub fn fix_kind(word: &str) -> Option<FixKind> {
    match word {
        "off" => Some(FixKind::Off),
        "remove" | "rm" => Some(FixKind::Remove),
        "restore" => Some(FixKind::Restore),
        "default" | "follow-default" => Some(FixKind::FollowDefault),
        _ => None,
    }
}

/// `2 customization problems: a; b`, or one: `Customization: a`.
fn line_of<'a>(findings: impl Iterator<Item = &'a Finding>) -> Option<String> {
    let findings: Vec<&Finding> = findings.collect();
    let warnings: Vec<&&Finding> = findings.iter().filter(|f| f.level == Level::Warning).collect();
    let shown: Vec<&str> = if warnings.is_empty() {
        findings.iter().take(2).map(|f| f.title.as_str()).collect()
    } else {
        warnings.iter().take(2).map(|f| f.title.as_str()).collect()
    };
    let first = *shown.first()?;
    let rest = findings.len() - shown.len();
    let mut line = if findings.len() == 1 {
        format!("Customization: {first}")
    } else {
        format!("{} things change your customization: {}", findings.len(), shown.join("; "))
    };
    if rest > 0 {
        line.push_str(&format!(" and {rest} more"));
    }
    Some(line)
}
