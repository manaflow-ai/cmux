//! `cmux setup check DIR`: everything `cmux setup install` would refuse in a
//! setup folder, and what it would only warn about, read offline. It reads
//! the folder and nothing else: no daemon, no network, no write, and not the
//! person's own customization (so a check passes or fails the same on every
//! machine with this cmux).
//!
//! Install stops at the first problem; the check reports every one. Both run
//! the same collectors ([`Finding`] lists), so a folder the check passes is a
//! folder install accepts, and install's message is the first error here.

use std::collections::BTreeMap;
use std::path::Path;

use cmux_config::{Domains, Schema, ThemeDiagnosticKind, ThemeFile, theme_file};
use serde::Serialize;
use serde_json::Value;

use super::{Manifest, SETUP_FILE, Setup, read_parts};
use crate::tree::Part;
use crate::{Error, Roots, validate};

/// The version of the [`Report`] shape.
pub const SCHEMA_VERSION: u32 = 1;

/// The stable codes a finding carries. A caller matches on these, never on
/// the message.
pub mod codes {
    /// No `cmux-setup.json`, or one that is not JSON or not a setup.
    pub const SETUP_UNREADABLE: &str = "setup.unreadable";
    /// A setup or profile format this cmux does not read.
    pub const SETUP_FORMAT: &str = "setup.format";
    /// The id is not `OWNER/NAME` in lowercase, or names another owner.
    pub const SETUP_ID: &str = "setup.id";
    /// `engines.cmux` asks for a newer cmux, or cannot be read.
    pub const SETUP_ENGINES: &str = "setup.engines";
    /// A name, description, path or file holds a hidden character.
    pub const HIDDEN_TEXT: &str = "text.hidden";
    /// Too many extensions, or one that is not a reference.
    pub const EXTENSION: &str = "setup.extension";
    /// A file in the folder install does not take (a link, too large, not
    /// text, both inline and in the repo, too many in one folder).
    pub const FILE_UNREADABLE: &str = "file.unreadable";
    /// A file at a path a setup may not write.
    pub const FILE_PLACE: &str = "file.place";
    /// A file the validator cmux runs at apply refuses.
    pub const FILE_INVALID: &str = "file.invalid";
    /// A setting this cmux does not have.
    pub const SETTING_UNKNOWN: &str = "setting.unknown";
    /// A setting only the person may change.
    pub const SETTING_PRIVATE: &str = "setting.private";
    /// A value the setting's row does not accept.
    pub const SETTING_VALUE: &str = "setting.value";
    /// A setting key the settings history renames or retires
    /// ([`super::SettingsHistory`]); a warning while install still takes it.
    pub const SETTING_DEPRECATED: &str = "setting.deprecated";
    /// The views app manifest (`customize/cmux-app.json`): an error from the
    /// manifest validator is [`FILE_INVALID`]; this is one of its warnings.
    pub const MANIFEST_WARNING: &str = "manifest.warning";
    /// A theme file is not a JSON object, or has a name a theme cannot have.
    pub const THEME_UNREADABLE: &str = "theme.unreadable";
    /// A theme file key or value the theme reader refuses.
    pub const THEME_VALUE: &str = "theme.value";
    /// A theme color the contrast guard raises (it applies, changed).
    pub const THEME_CORRECTED: &str = "theme.corrected";
    /// `appearance.themeFile` names a theme the setup does not carry and
    /// cmux does not ship.
    pub const THEME_MISSING: &str = "theme.missing";
    /// An action that is not a command or an agent cmux reads.
    pub const ACTION_INVALID: &str = "action.invalid";
    /// Something that looks like a credential.
    pub const SECRET: &str = "secret.found";
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    /// Install refuses the setup, or cmux leaves that part out when it loads
    /// it (a theme key the theme reader refuses, a theme that is not there).
    Error,
    /// Install takes it and it loads; something in it will not do what it
    /// says (a color the contrast guard raises, an `engines.cmux` no cmux reads).
    Warning,
}

