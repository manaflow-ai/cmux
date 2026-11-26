//! Set Up GitHub on This Machine (`cmux cloud setup-github`): the person's git identity from the
//! Mac, and GitHub for the Cloud machine's git.
//!
//! By default through the cmux GitHub App: `cmux github setup` makes the machine's git ask its
//! Cloud agent for a short-lived token scoped to one repo each time, and no GitHub token is stored
//! on the machine. Only when the App or the team's connection is not there (or the machine has no
//! Cloud agent) does the machine sign in itself through GitHub's device flow: it runs its own
//! `gh auth login --web`, GitHub gives it a one-time code, the person approves that code in their
//! own browser, and GitHub hands the machine a token of its own, which stays there.
//!
//! No token leaves the Mac either way. The result carries only `ok`, `method`, `fallback_reason`,
//! `user_name`, `user_email`, `gh_status` and, while a sign-in waits, `device_code` and
//! `verification_uri`.
//!
//! The app runs [`command`] through the Worker's exec (`POST /v1/cloud/machines/{id}/exec`) as the
//! machine's work user, and reads its answer with [`parse`]. The API takes one shell string, so the
//! two values from the Mac are the only caller data in it: [`validated`] refuses control
//! characters, and [`shell_quote`] single-quotes each value. One shell parses the string once and
//! nothing parses the values again: they reach `git config` as one argv entry each.
//!
//! Pure: the app reads the Mac's git config, runs the exec, and localizes the toast itself.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use unicode_segmentation::UnicodeSegmentation;

/// The Worker's GitHub App check as the app holds it (`CloudGitHubApp`'s raw values).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum App {
    Ready,
    NotConnected,
    NeedsReauth,
    Linking,
    Error,
    NotConfigured,
    Unknown,
}

/// `git config --global user.name` and `user.email` as the Mac has them; `None` when unset.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitIdentity {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
}

/// Where gh stands on the machine after the run (`gh_status`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitHubStatus {
    /// `cmux github setup` ran: git asks the cmux GitHub App for each repo's token.
    App,
    /// `gh auth status` already passed: nothing was started.
    LoggedIn,
    /// The device flow is waiting for the person to enter `device_code`.
    Pending,
    /// The image has no `gh`.
    Missing,
    /// The sign-in did not start or printed no code.
    Failed,
}

impl GitHubStatus {
    pub fn raw(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::LoggedIn => "logged_in",
            Self::Pending => "pending",
            Self::Missing => "missing",
            Self::Failed => "failed",
        }
    }

    fn from_raw(raw: &str) -> Option<Self> {
        Some(match raw {
            "app" => Self::App,
            "logged_in" => Self::LoggedIn,
            "pending" => Self::Pending,
            "missing" => Self::Missing,
            "failed" => Self::Failed,
            _ => return None,
        })
    }
}

/// Whether the git identity reached the machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IdentityStatus {
    Set,
    Skipped,
    Failed,
}

impl IdentityStatus {
    fn from_raw(raw: &str) -> Option<Self> {
        Some(match raw {
            "set" => Self::Set,
            "skipped" => Self::Skipped,
            "failed" => Self::Failed,
            _ => return None,
        })
    }
}

/// What the machine reported.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Outcome {
    pub identity: IdentityStatus,
    pub git_hub: GitHubStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_code: Option<String>,
    /// The run was asked to use the App, and the machine has no Cloud agent or `cmux github`.
    #[serde(default)]
    pub app_not_on_machine: bool,
}

impl Outcome {
    pub fn new(identity: IdentityStatus, git_hub: GitHubStatus) -> Self {
        Self { identity, git_hub, device_code: None, app_not_on_machine: false }
    }

    /// Nothing failed: the identity was set (or the Mac had none to set), and git uses the App,
    /// or gh is signed in or waits for the person's approval.
    pub fn ok(&self) -> bool {
        self.identity != IdentityStatus::Failed
            && matches!(
                self.git_hub,
                GitHubStatus::App | GitHubStatus::LoggedIn | GitHubStatus::Pending
            )
    }
}

