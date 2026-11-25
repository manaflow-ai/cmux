//! A checkout's `compose.yaml` / `docker-compose.yml`: the app service (the one with `build:`,
//! or the one a devcontainer names) becomes the project, and every other service (postgres,
//! redis...) a sidecar the machine starts with `docker compose up -d`.
//!
//! The app runs on the machine itself (an AutoCloud machine is a full VM), so its `environment`
//! goes to `[env]`, except names that look secret (`PASSWORD`, `SECRET`, `TOKEN`, `KEY`,
//! `PRIVATE`) or values that carry a login: those go to `[secrets] names` and their values never
//! enter the plan. An `env_file`'s keys become secret names; its values are never read into the
//! plan.

use std::path::{Path, PathBuf};

use yaml_rust::{Yaml, YamlLoader};

use super::project_files::{
    ENSURE_DOCKER, checkout_source, dotenv_keys, folder_name, looks_secret, rel, repo_at, sh_quote,
    shell_refs, value_has_login,
};
use crate::plan::{MachineConfig, Plan, Project, SourceKind, Unsupported, machine_name};

/// The file names `docker compose` looks for, in its own order.
pub const FILE_NAMES: [&str; 4] =
    ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"];

/// What a compose read gives: the project and what it could not take.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Read {
    pub project: Project,
    pub unsupported: Vec<Unsupported>,
    pub warnings: Vec<String>,
}

/// The checkout's compose file, if it has one.
pub fn find(root: &Path) -> Option<PathBuf> {
    FILE_NAMES.iter().map(|n| root.join(n)).find(|p| p.is_file())
}

/// The checkout's compose project, or `None` without a compose file (or with one that does not
/// parse; [`plan`] says why).
pub fn project(root: &Path) -> Option<Project> {
    let file = find(root)?;
    read_files(root, &[file], None, None).ok().map(|r| r.project)
}

/// The plan for a checkout with a compose file: one project, or none and a warning.
pub fn plan(root: &Path) -> Plan {
    let mut plan = Plan::new(checkout_source(SourceKind::Compose, root));
    let Some(file) = find(root) else {
        plan.warnings.push(format!("no compose file in {}", root.display()));
        return plan;
    };
    match read_files(root, &[file], None, None) {
        Ok(read) => {
            plan.projects.push(read.project);
            plan.unsupported.extend(read.unsupported);
            plan.warnings.extend(read.warnings);
        }
        Err(why) => plan.warnings.push(why),
    }
    plan
}