/// One problem in a setup folder.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub severity: Severity,
    /// One of [`codes`].
    pub code: &'static str,
    /// The repo-relative file it is in (`cmux-setup.json` for the header,
    /// its settings and actions).
    pub path: String,
    /// The setting, theme key, action or JSON pointer it is about.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    /// What is wrong. Never quotes a refused value (it may be a credential).
    pub message: String,
    /// What to change, when there is one thing to say.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

impl Finding {
    pub fn error(code: &'static str, path: impl Into<String>, message: impl Into<String>) -> Self {
        Finding {
            severity: Severity::Error,
            code,
            path: path.into(),
            key: None,
            line: None,
            message: message.into(),
            fix: None,
        }
    }

    pub fn warning(
        code: &'static str,
        path: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Finding { severity: Severity::Warning, ..Finding::error(code, path, message) }
    }

    pub fn key(mut self, key: impl Into<String>) -> Self {
        self.key = Some(key.into());
        self
    }

    pub fn fix(mut self, fix: impl Into<String>) -> Self {
        self.fix = Some(fix.into());
        self
    }

    fn line(mut self, line: Option<u32>) -> Self {
        self.line = line;
        self
    }

    pub fn is_error(&self) -> bool {
        self.severity == Severity::Error
    }
}

/// The first error in `findings`, as the error install returns.
pub(crate) fn first_error(
    findings: Vec<Finding>,
    wrap: impl Fn(String) -> Error,
) -> Result<(), Error> {
    match findings.into_iter().find(Finding::is_error) {
        Some(finding) => Err(wrap(finding.message)),
        None => Ok(()),
    }
}

/// A checks that did not run, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Skipped {
    pub check: &'static str,
    pub why: String,
}

/// What `cmux setup check` prints with `--json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Report {
    pub schema_version: u32,
    /// The id the header names; `None` when the header does not read.
    pub setup_id: Option<String>,
    /// No error: install takes it (warnings allowed).
    pub ok: bool,
    /// Every finding, errors and warnings, in the order install checks.
    pub findings: Vec<Finding>,
    /// Checks this cmux cannot run on this setup.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<Skipped>,
}

impl Report {
    pub fn errors(&self) -> usize {
        self.findings.iter().filter(|finding| finding.is_error()).count()
    }

    pub fn warnings(&self) -> usize {
        self.findings.len() - self.errors()
    }
}

/// What a setting key used to be, from the settings history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Deprecated {
    /// The key it became; `None` when it is gone.
    pub replacement: Option<String>,
    /// Why, or since when, in a few words.
    pub note: String,
}

/// The settings keys cmux renamed or retired over time. The check asks it
/// about every key a setup sets; [`NoHistory`] knows none. The migration
/// table (`schemas/settings/migrations.json`) plugs in here.
pub trait SettingsHistory {
    fn deprecated(&self, key: &str) -> Option<Deprecated>;
}

/// The keys cmux retired (`schemas/settings/retired-keys.json`, which
/// cmux-config embeds): a retired key is deprecated, and the row that took
/// its place (`replaced_by`) is the fix.
pub struct RetiredKeys;

impl SettingsHistory for RetiredKeys {
    fn deprecated(&self, key: &str) -> Option<Deprecated> {
        let path: Vec<String> = key.split('.').map(str::to_owned).collect();
        let reason = cmux_config::schema::retired_reason(&path)?;
        let replacement = cmux_config::schema::replaced_keys()
            .iter()
            .find(|replaced| replaced.old == path)
            .map(|replaced| replaced.row.join("."));
        Some(Deprecated { replacement, note: format!("cmux retired it: {reason}") })
    }
}

/// A history with no entries.
pub struct NoHistory;

impl SettingsHistory for NoHistory {
    fn deprecated(&self, _key: &str) -> Option<Deprecated> {
        None
    }
}

/// What the check is run against.
pub struct CheckOptions<'a> {
    /// The repo's owner (the id rule). `None`: the owner the header's
    /// `repository` names, else the id's own first part.
    pub owner: Option<&'a str>,
    /// This cmux's version (`engines.cmux`).
    pub running: &'a str,
    pub history: &'a dyn SettingsHistory,
}

