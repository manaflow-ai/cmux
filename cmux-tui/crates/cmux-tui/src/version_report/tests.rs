use super::*;

#[test]
fn placeholder_stamps_are_not_releases() {
    assert!(is_release("0.13.5"));
    assert!(is_release("1.0.0-rc.1"));
    assert!(is_release("0.0.1"));
    assert!(!is_release(""));
    assert!(!is_release("0.0.0-r2.sha-abc"));
}

#[test]
fn the_text_leads_with_the_distribution_release() {
    assert_eq!(version_text("0.13.5", Some("abc"), Some("def")), "0.13.5 (abc; ghostty def)");
    assert_eq!(version_text("0.13.5", Some("abc"), None), "0.13.5 (abc)");
    assert_eq!(version_text("0.13.5", None, Some("def")), "0.13.5");
}

#[test]
fn an_unpublished_artifact_names_the_cmux_next_version() {
    assert_eq!(release_version("0.0.0-r2.sha-0123abc", "1.0.0"), "1.0.0");
    assert_eq!(release_version("0.13.5", "1.0.0"), "0.13.5");
    assert_eq!(release_version("1.0.0", "1.0.0"), "1.0.0");
}

#[test]
fn the_channel_comes_from_the_binary_path() {
    let cases = [
        ("/usr/lib/node_modules/cmux-tui-linux-x64/bin/cmux-tui", InstallChannel::Npm),
        (
            "/home/t/.npm/_npx/1a2b/node_modules/cmux-tui-linux-arm64/bin/cmux-tui",
            InstallChannel::Npm,
        ),
        (
            "/home/t/.local/share/uv/tools/cmux/lib/python3.12/site-packages/cmux/bin/cmux-tui",
            InstallChannel::Pypi,
        ),
        ("/usr/lib/python3/dist-packages/cmux/bin/cmux-tui", InstallChannel::Pypi),
        ("/Applications/cmux NEXT.app/Contents/Resources/bin/cmux-tui", InstallChannel::App),
        ("/home/t/src/cmux/cmux-tui/target/release/cmux-tui", InstallChannel::Other),
        ("/home/t/.cmux-tui/bin/cmux-tui", InstallChannel::Other),
    ];
    for (path, channel) in cases {
        assert_eq!(InstallChannel::detect(Path::new(path)), channel, "{path}");
    }
}

#[test]
fn only_package_installs_name_an_update_command() {
    assert_eq!(InstallChannel::Npm.update_command(), Some("npm install --global cmux@latest"));
    assert_eq!(InstallChannel::Pypi.update_command(), Some("uv tool upgrade cmux"));
    assert_eq!(InstallChannel::App.update_command(), None);
    assert_eq!(InstallChannel::Other.update_command(), None);
}