/// Reads compose files (later ones override earlier ones' services, as `docker compose -f A -f
/// B`) into one project rooted at the checkout. `app` names the service that is the project (a
/// devcontainer's `service`); without one it is the first service with `build:`. `run_services`
/// limits the sidecars (a devcontainer's `runServices`).
pub fn read_files(
    root: &Path,
    files: &[PathBuf],
    app: Option<&str>,
    run_services: Option<&[String]>,
) -> Result<Read, String> {
    let mut services: Vec<(String, Yaml)> = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(file)
            .map_err(|e| format!("cannot read {}: {e}", rel(root, file)))?;
        let docs = YamlLoader::load_from_str(&text)
            .map_err(|e| format!("{} is not YAML: {e}", rel(root, file)))?;
        let Some(Yaml::Hash(top)) = docs.into_iter().next() else { continue };
        if let Some(Yaml::Hash(map)) = top.get(&Yaml::String("services".into())) {
            for (name, service) in map {
                let Some(name) = name.as_str() else { continue };
                if let Some(slot) = services.iter_mut().find(|(n, _)| n == name) {
                    slot.1 = merge(&slot.1, service);
                } else {
                    services.push((name.to_owned(), service.clone()));
                }
            }
        }
    }
    let Some(first) = files.first() else { return Err("no compose file".into()) };
    if services.is_empty() {
        return Err(format!("{} names no services", rel(root, first)));
    }
    let compose_dir = first.parent().unwrap_or(root).to_path_buf();
    let app_name = match app {
        Some(name) => {
            if !services.iter().any(|(n, _)| n == name) {
                return Err(format!("{} has no service {name}", rel(root, first)));
            }
            Some(name.to_owned())
        }
        None => services.iter().find(|(_, s)| !s["build"].is_badvalue()).map(|(n, _)| n.clone()),
    };

    let mut read = Read::default();
    let mut machine = MachineConfig::default();
    let mut project = Project {
        key: rel(root, first),
        name: machine_name(&folder_name(root)),
        repo: Some(repo_at(root)),
        checked: true,
        ..Project::default()
    };
    let file_args: String =
        files.iter().map(|f| format!(" -f {}", sh_quote(&rel(root, f)))).collect();

    if let Some(app_name) = &app_name
        && let Some((_, service)) = services.iter().find(|(n, _)| n == app_name)
    {
        project.notes.push(format!(
            "service {app_name} is this project: it runs on the machine itself, not in a container"
        ));
        if let Some(image) = service["image"].as_str() {
            project.image = Some(image.to_owned());
            project.notes.push(format!(
                "{app_name} ran in image {image}; the machine is a full VM, so [setup] replays its setup instead"
            ));
        }
        if !service["build"].is_badvalue() {
            machine.setup.push(ENSURE_DOCKER.to_owned());
            machine.setup.push(format!("docker compose{file_args} build {}", sh_quote(app_name)));
            project.notes.push(format!(
                "{app_name} was built from a Dockerfile; [setup] builds the image too, and its RUN steps are what the machine may still need"
            ));
        }
        for port in ports(&service["ports"], PortSide::Container) {
            push_port(&mut project.ports, port);
        }
        for port in ports(&service["expose"], PortSide::Container) {
            push_port(&mut project.ports, port);
        }
        environment(&service["environment"], &mut machine);
        for env_file in env_files(&service["env_file"]) {
            let path = compose_dir.join(&env_file);
            let shown = rel(root, &path);
            match std::fs::read_to_string(&path) {
                Ok(text) => {
                    let keys = dotenv_keys(&text);
                    project.notes.push(format!(
                        "env_file {shown}: its {} names are secrets on the machine, delivered by cloud deliver-secrets",
                        keys.len()
                    ));
                    machine.secret_names.extend(keys);
                }
                Err(_) => project.notes.push(format!(
                    "env_file {shown} is not in the checkout; deliver its values with cloud deliver-secrets"
                )),
            }
        }
        for key in ["volumes", "network_mode", "privileged", "cap_add", "devices"] {
            if !service[key].is_badvalue() {
                read.unsupported.push(Unsupported {
                    what: format!("{app_name}: {key}"),
                    why: "the app runs on the machine itself, not in a container, so container options do not apply".into(),
                });
            }
        }
    }

    let mut sidecars = Vec::new();
    for (name, service) in &services {
        if Some(name) == app_name.as_ref() {
            continue;
        }
        if let Some(only) = run_services
            && !only.iter().any(|s| s == name)
        {
            continue;
        }
        if !service["profiles"].is_badvalue() {
            project.notes.push(format!(
                "service {name} is behind a profile and is not started by [setup]; start it with docker compose --profile"
            ));
            continue;
        }
        for port in ports(&service["ports"], PortSide::Host) {
            push_port(&mut project.ports, port);
        }
        // Compose reads `${X}` from the shell or `.env` when it starts the service; setup gets no
        // secret values, so name them for the person.
        let mut refs = Vec::new();
        collect_refs(service, &mut refs);
        if !refs.is_empty() {
            read.warnings.push(format!(
                "service {name} reads {} from the environment when compose starts it; [setup] runs without secret values, so put them in the machine's .env",
                refs.join(", ")
            ));
        }
        if !service["env_file"].is_badvalue() {
            project.notes.push(format!(
                "service {name} reads env_file {}; it must exist on the machine before docker compose up",
                env_files(&service["env_file"]).join(", ")
            ));
        }
        sidecars.push(name.clone());
    }
    if !sidecars.is_empty() {
        if !machine.setup.iter().any(|s| s == ENSURE_DOCKER) {
            machine.setup.push(ENSURE_DOCKER.to_owned());
        }
        let names: Vec<String> = sidecars.iter().map(|s| sh_quote(s)).collect();
        machine.setup.push(format!("docker compose{file_args} up -d {}", names.join(" ")));
        project.services = sidecars;
    }
    if app_name.is_none() {
        project
            .notes
            .push("no service is built here, so every service runs beside the checkout".into());
    }
    if compose_dir.join(".env").is_file() {
        project.notes.push(format!(
            "{} sets compose's variables; it stays out of the plan, deliver what it holds with cloud deliver-secrets",
            rel(root, &compose_dir.join(".env"))
        ));
    }
    project.machine = machine;
    read.project = project;
    Ok(read)
}

/// A service merged over an earlier file's: maps merge key by key, anything else is replaced.
fn merge(base: &Yaml, over: &Yaml) -> Yaml {
    match (base, over) {
        (Yaml::Hash(b), Yaml::Hash(o)) => {
            let mut out = b.clone();
            for (k, v) in o {
                let merged = match out.get(k) {
                    Some(existing) => merge(existing, v),
                    None => v.clone(),
                };
                out.insert(k.clone(), merged);
            }
            Yaml::Hash(out)
        }
        _ => over.clone(),
    }
}

