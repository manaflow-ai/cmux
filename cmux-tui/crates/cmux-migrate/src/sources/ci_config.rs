//! A checkout's CI config read for what its machine needs: `.github/workflows/*.yml`,
//! `.gitlab-ci.yml`, `.circleci/config.yml` and `bitbucket-pipelines.yml`. CI already knows the
//! image the code builds in, the dependency installs, the test commands, the secret names and the
//! service containers, so they seed `[setup]`, `[setup] check`, `[secrets]` and `services`.
//! Names only: no env value or secret value is kept.

use std::path::Path;

use yaml_rust::{Yaml, YamlLoader};

use super::project_files::{apt_install, is_env_name, looks_secret, shell_refs, value_has_login};
use crate::plan::Project;

/// At most this many dependency-install lines and test lines enter a machine.
pub const MAX_SETUP: usize = 12;
pub const MAX_CHECK: usize = 8;

/// What the CI files of one checkout say.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Read {
    pub files: Vec<String>,
    pub image: Option<String>,
    pub setup: Vec<String>,
    pub check: Vec<String>,
    pub secret_names: Vec<String>,
    pub services: Vec<String>,
    pub notes: Vec<String>,
    pub warnings: Vec<String>,
}

impl Read {
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }
}

/// The CI config files that exist, as paths relative to the root.
pub fn find(root: &Path) -> Vec<String> {
    let mut found = Vec::new();
    if let Ok(entries) = std::fs::read_dir(root.join(".github/workflows")) {
        let mut names: Vec<String> = entries
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".yml") || n.ends_with(".yaml"))
            .collect();
        names.sort();
        found.extend(names.into_iter().map(|n| format!(".github/workflows/{n}")));
    }
    for f in [".gitlab-ci.yml", ".circleci/config.yml", "bitbucket-pipelines.yml"] {
        if root.join(f).is_file() {
            found.push(f.to_owned());
        }
    }
    found
}

pub fn read(root: &Path) -> Read {
    let mut read = Read::default();
    let mut setup = Vec::new();
    let mut check = Vec::new();
    for file in find(root) {
        let text = match std::fs::read_to_string(root.join(&file)) {
            Ok(t) => t,
            Err(e) => {
                read.warnings.push(format!("cannot read {file}: {e}"));
                continue;
            }
        };
        read.files.push(file.clone());
        for name in expression_secrets(&text) {
            push_unique(&mut read.secret_names, name);
        }
        let docs = match YamlLoader::load_from_str(&text) {
            Ok(d) => d,
            Err(e) => {
                read.warnings
                    .push(format!("{file} is not YAML ({e}); only its secret names were read"));
                continue;
            }
        };
        let Some(doc) = docs.first() else { continue };
        let mut found = Found::default();
        walk(doc, &mut found);
        if read.image.is_none() {
            read.image = found.images.into_iter().next();
        }
        for (name, image) in found.services {
            if !read.services.contains(&name) {
                read.services.push(name.clone());
                read.notes.push(format!(
                    "{file} runs service {name}{}; start it on the machine (docker run, or a compose file)",
                    image.map(|i| format!(" ({i})")).unwrap_or_default()
                ));
            }
        }
        for name in found.secrets {
            push_unique(&mut read.secret_names, name);
        }
        for context in found.contexts {
            read.notes.push(format!(
                "{file} uses CircleCI context {context}; its variables are not in the file, set each with cmux cloud secret set NAME"
            ));
        }
        for line in found.commands {
            match classify(&line) {
                Some(Kind::Setup(cmd)) => push_unique(&mut setup, cmd),
                Some(Kind::Check(cmd)) => push_unique(&mut check, cmd),
                None => {}
            }
        }
    }
    read.secret_names.sort();
    read.secret_names.dedup();
    if setup.len() > MAX_SETUP {
        read.notes.push(format!(
            "CI has {} install steps; the first {MAX_SETUP} are in [setup]",
            setup.len()
        ));
    }
    if check.len() > MAX_CHECK {
        read.notes.push(format!(
            "CI has {} test commands; the first {MAX_CHECK} are in check",
            check.len()
        ));
    }
    setup.truncate(MAX_SETUP);
    check.truncate(MAX_CHECK);
    read.setup = setup;
    read.check = check;
    if let Some(image) = &read.image {
        read.notes.push(format!(
            "CI runs in image {image}; the machine is a full VM, so [setup] repeats the install steps CI runs"
        ));
    }
    if !read.files.is_empty() {
        read.notes.insert(0, format!("read CI config {}", read.files.join(", ")));
    }
    read
}

