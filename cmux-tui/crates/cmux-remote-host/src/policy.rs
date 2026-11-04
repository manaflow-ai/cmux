//! Never asked, always refused (docs/computer-use-approvals.md, Rules): cmux's
//! and Cua's own UI, password managers, the login and authentication prompts,
//! security agents, system settings, and terminals or cmux builds the owner
//! did not allow (`allow_terminals`). Matched on the resolved executable's
//! file name, case-insensitively, without a Windows `.exe`.

use crate::approval::Target;

/// Tools that run other tools inside the driver, past the worker's checks.
pub const OPAQUE_TOOLS: [&str; 2] = ["run_script", "replay_trajectory"];

const CMUX: &[&str] = &[
    "cmux", "cmux-tui", "cmux-remote-host", "cmux-remote", "acpmux", "cmux-cua", "cua-driver", "cua-driver-uia",
];
const PASSWORD_MANAGERS: &[&str] = &[
    "keepassxc", "keepass", "1password", "bitwarden", "enpass", "seahorse", "kwalletmanager5", "kwalletmanager",
    "gnome-keyring-daemon", "credentialuibroker", "pinentry", "pinentry-gnome3", "pinentry-qt", "pinentry-gtk-2",
    "pinentry-curses", "pinentry-tty", "ssh-askpass", "ksshaskpass", "x11-ssh-askpass", "lxqt-openssh-askpass",
];
const AUTHENTICATION: &[&str] = &[
    "gcr-prompter", "gcr4-prompter", "polkit-gnome-authentication-agent-1", "polkit-kde-authentication-agent-1",
    "polkit-mate-authentication-agent-1", "lxpolkit", "pkexec", "gdm", "gdm-session-worker", "sddm", "sddm-greeter",
    "lightdm", "lightdm-gtk-greeter", "gnome-shell-portal-helper", "consent", "logonui", "lockapp", "winlogon",
    "securityhealthsystray", "securityhealthservice",
];
const SETTINGS: &[&str] = &[
    "gnome-control-center", "systemsettings", "systemsettings5", "kcmshell5", "kcmshell6", "xfce4-settings-manager",
    "systemsettingsadminflows", "mmc", "regedit", "taskmgr", "gpedit", "secpol",
];
const TERMINALS: &[&str] = &[
    "gnome-terminal", "gnome-terminal-server", "kgx", "ptyxis", "konsole", "xterm", "uxterm", "alacritty", "kitty",
    "wezterm", "wezterm-gui", "foot", "footclient", "tilix", "terminator", "xfce4-terminal", "lxterminal",
    "mate-terminal", "urxvt", "st", "ghostty", "windowsterminal", "wt", "openconsole", "conhost", "cmd", "powershell",
    "pwsh", "powershell_ise", "mintty", "bash", "sh", "zsh", "fish", "guake", "yakuake", "tilda", "terminology",
    "qterminal", "tabby", "hyper", "rio", "warp", "warp-terminal", "dash", "ksh", "tcsh", "csh", "nu", "tmux", "screen",
    "cool-retro-term", "sakura", "termite", "contour", "wave", "waveterm",
];

/// The executable's comparable name: its file name, lower case, no `.exe`.
pub fn executable_name(executable: &str) -> String {
    let file = executable.rsplit(['/', '\\']).next().unwrap_or(executable).to_ascii_lowercase();
    file.strip_suffix(".exe").map(str::to_owned).unwrap_or(file)
}

/// Why `target` is never allowed, or None when it may be asked about.
pub fn refusal(target: &Target, allow_terminals: &[String]) -> Option<&'static str> {
    let Some(executable) = target.executable.as_deref() else {
        // macOS bundle targets are the Swift worker's (CuaTargetPolicy).
        return None;
    };
    let name = executable_name(executable);
    let listed = |list: &[&str]| list.contains(&name.as_str());
    if listed(CMUX) || name.starts_with("cmux") {
        return Some("cmux's and Cua's own apps are never controlled");
    }
    if listed(PASSWORD_MANAGERS) {
        return Some("password managers are never controlled");
    }
    if listed(AUTHENTICATION) {
        return Some("login, lock and authentication prompts are never controlled");
    }
    if listed(SETTINGS) {
        return Some("system settings are never controlled");
    }
    if listed(TERMINALS) {
        let allowed = allow_terminals
            .iter()
            .any(|entry| entry == executable || executable_name(entry) == name);
        if !allowed {
            return Some("terminals are controlled only when the owner allows them (allow_terminals)");
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(executable: &str) -> Target {
        Target { bundle_id: None, executable: Some(executable.into()), name: String::new() }
    }

    #[test]
    fn own_apps_secrets_and_terminals_are_refused() {
        assert!(refusal(&target("/usr/bin/cmux-tui"), &[]).is_some());
        assert!(refusal(&target("/opt/cmux-nightly/bin/cmux-next"), &[]).is_some());
        assert!(refusal(&target("/usr/bin/keepassxc"), &[]).is_some());
        assert!(refusal(&target("C:\\Windows\\System32\\consent.exe"), &[]).is_some());
        assert!(refusal(&target("/usr/bin/gnome-control-center"), &[]).is_some());
        assert!(refusal(&target("/usr/libexec/gnome-terminal-server"), &[]).is_some());
    }

    #[test]
    fn an_allowed_terminal_and_ordinary_apps_may_be_asked() {
        assert!(refusal(&target("/usr/bin/konsole"), &["konsole".into()]).is_none());
        assert!(refusal(&target("/usr/lib/firefox/firefox"), &[]).is_none());
        assert!(refusal(&target("C:\\Program Files\\Mozilla Firefox\\firefox.exe"), &[]).is_none());
    }
}
