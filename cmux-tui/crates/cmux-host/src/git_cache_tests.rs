use super::*;

#[test]
fn system_include_is_added_once() {
    let next = plan_system(Some("[include]\n\tpath = /etc/cmux/gitconfig")).unwrap();
    assert_eq!(next, format!("[include]\n\tpath = /etc/cmux/gitconfig\n{}", include_stanza()));
    assert_eq!(plan_system(Some(&next)), None);
    assert_eq!(plan_system(None).unwrap(), include_stanza());
}

#[test]
fn serve_args_name_the_include_and_helper() {
    let host = vec!["/opt/cmux/current/bin/cmux".to_owned(), "host".to_owned()];
    let args = serve_args(&host, "team-1", true);
    assert_eq!(&args[..3], ["host", "git-cache", "serve"]);
    let helper = args.iter().position(|a| a == "--helper").map(|i| &args[i + 1]).unwrap();
    assert_eq!(helper, "!'/opt/cmux/current/bin/cmux' 'host' git-cache credential");
    assert!(args.windows(2).any(|w| w == ["--edge", EDGE]));
    assert!(args.windows(2).any(|w| w == ["--include", INCLUDE]));
    assert!(!serve_args(&host, "t", false).contains(&"--edge".to_owned()));
    assert!(args.windows(2).any(|w| w == ["--cargo-config", CARGO_CONFIG]));
}

#[test]
fn root_cargo_config_links_once_and_keeps_a_machines_own() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join(".cargo/config.toml");
    let target = dir.path().join("run/cargo-config.toml");
    assert!(link_root_cargo_config(&root, &target).unwrap());
    assert_eq!(std::fs::read_link(&root).unwrap(), target);
    assert!(link_root_cargo_config(&root, &target).unwrap());
    // Dangling until the proxy writes it: cargo sees no file.
    assert!(!root.exists());
    let own = dir.path().join("own/.cargo/config.toml");
    std::fs::create_dir_all(own.parent().unwrap()).unwrap();
    std::fs::write(&own, "[build]\n").unwrap();
    assert!(!link_root_cargo_config(&own, &target).unwrap());
    assert_eq!(std::fs::read_to_string(&own).unwrap(), "[build]\n");
}