fn environment(env: &Yaml, machine: &mut MachineConfig) {
    let mut entries: Vec<(String, Option<String>)> = Vec::new();
    match env {
        Yaml::Hash(map) => {
            for (k, v) in map {
                let Some(k) = k.as_str() else { continue };
                entries.push((k.to_owned(), scalar(v)));
            }
        }
        Yaml::Array(items) => {
            for item in items {
                let Some(item) = item.as_str() else { continue };
                match item.split_once('=') {
                    Some((k, v)) => entries.push((k.to_owned(), Some(v.to_owned()))),
                    None => entries.push((item.to_owned(), None)),
                }
            }
        }
        _ => {}
    }
    for (name, value) in entries {
        match value {
            // Passed through from the host's shell: the value is the person's to deliver.
            None => {
                machine.secret_names.insert(name);
            }
            Some(value) if looks_secret(&name) || value_has_login(&value) => {
                machine.secret_names.insert(name);
            }
            Some(value) => {
                // `${X}` comes from the person's shell or `.env`: X is theirs to deliver.
                machine.secret_names.extend(shell_refs(&value));
                machine.env.insert(name, value);
            }
        }
    }
}

fn scalar(value: &Yaml) -> Option<String> {
    match value {
        Yaml::String(s) => Some(s.clone()),
        Yaml::Integer(i) => Some(i.to_string()),
        Yaml::Real(r) => Some(r.clone()),
        Yaml::Boolean(b) => Some(b.to_string()),
        _ => None,
    }
}

fn env_files(value: &Yaml) -> Vec<String> {
    match value {
        Yaml::String(s) => vec![s.clone()],
        Yaml::Array(items) => items
            .iter()
            .filter_map(|i| {
                i.as_str().map(str::to_owned).or_else(|| i["path"].as_str().map(str::to_owned))
            })
            .collect(),
        Yaml::Hash(_) => value["path"].as_str().map(|s| vec![s.to_owned()]).unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn collect_refs(value: &Yaml, out: &mut Vec<String>) {
    match value {
        Yaml::String(s) => {
            for r in shell_refs(s) {
                if !out.contains(&r) {
                    out.push(r);
                }
            }
        }
        Yaml::Array(items) => items.iter().for_each(|i| collect_refs(i, out)),
        Yaml::Hash(map) => map.values().for_each(|v| collect_refs(v, out)),
        _ => {}
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PortSide {
    /// The port the process listens on (the app runs on the machine, so it listens there).
    Container,
    /// The port published on the host (a sidecar's, reached from the machine).
    Host,
}

fn ports(value: &Yaml, side: PortSide) -> Vec<u16> {
    let Yaml::Array(items) = value else { return Vec::new() };
    let mut out = Vec::new();
    for item in items {
        match item {
            Yaml::Integer(p) => out.extend(u16::try_from(*p).ok()),
            Yaml::String(s) => out.extend(short_port(s, side)),
            Yaml::Hash(_) => {
                let target = item["target"].as_i64().and_then(|p| u16::try_from(p).ok());
                let published =
                    scalar(&item["published"]).and_then(|p| range(&p).into_iter().next());
                let port = match side {
                    PortSide::Container => target,
                    PortSide::Host => published.or(target),
                };
                out.extend(port);
            }
            _ => {}
        }
    }
    out
}

/// `3000`, `8080:80`, `127.0.0.1:8080:80/tcp`, `3000-3002:3000-3002`.
fn short_port(spec: &str, side: PortSide) -> Vec<u16> {
    let spec = spec.split('/').next().unwrap_or(spec);
    let parts: Vec<&str> = spec.rsplitn(3, ':').collect();
    let container = parts.first().copied().unwrap_or("");
    let host = parts.get(1).copied().filter(|h| !h.is_empty());
    match side {
        PortSide::Container => range(container),
        PortSide::Host => range(host.unwrap_or(container)),
    }
}

fn range(spec: &str) -> Vec<u16> {
    match spec.split_once('-') {
        Some((a, b)) => match (a.trim().parse::<u16>(), b.trim().parse::<u16>()) {
            (Ok(a), Ok(b)) if b.checked_sub(a).is_some_and(|span| span < 100) => (a..=b).collect(),
            (Ok(a), _) => vec![a],
            _ => Vec::new(),
        },
        None => spec.trim().parse().ok().into_iter().collect(),
    }
}

fn push_port(ports: &mut Vec<u16>, port: u16) {
    if !ports.contains(&port) {
        ports.push(port);
    }
}

#[cfg(test)]
#[path = "compose_tests.rs"]
mod tests;
