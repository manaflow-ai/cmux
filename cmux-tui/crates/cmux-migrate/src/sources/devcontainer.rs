//! A checkout's `devcontainer.json` (Codespaces, DevPod, Daytona and Coder's envbuilder read the
//! same file): `.devcontainer/devcontainer.json`, `.devcontainer.json`, and each
//! `.devcontainer/NAME/devcontainer.json`, one project per file, keyed by its path.
//!
//! An AutoCloud machine is a full VM, not a container, so the file is replayed rather than run:
//! features become install steps (mise or apt), lifecycle commands become `[setup]` in the order
//! the container would run them, `containerEnv`/`remoteEnv` become `[env]` (a
//! `${localEnv:X}` value becomes the secret name X, since its value lives on the person's
//! laptop), and a compose-based config is read by [`super::compose`] with its `service` as the
//! project.

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::compose;
use super::project_files::{
    ENSURE_DOCKER, ENSURE_MISE, apt_install, at, checkout_source, folder_name, is_env_name,
    looks_secret, mise_use, parse_jsonc, rel, repo_at, sh_quote, value_has_login,
};
use crate::plan::{MachineConfig, Plan, Project, SourceKind, Unsupported, machine_name};

/// One config's read: its project and what it could not take.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Read {
    pub project: Project,
    pub unsupported: Vec<Unsupported>,
    pub warnings: Vec<String>,
}

/// Every devcontainer config in the checkout, the default ones first, then
/// `.devcontainer/NAME/devcontainer.json` by name.
pub fn find(root: &Path) -> Vec<PathBuf> {
    let mut found: Vec<PathBuf> =
        [root.join(".devcontainer/devcontainer.json"), root.join(".devcontainer.json")]
            .into_iter()
            .filter(|p| p.is_file())
            .collect();
    if let Ok(entries) = std::fs::read_dir(root.join(".devcontainer")) {
        let mut nested: Vec<PathBuf> = entries
            .filter_map(Result::ok)
            .map(|e| e.path().join("devcontainer.json"))
            .filter(|p| p.is_file())
            .collect();
        nested.sort();
        found.extend(nested);
    }
    found
}

/// The checkout's first devcontainer config as a project (the one the tools open by default).
pub fn project(root: &Path) -> Option<Project> {
    projects(root).into_iter().next()
}

/// One project per devcontainer config that parses; what each could not take is in its notes.
pub fn projects(root: &Path) -> Vec<Project> {
    let files = find(root);
    let many = files.len() > 1;
    files
        .iter()
        .filter_map(|f| read_file(root, f, many).ok())
        .map(|mut r| {
            r.project.notes.extend(
                r.unsupported.iter().map(|u| format!("not carried: {} ({})", u.what, u.why)),
            );
            r.project
        })
        .collect()
}

/// The plan for a checkout's devcontainer configs: one project each.
pub fn plan(root: &Path) -> Plan {
    let mut plan = Plan::new(checkout_source(SourceKind::Devcontainer, root));
    let files = find(root);
    if files.is_empty() {
        plan.warnings.push(format!("no devcontainer.json in {}", root.display()));
    }
    let many = files.len() > 1;
    for file in &files {
        match read_file(root, file, many) {
            Ok(read) => {
                plan.projects.push(read.project);
                plan.unsupported.extend(read.unsupported);
                plan.warnings.extend(read.warnings);
            }
            Err(why) => plan.warnings.push(why),
        }
    }
    plan
}

