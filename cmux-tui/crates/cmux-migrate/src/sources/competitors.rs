//! Other cloud dev environments: pure parsers over what each product exports (its CLI's JSON, its
//! config file), and [`route`], how to reach each product's box when it has one.
//!
//! - GitHub Codespaces: [`codespaces_plan`] over `gh codespace list --json ...` and the
//!   Codespaces secret names.
//! - Gitpod / Ona: [`gitpod_plan`] over `.gitpod.yml`. (`gitpod workspace list -o json`'s schema is
//!   not published in a form checked here, so only the file is read.)
//! - Coder: [`coder_plan`] over `coder list -o json`; each workspace is then an SSH host
//!   (`coder.<ws>`) for [`super::ssh_host`].
//! - Daytona, exe.dev, Namespace, DevPod, Devin, Capy: [`route`].

use serde_json::Value;
use yaml_rust::{Yaml, YamlLoader};

use crate::plan::{Plan, Project, Repo, Source, SourceKind, Unsupported, machine_name};

/// The fields to ask `gh codespace list` for. `gh codespace view --json` also has
/// `devcontainerPath`; a list entry that carries it (merged in by the CLI) is read too.
pub const CODESPACES_LIST_FIELDS: &str =
    "name,displayName,repository,gitStatus,machineName,state,lastUsedAt";

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// Secret names from `gh secret list --app codespaces --json name` (`[{"name":..}]`) or
/// `gh api /user/codespaces/secrets` (`{"secrets":[{"name":..}]}`).
pub fn codespaces_secret_names(json: &str) -> Result<Vec<String>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("codespaces secrets: {e}"))?;
    let list = match &v {
        Value::Array(a) => a,
        Value::Object(_) => v
            .get("secrets")
            .and_then(Value::as_array)
            .ok_or("codespaces secrets: no \"secrets\" list")?,
        _ => return Err("codespaces secrets: not a list".into()),
    };
    Ok(list.iter().filter_map(|s| str_of(s, "name")).map(str::to_owned).collect())
}

/// One project per codespace from `gh codespace list --json CODESPACES_LIST_FIELDS`; every
/// secret name in `secrets_json` (either form [`codespaces_secret_names`] reads) is asked for on
/// every project, since a user secret's repository list is not in that answer.
pub fn codespaces_plan(list_json: &str, secrets_json: Option<&str>) -> Result<Plan, String> {
    let list: Vec<Value> =
        serde_json::from_str(list_json).map_err(|e| format!("gh codespace list: {e}"))?;
    let secrets = match secrets_json {
        Some(s) => codespaces_secret_names(s)?,
        None => Vec::new(),
    };
    let mut plan = Plan::new(Source {
        kind: SourceKind::Codespaces,
        label: "GitHub Codespaces".into(),
        id: "codespaces".into(),
    });
    for cs in &list {
        let Some(name) = str_of(cs, "name") else { continue };
        let repository = str_of(cs, "repository");
        let git = cs.get("gitStatus").cloned().unwrap_or(Value::Null);
        let ahead = git.get("ahead").and_then(Value::as_u64).unwrap_or(0);
        let unpushed_flag = git.get("hasUnpushedChanges").and_then(Value::as_bool).unwrap_or(false);
        let uncommitted =
            git.get("hasUncommittedChanges").and_then(Value::as_bool).unwrap_or(false);
        let repo_base = repository.and_then(|r| r.rsplit('/').next());
        let repo = Repo {
            url: repository.map(|r| format!("https://github.com/{r}.git")),
            branch: str_of(&git, "ref").map(str::to_owned),
            commit: None,
            // Codespaces check the repo out at /workspaces/<repo>.
            path: repo_base.map(|b| format!("/workspaces/{b}")),
            // The API says only whether there are uncommitted files: at least one.
            dirty_files: u32::from(uncommitted),
            unpushed_commits: if ahead > 0 {
                u32::try_from(ahead).unwrap_or(u32::MAX)
            } else {
                u32::from(unpushed_flag)
            },
        };
        let mut project = Project {
            key: name.to_owned(),
            name: machine_name(str_of(cs, "displayName").or(repo_base).unwrap_or(name)),
            checked: true,
            ..Default::default()
        };
        project.machine.secret_names.extend(secrets.iter().cloned());
        if repo.carry_worktree()
            && let Some(path) = &repo.path
        {
            project.notes.push(format!(
                "local work is carried with `gh codespace ssh -c {name} -- git -C {path} bundle \
                 create - --all > {name}.bundle`"
            ));
            plan.warnings.push(format!(
                "codespace {name} has uncommitted or unpushed work: it is carried as a git bundle"
            ));
        }
        match str_of(cs, "devcontainerPath") {
            Some(p) => project.notes.push(format!(
                "its devcontainer ({p}) is read by the devcontainer reader from the clone"
            )),
            None => project.notes.push(
                "a .devcontainer in the repo is read by the devcontainer reader from the clone"
                    .into(),
            ),
        }
        if let Some(m) = str_of(cs, "machineName") {
            project.notes.push(format!("ran on Codespaces machine type {m}"));
        }
        if let Some(state) = str_of(cs, "state")
            && state != "Available"
            && repo.carry_worktree()
        {
            project.notes.push(format!(
                "the codespace is {state}: `gh codespace ssh` starts it to read the work"
            ));
        }
        project.repo = Some(repo);
        plan.projects.push(project);
    }
    if !secrets.is_empty() {
        plan.warnings.push(
            "Codespaces secret values are not readable from outside a codespace: each is asked for \
             once and delivered with `cloud deliver-secrets`"
                .into(),
        );
    }
    Ok(plan)
}

