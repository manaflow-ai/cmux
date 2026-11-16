//! The shell and Python the login copy runs on the machine, byte for byte the app's
//! (`CloudCredentialInstaller.preflight`, `creatorTeamPreflight` and `script`, the last in
//! `install.py`). The parity test
//! (`tests::the_machine_scripts_are_the_apps_byte_for_byte`) reads the Swift source and fails when
//! the two differ, until the app's copy is deleted and calls these.

/// The owner guest check: an owner guest with the image's launchers, and the staging folder made
/// as `cmux`'s own 0700 folder, no symlink, owned by `cmux`. The write follows it with no exec of
/// its own in between.
pub const PREFLIGHT: &str = r##"set -eu
[ "$(cat /etc/cmux/vm-kind 2>/dev/null)" = owner ]
[ -f /etc/cmux/agent-auth.sh ]
if [ "$(id -u)" = 0 ]; then install -d -m 700 -o cmux -g cmux /home/cmux/.cmux/credential-transfer; else
  [ "$(id -un)" = cmux ]; (umask 077 && mkdir -p /home/cmux/.cmux/credential-transfer); chmod 700 /home/cmux/.cmux/credential-transfer
fi
[ ! -L /home/cmux/.cmux/credential-transfer ] && [ "$(stat -c %U /home/cmux/.cmux/credential-transfer)" = cmux ]"##;

/// The DEV and dogfood creator allowance: an owner or team guest, every other check of
/// [`PREFLIGHT`] kept.
pub const CREATOR_TEAM_PREFLIGHT: &str = r##"set -eu
case "$(cat /etc/cmux/vm-kind 2>/dev/null)" in owner|team) ;; *) exit 1 ;; esac
[ -f /etc/cmux/agent-auth.sh ]
if [ "$(id -u)" = 0 ]; then install -d -m 700 -o cmux -g cmux /home/cmux/.cmux/credential-transfer; else
  [ "$(id -un)" = cmux ]; (umask 077 && mkdir -p /home/cmux/.cmux/credential-transfer); chmod 700 /home/cmux/.cmux/credential-transfer
fi
[ ! -L /home/cmux/.cmux/credential-transfer ] && [ "$(stat -c %U /home/cmux/.cmux/credential-transfer)" = cmux ]"##;

/// The installer [`super::install_command`] runs. Exit 70: not an allowed guest kind or no
/// launchers; 71: the staged file or the work user is wrong; 72: a conflicting configuration or a
/// failed write. The staged file is removed whatever the answer.
pub fn install_script() -> &'static str {
    INSTALL_PY.strip_suffix('\n').unwrap_or(INSTALL_PY)
}

/// `install.py` as stored: the file ends with a newline the app's string does not have.
const INSTALL_PY: &str = include_str!("install.py");
