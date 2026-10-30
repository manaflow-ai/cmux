//! Execute the dashboard attachment code, including the remote-message boundary.
#[test]
fn web_image_attachments() {
    let output = std::process::Command::new("node")
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
