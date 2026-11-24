//! Where a checkout keeps its secrets, found by reference only: `.env.example` style files,
//! Doppler, 1Password (`op://`), Vault, AWS Secrets Manager and SSM, Infisical. Each becomes a
//! secret name in the machine's `[secrets] names` and a note saying where it came from and how
//! to set it. No value is read or kept; a real `.env` is never opened.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use yaml_rust::YamlLoader;

use super::project_files::{dotenv_keys, is_env_name, rel};
use crate::plan::Project;

const EXAMPLE_SUFFIXES: [&str; 6] = [".example", ".sample", ".template", ".tpl", ".op", ".dist"];

/// What the checkout's secret references say.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Read {
    /// Secret name to where it came from.
    pub names: BTreeMap<String, String>,
    pub notes: Vec<String>,
}

impl Read {
    pub fn is_empty(&self) -> bool {
        self.names.is_empty() && self.notes.is_empty()
    }
}

pub fn read(root: &Path) -> Read {
    let mut read = Read::default();
    let mut files = Vec::new();
    collect(root, root, 0, &mut files);
    files.sort();
    let mut real_env = Vec::new();
    for path in &files {
        let shown = rel(root, path);
        let file = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if is_real_env(&file) {
            real_env.push(shown);
            continue;
        }
        let Ok(text) = std::fs::read_to_string(path) else { continue };
        if file.starts_with(".env") {
            if [".env.example", ".env.sample", ".env.template"].contains(&file.as_str()) {
                for key in dotenv_keys(&text) {
                    read.names.entry(key).or_insert_with(|| format!("{shown} lists it"));
                }
            }
            one_password(&text, &shown, &mut read);
        } else if file.ends_with(".tpl") {
            one_password(&text, &shown, &mut read);
        } else if file == "doppler.yaml" {
            doppler(&text, &shown, &mut read);
        } else if file == ".infisical.json" {
            read.notes.push(format!(
                "Infisical ({shown}): the file names a workspace, not its secrets; list them with infisical secrets, then set each with cmux cloud secret set NAME"
            ));
        } else {
            vault_and_aws(&text, &shown, &mut read);
        }
    }
    if !real_env.is_empty() {
        read.notes.push(format!(
            "{} holds real values and was not read; deliver them with cloud deliver-secrets, or cmux cloud secret set NAME",
            real_env.join(", ")
        ));
    }
    if !read.names.is_empty() {
        let mut by_origin: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for (name, origin) in &read.names {
            by_origin.entry(origin.as_str()).or_default().push(name);
        }
        let mut notes = Vec::new();
        for (origin, names) in by_origin {
            notes.push(format!(
                "secret {} from {origin}; set each with cmux cloud secret set NAME",
                names.join(", ")
            ));
        }
        notes.append(&mut read.notes);
        read.notes = notes;
    }
    read
}

/// Folds secret references into a project.
pub fn merge(read: &Read, project: &mut Project) {
    project.machine.secret_names.extend(read.names.keys().cloned());
    project.notes.extend(read.notes.iter().cloned());
}

fn is_real_env(file: &str) -> bool {
    file.starts_with(".env") && !EXAMPLE_SUFFIXES.iter().any(|s| file.ends_with(s))
}

/// Candidate files: `.env*`, `*.tpl`, scripts and CI files to scan for Vault/AWS, the Doppler
/// and Infisical files. Shallow, and never into dependency or build folders.
fn collect(root: &Path, dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            let skip =
                matches!(name.as_str(), "node_modules" | "target" | "vendor" | ".git" | "dist");
            let wanted = depth == 0
                && matches!(
                    name.as_str(),
                    ".github" | ".circleci" | "scripts" | ".devcontainer" | "ci"
                )
                || depth > 0 && depth < 3 && !name.starts_with('.');
            if !skip && wanted {
                collect(root, &path, depth.saturating_add(1), out);
            }
            continue;
        }
        let in_ci_dir = path
            .strip_prefix(root)
            .is_ok_and(|p| p.starts_with(".github") || p.starts_with(".circleci"));
        let scanned = name.ends_with(".sh")
            || name == "Makefile"
            || name == "Dockerfile"
            || name == ".gitlab-ci.yml"
            || name == "bitbucket-pipelines.yml"
            || (in_ci_dir && (name.ends_with(".yml") || name.ends_with(".yaml")));
        if name.starts_with(".env")
            || name.ends_with(".tpl")
            || name == "doppler.yaml"
            || name == ".infisical.json"
            || scanned
        {
            out.push(path);
        }
    }
}