/// Checks the setup folder `dir`, reading only it.
pub fn check_dir(dir: &Path, options: &CheckOptions) -> Report {
    let mut findings = Vec::new();
    let read = match read_parts(dir, &mut findings) {
        Ok(read) => read,
        Err(finding) => {
            findings.push(*finding);
            return report(None, findings);
        }
    };
    let manifest = &read.manifest;
    let owner = options
        .owner
        .map(str::to_owned)
        .or_else(|| repository_owner(manifest))
        .unwrap_or_else(|| manifest.id.split('/').next().unwrap_or_default().to_owned());
    findings.extend(super::header_findings(manifest, &owner, options.running));
    if engine_unreadable(manifest.engines.cmux.as_deref()) {
        findings.push(
            Finding::warning(
                codes::SETUP_ENGINES,
                SETUP_FILE,
                "engines.cmux is not a version cmux reads, so every cmux installs it",
            )
            .key("engines.cmux")
            .fix("write the oldest cmux it works on as >=X.Y.Z"),
        );
    }
    findings.extend(setup_findings(&read, options.history));
    findings.extend(file_findings(dir, &read));
    report(Some(manifest.id.clone()), findings)
}

fn report(setup_id: Option<String>, findings: Vec<Finding>) -> Report {
    Report {
        schema_version: SCHEMA_VERSION,
        setup_id,
        ok: !findings.iter().any(Finding::is_error),
        findings,
        skipped: vec![Skipped {
            check: "agent-pane.tokens",
            why: "this cmux has no list of agent pane style tokens, so agent-pane/theme.css is checked only for hidden characters and secrets".to_owned(),
        }],
    }
}

fn repository_owner(manifest: &Manifest) -> Option<String> {
    let repository = manifest.repository.as_deref()?;
    super::Reference::parse(repository).ok().map(|reference| reference.owner)
}

fn engine_unreadable(required: Option<&str>) -> bool {
    required.is_some_and(|required| {
        super::version(required.trim_start_matches(['>', '=', '^', '~', ' ', 'v'])).is_none()
    })
}

/// What install's `check_setup` refuses, and the settings history.
fn setup_findings(setup: &Setup, history: &dyn SettingsHistory) -> Vec<Finding> {
    // The profile's place rule reads no folder: any roots give the same answer.
    let roots = Roots::under(Path::new("/"));
    let mut findings = crate::profile::profile_findings(&roots, &setup.profile);
    for key in setup.profile.settings.keys() {
        let Some(deprecated) = history.deprecated(key) else { continue };
        let fix = match &deprecated.replacement {
            Some(new) => format!("set {new} instead"),
            None => format!("take {key} out"),
        };
        for finding in findings.iter_mut().filter(|finding| {
            finding.code == codes::SETTING_UNKNOWN && finding.key.as_deref() == Some(key)
        }) {
            finding.fix = Some(fix.clone());
        }
        findings.push(
            Finding::warning(
                codes::SETTING_DEPRECATED,
                SETUP_FILE,
                format!("the setting {key} is deprecated: {}", deprecated.note),
            )
            .key(key.clone())
            .fix(fix),
        );
    }
    findings.extend(super::action_findings(setup.actions()));
    findings.extend(super::secrets::secret_findings(setup));
    findings
}