fn yaml_str(y: &Yaml) -> Option<String> {
    match y {
        Yaml::String(s) => Some(s.clone()),
        Yaml::Integer(i) => Some(i.to_string()),
        Yaml::Real(r) => Some(r.clone()),
        Yaml::Boolean(b) => Some(b.to_string()),
        _ => None,
    }
}

/// Ports of a `.gitpod.yml` `port:` value: `3000`, or a range `"3000-3002"` (at most 20 kept).
fn gitpod_ports(y: &Yaml) -> Vec<u16> {
    let Some(s) = yaml_str(y) else { return Vec::new() };
    if let Some((a, b)) = s.split_once('-')
        && let (Ok(a), Ok(b)) = (a.trim().parse::<u16>(), b.trim().parse::<u16>())
    {
        return (a..=b.max(a)).take(20).collect();
    }
    s.trim().parse().map(|p| vec![p]).unwrap_or_default()
}

/// The project a `.gitpod.yml` describes. Each task's `before` and `init` become `[setup] run`,
/// in task order; its `command` (a dev server or watcher that does not exit, which would hold
/// setup forever) becomes a note naming what to start. `env` under a task becomes `[env]`.
pub fn gitpod_plan(label: &str, repo_url: Option<&str>, gitpod_yml: &str) -> Result<Plan, String> {
    let docs = YamlLoader::load_from_str(gitpod_yml).map_err(|e| format!(".gitpod.yml: {e}"))?;
    let doc = docs.into_iter().next().unwrap_or(Yaml::Null);
    let mut plan = Plan::new(Source {
        kind: SourceKind::Gitpod,
        label: label.to_owned(),
        id: format!("gitpod:{label}"),
    });
    let mut project = Project {
        key: label.to_owned(),
        name: machine_name(label.rsplit('/').next().unwrap_or(label).trim_end_matches(".git")),
        repo: repo_url
            .map(|u| Repo { url: Some(crate::plan::strip_login(u)), ..Default::default() }),
        checked: true,
        ..Default::default()
    };
    if let Some(tasks) = doc["tasks"].as_vec() {
        for (i, task) in tasks.iter().enumerate() {
            for key in ["before", "init"] {
                if let Some(cmd) = yaml_str(&task[key]) {
                    let cmd = cmd.trim();
                    if !cmd.is_empty() {
                        project.machine.setup.push(cmd.to_owned());
                    }
                }
            }
            if let Some(cmd) = yaml_str(&task["command"]) {
                let name = yaml_str(&task["name"])
                    .unwrap_or_else(|| format!("task {}", i.saturating_add(1)));
                project.notes.push(format!("{name} starts with: {}", cmd.trim()));
            }
            if let Some(env) = task["env"].as_hash() {
                for (k, v) in env {
                    if let (Some(k), Some(v)) = (yaml_str(k), yaml_str(v)) {
                        project.machine.env.insert(k, v);
                    }
                }
            }
        }
    }
    if let Some(ports) = doc["ports"].as_vec() {
        for p in ports {
            for port in gitpod_ports(&p["port"]) {
                if !project.ports.contains(&port) {
                    project.ports.push(port);
                }
            }
        }
    }
    match &doc["image"] {
        Yaml::String(image) => project.image = Some(image.clone()),
        Yaml::Hash(_) => {
            if let Some(file) = yaml_str(&doc["image"]["file"]) {
                project.notes.push(format!(
                    "the workspace image is built from {file}: its RUN lines belong in [setup]"
                ));
            }
        }
        _ => {}
    }
    if let Some(exts) = doc["vscode"]["extensions"].as_vec() {
        let exts: Vec<String> = exts.iter().filter_map(yaml_str).collect();
        if !exts.is_empty() {
            project.notes.push(format!("VS Code extensions: {}", exts.join(", ")));
        }
    }
    if !doc["github"]["prebuilds"].is_badvalue() && !doc["github"]["prebuilds"].is_null() {
        plan.unsupported.push(Unsupported {
            what: "Gitpod prebuilds".into(),
            why: "AutoCloud runs [setup] when a machine is made; there is no prebuild trigger yet"
                .into(),
        });
    }
    plan.projects.push(project);
    Ok(plan)
}

