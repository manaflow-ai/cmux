//! Settings > Skills (Leo 2026-11-08: "the little minor things where it's like ... just because of
//! this, I'm out"): every Agent Skill (`<name>/SKILL.md`) the coding agents cmux runs would load,
//! whether each one is on, turning one on or off the way its harness reads it, and a new skill's
//! scaffold. The wire adapter is server/skills_wire.rs; the page is
//! webviews/src/pages/settings/components/SkillsCard.tsx.
//!
//! Where each harness looks (and what this lists):
//!
//! | harness | scope | folder |
//! | --- | --- | --- |
//! | claude | user | `$CLAUDE_CONFIG_DIR` or `~/.claude`, `skills/*` (and `skills/synced/*`) |
//! | claude | project | `<root>/.claude/skills/*` |
//! | claude | plugin | `<installPath>/skills/*` of each plugin in `plugins/installed_plugins.json` |
//! | codex | user | `~/.agents/skills/*`, and `$CODEX_HOME` or `~/.codex`, `skills/*` |
//! | codex | system | `$CODEX_HOME/skills/.system/*` |
//! | codex | admin | `/etc/codex/skills/*` |
//! | codex | project | `<root>/.agents/skills/*` |
//!
//! On and off: Claude Code reads `skillOverrides` (`"off"` turns a skill off; `"name-only"` and
//! `"user-invocable-only"` keep it on in part) from the user's `settings.json` and a project's
//! `.claude/settings.json` and `.claude/settings.local.json`, and a plugin's skills follow the
//! plugin's `enabledPlugins` entry. Codex reads `[[skills.config]]` rules (`path` or `name`,
//! `enabled`; the last match wins) from `config.toml`. A write keeps the rest of the person's file as
//! it was: a JSON file's other top-level entries keep their order and text, a TOML file keeps its
//! comments, and a file that does not parse is never written (`skills.settings_unreadable`).
//!
//! Cost stays bounded however many skills a machine has: each folder lists at most
//! [`MAX_ENTRIES_PER_FOLDER`] entries, the whole list at most [`MAX_SKILLS`], and only the first
//! [`MAX_HEAD_BYTES`] of a SKILL.md are read for its frontmatter.

use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::value::RawValue;
use serde_json::{Map, Value, json};

/// The most entries one skills folder contributes.
pub(crate) const MAX_ENTRIES_PER_FOLDER: usize = 500;
/// The most skills one list holds.
pub(crate) const MAX_SKILLS: usize = 2000;
/// The most project roots one list looks in.
pub(crate) const MAX_PROJECTS: usize = 32;
/// How much of a SKILL.md is read for its frontmatter.
pub(crate) const MAX_HEAD_BYTES: usize = 64 * 1024;
/// A SKILL.md larger than this is listed with `problem: "too_large"`.
pub(crate) const MAX_SKILL_BYTES: u64 = 1024 * 1024;
const MAX_NAME: usize = 64;
const MAX_DESCRIPTION: usize = 1024;

/// A refusal's wire code (`skills.*`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SkillsError {
    NotFound,
    NotToggleable,
    SettingsUnreadable,
    WriteFailed,
    BadName,
    BadDescription,
    Exists,
    BadScope,
    BadRequest,
}

impl SkillsError {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotFound => "skills.not_found",
            Self::NotToggleable => "skills.not_toggleable",
            Self::SettingsUnreadable => "skills.settings_unreadable",
            Self::WriteFailed => "skills.write_failed",
            Self::BadName => "skills.bad_name",
            Self::BadDescription => "skills.bad_description",
            Self::Exists => "skills.exists",
            Self::BadScope => "skills.bad_scope",
            Self::BadRequest => "skills.bad_request",
        }
    }
}

/// Where this machine's harness folders are. Tests point every one into a temporary folder.
#[derive(Debug, Clone)]
pub(crate) struct SkillsEnv {
    pub home: PathBuf,
    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    pub claude_dir: PathBuf,
    /// `$CODEX_HOME`, else `~/.codex`.
    pub codex_dir: PathBuf,
    /// `/etc/codex/skills`.
    pub codex_admin: PathBuf,
}

