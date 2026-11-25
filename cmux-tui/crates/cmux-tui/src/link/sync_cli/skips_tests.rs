use super::{LISTED, Skips, Why, heavy, secret};

/// The credential folders a copy leaves out at any depth are exactly the
/// ones the App refuses as a selected folder
/// (`AgentPaneCloudFolderRefusal.secretFolders`), read from its source.
#[test]
fn credential_folders_are_the_apps_secret_folders() {
    let swift = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
        "../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneCloudFolder.swift",
    );
    let source = std::fs::read_to_string(&swift).unwrap();
    let list = source
        .split("public static let secretFolders = [")
        .nth(1)
        .and_then(|rest| rest.split(']').next())
        .expect("secretFolders in AgentPaneCloudFolder.swift");
    let apps: Vec<&str> = list.split('"').skip(1).step_by(2).collect();
    assert!(!apps.is_empty());
    assert_eq!(super::CREDENTIAL_FOLDERS, apps.as_slice());
}

#[test]
fn secrets_are_env_files_and_keys() {
    for name in [".env", ".env.local", "id_rsa", "id_ed25519.pub", "cert.PEM", "a.p12", "x.key"] {
        assert!(secret(name).is_some(), "{name}");
    }
    for name in ["env.txt", "README.md", "keys.rs", "pem"] {
        assert!(secret(name).is_none(), "{name}");
    }
}

#[test]
fn ambiguous_heavy_names_need_the_file_that_makes_them_one() {
    let dir = tempfile::tempdir().unwrap();
    assert!(heavy(dir.path(), "node_modules"));
    assert!(!heavy(dir.path(), "target"));
    assert!(!heavy(dir.path(), "build"));
    assert!(!heavy(dir.path(), "venv"));
    std::fs::write(dir.path().join("Cargo.toml"), "").unwrap();
    std::fs::write(dir.path().join("package.json"), "{}").unwrap();
    assert!(heavy(dir.path(), "target"));
    assert!(heavy(dir.path(), "build"));
    assert!(heavy(dir.path(), "dist"));
    assert!(!heavy(dir.path(), "src"));
}

#[test]
fn every_skip_is_counted_and_the_first_ones_are_named() {
    let mut skips = Skips::new(std::path::Path::new("/top"));
    for index in 0..LISTED + 5 {
        skips.note(&format!("f{index:04}"), Why::Special);
    }
    skips.note(".env", Why::EnvFile);
    assert_eq!(skips.total(), LISTED as u64 + 6);
    let (files, counts) = skips.json();
    assert_eq!(files.as_array().unwrap().len(), LISTED);
    assert_eq!(counts["special"], LISTED as u64 + 5);
    assert_eq!(counts["secret"], 1);
}
