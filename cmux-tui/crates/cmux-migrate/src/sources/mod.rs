//! One reader per place people come from. Each takes a root it reads (a home folder, a checkout,
//! a file someone exported) and returns a [`crate::Plan`]; none writes, none talks to a network.
//! Commands that reach a network (an SSH host, a competitor's API) gather their facts in the CLI
//! and hand them here as plain data, so every reader is a pure function a test can feed.

pub mod laptop;

pub mod competitors;
pub mod detect;
pub mod ssh_host;

pub mod compose;
pub mod devcontainer;
pub mod nix;
pub mod project_files;

pub mod ci_config;
pub mod secrets_refs;

/// What a checkout's CI config and secret references add to a plan from any directory reader:
/// merged into the plan's first project, or one new project when the plan has none. Returns
/// whether anything was added.
pub fn merge_ci_and_secrets(root: &std::path::Path, plan: &mut crate::Plan) -> bool {
    let ci = ci_config::read(root);
    let secrets = secrets_refs::read(root);
    plan.warnings.extend(ci.warnings.iter().cloned());
    if ci.is_empty() && secrets.is_empty() {
        return false;
    }
    if plan.projects.is_empty() {
        plan.projects.push(crate::plan::Project {
            key: root.display().to_string(),
            name: crate::plan::machine_name(&project_files::folder_name(root)),
            repo: Some(project_files::repo_at(root)),
            checked: true,
            ..Default::default()
        });
    }
    let Some(project) = plan.projects.first_mut() else { return true };
    ci_config::merge(&ci, project);
    secrets_refs::merge(&secrets, project);
    true
}
