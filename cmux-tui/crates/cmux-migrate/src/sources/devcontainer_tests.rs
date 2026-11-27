use std::path::Path;

use super::*;
use crate::sources::project_files::{ENSURE_DOCKER, ENSURE_MISE, strip_jsonc};

fn write(root: &Path, path: &str, text: &str) {
    let path = root.join(path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn checkout() -> tempfile::TempDir {
    let dir = tempfile::Builder::new().prefix("web-app").tempdir().unwrap();
    write(dir.path(), ".git/HEAD", "ref: refs/heads/main\n");
    write(
        dir.path(),
        ".git/config",
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://me:ghp_secret@github.com/me/web.git\n",
    );
    dir
}

const JSONC: &str = r#"
// The team's container.
{
  "name": "Web // not a comment",
  /* block
     comment */
  "image": "mcr.microsoft.com/devcontainers/typescript-node:20",
  "features": {
    "ghcr.io/devcontainers/features/node:1": { "version": "20" },
    "ghcr.io/devcontainers/features/python:1": {},
    "ghcr.io/devcontainers/features/docker-in-docker:2": {},
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": { "minikube": "none" },
    "ghcr.io/someone/features/weird-tool:1": {},
  },
  "onCreateCommand": "echo create",
  "updateContentCommand": ["npm", "ci", "--no-audit"],
  "postCreateCommand": { "deps": "bun install", "db": ["bun", "run", "db:migrate"] },
  "postStartCommand": "bun run dev &",
  "containerEnv": {
    "NODE_ENV": "development",
    "GITHUB_TOKEN": "${localEnv:GITHUB_TOKEN}",
    "OPENAI": "${localEnv:OPENAI_API_KEY:}",
    "PATH": "${containerEnv:PATH}:/opt/bin",
  },
  "remoteEnv": { "API_SECRET": "planted-value-xyz" },
  "forwardPorts": [3000, "db:5432"],
  "appPort": "8080:80",
  "customizations": { "vscode": { "extensions": ["dbaeumer.vscode-eslint", "esbenp.prettier-vscode"] } },
  "secrets": { "STRIPE_KEY": { "description": "test key" } },
  "remoteUser": "node",
  "mounts": ["source=x,target=/y,type=bind"],
}
"#;

#[test]
fn jsonc_comments_and_trailing_commas_are_removed_but_strings_kept() {
    let text = r#"{"a": "x // y, ]", /* c */ "b": [1, 2,], // end
    }"#;
    let value: Value = serde_json::from_str(&strip_jsonc(text)).unwrap();
    assert_eq!(value["a"], "x // y, ]");
    assert_eq!(value["b"], serde_json::json!([1, 2]));
}

#[test]
fn a_full_config_maps_every_part() {
    let dir = checkout();
    write(dir.path(), ".devcontainer/devcontainer.json", JSONC);
    let plan = plan(dir.path());
    assert_eq!(plan.source.kind, SourceKind::Devcontainer);
    assert_eq!(plan.projects.len(), 1, "{:?}", plan.warnings);
    let p = &plan.projects[0];
    assert_eq!(p.key, ".devcontainer/devcontainer.json");
    assert!(p.name.starts_with("web-app"));
    assert_eq!(p.image.as_deref(), Some("mcr.microsoft.com/devcontainers/typescript-node:20"));
    let repo = p.repo.as_ref().unwrap();
    assert_eq!(repo.url.as_deref(), Some("https://github.com/me/web.git"));
    assert_eq!(repo.branch.as_deref(), Some("main"));

    let setup = &p.machine.setup;
    assert_eq!(setup.iter().filter(|s| *s == ENSURE_MISE).count(), 1);
    assert!(setup.iter().any(|s| s.ends_with("mise use -g node@20")));
    assert!(setup.iter().any(|s| s.ends_with("mise use -g python@latest")));
    assert!(setup.iter().any(|s| s == ENSURE_DOCKER));
    assert!(setup.iter().any(|s| s.ends_with("kubectl@latest")));
    assert!(!setup.iter().any(|s| s.contains("minikube")));
    // Lifecycle order: onCreate, updateContent, postCreate (object form, every entry), postStart.
    let at = |needle: &str| {
        setup.iter().position(|s| s == needle).unwrap_or_else(|| panic!("{needle} in {setup:?}"))
    };
    let create = at("echo create");
    let update = at("npm ci --no-audit");
    let deps = at("bun install");
    let migrate = at("bun run db:migrate");
    let start = at("bun run dev &");
    assert!(create < update && update < deps.min(migrate) && deps.max(migrate) < start);

    let env = &p.machine.env;
    assert_eq!(env.get("NODE_ENV").map(String::as_str), Some("development"));
    assert_eq!(env.get("PATH").map(String::as_str), Some("${PATH}:/opt/bin"));
    assert!(!env.contains_key("GITHUB_TOKEN") && !env.contains_key("API_SECRET"));
    let secrets = &p.machine.secret_names;
    for name in ["GITHUB_TOKEN", "OPENAI_API_KEY", "API_SECRET", "STRIPE_KEY"] {
        assert!(secrets.contains(name), "{name} in {secrets:?}");
    }
    assert_eq!(p.ports, vec![3000, 5432, 80]);
    assert!(p.notes.iter().any(|n| n.contains("dbaeumer.vscode-eslint")));
    assert!(p.notes.iter().any(|n| n.contains("remoteUser was node")));
    assert!(plan.unsupported.iter().any(|u| u.what.contains("weird-tool")));
    assert!(plan.unsupported.iter().any(|u| u.what.contains("mounts")));

    let json = serde_json::to_string(&plan).unwrap();
    assert!(!json.contains("planted-value-xyz"));
    assert!(!json.contains("ghp_secret"));
    let toml = crate::machine_toml::render(&p.machine);
    assert!(!toml.contains("planted-value-xyz"));
}

#[test]
fn a_dockerfile_build_becomes_a_setup_step() {
    let dir = checkout();
    write(
        dir.path(),
        ".devcontainer/devcontainer.json",
        r#"{ "build": { "dockerfile": "Dockerfile", "context": "..", "args": { "V": "1" } } }"#,
    );
    let p = project(dir.path()).unwrap();
    let build = p.machine.setup.iter().find(|s| s.starts_with("docker build")).unwrap();
    assert!(build.contains("-f .devcontainer/Dockerfile"), "{build}");
    assert!(build.ends_with(" ."), "{build}");
    assert!(build.contains("--build-arg V=1"));
    assert_eq!(p.machine.setup[0], ENSURE_DOCKER);
    assert!(p.notes.iter().any(|n| n.contains(".devcontainer/Dockerfile")));
}

#[test]
fn several_configs_make_one_project_each() {
    let dir = checkout();
    write(dir.path(), ".devcontainer.json", r#"{ "image": "a" }"#);
    write(dir.path(), ".devcontainer/api/devcontainer.json", r#"{ "image": "b" }"#);
    write(dir.path(), ".devcontainer/web/devcontainer.json", r#"{ "image": "c" }"#);
    let plan = plan(dir.path());
    let keys: Vec<&str> = plan.projects.iter().map(|p| p.key.as_str()).collect();
    assert_eq!(
        keys,
        [
            ".devcontainer.json",
            ".devcontainer/api/devcontainer.json",
            ".devcontainer/web/devcontainer.json"
        ]
    );
    let names: std::collections::BTreeSet<&str> =
        plan.projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names.len(), 3, "{names:?}");
    assert!(plan.projects[1].name.ends_with("-api"));
}

#[test]
fn a_compose_config_takes_its_service_as_the_project() {
    let dir = checkout();
    write(
        dir.path(),
        ".devcontainer/devcontainer.json",
        r#"{
          "dockerComposeFile": ["../docker-compose.yml", "docker-compose.extend.yml"],
          "service": "app",
          "runServices": ["app", "db"],
          "forwardPorts": [3000],
          "postCreateCommand": "npm i"
        }"#,
    );
    write(
        dir.path(),
        "docker-compose.yml",
        "services:\n  app:\n    image: node:20\n    environment:\n      DB_PASSWORD: hunter2-planted\n  db:\n    image: postgres:16\n    ports: ['5433:5432']\n  cache:\n    image: redis\n",
    );
    write(
        dir.path(),
        ".devcontainer/docker-compose.extend.yml",
        "services:\n  app:\n    environment:\n      LOG_LEVEL: debug\n",
    );
    let plan = plan(dir.path());
    assert_eq!(plan.projects.len(), 1, "{:?}", plan.warnings);
    let p = &plan.projects[0];
    assert_eq!(p.key, ".devcontainer/devcontainer.json");
    assert_eq!(p.services, vec!["db".to_owned()]);
    assert_eq!(p.image.as_deref(), Some("node:20"));
    assert!(p.machine.setup.iter().any(|s| s
        == "docker compose -f docker-compose.yml -f .devcontainer/docker-compose.extend.yml up -d db"));
    assert_eq!(p.machine.setup.last().map(String::as_str), Some("npm i"));
    assert_eq!(p.machine.env.get("LOG_LEVEL").map(String::as_str), Some("debug"));
    assert!(p.machine.secret_names.contains("DB_PASSWORD"));
    assert!(p.ports.contains(&5433) && p.ports.contains(&3000));
    assert!(p.notes.iter().any(|n| n.contains("service app")));
    assert!(!serde_json::to_string(&plan).unwrap().contains("hunter2-planted"));
}

#[test]
fn no_config_is_a_warning_not_a_project() {
    let dir = checkout();
    assert!(project(dir.path()).is_none());
    assert_eq!(plan(dir.path()).warnings.len(), 1);
}

#[test]
fn feature_ids_map_by_short_name_and_version() {
    let none = serde_json::json!({});
    assert!(feature_steps("ghcr.io/devcontainers/features/terraform:1", &none).is_some());
    assert!(feature_steps("ghcr.io/devcontainers/features/aws-cli", &none).is_some());
    assert!(feature_steps("ghcr.io/devcontainers/features/azure-cli:1", &none).is_some());
    assert!(
        feature_steps("ghcr.io/devcontainers/features/dotnet:2", &none).unwrap()[0]
            .contains("--channel LTS")
    );
    let java = feature_steps(
        "ghcr.io/devcontainers/features/java:1",
        &serde_json::json!({ "version": "21" }),
    )
    .unwrap();
    assert!(java[1].ends_with("java@21"));
    assert!(feature_steps("ghcr.io/devcontainers/features/nvidia-cuda:1", &none).is_none());
    assert!(feature_steps("ghcr.io/devcontainers-contrib/features/node:1", &none).is_none());
}

#[test]
fn lifecycle_forms() {
    assert_eq!(lifecycle(&serde_json::json!("make")), vec!["make"]);
    assert_eq!(lifecycle(&serde_json::json!(["echo", "a b"])), vec!["echo 'a b'"]);
    assert_eq!(
        lifecycle(&serde_json::json!({ "a": "one", "b": ["two", "x"] })),
        vec!["one", "two x"]
    );
    assert!(lifecycle(&Value::Null).is_empty());
}