impl SkillsEnv {
    pub(crate) fn from_process() -> Option<Self> {
        let home = std::env::var_os("HOME").map(PathBuf::from).filter(|p| p.is_absolute())?;
        let dir = |var: &str, fallback: &str| {
            std::env::var_os(var)
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .unwrap_or_else(|| home.join(fallback))
        };
        Some(Self {
            claude_dir: dir("CLAUDE_CONFIG_DIR", ".claude"),
            codex_dir: dir("CODEX_HOME", ".codex"),
            codex_admin: PathBuf::from("/etc/codex/skills"),
            home,
        })
    }

    fn claude_settings(&self) -> PathBuf {
        self.claude_dir.join("settings.json")
    }

    fn codex_config(&self) -> PathBuf {
        self.codex_dir.join("config.toml")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Harness {
    Claude,
    Codex,
}

impl Harness {
    fn parse(text: &str) -> Option<Self> {
        match text {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            _ => None,
        }
    }
    fn wire(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Scope {
    User,
    Project,
    Plugin,
    Admin,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Toggle {
    /// The switch turns this skill on or off.
    Skill,
    /// The switch turns the whole plugin (every one of its skills) on or off.
    Plugin,
}

/// One listed skill, as `skills-list` answers it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct Skill {
    pub id: String,
    pub harness: Harness,
    pub scope: Scope,
    pub name: String,
    pub description: String,
    pub file: String,
    pub dir: String,
    pub project: Option<String>,
    pub plugin: Option<String>,
    pub enabled: bool,
    pub toggle: Option<Toggle>,
    pub mode: Option<String>,
    pub problem: Option<&'static str>,
    pub shadowed: bool,
}

/// A project root the list looks in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub(crate) struct Project {
    pub root: String,
    pub name: String,
}

/// The git root of `folder` (the nearest ancestor with `.git`), else `folder` itself; never home
/// or above it, and never `/`.
pub(crate) fn project_root(folder: &Path, home: &Path) -> Option<PathBuf> {
    if !folder.is_absolute() {
        return None;
    }
    for dir in folder.ancestors() {
        if dir == home || dir.parent().is_none() || !dir.starts_with(home) && home.starts_with(dir)
        {
            break;
        }
        if dir.join(".git").exists() {
            return Some(dir.to_path_buf());
        }
    }
    (folder != home && folder.parent().is_some() && !home.starts_with(folder) && folder.is_dir())
        .then(|| folder.to_path_buf())
}

/// The distinct roots of `folders`, in order, at most [`MAX_PROJECTS`].
pub(crate) fn projects(folders: impl IntoIterator<Item = PathBuf>, home: &Path) -> Vec<Project> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for folder in folders {
        if out.len() >= MAX_PROJECTS {
            break;
        }
        let Some(root) = project_root(&folder, home) else { continue };
        if !seen.insert(root.clone()) {
            continue;
        }
        let name = root.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        out.push(Project { root: root.to_string_lossy().into_owned(), name });
    }
    out
}

/// Every skill of both harnesses for this machine and `projects`, sorted by harness, scope,
/// project and name.
pub(crate) fn list(env: &SkillsEnv, projects: &[Project]) -> Vec<Skill> {
    let mut skills = Vec::new();
    let mut budget = MAX_SKILLS;
    let claude = Overrides::claude(env, None);
    let mut scan = |skills: &mut Vec<Skill>, folder: &Path, base: Base<'_>| {
        if budget == 0 {
            return;
        }
        let found = scan_folder(folder, &base, budget);
        budget -= found.len();
        skills.extend(found);
    };
    let user = env.claude_dir.join("skills");
    scan(&mut skills, &user, Base::claude(Scope::User, None, None, &claude));
    scan(&mut skills, &user.join("synced"), Base::claude(Scope::User, None, None, &claude));
    for project in projects {
        let overrides = Overrides::claude(env, Some(Path::new(&project.root)));
        let folder = Path::new(&project.root).join(".claude/skills");
        scan(
            &mut skills,
            &folder,
            Base::claude(Scope::Project, Some(&project.root), None, &overrides),
        );
    }
    let enabled_plugins = enabled_plugins(&env.claude_settings());
    for (plugin, install) in installed_plugins(&env.claude_dir) {
        let on = enabled_plugins.get(&plugin).copied().unwrap_or(true);
        let base = Base {
            harness: Harness::Claude,
            scope: Scope::Plugin,
            project: None,
            plugin: Some(&plugin),
            state: State::Plugin(on),
        };
        scan(&mut skills, &install.join("skills"), base);
    }
    let rules = CodexRules::read(&env.codex_config());
    let codex = |scope, project| Base {
        harness: Harness::Codex,
        scope,
        project,
        plugin: None,
        state: State::Codex(&rules),
    };
    scan(&mut skills, &env.home.join(".agents/skills"), codex(Scope::User, None));
    scan(&mut skills, &env.codex_dir.join("skills"), codex(Scope::User, None));
    scan(&mut skills, &env.codex_dir.join("skills/.system"), codex(Scope::System, None));
    scan(&mut skills, &env.codex_admin, codex(Scope::Admin, None));
    for project in projects {
        let folder = Path::new(&project.root).join(".agents/skills");
        scan(&mut skills, &folder, codex(Scope::Project, Some(&project.root)));
    }
    // Claude Code: a personal skill wins over a project's skill of the same name.
    let personal: HashSet<String> = skills
        .iter()
        .filter(|s| s.harness == Harness::Claude && s.scope == Scope::User)
        .map(|s| s.name.clone())
        .collect();
    for skill in &mut skills {
        skill.shadowed = skill.harness == Harness::Claude
            && skill.scope == Scope::Project
            && personal.contains(&skill.name);
    }
    let mut seen = HashSet::new();
    skills.retain(|s| seen.insert(s.id.clone()));
    skills.sort_by(|a, b| {
        (a.harness, a.scope, &a.project, &a.plugin, &a.name, &a.file)
            .cmp(&(b.harness, b.scope, &b.project, &b.plugin, &b.name, &b.file))
    });
    skills
}

/// The listed skill whose id is `id`.
pub(crate) fn find(env: &SkillsEnv, projects: &[Project], id: &str) -> Option<Skill> {
    list(env, projects).into_iter().find(|s| s.id == id)
}

/// Turns the skill `id` on or off where its harness reads it, and answers it as listed afterwards.
pub(crate) fn set_enabled(
    env: &SkillsEnv,
    projects: &[Project],
    id: &str,
    enabled: bool,
) -> Result<Skill, SkillsError> {
    let skill = find(env, projects, id).ok_or(SkillsError::NotFound)?;
    match (skill.harness, skill.toggle) {
        (_, None) => return Err(SkillsError::NotToggleable),
        (Harness::Claude, Some(Toggle::Plugin)) => {
            let plugin = skill.plugin.as_deref().ok_or(SkillsError::NotToggleable)?;
            edit_json(&env.claude_settings(), |top| {
                set_nested(top, "enabledPlugins", plugin, Some(Value::Bool(enabled)))
            })?;
        }
        (Harness::Claude, Some(Toggle::Skill)) => {
            let file = match (&skill.scope, &skill.project) {
                (Scope::Project, Some(root)) => Path::new(root).join(".claude/settings.local.json"),
                _ => env.claude_settings(),
            };
            // Off writes "off"; on removes this file's rule, then writes "on" only when another
            // file still turns it off.
            let value = (!enabled).then(|| Value::String("off".into()));
            edit_json(&file, |top| set_nested(top, "skillOverrides", &skill.name, value.clone()))?;
            let after = find(env, projects, id).ok_or(SkillsError::NotFound)?;
            if after.enabled != enabled {
                edit_json(&file, |top| {
                    set_nested(top, "skillOverrides", &skill.name, Some(Value::String("on".into())))
                })?;
            }
        }
        (Harness::Codex, Some(_)) => {
            edit_codex_rules(&env.codex_config(), &skill.file, None)?;
            let after = find(env, projects, id).ok_or(SkillsError::NotFound)?;
            if after.enabled != enabled {
                edit_codex_rules(&env.codex_config(), &skill.file, Some(enabled))?;
            }
        }
    }
    find(env, projects, id).ok_or(SkillsError::NotFound)
}

/// What `skills-create` asks for.
#[derive(Debug, Clone)]
pub(crate) struct NewSkill {
    pub harness: String,
    pub scope: String,
    pub project: Option<String>,
    pub name: String,
    pub description: String,
}

/// Whether `name` is a skill name both harnesses load: lowercase letters, digits and single
/// hyphens, at most 64 characters.
pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME
        && name.split('-').all(|part| {
            !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
}

/// Makes `<folder>/<name>/SKILL.md` with frontmatter and a short body; never replaces a folder.
pub(crate) fn create(
    env: &SkillsEnv,
    projects: &[Project],
    new: &NewSkill,
) -> Result<Skill, SkillsError> {
    let harness = Harness::parse(&new.harness).ok_or(SkillsError::BadScope)?;
    if !valid_name(&new.name) {
        return Err(SkillsError::BadName);
    }
    let description = new.description.trim();
    if description.chars().count() > MAX_DESCRIPTION || description.chars().any(|c| c.is_control())
    {
        return Err(SkillsError::BadDescription);
    }
    let folder = match (new.scope.as_str(), harness, new.project.as_deref()) {
        ("user", Harness::Claude, None) => env.claude_dir.join("skills"),
        ("user", Harness::Codex, None) => env.home.join(".agents/skills"),
        ("project", _, Some(root)) => {
            if !projects.iter().any(|p| p.root == root) {
                return Err(SkillsError::BadScope);
            }
            let sub = if harness == Harness::Claude { ".claude/skills" } else { ".agents/skills" };
            Path::new(root).join(sub)
        }
        _ => return Err(SkillsError::BadScope),
    };
    let dir = folder.join(&new.name);
    if fs::symlink_metadata(&dir).is_ok() {
        return Err(SkillsError::Exists);
    }
    fs::create_dir_all(&folder).map_err(|_| SkillsError::WriteFailed)?;
    match fs::create_dir(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => return Err(SkillsError::Exists),
        Err(_) => return Err(SkillsError::WriteFailed),
    }
    let text = scaffold(&new.name, description);
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dir.join("SKILL.md"))
        .and_then(|mut f| f.write_all(text.as_bytes()));
    if written.is_err() {
        let _ = fs::remove_dir(&dir);
        return Err(SkillsError::WriteFailed);
    }
    let id = skill_id(harness, &dir.join("SKILL.md"));
    find(env, projects, &id).ok_or(SkillsError::WriteFailed)
}

/// A new SKILL.md: `name` and `description` frontmatter, then a heading and a line to replace.
pub(crate) fn scaffold(name: &str, description: &str) -> String {
    let quoted = serde_json::to_string(description).unwrap_or_else(|_| "\"\"".into());
    let title: String = name
        .split('-')
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_ascii_uppercase().to_string() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ");
    format!(
        "---\nname: {name}\ndescription: {quoted}\n---\n\n# {title}\n\nSay when to use this skill, then the steps to follow.\n"
    )
}

fn skill_id(harness: Harness, file: &Path) -> String {
    format!("{}:{}", harness.wire(), file.to_string_lossy())
}

// ---------------------------------------------------------------------------------------------
// Discovery

enum State<'a> {
    Claude(&'a Overrides),
    Plugin(bool),
    Codex(&'a CodexRules),
}

struct Base<'a> {
    harness: Harness,
    scope: Scope,
    project: Option<&'a str>,
    plugin: Option<&'a str>,
    state: State<'a>,
}

impl<'a> Base<'a> {
    fn claude(
        scope: Scope,
        project: Option<&'a str>,
        plugin: Option<&'a str>,
        overrides: &'a Overrides,
    ) -> Self {
        Self { harness: Harness::Claude, scope, project, plugin, state: State::Claude(overrides) }
    }
}

fn scan_folder(folder: &Path, base: &Base<'_>, budget: usize) -> Vec<Skill> {
    let Ok(entries) = fs::read_dir(folder) else { return Vec::new() };
    let mut dirs: Vec<PathBuf> = entries
        .take(MAX_ENTRIES_PER_FOLDER)
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            !name.starts_with('.') && name != "synced"
        })
        .collect();
    dirs.sort();
    let mut out = Vec::new();
    for dir in dirs {
        if out.len() >= budget {
            break;
        }
        let file = dir.join("SKILL.md");
        let Ok(meta) = fs::metadata(&file) else { continue };
        if !meta.is_file() {
            continue;
        }
        out.push(describe(&dir, &file, meta.len(), base));
    }
    out
}