/// Folds what CI says into a project. Existing setup, image and notes stay first.
pub fn merge(read: &Read, project: &mut Project) {
    if read.is_empty() {
        return;
    }
    if project.image.is_none() {
        project.image = read.image.clone();
    }
    for s in &read.setup {
        push_unique(&mut project.machine.setup, s.clone());
    }
    for c in &read.check {
        push_unique(&mut project.machine.check, c.clone());
    }
    project.machine.secret_names.extend(read.secret_names.iter().cloned());
    for s in &read.services {
        push_unique(&mut project.services, s.clone());
    }
    if !read.secret_names.is_empty() {
        project.notes.push(format!(
            "CI uses secrets {} (names only); set each with cmux cloud secret set NAME",
            read.secret_names.join(", ")
        ));
    }
    project.notes.extend(read.notes.iter().cloned());
}

enum Kind {
    Setup(String),
    Check(String),
}

#[derive(Default)]
struct Found {
    images: Vec<String>,
    services: Vec<(String, Option<String>)>,
    secrets: Vec<String>,
    contexts: Vec<String>,
    commands: Vec<String>,
}

const SCRIPT_KEYS: [&str; 5] = ["run", "script", "before_script", "command", "commands"];
const ENV_KEYS: [&str; 3] = ["env", "variables", "environment"];

fn key_of(k: &Yaml) -> &str {
    k.as_str().unwrap_or("")
}

fn walk(y: &Yaml, f: &mut Found) {
    match y {
        Yaml::Hash(map) => {
            for (k, v) in map {
                let key = key_of(k);
                match key {
                    "with" => continue,
                    "services" => {
                        services(v, f);
                        continue;
                    }
                    "container" | "image" => {
                        if let Some(i) = image_of(v) {
                            f.images.push(i);
                        }
                    }
                    "docker" => {
                        if let Yaml::Array(items) = v {
                            for (n, item) in items.iter().enumerate() {
                                let Some(image) = image_of(item) else { continue };
                                if n == 0 {
                                    f.images.push(image);
                                } else {
                                    f.services.push((service_name(&image), Some(image)));
                                }
                            }
                            continue;
                        }
                    }
                    "context" => {
                        for c in strings_of(v) {
                            push_unique(&mut f.contexts, c);
                        }
                    }
                    _ => {}
                }
                if ENV_KEYS.contains(&key)
                    && let Yaml::Hash(env) = v
                {
                    for (name, value) in env {
                        let name = key_of(name);
                        if is_env_name(name) && looks_secret(name) && !predefined(name) {
                            push_unique(&mut f.secrets, name.to_owned());
                        }
                        // GitLab: `X: $Y` reads another variable.
                        if let Some(value) = value.as_str() {
                            for r in shell_refs(value) {
                                if looks_secret(&r) && !predefined(&r) {
                                    push_unique(&mut f.secrets, r);
                                }
                            }
                        }
                    }
                }
                if SCRIPT_KEYS.contains(&key) {
                    scripts(v, f);
                } else {
                    walk(v, f);
                }
            }
        }
        Yaml::Array(items) => items.iter().for_each(|i| walk(i, f)),
        _ => {}
    }
}

fn scripts(y: &Yaml, f: &mut Found) {
    match y {
        Yaml::String(s) => {
            for r in shell_refs(s) {
                if looks_secret(&r) && !predefined(&r) && !s.contains(&format!("{r}=")) {
                    push_unique(&mut f.secrets, r);
                }
            }
            f.commands.extend(s.lines().map(str::to_owned));
        }
        Yaml::Array(items) => items.iter().for_each(|i| scripts(i, f)),
        Yaml::Hash(_) => walk(y, f),
        _ => {}
    }
}

fn services(y: &Yaml, f: &mut Found) {
    match y {
        Yaml::Hash(map) => {
            for (name, v) in map {
                let image = image_of(v);
                f.services.push((key_of(name).to_owned(), image));
            }
        }
        Yaml::Array(items) => {
            for item in items {
                let image = match item {
                    Yaml::String(s) => Some(s.clone()),
                    other => other["name"].as_str().or(other["image"].as_str()).map(str::to_owned),
                };
                let Some(image) = image else { continue };
                let name = item["alias"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| service_name(&image));
                // Bitbucket lists names the `definitions` hash also gives: the image arrives there.
                f.services.push((name, image.contains([':', '/']).then_some(image)));
            }
        }
        _ => {}
    }
}