/// One config file. `many` names the machine after the config's folder too, so several configs
/// in one checkout get distinct machines.
pub fn read_file(root: &Path, file: &Path, many: bool) -> Result<Read, String> {
    let shown = rel(root, file);
    let text = std::fs::read_to_string(file).map_err(|e| format!("cannot read {shown}: {e}"))?;
    let json = parse_jsonc(&text).map_err(|e| format!("{shown} is not JSON: {e}"))?;
    let Value::Object(_) = json else { return Err(format!("{shown} is not a JSON object")) };
    let config_dir = file.parent().unwrap_or(root).to_path_buf();

    let mut read = Read::default();
    let mut name = folder_name(root);
    if many {
        let sub = file
            .parent()
            .filter(|d| d.file_name().is_some_and(|n| n != ".devcontainer"))
            .map(folder_name);
        if let Some(sub) = sub {
            name = format!("{name}-{sub}");
        }
    }

    // A compose-based config: the compose reader gives the project, with `service` as the app.
    let compose_files: Vec<PathBuf> =
        strings(at(&json, &["dockerComposeFile"])).iter().map(|f| config_dir.join(f)).collect();
    let mut project = if compose_files.is_empty() {
        Project { repo: Some(repo_at(root)), checked: true, ..Project::default() }
    } else {
        let service = at(&json, &["service"]).as_str();
        let run_services: Option<Vec<String>> =
            json.get("runServices").map(strings).filter(|v| !v.is_empty());
        let r = compose::read_files(root, &compose_files, service, run_services.as_deref())?;
        read.unsupported.extend(r.unsupported);
        read.warnings.extend(r.warnings);
        let mut p = r.project;
        if let Some(service) = service {
            p.notes.push(format!("devcontainer service {service} is this project"));
        }
        p
    };
    project.key = shown.clone();
    project.name = machine_name(&name);
    if let Some(title) = at(&json, &["name"]).as_str() {
        project.notes.push(format!("devcontainer \"{title}\" ({shown})"));
    }
    let mut machine = std::mem::take(&mut project.machine);

    // The container the source ran in.
    if let Some(image) = at(&json, &["image"]).as_str() {
        project.image = Some(image.to_owned());
        project.notes.push(format!(
            "ran in image {image}; the machine is a full VM, so [setup] installs what the config's features and commands add"
        ));
    }
    let dockerfile =
        at(&json, &["build", "dockerfile"]).as_str().or(at(&json, &["dockerFile"]).as_str());
    if let Some(dockerfile) = dockerfile {
        let context = at(&json, &["build", "context"])
            .as_str()
            .or(at(&json, &["context"]).as_str())
            .unwrap_or(".");
        let dockerfile_path = rel(root, &config_dir.join(dockerfile));
        let context_path = rel(root, &config_dir.join(context));
        let tag = format!("{}-devcontainer", machine_name(&name));
        let mut build = format!("docker build -f {} -t {tag}", sh_quote(&dockerfile_path));
        if let Value::Object(args) = at(&json, &["build", "args"]) {
            for (k, v) in args {
                if let Some(v) = v.as_str() {
                    build.push_str(&format!(" --build-arg {}", sh_quote(&format!("{k}={v}"))));
                }
            }
        }
        if let Some(target) = at(&json, &["build", "target"]).as_str() {
            build.push_str(&format!(" --target {}", sh_quote(target)));
        }
        build.push(' ');
        build.push_str(&sh_quote(&context_path));
        push_once(&mut machine.setup, ENSURE_DOCKER);
        machine.setup.push(build);
        project.notes.push(format!(
            "built from {dockerfile_path}; [setup] builds it as {tag}, and its RUN steps are what the machine may still need"
        ));
    }

    // Features, in the file's order.
    if let Value::Object(features) = at(&json, &["features"]) {
        for (id, options) in features {
            match feature_steps(id, options) {
                Some(steps) => {
                    for step in steps {
                        push_once(&mut machine.setup, &step);
                    }
                }
                None => read.unsupported.push(Unsupported {
                    what: format!("feature {id}"),
                    why: "no install step is known for it; add one to [setup]".into(),
                }),
            }
        }
    }

    // Lifecycle commands, in the order a container runs them.
    if !at(&json, &["initializeCommand"]).is_null() {
        project.notes.push(
            "initializeCommand runs on the person's own computer before the container; it is not replayed on the machine".into(),
        );
    }
    for hook in ["onCreateCommand", "updateContentCommand", "postCreateCommand", "postStartCommand"]
    {
        let commands = lifecycle(at(&json, &[hook]));
        if hook == "postStartCommand" && !commands.is_empty() {
            project.notes.push(
                "postStartCommand ran on every container start; [setup] runs it when the config changes".into(),
            );
        }
        machine.setup.extend(commands);
    }
    if !at(&json, &["postAttachCommand"]).is_null() {
        project.notes.push(format!(
            "postAttachCommand ran on every attach and is not replayed: {}",
            lifecycle(at(&json, &["postAttachCommand"])).join("; ")
        ));
    }

    // Environment.
    for key in ["containerEnv", "remoteEnv"] {
        if let Value::Object(env) = at(&json, &[key]) {
            for (k, v) in env {
                let Some(v) = v.as_str() else { continue };
                env_entry(k, v, &mut machine);
            }
        }
    }
    if let Value::Object(secrets) = at(&json, &["secrets"]) {
        machine.secret_names.extend(secrets.keys().filter(|k| is_env_name(k)).cloned());
    }

    // Ports.
    for v in array(at(&json, &["forwardPorts"])).into_iter().chain(array(at(&json, &["appPort"]))) {
        let port = match v {
            Value::Number(n) => n.as_u64().and_then(|n| u16::try_from(n).ok()),
            Value::String(s) => s.rsplit(':').next().and_then(|p| p.trim().parse().ok()),
            _ => None,
        };
        if let Some(port) = port
            && !project.ports.contains(&port)
        {
            project.ports.push(port);
        }
    }

    // What a person should know.
    let extensions = strings(at(&json, &["customizations", "vscode", "extensions"]));
    if !extensions.is_empty() {
        project.notes.push(format!("VS Code extensions: {}", extensions.join(", ")));
    }
    for key in ["remoteUser", "containerUser"] {
        if let Some(user) = at(&json, &[key]).as_str() {
            project
                .notes
                .push(format!("{key} was {user}; on the machine commands run as its own user"));
        }
    }
    for (key, why) in [
        (
            "mounts",
            "a machine has its own disk; carry the files with the checkout or a dotfiles repo",
        ),
        ("runArgs", "docker run options do not apply to a VM"),
        ("workspaceMount", "the checkout is cloned onto the machine"),
    ] {
        if !at(&json, &[key]).is_null() {
            read.unsupported.push(Unsupported { what: format!("{shown}: {key}"), why: why.into() });
        }
    }
    if at(&json, &["hostRequirements", "gpu"]).as_bool() == Some(true)
        || at(&json, &["hostRequirements", "gpu"]).as_str().is_some_and(|g| g != "optional")
    {
        read.unsupported.push(Unsupported {
            what: format!("{shown}: hostRequirements.gpu"),
            why: "AutoCloud machines have no GPU yet".into(),
        });
    }

    project.machine = machine;
    read.project = project;
    Ok(read)
}