/// What the validators cmux runs at apply say about the setup's files, read
/// as they are (not merged with anyone's own), and each theme file by the
/// theme reader.
fn file_findings(dir: &Path, setup: &Setup) -> Vec<Finding> {
    let files: BTreeMap<String, Vec<u8>> = setup
        .profile
        .files
        .iter()
        .map(|(path, text)| (path.clone(), text.as_bytes().to_vec()))
        .collect();
    let mut findings = Vec::new();
    let problems = validate::problems(&files);
    for problem in &problems {
        findings.push(
            Finding::error(codes::FILE_INVALID, &problem.path, &problem.message).line(problem.line),
        );
    }
    for (path, text) in &setup.profile.files {
        if Part::of(path) == Part::Views && path.starts_with("customize/cmux-app") {
            findings.extend(manifest_warnings(path, text));
        }
        let Some(name) = path.strip_prefix("themes/").and_then(|rest| rest.strip_suffix(".json"))
        else {
            continue;
        };
        if problems.iter().any(|problem| &problem.path == path) {
            continue;
        }
        findings.extend(theme_findings(dir, path, name, text));
    }
    if let Some(theme) = setup.profile.settings.get(theme_file::SETTING_KEY).and_then(Value::as_str)
        && !theme.is_empty()
        && !setup.profile.files.contains_key(&format!("themes/{theme}.json"))
        && theme_file::shipped(theme).is_none()
    {
        findings.push(
            Finding::error(
                codes::THEME_MISSING,
                SETUP_FILE,
                format!("appearance.themeFile is {theme:?}, and there is no themes/{theme}.json in the setup and no theme of that name in cmux"),
            )
            .key(theme_file::SETTING_KEY)
            .fix(format!("add themes/{theme}.json, or name a theme the setup carries")),
        );
    }
    findings
}

fn manifest_warnings(path: &str, text: &str) -> Vec<Finding> {
    let Ok(manifest) = cmux_config::jsonc::parse(text) else { return Vec::new() };
    cmux_app_manifest::validate_manifest(&manifest)
        .into_iter()
        .filter(|issue| issue.severity == cmux_app_manifest::Severity::Warning)
        .map(|issue| {
            let finding = Finding::warning(
                codes::MANIFEST_WARNING,
                path,
                crate::redact::text(&issue.message),
            );
            if issue.path.is_empty() { finding } else { finding.key(issue.path) }
        })
        .collect()
}

fn theme_findings(dir: &Path, path: &str, name: &str, text: &str) -> Vec<Finding> {
    if !theme_file::is_valid_name(name) {
        return vec![
            Finding::error(
                codes::THEME_UNREADABLE,
                path,
                format!("{name:?} is not a name a theme file can have"),
            )
            .fix("name it with letters, digits, '-' and '_'"),
        ];
    }
    let folder = dir.join(theme_file::FOLDER_NAME);
    let read = ThemeFile::read(
        name,
        Some(Ok(text)),
        &Value::Object(Default::default()),
        Some(&folder),
        Schema::embedded(),
        &Domains::default(),
    );
    read.diagnostics
        .into_iter()
        .map(|diagnostic| {
            let message = crate::redact::text(&diagnostic.message);
            let message = if diagnostic.path.is_empty() {
                message
            } else {
                format!("{}: {message}", diagnostic.path)
            };
            let finding = match diagnostic.kind {
                ThemeDiagnosticKind::UnreadableFile => {
                    Finding::error(codes::THEME_UNREADABLE, path, message)
                }
                ThemeDiagnosticKind::InvalidValue => {
                    Finding::error(codes::THEME_VALUE, path, message)
                }
                ThemeDiagnosticKind::CorrectedValue => {
                    Finding::warning(codes::THEME_CORRECTED, path, message)
                }
            };
            let finding = finding.line(diagnostic.line.map(|line| line as u32));
            if diagnostic.path.is_empty() { finding } else { finding.key(diagnostic.path) }
        })
        .collect()
}

/// The schema key nearest `key` (a typo of one), when one is close.
pub(crate) fn nearest_key(key: &str) -> Option<String> {
    let mut best: Option<(usize, &str)> = None;
    for row in &Schema::embedded().rows {
        let distance = edit_distance(key, &row.key);
        if best.is_none_or(|(least, _)| distance < least) {
            best = Some((distance, &row.key));
        }
    }
    let (distance, found) = best?;
    (distance <= 3.max(key.len() / 8)).then(|| found.to_owned())
}

fn edit_distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut previous = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let here = row[j + 1];
            row[j + 1] = (previous + usize::from(ca != *cb)).min(row[j] + 1).min(here + 1);
            previous = here;
        }
    }
    row[b.len()]
}

#[cfg(test)]
#[path = "check_tests.rs"]
mod tests;
