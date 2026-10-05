//! The user's Ghostty config files decide what a shell the daemon starts
//! gets (DAEMON-SHELL-FEATURES-FROM-GHOSTTY-FILES): its features, cursor
//! blink and `shell-integration` mode. The reader's own syntax cases are in
//! `ghostty_files` (the shared vectors).

use super::tests::{env_of, launch};
use super::*;

/// With no caller value, a daemon-integrated shell takes the user's
/// Ghostty `shell-integration-features` and `cursor-style-blink` from
/// their config files (DAEMON-SHELL-FEATURES-FROM-GHOSTTY-FILES): the
/// default files under the shell's `XDG_CONFIG_HOME`, or the app's
/// `CMUX_NEXT_GHOSTTY_CONFIG`. Every feature off exports an empty value,
/// never the defaults; a caller value still wins; the ssh features still
/// need a Ghostty CLI.
#[test]
fn a_daemon_integrated_shell_follows_the_users_ghostty_files() {
    let dir = std::env::temp_dir().join(format!("cmux-shell-features-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("ghostty")).unwrap();
    let xdg = dir.to_str().unwrap();
    let config = dir.join("ghostty").join("config");
    let features = |text: &str, env: &[(&str, &str)]| {
        fs::write(&config, text).unwrap();
        env_of(&launch("zsh", env), FEATURES_ENV)
    };
    let in_xdg = [("XDG_CONFIG_HOME", xdg), ("HOME", "/home/me")];
    assert_eq!(
        features(
            "shell-integration-features = no-title,sudo\ncursor-style-blink = false\n",
            &in_xdg
        )
        .as_deref(),
        Some("cursor:steady,path,sudo")
    );
    assert_eq!(features("shell-integration-features = false\n", &in_xdg).as_deref(), Some(""));
    assert_eq!(
        features("shell-integration-features = ssh-env\n", &in_xdg).as_deref(),
        Some("cursor:blink,path,title"),
        "no Ghostty CLI: the ssh wrapper goes"
    );
    let caller = [("XDG_CONFIG_HOME", xdg), (FEATURES_ENV, "path")];
    assert_eq!(
        features("shell-integration-features = false\n", &caller).as_deref(),
        Some("path"),
        "the caller's value stays"
    );
    let app_file = [("CMUX_NEXT_GHOSTTY_CONFIG", config.to_str().unwrap()), ("HOME", "/home/me")];
    assert_eq!(
        features("shell-integration-features = no-path\n", &app_file).as_deref(),
        Some("cursor:blink,title")
    );
    fs::remove_dir_all(&dir).unwrap();
}

/// The user's Ghostty `shell-integration` from their files decides the
/// shell the daemon integrates, as in Ghostty's `Exec`: `detect` by the
/// command's name, a forced shell whatever the command, and `none`
/// never; `none` still exports the features for a manual integration.
#[test]
fn the_users_shell_integration_mode_decides_the_shell() {
    let mksh = ["mksh".to_string()];
    let zsh = ["/bin/zsh".to_string()];
    assert_eq!(shell_for(Mode::Detect, &zsh), Some(Shell::Zsh));
    assert_eq!(shell_for(Mode::Detect, &mksh), None);
    assert_eq!(shell_for(Mode::Zsh, &mksh), Some(Shell::Zsh));
    assert_eq!(shell_for(Mode::Fish, &zsh), Some(Shell::Fish));
    assert_eq!(shell_for(Mode::None, &zsh), None);
    assert_eq!(shell_for(Mode::Nushell, &zsh), None, "no nushell scripts here");

    let dir = std::env::temp_dir().join(format!("cmux-shell-mode-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    let config = dir.join("config");
    fs::write(&config, "shell-integration = none\nshell-integration-features = no-path\n").unwrap();
    let launched = integrate_default_shell(
        vec!["zsh".into()],
        vec![("CMUX_NEXT_GHOSTTY_CONFIG".into(), config.to_str().unwrap().into())],
    );
    assert_eq!(launched.command, vec!["zsh".to_string()]);
    assert_eq!(env_of(&launched, "ZDOTDIR"), None, "none: no injection");
    assert_eq!(env_of(&launched, FEATURES_ENV).as_deref(), Some("cursor:blink,title"));
    fs::remove_dir_all(&dir).unwrap();
}
