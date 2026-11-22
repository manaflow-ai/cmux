use super::*;

pub(crate) fn alert(owner: &str, texts: &[&str], buttons: &[&str]) -> RawAlert {
    RawAlert {
        window_id: "900".into(),
        pid: 77,
        owner: owner.into(),
        layer: 8,
        texts: texts.iter().map(|t| (*t).to_string()).collect(),
        buttons: buttons.iter().map(|b| (*b).to_string()).collect(),
        ..RawAlert::default()
    }
}

/// The fleet's dialog kinds (popup_shot.py DIALOG_KINDS), by the texts its
/// Macs showed.
#[test]
fn classes_match_the_fleets_dialog_kinds() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "UserNotificationCenter",
            "This Mac can’t connect to iCloud because of a problem with a@b.c.",
            "icloud-sign-in",
        ),
        (
            "UserNotificationCenter",
            "Enter the password for your Apple Account “a@b.c”.",
            "apple-password",
        ),
        ("akd", "Sign in to iCloud", "apple-password"),
        ("UserNotificationCenter", "cmux quit unexpectedly.", "crash-report"),
        (
            "UserNotificationCenter",
            "A problem repeatedly caused the program to quit.",
            "crash-report",
        ),
        ("CoreServicesUIAgent", "“cmux DEV copytest” is damaged and can’t be opened.", "damaged"),
        ("CoreServicesUIAgent", "The application “cmux DEV” can’t be opened.", "cant-be-opened"),
        (
            "CoreServicesUIAgent",
            "You can’t open the application “Safari” because it is not responding.",
            "not-responding",
        ),
        (
            "UserNotificationCenter",
            "“worker-1a2b” would like to access your photo library.",
            "protected-folder",
        ),
        (
            "UserNotificationCenter",
            "“python3.14” would like to access files on a removable volume.",
            "protected-folder",
        ),
        (
            "UserNotificationCenter",
            "“bash” is requesting to bypass the system private window picker and directly access your screen and audio.",
            "screen-picker",
        ),
        (
            "UserNotificationCenter",
            "“Tailscale” Would Like to Add VPN Configurations",
            "vpn-configuration",
        ),
        (
            "UserNotificationCenter",
            "“cmux” would like to find and connect to devices on your local network.",
            "local-network",
        ),
        (
            "universalAccessAuthWarn",
            "“bash” would like to record this computer’s screen and audio.",
            "screen-recording",
        ),
        ("UserNotificationCenter", "“Terminal” wants access to control “Finder”.", "automation"),
        ("universalAccessAuthWarn", "Accessibility Access", "accessibility"),
        ("universalAccessAuthWarn", "Input Monitoring", "privacy-access"),
        (
            "CoreServicesUIAgent",
            "“cmux” is an app downloaded from the Internet. Are you sure you want to open it?",
            "gatekeeper",
        ),
        ("SecurityAgent", "Keychain Not Found", "keychain-not-found"),
        ("SecurityAgent", "cmux wants to use the “login” keychain.", "keychain"),
        ("coreautha", "Touch ID or enter your password", "password"),
        ("loginwindow", "Your system has run out of application memory.", "out-of-memory"),
        ("UserNotificationCenter", "Something nobody has seen before", "other"),
    ];
    for (owner, text, class) in cases {
        assert_eq!(classify(&alert(owner, &[text], &["OK"])), *class, "{owner}: {text}");
    }
    let unread =
        RawAlert { unreadable: Some("no answer".into()), ..alert("SecurityAgent", &[], &[]) };
    assert_eq!(classify(&unread), "unreadable");
    assert!(read(&unread).put_off.is_empty());
}

#[test]
fn only_system_agents_dialogs_are_alert_windows() {
    for owner in ["SecurityAgent", "CoreServicesUIAgent", "UserNotificationCenter", "coreautha"] {
        assert!(is_alert_window(owner, 8), "{owner}");
    }
    assert!(is_alert_window("universalAccessAuthWarn", 0));
    // loginwindow: its out-of-memory panel, never the lock screen's shields.
    assert!(is_alert_window("loginwindow", 8));
    assert!(!is_alert_window("loginwindow", 0));
    assert!(!is_alert_window("loginwindow", 2001));
    // An app's own window, a menu or a status item is no system alert.
    for (owner, layer) in [("Safari", 0), ("Safari", 101), ("SystemUIServer", 25), ("Dock", 20)] {
        assert!(!is_alert_window(owner, layer), "{owner} {layer}");
    }
}

