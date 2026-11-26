use super::*;
use crate::plan::Step;

/// `gh codespace list --json name,displayName,repository,gitStatus,machineName,state,lastUsedAt`
/// in gh's own shape (gitStatus as gh exports it: ref, ahead, behind, hasUnpushedChanges,
/// hasUncommittedChanges).
const CODESPACES: &str = r#"[
  {"name":"fluffy-space-x9w","displayName":"fluffy space","repository":"acme/api",
   "gitStatus":{"ahead":2,"behind":0,"hasUncommittedChanges":true,"hasUnpushedChanges":true,"ref":"feat/login"},
   "machineName":"standardLinux32gb","state":"Shutdown","lastUsedAt":"2026-11-20T10:00:00Z",
   "devcontainerPath":".devcontainer/devcontainer.json"},
  {"name":"clean-one","displayName":"","repository":"acme/web",
   "gitStatus":{"ahead":0,"behind":3,"hasUncommittedChanges":false,"hasUnpushedChanges":false,"ref":"main"},
   "machineName":"basicLinux32gb","state":"Available","lastUsedAt":"2026-11-21T10:00:00Z"}
]"#;

#[test]
fn codespaces_become_projects() {
    let plan =
        codespaces_plan(CODESPACES, Some(r#"[{"name":"NPM_TOKEN"},{"name":"DB_URL"}]"#)).unwrap();
    assert_eq!(plan.source.kind, SourceKind::Codespaces);
    assert_eq!(plan.projects.len(), 2);
    let a = &plan.projects[0];
    assert_eq!(a.key, "fluffy-space-x9w");
    assert_eq!(a.name, "fluffy-space");
    let r = a.repo.as_ref().unwrap();
    assert_eq!(r.url.as_deref(), Some("https://github.com/acme/api.git"));
    assert_eq!(r.branch.as_deref(), Some("feat/login"));
    assert_eq!((r.dirty_files, r.unpushed_commits), (1, 2));
    assert!(a.notes.iter().any(|n| n.contains("gh codespace ssh -c fluffy-space-x9w")));
    assert!(a.notes.iter().any(|n| n.contains("Shutdown")));
    assert_eq!(a.machine.secret_names.iter().collect::<Vec<_>>(), ["DB_URL", "NPM_TOKEN"]);

    let b = &plan.projects[1];
    assert_eq!(b.name, "web");
    assert!(!b.repo.as_ref().unwrap().carry_worktree());

    let steps = plan.steps();
    assert!(
        steps
            .iter()
            .any(|s| matches!(s, Step::CarryWorktree { path, .. } if path == "/workspaces/api"))
    );
    assert_eq!(steps.iter().filter(|s| matches!(s, Step::CarryWorktree { .. })).count(), 1);
}

#[test]
fn codespaces_user_secrets_shape() {
    let names = codespaces_secret_names(
        r#"{"total_count":1,"secrets":[{"name":"GH_PAT","visibility":"selected"}]}"#,
    )
    .unwrap();
    assert_eq!(names, ["GH_PAT"]);
    assert!(codespaces_plan("{", None).is_err());
}

const GITPOD_YML: &str = r#"
image: gitpod/workspace-full
tasks:
  - name: deps
    before: export PATH=$HOME/bin:$PATH
    init: |
      npm ci
      npm run build
    command: npm run dev
    env:
      NODE_ENV: development
  - init: go mod download
ports:
  - port: 3000
    onOpen: open-preview
  - port: 9000-9002
vscode:
  extensions:
    - dbaeumer.vscode-eslint
    - golang.go
github:
  prebuilds:
    master: true
"#;

#[test]
fn gitpod_yml_becomes_setup() {
    let plan =
        gitpod_plan("acme/app", Some("https://u:t@github.com/acme/app.git"), GITPOD_YML).unwrap();
    let p = &plan.projects[0];
    assert_eq!(p.name, "app");
    assert_eq!(p.repo.as_ref().unwrap().url.as_deref(), Some("https://github.com/acme/app.git"));
    assert_eq!(
        p.machine.setup,
        ["export PATH=$HOME/bin:$PATH", "npm ci\nnpm run build", "go mod download"]
    );
    assert_eq!(p.machine.env.get("NODE_ENV").map(String::as_str), Some("development"));
    assert_eq!(p.ports, [3000, 9000, 9001, 9002]);
    assert_eq!(p.image.as_deref(), Some("gitpod/workspace-full"));
    assert!(p.notes.iter().any(|n| n == "deps starts with: npm run dev"));
    assert!(p.notes.iter().any(|n| n.contains("dbaeumer.vscode-eslint, golang.go")));
    assert_eq!(plan.unsupported[0].what, "Gitpod prebuilds");
}

#[test]
fn gitpod_dockerfile_image_and_bad_yaml() {
    let plan = gitpod_plan("x", None, "image:\n  file: .gitpod.Dockerfile\n").unwrap();
    assert!(plan.projects[0].notes[0].contains(".gitpod.Dockerfile"));
    assert!(plan.unsupported.is_empty());
    assert!(gitpod_plan("x", None, "tasks: [").is_err());
}

/// `coder list -o json`: codersdk.Workspace objects.
const CODER: &str = r#"[
  {"id":"1","name":"dev","owner_name":"ana","template_name":"docker-go","outdated":false,
   "latest_build":{"status":"running","transition":"start"}},
  {"id":"2","name":"gpu-box","owner_name":"ana","template_name":"docker-go",
   "latest_build":{"status":"stopped","transition":"stop"}}
]"#;

#[test]
fn coder_workspaces_point_at_the_ssh_importer() {
    let plan = coder_plan(CODER).unwrap();
    assert_eq!(plan.projects.len(), 2);
    assert_eq!(plan.projects[0].key, "ana/dev");
    assert!(!plan.projects[0].checked);
    assert!(plan.projects[0].notes[0].contains("coder.dev"));
    assert!(plan.projects[1].notes.iter().any(|n| n.contains("coder start gpu-box")));
    assert_eq!(plan.unsupported.len(), 1);
    assert_eq!(plan.unsupported[0].what, "Coder template docker-go");
}

#[test]
fn every_product_has_a_route() {
    for p in Product::ALL {
        match route(p) {
            Route::Devcontainer => {}
            Route::SshHost { how } => assert!(!how.is_empty()),
            Route::Unsupported { why, imports } => assert!(!why.is_empty() && !imports.is_empty()),
        }
    }
    assert_eq!(route(Product::ExeDev), Route::SshHost { how: "ssh <vm>.exe.xyz" });
}