fn describe(dir: &Path, file: &Path, size: u64, base: &Base<'_>) -> Skill {
    let folder_name = dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let (front, problem) = match read_head(file) {
        None => (None, Some("unreadable")),
        Some(text) => match frontmatter(&text) {
            None => (None, Some("no_frontmatter")),
            Some(front) => (Some(front), None),
        },
    };
    let field = |key: &str| {
        front.as_ref().and_then(|f| f.iter().find(|(k, _)| k == key)).map(|(_, v)| v.clone())
    };
    let name = field("name").filter(|n| !n.is_empty()).unwrap_or(folder_name);
    let description = field("description").unwrap_or_default();
    let problem = problem
        .or_else(|| (size > MAX_SKILL_BYTES).then_some("too_large"))
        .or_else(|| description.is_empty().then_some("no_description"));
    let (enabled, toggle, mode) = match &base.state {
        State::Claude(overrides) => {
            let mode = overrides.mode(&name);
            (
                mode.as_deref() != Some("off"),
                Some(Toggle::Skill),
                mode.filter(|m| m != "off" && m != "on"),
            )
        }
        State::Plugin(on) => (*on, Some(Toggle::Plugin), None),
        State::Codex(rules) => (rules.enabled(file, &name), Some(Toggle::Skill), None),
    };
    Skill {
        id: skill_id(base.harness, file),
        harness: base.harness,
        scope: base.scope,
        name,
        description,
        file: file.to_string_lossy().into_owned(),
        dir: dir.to_string_lossy().into_owned(),
        project: base.project.map(str::to_owned),
        plugin: base.plugin.map(str::to_owned),
        enabled,
        toggle,
        mode,
        problem,
        shadowed: false,
    }
}