/// Why the machine signs in to GitHub itself instead of using the App (`fallback_reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fallback {
    /// The team has no usable connection to the App (the token endpoint's `integration.not_found`).
    NotConnected,
    /// This deployment has no App.
    NotConfigured,
    /// The check did not answer.
    Unknown,
    /// The machine has no Cloud agent or no `cmux github` (an older image).
    NotOnMachine,
}

impl Fallback {
    pub fn raw(self) -> &'static str {
        match self {
            Self::NotConnected => "not_connected",
            Self::NotConfigured => "not_configured",
            Self::Unknown => "unknown",
            Self::NotOnMachine => "not_on_machine",
        }
    }
}

/// Why the run will not ask for the App (`None` when the check says it is ready).
pub fn reason(app: App) -> Option<Fallback> {
    match app {
        App::Ready => None,
        App::NotConnected | App::NeedsReauth | App::Linking | App::Error => {
            Some(Fallback::NotConnected)
        }
        App::NotConfigured => Some(Fallback::NotConfigured),
        App::Unknown => Some(Fallback::Unknown),
    }
}

/// `None` when git uses the App; else why not (a ready App the machine said it could not use:
/// `NotOnMachine`; a run that never said, such as a failed exec: `Unknown`).
pub fn fallback(app: App, outcome: &Outcome) -> Option<Fallback> {
    if outcome.git_hub == GitHubStatus::App {
        return None;
    }
    Some(reason(app).unwrap_or(if outcome.app_not_on_machine {
        Fallback::NotOnMachine
    } else {
        Fallback::Unknown
    }))
}

/// Where the person enters the code. A constant, never read from the machine: the app opens only
/// this page, whatever the machine prints.
pub const VERIFICATION_URI: &str = "https://github.com/login/device";

/// The exec's own timeout (the Cloud API's `timeoutMs`): the script waits at most 15 s for gh's
/// code, inside `action.run`'s 40 s result deadline.
pub const TIMEOUT_MS: u64 = 25_000;

/// The longest value passed on (in characters as a person counts them); a real name or address
/// is far shorter.
pub const MAX_VALUE_LENGTH: usize = 256;

/// The Cloud agent's socket on the machine, which `cmux github` asks for each token.
pub const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";

/// The probe's bound, well inside the exec's [`TIMEOUT_MS`] with the device flow's 15 s after it.
pub const PROBE_SECONDS: u64 = 4;

/// The detached sign-in's `$0`: the stop signals only a shell whose command line has it.
pub const SIGN_IN_MARKER: &str = "cmux-gh-login";

/// A value from the Mac that may not go into the command: a control character or too long.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Unsafe;

/// `identity` with each value trimmed (git ends its output with a newline), empty values dropped,
/// and a refusal for a value with a control character (a newline inside it, a NUL, an escape) or
/// longer than [`MAX_VALUE_LENGTH`].
pub fn validated(identity: &GitIdentity) -> Result<GitIdentity, Unsafe> {
    Ok(GitIdentity {
        name: validated_value(identity.name.as_deref())?,
        email: validated_value(identity.email.as_deref())?,
    })
}

pub fn validated_value(value: Option<&str>) -> Result<Option<String>, Unsafe> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    if value.chars().any(char::is_control) || value.graphemes(true).count() > MAX_VALUE_LENGTH {
        return Err(Unsafe);
    }
    Ok(Some(value.to_owned()))
}