fn secret_name(raw: &str) -> Option<String> {
    let name: String = raw
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' })
        .collect();
    let name = name.trim_matches('_').to_owned();
    is_env_name(&name).then_some(name)
}

/// `KEY=op://vault/item/field` and `{{ op://vault/item/field }}`: the reference, never what it
/// resolves to.
fn one_password(text: &str, shown: &str, read: &mut Read) {
    for line in text.lines() {
        let Some((before, from)) = line.find("op://").and_then(|at| line.split_at_checked(at))
        else {
            continue;
        };
        let reference: String = from
            .chars()
            .take_while(|c| !c.is_whitespace() && !matches!(c, '"' | '\'' | '}' | ')'))
            .collect();
        let before = before.trim().trim_start_matches("export ");
        let key = before.split_once('=').map(|(k, _)| k.trim()).filter(|k| is_env_name(k));
        let name = match key {
            Some(k) => Some(k.to_owned()),
            None => reference.rsplit('/').next().and_then(secret_name),
        };
        if let Some(name) = name {
            read.names
                .entry(name)
                .or_insert_with(|| format!("{shown} 1Password reference {reference}"));
        }
    }
}

fn doppler(text: &str, shown: &str, read: &mut Read) {
    let mut project = None;
    let mut config = None;
    if let Ok(docs) = YamlLoader::load_from_str(text)
        && let Some(doc) = docs.first()
    {
        let setup = &doc["setup"];
        let first = if setup.is_array() { &setup[0] } else { setup };
        project = first["project"].as_str().map(str::to_owned);
        config = first["config"].as_str().map(str::to_owned);
    }
    read.notes.push(format!(
        "Doppler ({shown}{}{}): its secret names live in Doppler; list them with doppler secrets --only-names, then set each with cmux cloud secret set NAME",
        project.map(|p| format!(", project {p}")).unwrap_or_default(),
        config.map(|c| format!(", config {c}")).unwrap_or_default(),
    ));
}

fn vault_and_aws(text: &str, shown: &str, read: &mut Read) {
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let words: Vec<&str> = line.split_whitespace().collect();
        for (i, w) in words.iter().enumerate() {
            let w_name = w.split('=').next().unwrap_or(w);
            let clean = w_name.trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '_');
            if clean.starts_with("VAULT_") && is_env_name(clean) {
                read.names
                    .entry(clean.to_owned())
                    .or_insert_with(|| format!("{shown} Vault variable"));
            }
            if *w == "vault"
                && words.get(i.saturating_add(1)) == Some(&"kv")
                && words.get(i.saturating_add(2)) == Some(&"get")
            {
                let args = words.get(i.saturating_add(3)..).unwrap_or_default();
                let field = args.iter().find_map(|a| a.strip_prefix("-field="));
                let path = args.iter().find(|a| !a.starts_with('-'));
                if let Some(path) = path.filter(|p| !p.contains('$')) {
                    let name = field
                        .and_then(secret_name)
                        .or_else(|| secret_name(path.rsplit('/').next().unwrap_or(path)));
                    if let Some(name) = name {
                        read.names
                            .entry(name)
                            .or_insert_with(|| format!("{shown} Vault path {path}"));
                    }
                }
            }
            if *w == "aws" {
                let (service, verb) =
                    (words.get(i.saturating_add(1)), words.get(i.saturating_add(2)));
                let (flag, label) = match (service, verb) {
                    (Some(&"secretsmanager"), Some(&"get-secret-value")) => {
                        ("--secret-id", "AWS Secrets Manager")
                    }
                    (Some(&"ssm"), Some(&"get-parameter" | &"get-parameters")) => {
                        ("--name", "AWS SSM parameter")
                    }
                    _ => continue,
                };
                let args = words.get(i.saturating_add(3)..).unwrap_or_default();
                let value = args.iter().enumerate().find_map(|(j, a)| {
                    match a.strip_prefix(&format!("{flag}=")) {
                        Some(v) => Some(v),
                        None => {
                            (*a == flag).then(|| args.get(j.saturating_add(1)).copied()).flatten()
                        }
                    }
                });
                let Some(id) =
                    value.map(|v| v.trim_matches(['"', '\''])).filter(|v| !v.contains('$'))
                else {
                    continue;
                };
                let last = id.rsplit([':', '/']).next().unwrap_or(id);
                if let Some(name) = secret_name(last) {
                    read.names.entry(name).or_insert_with(|| format!("{shown} {label} {id}"));
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "secrets_refs_tests.rs"]
mod tests;