fn read_head(file: &Path) -> Option<String> {
    let mut buf = Vec::new();
    fs::File::open(file).ok()?.take(MAX_HEAD_BYTES as u64).read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// The top-level `key: value` scalars of a SKILL.md's YAML frontmatter, in order: plain, quoted,
/// folded (`>`) and literal (`|`) values; nested maps and lists are skipped. None when the file
/// does not start with a `---` fence that closes.
pub(crate) fn frontmatter(text: &str) -> Option<Vec<(String, String)>> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut lines = text.lines();
    if lines.next()?.trim_end() != "---" {
        return None;
    }
    let mut body = Vec::new();
    let mut closed = false;
    for line in lines {
        let t = line.trim_end();
        if t == "---" || t == "..." {
            closed = true;
            break;
        }
        body.push(line);
    }
    if !closed {
        return None;
    }
    let mut out = Vec::new();
    let mut i = 0;
    while i < body.len() {
        let line = body[i];
        i += 1;
        if line.starts_with([' ', '\t', '#', '-']) || line.trim().is_empty() {
            continue;
        }
        let Some((key, rest)) = line.split_once(':') else { continue };
        let key = key.trim().to_owned();
        let rest = rest.trim();
        // The lines indented under this key.
        let start = i;
        while i < body.len() && (body[i].starts_with([' ', '\t']) || body[i].trim().is_empty()) {
            i += 1;
        }
        let block: Vec<&str> = body[start..i].iter().map(|l| l.trim()).collect();
        let value = if let Some(style) = rest.chars().next().filter(|c| *c == '|' || *c == '>') {
            let lines: Vec<&str> = trim_blank_tail(&block);
            if style == '|' { lines.join("\n") } else { fold(&lines) }
        } else if rest.starts_with('"') || rest.starts_with('\'') {
            let joined = std::iter::once(rest).chain(block.iter().copied()).collect::<Vec<_>>();
            unquote(&fold(&joined))
        } else if rest.is_empty() {
            // A nested map or list: not a scalar.
            if block.iter().any(|l| !l.is_empty()) { continue } else { String::new() }
        } else {
            let mut parts = vec![strip_comment(rest)];
            parts.extend(block.iter().copied().filter(|l| !l.is_empty()));
            parts.join(" ")
        };
        out.push((key, value.trim().to_owned()));
    }
    Some(out)
}

