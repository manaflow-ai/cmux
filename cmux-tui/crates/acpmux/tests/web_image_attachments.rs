//! Execute the dashboard attachment code, including the remote-message boundary.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Runs only Node on a static page: no daemon and no agent. Node is the one host
// tool it needs; the hermetic PATH does not hold it.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny().tools(&["node"]);

#[test]
fn web_image_attachments() {
    // Windows runs no hermetic re-start (see `daemon_env`); there, the host's node.
    #[cfg(unix)]
    let node = daemon_env::tool_dir(&["node"]).join("node");
    #[cfg(windows)]
    let node = std::path::PathBuf::from("node");
    let output = std::process::Command::new(node)
        .args(["--test", concat!(env!("CARGO_MANIFEST_DIR"), "/tests/web_image_attachments.mjs")])
        .output()
        .expect("Node is required for the dashboard behavioral regression");
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
