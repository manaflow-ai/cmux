//! `deploy` and remote panes (docs/app-store-platonic-ideal.md 7, 8, 8a):
//! install = deploy + pin. The schema holds the shapes (the image, port and
//! health path have no shell characters); these are the rules across fields.

use crate::issue::Issue;
use serde_json::Value;

pub(crate) fn check(m: &Value, first_party: bool, out: &mut Vec<Issue>) {
    let remote = m.pointer("/implements/cmux.pane~11/remote").is_some();
    let deploy = m.get("deploy");
    if remote && deploy.is_none() {
        out.push(Issue::error(
            "/implements/cmux.pane~11/remote",
            "deploy.missing",
            "a remote pane shows the app's deployed instance: add the top-level deploy block",
        ));
    }
    let Some(deploy) = deploy else { return };
    // `local` runs the app's server on the person's own Mac: first-party only
    // (untrusted server code deploys to a VM or a self-hosted machine, never the Mac).
    let local =
        deploy["targets"].as_array().is_some_and(|targets| targets.iter().any(|t| t == "local"));
    if local && !first_party {
        out.push(Issue::error(
            "/deploy/targets",
            "deploy.localTarget",
            "only first-party apps may deploy to the local Mac; use cloud-vm or self-hosted",
        ));
    }
}