fn trim_blank_tail<'a>(lines: &[&'a str]) -> Vec<&'a str> {
    let mut v = lines.to_vec();
    while v.last().is_some_and(|l| l.is_empty()) {
        v.pop();
    }
    v
}

/// YAML folding: lines join with a space, a blank line is a line break.
fn fold(lines: &[&str]) -> String {
    let mut out = String::new();
    for line in lines {
        if line.is_empty() {
            out.push('\n');
        } else {
            if !out.is_empty() && !out.ends_with('\n') {
                out.push(' ');
            }
            out.push_str(line);
        }
    }
    out
}

fn strip_comment(value: &str) -> &str {
    value.find(" #").map_or(value, |at| &value[..at]).trim_end()
}

fn unquote(value: &str) -> String {
    let value = value.trim();
    if let Some(inner) = value.strip_prefix('\'') {
        let end = inner.rfind('\'').unwrap_or(inner.len());
        return inner[..end].replace("''", "'");
    }
    let Some(inner) = value.strip_prefix('"') else { return value.to_owned() };
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => break,
            '\\' => match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => out.push(other),
                None => break,
            },
            c => out.push(c),
        }
    }
    out
}

// ---------------------------------------------------------------------------------------------
// Claude Code settings

/// `skillOverrides` by name, user file first, then a project's shared and local files.
struct Overrides(Vec<(String, String)>);