/// No row can name a title outside the fixed put-off set, or one that
/// grants: whatever is added to the table later.
#[test]
fn every_row_stays_inside_the_put_off_titles() {
    let owners = [
        "SecurityAgent",
        "CoreServicesUIAgent",
        "UserNotificationCenter",
        "coreautha",
        "universalAccessAuthWarn",
        "tccd",
        "TCC",
        "akd",
        "AuthKitUIService",
        "loginwindow",
        "Safari",
    ];
    let classes = [
        "icloud-sign-in",
        "apple-password",
        "crash-report",
        "damaged",
        "not-responding",
        "cant-be-opened",
        "protected-folder",
        "screen-picker",
        "vpn-configuration",
        "local-network",
        "screen-recording",
        "automation",
        "accessibility",
        "privacy-access",
        "gatekeeper",
        "keychain-not-found",
        "keychain",
        "password",
        "out-of-memory",
        "other",
        "unreadable",
    ];
    let texts: [&[&str]; 3] = [&[], &["downloaded from the Internet"], &["Keychain Not Found"]];
    for owner in owners {
        for class in classes {
            for text in texts {
                let a = alert(owner, text, &["Cancel", "Reset To Defaults", "Allow", "OK"]);
                for title in put_off_titles(&a, class) {
                    assert!(PUT_OFF_TITLES.contains(title), "{owner} {class}: {title}");
                    assert!(!never(title), "{owner} {class}: {title}");
                }
                // A class nobody may answer stays that way for every owner.
                if matches!(
                    class,
                    "screen-picker"
                        | "vpn-configuration"
                        | "keychain"
                        | "password"
                        | "other"
                        | "unreadable"
                ) && owner != "SecurityAgent"
                {
                    assert!(put_off_titles(&a, class).is_empty(), "{owner} {class}");
                }
            }
        }
    }
    for title in PUT_OFF_TITLES {
        assert!(!never(title), "{title}");
    }
}

#[test]
fn granting_titles_are_never_pressed() {
    for title in [
        "Allow",
        "Always Allow",
        "OK, Allow",
        "Allow Full Access",
        "Allow Once",
        "Open",
        "Open System Settings",
        "Open System Preferences",
        "Open Security Preferences",
        "Open Anyway",
        "Report",
        "Report…",
        "Report...",
        "Reopen",
        "Reset To Defaults",
        "Update",
        "Limit Access…",
        "Select Photos…",
        "Force Quit",
        "Force Quit…",
        "Continue",
        "Sign In",
        "Relaunch",
        "Move to Trash",
        "Move to Bin",
        "Install",
        "Unlock",
        "Use Password…",
        "Done",
        "Resume",
        "allow",
        "RESET TO DEFAULTS",
    ] {
        assert!(never(title), "{title}");
        // On an alert that would otherwise be put off, and on one that has the button.
        let a = alert("UserNotificationCenter", &["cmux quit unexpectedly."], &["Ignore", title]);
        let refused = check(&a, title).unwrap_err();
        assert_eq!(refused.code, CODE_BUTTON, "{title}");
        assert!(refused.message.contains("UserNotificationCenter"), "{}", refused.message);
    }
    assert!(!never("Don't Allow") && !never("Don’t Allow"));
}

#[test]
fn a_button_is_matched_in_the_alerts_own_spelling() {
    let a = alert(
        "UserNotificationCenter",
        &["“worker-1a2b” would like to access your photo library."],
        &["Don’t Allow", "Allow Full Access", "Limit Access…"],
    );
    assert_eq!(read(&a).put_off, ["Don’t Allow"]);
    assert_eq!(check(&a, "Don't Allow").unwrap(), "Don’t Allow");
    assert_eq!(check(&a, "Deny").unwrap_err().code, CODE_BUTTON, "it has no Deny button");
    assert_eq!(check(&a, "Allow Full Access").unwrap_err().code, CODE_BUTTON);
}

/// Tailscale's asks keep the fleet on its network: a person answers them.
#[test]
fn tailscales_asks_are_left_for_a_person() {
    for text in [
        "“Tailscale” Would Like to Add VPN Configurations",
        "“Tailscale” would like to find and connect to devices on your local network.",
    ] {
        let a = alert("UserNotificationCenter", &[text], &["Allow", "Don’t Allow"]);
        assert!(read(&a).put_off.is_empty(), "{text}");
        assert_eq!(check(&a, "Don't Allow").unwrap_err().code, CODE_UNKNOWN, "{text}");
    }
}

/// As read on a fleet mini (cmuxs-mac-mini-6, 2026-11-22): the warning is a
/// layer 0 window with a title, no static text and these three buttons.
#[test]
fn the_screen_recording_warning_as_a_fleet_mini_showed_it() {
    assert!(is_alert_window("universalAccessAuthWarn", 0));
    let a = RawAlert {
        layer: 0,
        title: "Screen Recording".into(),
        ..alert("universalAccessAuthWarn", &[], &["Open System Settings", "Deny", "Help"])
    };
    assert_eq!(classify(&a), "screen-recording");
    assert_eq!(read(&a).put_off, ["Deny"]);
    assert_eq!(check(&a, "Deny").unwrap(), "Deny");
    for refused in ["Open System Settings", "Help"] {
        assert_eq!(check(&a, refused).unwrap_err().code, CODE_BUTTON, "{refused}");
    }
}