/// `containerEnv`/`remoteEnv` entry: `${localEnv:X}` names a secret X (the value is on the
/// person's laptop), `${containerEnv:X}` becomes the shell's `${X}`, a secret-looking name keeps
/// only its name.
fn env_entry(name: &str, value: &str, machine: &mut MachineConfig) {
    let local = local_env_refs(value);
    if !local.is_empty() {
        machine.secret_names.extend(local);
        return;
    }
    if looks_secret(name) || value_has_login(value) {
        machine.secret_names.insert(name.to_owned());
        return;
    }
    machine.env.insert(name.to_owned(), container_env_to_shell(value));
}

/// The X of every `${localEnv:X}` / `${localEnv:X:default}`.
pub fn local_env_refs(value: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = value;
    while let Some((_, after)) = rest.split_once("${localEnv:") {
        rest = after;
        let name = rest.split(['}', ':']).next().unwrap_or_default();
        if is_env_name(name) && !out.iter().any(|n| n == name) {
            out.push(name.to_owned());
        }
    }
    out
}

fn container_env_to_shell(value: &str) -> String {
    let mut out = String::new();
    let mut rest = value;
    while let Some((before, after)) = rest.split_once("${containerEnv:") {
        out.push_str(before);
        let (inner, next) = after.split_once('}').unwrap_or((after, ""));
        match inner.split_once(':') {
            Some((name, default)) => out.push_str(&format!("${{{name}:-{default}}}")),
            None => out.push_str(&format!("${{{inner}}}")),
        }
        rest = next;
    }
    out.push_str(rest);
    out
}