impl Overrides {
    fn claude(env: &SkillsEnv, project: Option<&Path>) -> Self {
        let mut files = vec![env.claude_settings()];
        if let Some(root) = project {
            files.push(root.join(".claude/settings.json"));
            files.push(root.join(".claude/settings.local.json"));
        }
        let mut rules = Vec::new();
        for file in files {
            let Some(Value::Object(map)) = read_json(&file).map(|v| v["skillOverrides"].clone())
            else {
                continue;
            };
            for (name, mode) in map {
                if let Value::String(mode) = mode {
                    rules.push((name, mode));
                }
            }
        }
        Self(rules)
    }

    fn mode(&self, name: &str) -> Option<String> {
        self.0.iter().rev().find(|(n, _)| n == name).map(|(_, m)| m.clone())
    }
}

fn read_json(file: &Path) -> Option<Value> {
    serde_json::from_str(&fs::read_to_string(file).ok()?).ok()
}

fn enabled_plugins(settings: &Path) -> std::collections::HashMap<String, bool> {
    let mut out = std::collections::HashMap::new();
    if let Some(Value::Object(map)) = read_json(settings).map(|v| v["enabledPlugins"].clone()) {
        for (key, on) in map {
            if let Value::Bool(on) = on {
                out.insert(key, on);
            }
        }
    }
    out
}

/// `plugins/installed_plugins.json`: `{plugins: {"name@market": [{installPath}, ...] | {installPath}}}`.
fn installed_plugins(claude_dir: &Path) -> Vec<(String, PathBuf)> {
    let Some(value) = read_json(&claude_dir.join("plugins/installed_plugins.json")) else {
        return Vec::new();
    };
    let Some(map) = value["plugins"].as_object() else { return Vec::new() };
    let mut out = BTreeSet::new();
    for (key, installs) in map.iter().take(MAX_ENTRIES_PER_FOLDER) {
        let installs = match installs {
            Value::Array(list) => list.iter().collect::<Vec<_>>(),
            other => vec![other],
        };
        // The newest install of a plugin (the last listed) is the one that loads.
        if let Some(path) = installs.iter().rev().find_map(|i| i["installPath"].as_str()) {
            let path = PathBuf::from(path);
            if path.is_absolute() {
                out.insert((key.clone(), path));
            }
        }
    }
    out.into_iter().collect()
}

/// Edits a JSON settings file in place: its top-level entries keep their order and text; only
/// the entry `edit` changes is written anew. A missing file starts empty; one that does not
/// parse as an object is left alone (`skills.settings_unreadable`).
fn edit_json(
    file: &Path,
    edit: impl FnOnce(&mut Vec<(String, Box<RawValue>)>) -> Result<(), SkillsError>,
) -> Result<(), SkillsError> {
    let text = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(_) => return Err(SkillsError::SettingsUnreadable),
    };
    let mut top = if text.trim().is_empty() {
        Vec::new()
    } else {
        parse_ordered(&text).ok_or(SkillsError::SettingsUnreadable)?
    };
    let before: Vec<(String, String)> =
        top.iter().map(|(k, v)| (k.clone(), v.get().to_owned())).collect();
    edit(&mut top)?;
    let after: Vec<(String, String)> =
        top.iter().map(|(k, v)| (k.clone(), v.get().to_owned())).collect();
    if before == after {
        return Ok(());
    }
    write_atomic(file, &render_ordered(&top))
}