fn service_name(image: &str) -> String {
    let last = image.rsplit('/').next().unwrap_or(image);
    last.split([':', '@']).next().unwrap_or(last).to_owned()
}

fn image_of(y: &Yaml) -> Option<String> {
    let s = match y {
        Yaml::String(s) => s.as_str(),
        Yaml::Hash(_) => y["image"].as_str().or(y["name"].as_str())?,
        _ => return None,
    };
    let s = s.trim();
    (!s.is_empty() && !s.contains('$') && !s.contains(' ') && !value_has_login(s))
        .then(|| s.to_owned())
}

fn strings_of(y: &Yaml) -> Vec<String> {
    match y {
        Yaml::String(s) => vec![s.clone()],
        Yaml::Array(a) => a.iter().filter_map(|i| i.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    }
}

/// Variables CI itself provides, not secrets a person owns.
fn predefined(name: &str) -> bool {
    name == "GITHUB_TOKEN"
        || name.starts_with("CI_")
        || name.starts_with("GITHUB_")
        || name.starts_with("BITBUCKET_")
        || name.starts_with("CIRCLE_")
}

/// `${{ secrets.NAME }}` anywhere in the text.
pub fn expression_secrets(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some((_, after)) = rest.split_once("${{") {
        let (mut inner, next) = after.split_once("}}").unwrap_or((after, ""));
        while let Some((_, tail)) = inner.split_once("secrets.") {
            let name: String =
                tail.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
            if is_env_name(&name) && !predefined(&name) {
                push_unique(&mut out, name.clone());
            }
            inner = tail.get(name.len()..).unwrap_or_default();
        }
        rest = next;
    }
    out
}

const SETUP_PREFIXES: [&str; 20] = [
    "npm ci",
    "npm install",
    "npm i ",
    "yarn install",
    "pnpm install",
    "pip install",
    "pip3 install",
    "python -m pip install",
    "python3 -m pip install",
    "poetry install",
    "pipenv install",
    "bundle install",
    "cargo fetch",
    "go mod download",
    "composer install",
    "uv sync",
    "mix deps.get",
    "dotnet restore",
    "mvn dependency",
    "bun install",
];
const CHECK_PREFIXES: [&str; 22] = [
    "npm test",
    "npm run test",
    "yarn test",
    "pnpm test",
    "pnpm run test",
    "pytest",
    "python -m pytest",
    "python3 -m pytest",
    "cargo test",
    "cargo nextest",
    "go test",
    "bundle exec rspec",
    "rspec",
    "mvn test",
    "gradle test",
    "./gradlew test",
    "make test",
    "tox",
    "phpunit",
    "dotnet test",
    "mix test",
    "bun test",
];

fn classify(line: &str) -> Option<Kind> {
    let mut line = line.trim().trim_start_matches("- ").trim();
    if line.is_empty() || line.starts_with('#') || line.ends_with('\\') || line.contains("${{") {
        return None;
    }
    line = line.strip_prefix("sudo ").unwrap_or(line).trim();
    if line == "yarn" {
        return Some(Kind::Setup("yarn install".into()));
    }
    // Anything that assigns a secret-looking variable or carries a login is not copied.
    if value_has_login(line)
        || line.split_whitespace().any(|w| w.split_once('=').is_some_and(|(k, _)| looks_secret(k)))
    {
        return None;
    }
    if let Some(rest) =
        line.strip_prefix("apt-get install").or_else(|| line.strip_prefix("apt install"))
    {
        let packages: Vec<&str> = rest.split_whitespace().filter(|w| !w.starts_with('-')).collect();
        let safe = packages
            .iter()
            .all(|p| p.chars().all(|c| c.is_ascii_alphanumeric() || "+-._:=".contains(c)));
        return (!packages.is_empty() && safe)
            .then(|| Kind::Setup(apt_install(&packages.join(" "))));
    }
    let shell_free = !line.contains(['&', '|', ';', '>', '<', '`']) && !line.contains("$(");
    if shell_free && SETUP_PREFIXES.iter().any(|p| line.starts_with(p)) {
        return Some(Kind::Setup(line.to_owned()));
    }
    if shell_free && CHECK_PREFIXES.iter().any(|p| line == *p || line.starts_with(&format!("{p} ")))
    {
        return Some(Kind::Check(line.to_owned()));
    }
    None
}

fn push_unique(v: &mut Vec<String>, s: String) {
    if !v.contains(&s) {
        v.push(s);
    }
}

#[cfg(test)]
#[path = "ci_config_tests.rs"]
mod tests;