/// One placeholder project per Coder workspace from `coder list -o json`, unchecked: its repos and
/// setup are read by running the SSH probe on `coder.<ws>` (after `coder config-ssh`). The
/// template's Terraform is Unsupported.
pub fn coder_plan(list_json: &str) -> Result<Plan, String> {
    let list: Vec<Value> =
        serde_json::from_str(list_json).map_err(|e| format!("coder list: {e}"))?;
    let mut plan =
        Plan::new(Source { kind: SourceKind::Coder, label: "Coder".into(), id: "coder".into() });
    let mut templates: Vec<String> = Vec::new();
    for ws in &list {
        let Some(name) = str_of(ws, "name") else { continue };
        let owner = str_of(ws, "owner_name");
        let mut project = Project {
            key: match owner {
                Some(o) => format!("{o}/{name}"),
                None => name.to_owned(),
            },
            name: machine_name(name),
            checked: false,
            ..Default::default()
        };
        project.notes.push(format!(
            "SSH-reachable: `coder config-ssh`, then the SSH host importer on coder.{name} reads \
             its repos, tools and dotfiles"
        ));
        if let Some(status) = ws.get("latest_build").and_then(|b| str_of(b, "status"))
            && status != "running"
        {
            project.notes.push(format!("the workspace is {status}: `coder start {name}` first"));
        }
        if let Some(t) = str_of(ws, "template_name") {
            project.notes.push(format!("made from template {t}"));
            if !templates.iter().any(|x| x == t) {
                templates.push(t.to_owned());
            }
        }
        plan.projects.push(project);
    }
    for t in templates {
        plan.unsupported.push(Unsupported {
            what: format!("Coder template {t}"),
            why:
                "a template's Terraform provisions infrastructure AutoCloud makes itself; copy its \
                  startup script into the project's [setup]"
                    .into(),
        });
    }
    Ok(plan)
}

/// A product people move from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Product {
    Codespaces,
    Gitpod,
    Coder,
    Daytona,
    ExeDev,
    Namespace,
    DevPod,
    Devin,
    Capy,
}

impl Product {
    pub const ALL: [Product; 9] = [
        Product::Codespaces,
        Product::Gitpod,
        Product::Coder,
        Product::Daytona,
        Product::ExeDev,
        Product::Namespace,
        Product::DevPod,
        Product::Devin,
        Product::Capy,
    ];
}

/// How a product's workspace is read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// The workspace is defined by the repo's `.devcontainer/devcontainer.json`: clone it and read
    /// that file ([`SourceKind::Devcontainer`]).
    Devcontainer,
    /// The box is reachable over SSH: run [`super::ssh_host::PROBE`] through `how`.
    SshHost { how: &'static str },
    /// No box a person can reach: `imports` is what can still be brought over.
    Unsupported { why: &'static str, imports: &'static str },
}

/// How each product's workspaces move. Facts checked 2026-11-24 against each product's docs;
/// the ones marked "unverified" in the source were not confirmed.
pub fn route(product: Product) -> Route {
    match product {
        // `gh codespace ssh -c NAME` runs a command in a codespace (gh CLI docs); the devcontainer
        // is in the repo. [`codespaces_plan`] reads the list.
        Product::Codespaces => Route::SshHost { how: "gh codespace ssh -c <codespace> --" },
        // Ona (formerly Gitpod) environments are defined by devcontainer.json; classic Gitpod by
        // `.gitpod.yml` ([`gitpod_plan`]).
        Product::Gitpod => Route::Devcontainer,
        // `coder config-ssh` writes `Host coder.<workspace>` entries (Coder docs).
        Product::Coder => Route::SshHost { how: "coder config-ssh, then ssh coder.<workspace>" },
        // Unverified: Daytona's CLI has had `daytona ssh <workspace>`; its newer sandboxes give
        // SSH access through a token from the dashboard or SDK.
        Product::Daytona => Route::SshHost { how: "daytona ssh <sandbox>" },
        // `ssh <vm>.exe.xyz` is a full shell on the VM; `ssh exe.dev` is only the lobby (exe.dev
        // docs, "How do I write my VM's SSH destination?").
        Product::ExeDev => Route::SshHost { how: "ssh <vm>.exe.xyz" },
        // `nsc ssh <instance-id>` for compute instances; Devboxes: `devbox ssh <name>` (Namespace
        // docs).
        Product::Namespace => {
            Route::SshHost { how: "nsc ssh <instance> (a Devbox: devbox ssh <name>)" }
        }
        // DevPod workspaces are devcontainers, and `devpod ssh <ws>` reaches local work too.
        Product::DevPod => Route::SshHost { how: "devpod ssh <workspace> --command" },
        // Devin works in its own machine snapshot; there is no SSH into it (unverified beyond its
        // docs' "Machine setup" flow).
        Product::Devin => Route::Unsupported {
            why: "Devin's machine is Devin's own: no shell a person can reach",
            imports: "the repos Devin was set up on, the setup and lint/test commands entered in \
                      its machine setup, and the secret names in its Secrets page (values asked \
                      for once)",
        },
        // Unverified: Capy runs each task in its own cloud sandbox with no published SSH access.
        Product::Capy => Route::Unsupported {
            why: "Capy's task sandboxes are not reachable from outside (unverified)",
            imports: "the repos connected to Capy, the setup script entered for each, and the \
                      environment variable names configured there (values asked for once)",
        },
    }
}

#[cfg(test)]
#[path = "competitors_tests.rs"]
mod tests;