fn parse_ordered(text: &str) -> Option<Vec<(String, Box<RawValue>)>> {
    struct Ordered(Vec<(String, Box<RawValue>)>);
    impl<'de> serde::Deserialize<'de> for Ordered {
        fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
            struct Visit;
            impl<'de> serde::de::Visitor<'de> for Visit {
                type Value = Ordered;
                fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                    f.write_str("a JSON object")
                }
                fn visit_map<A: serde::de::MapAccess<'de>>(
                    self,
                    mut map: A,
                ) -> Result<Ordered, A::Error> {
                    let mut out: Vec<(String, Box<RawValue>)> = Vec::new();
                    while let Some((key, value)) = map.next_entry::<String, Box<RawValue>>()? {
                        // A repeated key: the last one wins, where the first one stood.
                        if let Some(slot) = out.iter_mut().find(|(k, _)| *k == key) {
                            slot.1 = value;
                        } else {
                            out.push((key, value));
                        }
                    }
                    Ok(Ordered(out))
                }
            }
            d.deserialize_map(Visit)
        }
    }
    serde_json::from_str::<Ordered>(text).ok().map(|o| o.0)
}

fn render_ordered(top: &[(String, Box<RawValue>)]) -> String {
    if top.is_empty() {
        return "{}\n".into();
    }
    let mut out = String::from("{\n");
    for (i, (key, value)) in top.iter().enumerate() {
        let key = serde_json::to_string(key).unwrap_or_default();
        out.push_str("  ");
        out.push_str(&key);
        out.push_str(": ");
        out.push_str(value.get());
        out.push_str(if i + 1 == top.len() { "\n" } else { ",\n" });
    }
    out.push_str("}\n");
    out
}

/// Sets (`Some`) or removes (`None`) `top[object][key]`; an object left empty is removed.
fn set_nested(
    top: &mut Vec<(String, Box<RawValue>)>,
    object: &str,
    key: &str,
    value: Option<Value>,
) -> Result<(), SkillsError> {
    let at = top.iter().position(|(k, _)| k == object);
    let mut map: Map<String, Value> = match at {
        Some(at) => match serde_json::from_str::<Value>(top[at].1.get()) {
            Ok(Value::Object(map)) => map,
            _ => return Err(SkillsError::SettingsUnreadable),
        },
        None => Map::new(),
    };
    let unchanged = map.get(key) == value.as_ref();
    if unchanged {
        return Ok(());
    }
    match value {
        Some(value) => {
            map.insert(key.to_owned(), value);
        }
        None => {
            map.remove(key);
        }
    }
    if map.is_empty() {
        if let Some(at) = at {
            top.remove(at);
        }
        return Ok(());
    }
    // Pretty, indented one level as a top-level entry's value.
    let pretty = serde_json::to_string_pretty(&Value::Object(map))
        .map_err(|_| SkillsError::WriteFailed)?
        .replace('\n', "\n  ");
    let raw = RawValue::from_string(pretty).map_err(|_| SkillsError::WriteFailed)?;
    match at {
        Some(at) => top[at].1 = raw,
        None => top.push((object.to_owned(), raw)),
    }
    Ok(())
}