/// A lifecycle command in any of its forms: a string (run by a shell), an array (one command, no
/// shell), or an object of named commands (run in parallel in a container; in order here).
pub fn lifecycle(value: &Value) -> Vec<String> {
    match value {
        Value::String(s) if !s.trim().is_empty() => vec![s.clone()],
        Value::Array(argv) => {
            let words: Vec<String> = argv.iter().filter_map(Value::as_str).map(sh_quote).collect();
            if words.is_empty() { Vec::new() } else { vec![words.join(" ")] }
        }
        Value::Object(named) => named.values().flat_map(lifecycle).collect(),
        _ => Vec::new(),
    }
}

/// Install steps for a devcontainer feature, or `None` when none is known. The id's last path
/// part names it (`ghcr.io/devcontainers/features/node:1` is `node`).
pub fn feature_steps(id: &str, options: &Value) -> Option<Vec<String>> {
    let short = id.rsplit('/').next().unwrap_or(id);
    let short = short.split([':', '@']).next().unwrap_or(short);
    // Only the official collection's ids are taken by short name; others may differ.
    let official = !id.contains('/') || id.contains("devcontainers/features/");
    if !official {
        return None;
    }
    let version = |default: &str| -> String {
        match options["version"].as_str().or(options.as_str()) {
            None | Some("") | Some("os-provided") | Some("latest") | Some("none") => {
                default.to_owned()
            }
            Some("lts") if short != "node" => "latest".to_owned(),
            Some(v) => v.to_owned(),
        }
    };
    let mise = |tool: &str, v: String| vec![ENSURE_MISE.to_owned(), mise_use(tool, &v)];
    let steps = match short {
        "node" => mise("node", version("lts")),
        "python" => mise("python", version("latest")),
        "go" => mise("go", version("latest")),
        "rust" => mise("rust", version("latest")),
        "java" => mise("java", version("latest")),
        "terraform" => mise("terraform", version("latest")),
        "github-cli" => mise("gh", version("latest")),
        "aws-cli" => mise("aws-cli", version("latest")),
        "kubectl-helm-minikube" => {
            let mut steps = vec![ENSURE_MISE.to_owned()];
            for tool in ["kubectl", "helm", "minikube"] {
                let v = match options[tool].as_str() {
                    None | Some("") | Some("latest") => "latest".to_owned(),
                    Some("none") => continue,
                    Some(v) => v.to_owned(),
                };
                steps.push(mise_use(tool, &v));
            }
            steps
        }
        "dotnet" => {
            let channel = match options["version"].as_str() {
                None | Some("") | Some("latest") | Some("lts") => "LTS".to_owned(),
                Some(v) => v.to_owned(),
            };
            vec![format!(
                "command -v dotnet >/dev/null 2>&1 || [ -x \"$HOME/.dotnet/dotnet\" ] || curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel {}",
                sh_quote(&channel)
            )]
        }
        "azure-cli" => vec![
            "command -v az >/dev/null 2>&1 || curl -fsSL https://aka.ms/InstallAzureCLIDeb | sudo bash".into(),
        ],
        "docker-in-docker" | "docker-outside-of-docker" => vec![ENSURE_DOCKER.to_owned()],
        "common-utils" => {
            let mut steps =
                vec![apt_install("curl wget git zsh less jq unzip zip ca-certificates procps lsof")];
            if options["configureZshAsDefaultShell"].as_bool() == Some(true) {
                steps.push("sudo chsh -s \"$(command -v zsh)\" \"$USER\"".into());
            }
            steps
        }
        "git" => vec![apt_install("git")],
        "git-lfs" => vec![apt_install("git-lfs"), "git lfs install".into()],
        // The machine already serves SSH.
        "sshd" => Vec::new(),
        _ => return None,
    };
    Some(steps)
}

fn strings(value: &Value) -> Vec<String> {
    match value {
        Value::String(s) => vec![s.clone()],
        Value::Array(items) => items.iter().filter_map(|i| i.as_str().map(str::to_owned)).collect(),
        _ => Vec::new(),
    }
}

fn array(value: &Value) -> Vec<Value> {
    match value {
        Value::Array(items) => items.clone(),
        Value::Null => Vec::new(),
        other => vec![other.clone()],
    }
}

fn push_once(setup: &mut Vec<String>, step: &str) {
    if !setup.iter().any(|s| s == step) {
        setup.push(step.to_owned());
    }
}

#[cfg(test)]
#[path = "devcontainer_tests.rs"]
mod tests;