/// `value` as one POSIX shell word: inside single quotes nothing is special, and each `'` is
/// closed, escaped and reopened (`'\''`).
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// The one exec script. It prints `cmux-git: set|skipped|failed` and then
/// `cmux-gh: app|logged_in|missing|failed|pending <code>`, and nothing that came from gh except
/// the code. With `app`, the App's helper first ([`app_command`]); the device flow runs only when
/// the machine cannot use it. A rerun stops the previous sign-in first ([`stop_previous_command`]).
pub fn command(identity: &GitIdentity, app: bool) -> String {
    let mut lines = vec![
        "umask 077".to_owned(),
        // The work user's home and the image's tool store, whatever the provider's exec set.
        r#"h=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6); [ -n "$h" ] && HOME=$h; export HOME"#
            .to_owned(),
        r#"export PATH="/opt/cmux/current/bin:/usr/local/bin:$PATH""#.to_owned(),
        identity_command(identity),
        r#"proc=/proc; d="$HOME/.cache/cmux"; log="$d/gh-login.log""#.to_owned(),
        r#"mkdir -p "$d" || { echo 'cmux-gh: failed'; exit 0; }"#.to_owned(),
        // First, on every path: an earlier sign-in still waiting for its code would otherwise
        // finish later and put gh back as git's helper over the App's.
        stop_previous_command(),
    ];
    if app {
        lines.push(app_command(AGENT_SOCKET));
    }
    // A machine already signed in makes gh git's helper again, on every run that does not use the
    // App: an earlier run may have put the App's helper in, and it fails once the App is gone.
    let signed_in = "gh auth setup-git --hostname github.com >/dev/null 2>&1 || { echo 'cmux-gh: failed'; exit 0; }; ";
    lines.push(
        "if ! command -v gh >/dev/null 2>&1; then echo 'cmux-gh: missing'; exit 0; fi".to_owned(),
    );
    lines.push(format!(
        "if gh auth status --hostname github.com >/dev/null 2>&1; then {signed_in}echo 'cmux-gh: logged_in'; exit 0; fi"
    ));
    lines.push(r#"rm -f "$log""#.to_owned());
    lines.push("s=; command -v setsid >/dev/null 2>&1 && s=setsid".to_owned());
    // Detached from the exec (its own session, when setsid exists) so the sign-in outlives it; git
    // then uses gh as its credential helper.
    lines.push(format!(
        r#"$s nohup sh -c {} {SIGN_IN_MARKER} "$d" </dev/null >"$log" 2>&1 &"#,
        shell_quote(&sign_in_body())
    ));
    lines.push(read_code_command());
    lines.join("\n")
}

/// The App's git helper (`cmux github setup`, which replaces any helper git had for github.com),
/// when the machine's Cloud agent socket (`socket`) is there to mint its tokens and `cmux` has the
/// verb; prints `cmux-gh: app`. Else `cmux-app: unavailable` (no agent socket or no `cmux`: an
/// older image) or `cmux-app: failed` (the helper did not go in), and the device flow follows.
pub fn app_command(socket: &str) -> String {
    [
        format!("if [ -S {} ] && command -v cmux >/dev/null 2>&1; then", shell_quote(socket)),
        unbound_probe(),
        "  if [ -n \"$unusable\" ]; then echo 'cmux-app: unavailable'".to_owned(),
        "  elif cmux github setup >/dev/null 2>&1; then echo 'cmux-gh: app'; exit 0".to_owned(),
        "  else echo 'cmux-app: failed'; fi".to_owned(),
        "else".to_owned(),
        "  echo 'cmux-app: unavailable'".to_owned(),
        "fi".to_owned(),
    ]
    .join("\n")
}

/// A token ask for a repo no team has. Only a working path answers it with the API's
/// `policy.denied` (the team's connection may not act on that repo): the agent is bound, reaches
/// the API, and the team has an active GitHub connection. Anything else (`vm.unbound`, an
/// unreachable or broken agent, `integration.unavailable`, no connection, a token for it) means
/// the helper would fail every git call, so the device flow runs instead. The ask gets
/// [`PROBE_SECONDS`]: a hung agent (the CLI waits up to 240 s for it) is stopped and counts as
/// unusable too, so the device flow still starts inside [`TIMEOUT_MS`]. Sets `unusable` to 1 for
/// any of them.
pub fn unbound_probe() -> String {
    [
        r#"probe_err=$(mktemp 2>/dev/null || echo "/tmp/cmux-gh-probe.$$")"#.to_owned(),
        r#"printf 'protocol=https\nhost=github.com\npath=cmux-setup-probe/none.git\n\n' | cmux github credential get >/dev/null 2>"$probe_err" & probe=$!"#.to_owned(),
        format!(
            r#"j=0; while kill -0 "$probe" 2>/dev/null && [ $j -lt {} ]; do sleep 0.25; j=$((j+1)); done"#,
            PROBE_SECONDS * 4
        ),
        r#"if kill -0 "$probe" 2>/dev/null; then kill "$probe" 2>/dev/null; unusable=1"#.to_owned(),
        r#"elif grep -q 'policy\.denied' "$probe_err"; then unusable=; else unusable=1; fi"#.to_owned(),
        r#"rm -f "$probe_err""#.to_owned(),
    ]
    .join("\n")
}

/// Waits up to 15 s for gh's one-time code in `$log` and prints `cmux-gh: pending <code>`, or
/// `cmux-gh: failed`. Once the code is read the log is unlinked: gh keeps writing to the open
/// file, but the code no longer sits on the machine's disk for anything else to read. A log with
/// no code stays, for diagnosing the failed start.
pub fn read_code_command() -> String {
    [
        "i=0; code=",
        r#"while [ $i -lt 60 ]; do code=$(sed -n 's/.*one-time code: \([A-Z0-9][A-Z0-9]*-[A-Z0-9][A-Z0-9]*\).*/\1/p' "$log" 2>/dev/null | head -n 1); [ -n "$code" ] && break; sleep 0.25; i=$((i+1)); done"#,
        r#"if [ -n "$code" ]; then rm -f "$log"; echo "cmux-gh: pending $code"; else echo 'cmux-gh: failed'; fi"#,
    ]
    .join("\n")
}

/// The detached sign-in, run as `sh -c SCRIPT cmux-gh-login DIR`. It records itself in its own
/// file `DIR/gh-login.<its pid>.pid` (this boot's id, its pid, then gh's pid) and removes that
/// file when it ends, however it ends, so no file outlives the run it names. Each run removes only
/// its own file: a stopped run's exit can never take a newer run's record.
pub fn sign_in_body() -> String {
    [
        r#"f="$1/gh-login.$$.pid""#,
        r#"trap 'rm -f "$f"' EXIT"#,
        "trap 'exit 143' HUP INT TERM",
        r#"printf '%s\n%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" "$$" >"$f""#,
        "gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key & g=$!",
        r#"echo "$g" >>"$f""#,
        "wait $g && gh auth setup-git --hostname github.com",
    ]
    .join("\n")
}

/// Stops the sign-ins earlier runs started, from their files in `$d`; `$proc` is the proc
/// filesystem (`/proc`; a test passes a fake one). A pid is signalled only when all of these hold,
/// so a stale file (a reboot, a restored snapshot, a reused pid) signals nothing:
/// - it is a canonical decimal above 1 (never `0`, `1` or a leading zero: in dash
///   `kill -TERM -0` is the caller's own group and `-01` every process the user owns);
/// - the file was written this boot (its first line is this boot's id, and the id is known);
/// - the process's command line is the detached sign-in shell ([`SIGN_IN_MARKER`]) or
///   `gh auth login`.
///
/// The shell is signalled as a process group (setsid made it a group leader; without setsid the
/// group does not exist and only the pid is signalled), gh by its pid.
pub fn stop_previous_command() -> String {
    [
        r#"boot=$(cat "$proc/sys/kernel/random/boot_id" 2>/dev/null)"#.to_owned(),
        r#"for f in "$d"/gh-login.*.pid; do"#.to_owned(),
        r#"  [ -f "$f" ] || continue"#.to_owned(),
        r#"  { read -r b; read -r sp; read -r gp; } <"$f""#.to_owned(),
        r#"  if [ -n "$boot" ] && [ "$b" = "$boot" ]; then"#.to_owned(),
        r#"    for p in "$sp" "$gp"; do"#.to_owned(),
        r#"      case "$p" in ''|*[!0-9]*|0*|1) continue ;; esac"#.to_owned(),
        r#"      c=$(tr '\000' ' ' <"$proc/$p/cmdline" 2>/dev/null)"#.to_owned(),
        r#"      case "$c" in"#.to_owned(),
        format!(
            r#"        *' {SIGN_IN_MARKER} '*) kill -TERM "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null ;;"#
        ),
        r#"        'gh auth login '*|*'/gh auth login '*) kill -TERM "$p" 2>/dev/null ;;"#.to_owned(),
        r#"      esac"#.to_owned(),
        r#"    done"#.to_owned(),
        r#"  fi"#.to_owned(),
        r#"  rm -f "$f""#.to_owned(),
        r#"done"#.to_owned(),
    ]
    .join("\n")
}

/// The line that sets the identity and prints `cmux-git: set|skipped|failed`. The values from the
/// Mac appear only here, each as one single-quoted word.
pub fn identity_command(identity: &GitIdentity) -> String {
    let mut sets = Vec::new();
    if let Some(name) = &identity.name {
        sets.push(format!("git config --global user.name {}", shell_quote(name)));
    }
    if let Some(email) = &identity.email {
        sets.push(format!("git config --global user.email {}", shell_quote(email)));
    }
    if sets.is_empty() {
        return "echo 'cmux-git: skipped'".to_owned();
    }
    format!("if {}; then echo 'cmux-git: set'; else echo 'cmux-git: failed'; fi", sets.join(" && "))
}

/// Swift's `Character.isNewline`, by scalar (`\r\n` splits into an empty piece, which is skipped).
fn is_newline(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The outcome the script printed. A code is taken only in GitHub's shape (`XXXX-XXXX`, letters
/// and digits); anything else is `failed`.
pub fn parse(exit_code: i64, stdout: &str) -> Outcome {
    let (mut identity, mut git_hub, mut code, mut not_on_machine) =
        (IdentityStatus::Failed, GitHubStatus::Failed, None::<String>, false);
    for line in stdout.split(is_newline).filter(|line| !line.is_empty()) {
        let words: Vec<&str> = line.split(' ').filter(|word| !word.is_empty()).collect();
        if words.len() < 2 {
            continue;
        }
        match words[0] {
            "cmux-app:" => not_on_machine = not_on_machine || words[1] == "unavailable",
            "cmux-git:" => {
                identity = IdentityStatus::from_raw(words[1]).unwrap_or(IdentityStatus::Failed)
            }
            "cmux-gh:" => {
                git_hub = GitHubStatus::from_raw(words[1]).unwrap_or(GitHubStatus::Failed);
                code = (git_hub == GitHubStatus::Pending
                    && words.len() == 3
                    && is_device_code(words[2]))
                .then(|| words[2].to_owned());
                if git_hub == GitHubStatus::Pending && code.is_none() {
                    git_hub = GitHubStatus::Failed;
                }
            }
            _ => {}
        }
    }
    // A run that did not finish says nothing sure about the machine: its fallback reason is unknown.
    if exit_code != 0 {
        let identity = if identity == IdentityStatus::Set {
            IdentityStatus::Set
        } else {
            IdentityStatus::Failed
        };
        return Outcome::new(identity, GitHubStatus::Failed);
    }
    Outcome { identity, git_hub, device_code: code, app_not_on_machine: not_on_machine }
}

/// GitHub's one-time code shape: two groups of four capital letters or digits joined by `-`.
pub fn is_device_code(text: &str) -> bool {
    let parts: Vec<&str> = text.split('-').collect();
    parts.len() == 2
        && parts.iter().all(|part| {
            part.len() == 4
                && part.bytes().all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
        })
}

/// `action.run`'s `result`: only these keys, and never a token (the machine has the only one).
pub fn fields(
    outcome: &Outcome,
    identity: &GitIdentity,
    fallback: Option<Fallback>,
) -> Map<String, Value> {
    let mut fields = Map::new();
    fields.insert("ok".into(), Value::Bool(outcome.ok()));
    fields.insert("gh_status".into(), Value::from(outcome.git_hub.raw()));
    let method = if outcome.git_hub == GitHubStatus::App { "app" } else { "device" };
    fields.insert("method".into(), Value::from(method));
    if let Some(fallback) = fallback {
        fields.insert("fallback_reason".into(), Value::from(fallback.raw()));
    }
    if outcome.identity == IdentityStatus::Set {
        if let Some(name) = &identity.name {
            fields.insert("user_name".into(), Value::from(name.as_str()));
        }
        if let Some(email) = &identity.email {
            fields.insert("user_email".into(), Value::from(email.as_str()));
        }
    }
    if let Some(code) = &outcome.device_code {
        fields.insert("device_code".into(), Value::from(code.as_str()));
        fields.insert("verification_uri".into(), Value::from(VERIFICATION_URI));
    }
    fields
}

#[cfg(test)]
mod tests;