fn write_atomic(file: &Path, text: &str) -> Result<(), SkillsError> {
    let parent = file.parent().ok_or(SkillsError::WriteFailed)?;
    fs::create_dir_all(parent).map_err(|_| SkillsError::WriteFailed)?;
    let name = file.file_name().ok_or(SkillsError::WriteFailed)?.to_string_lossy().into_owned();
    let temp = parent.join(format!(".{name}.cmux-{}", std::process::id()));
    let result = (|| {
        let mut f = fs::File::create(&temp)?;
        f.write_all(text.as_bytes())?;
        f.sync_all()?;
        // The person's file keeps its permissions.
        if let Ok(meta) = fs::metadata(file) {
            fs::set_permissions(&temp, meta.permissions())?;
        }
        fs::rename(&temp, file)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
        return Err(SkillsError::WriteFailed);
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Codex config.toml

/// `[[skills.config]]` rules in order: (path or name, enabled).
struct CodexRules(Vec<(CodexSelector, bool)>);

enum CodexSelector {
    Path(PathBuf),
    Name(String),
}

impl CodexRules {
    fn read(file: &Path) -> Self {
        let Some(doc) =
            fs::read_to_string(file).ok().and_then(|t| t.parse::<toml_edit::DocumentMut>().ok())
        else {
            return Self(Vec::new());
        };
        let mut rules = Vec::new();
        for rule in codex_rule_tables(&doc) {
            let enabled = rule.get("enabled").and_then(|v| v.as_bool()).unwrap_or(true);
            if let Some(path) = rule.get("path").and_then(|v| v.as_str()) {
                rules.push((CodexSelector::Path(PathBuf::from(path)), enabled));
            } else if let Some(name) = rule.get("name").and_then(|v| v.as_str()) {
                rules.push((CodexSelector::Name(name.to_owned()), enabled));
            }
        }
        Self(rules)
    }

    fn enabled(&self, file: &Path, name: &str) -> bool {
        self.0
            .iter()
            .rev()
            .find(|(selector, _)| match selector {
                CodexSelector::Path(path) => same_file(path, file),
                CodexSelector::Name(n) => n == name,
            })
            .is_none_or(|(_, on)| *on)
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b || matches!((fs::canonicalize(a), fs::canonicalize(b)), (Ok(x), Ok(y)) if x == y)
}

/// Each rule of `skills.config`, whether written as `[[skills.config]]` or an inline array.
fn codex_rule_tables(doc: &toml_edit::DocumentMut) -> Vec<&dyn toml_edit::TableLike> {
    let Some(config) = doc.get("skills").and_then(|s| s.get("config")) else { return Vec::new() };
    if let Some(tables) = config.as_array_of_tables() {
        return tables.iter().map(|t| t as &dyn toml_edit::TableLike).collect();
    }
    if let Some(array) = config.as_array() {
        return array
            .iter()
            .filter_map(|v| v.as_inline_table().map(|t| t as &dyn toml_edit::TableLike))
            .collect();
    }
    Vec::new()
}

/// Removes this file's `path` rules (`None`), or appends `{path, enabled}` after them.
fn edit_codex_rules(file: &Path, skill: &str, enabled: Option<bool>) -> Result<(), SkillsError> {
    let text = match fs::read_to_string(file) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(_) => return Err(SkillsError::SettingsUnreadable),
    };
    let mut doc =
        text.parse::<toml_edit::DocumentMut>().map_err(|_| SkillsError::SettingsUnreadable)?;
    let skill_path = Path::new(skill);
    let mine = |path: Option<&str>| path.is_some_and(|p| same_file(Path::new(p), skill_path));
    let mut changed = false;
    if doc.get("skills").is_some_and(|s| !s.is_table_like()) {
        return Err(SkillsError::SettingsUnreadable);
    }
    let skills = doc.entry("skills").or_insert_with(|| {
        let mut table = toml_edit::Table::new();
        table.set_implicit(true);
        toml_edit::Item::Table(table)
    });
    let skills = skills.as_table_like_mut().ok_or(SkillsError::SettingsUnreadable)?;
    match skills.get_mut("config") {
        Some(item) if item.is_array_of_tables() => {
            let tables = item.as_array_of_tables_mut().ok_or(SkillsError::SettingsUnreadable)?;
            let before = tables.len();
            tables.retain(|t| !mine(t.get("path").and_then(|v| v.as_str())));
            changed |= tables.len() != before;
            if let Some(on) = enabled {
                let mut rule = toml_edit::Table::new();
                rule.insert("path", toml_edit::value(skill));
                rule.insert("enabled", toml_edit::value(on));
                tables.push(rule);
                changed = true;
            }
        }
        Some(item) if item.is_array() => {
            let array = item.as_array_mut().ok_or(SkillsError::SettingsUnreadable)?;
            let before = array.len();
            array.retain(|v| {
                !mine(v.as_inline_table().and_then(|t| t.get("path")).and_then(|p| p.as_str()))
            });
            changed |= array.len() != before;
            if let Some(on) = enabled {
                let mut rule = toml_edit::InlineTable::new();
                rule.insert("path", skill.into());
                rule.insert("enabled", on.into());
                array.push(rule);
                changed = true;
            }
        }
        Some(_) => return Err(SkillsError::SettingsUnreadable),
        None => {
            if let Some(on) = enabled {
                let mut rule = toml_edit::Table::new();
                rule.insert("path", toml_edit::value(skill));
                rule.insert("enabled", toml_edit::value(on));
                let mut tables = toml_edit::ArrayOfTables::new();
                tables.push(rule);
                skills.insert("config", toml_edit::Item::ArrayOfTables(tables));
                changed = true;
            }
        }
    }
    if !changed {
        return Ok(());
    }
    write_atomic(file, &doc.to_string())
}

/// `skills-list`'s reply.
pub(crate) fn list_reply(env: &SkillsEnv, projects: &[Project]) -> Value {
    json!({
        "home": env.home.to_string_lossy(),
        "projects": projects,
        "skills": list(env, projects),
    })
}

#[cfg(test)]
#[path = "skills_catalog_tests.rs"]
mod tests;
