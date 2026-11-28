//! Parity with the app's `CloudGitHubSetupTests`: the git identity from the Mac reaches the machine
//! as data, never as shell code; the result carries only the agreed keys, never a token; and the
//! script's pieces, run by a real `sh` (and `dash`), do what they say.

use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::*;

/// Names a person could have, and names written to break out of a shell string.
const HOSTILE: [&str; 8] = [
    "O'Brien; rm -rf ~",
    "O'Brien'; touch \"$PWNED\"; echo '",
    "$(touch \"$PWNED\")",
    "`touch \"$PWNED\"`",
    "a\" ; touch \"$PWNED\" ; \"",
    "back\\slash \\' and \\\\",
    "José Ñúñez 李雷 🚀",
    "${PWNED:+x} $HOME * ? [a] ~ & | < > ;",
];

/// The shells the stop runs under: the image's `/bin/sh` and dash (Debian's `/bin/sh`).
const SHELLS: [&str; 2] = ["/bin/sh", "/bin/dash"];

/// A scratch folder removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!("cn-gh-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn path(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn run(executable: &str, args: &[&str], env: &[(&str, &str)]) -> (i32, String) {
    let output = Command::new(executable)
        .args(args)
        .env_clear()
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .unwrap();
    (output.status.code().unwrap_or(-1), String::from_utf8_lossy(&output.stdout).into_owned())
}

fn executable(path: &Path, body: &str) {
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

fn identity(name: Option<&str>, email: Option<&str>) -> GitIdentity {
    GitIdentity { name: name.map(str::to_owned), email: email.map(str::to_owned) }
}

fn object(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

// MARK: Quoting

/// The identity line, run by a real `sh` against a scratch HOME, writes each hostile value to git
/// config byte for byte, and none of them runs a command.
#[test]
fn hostile_values_reach_git_config_as_data() {
    if !Path::new("/usr/bin/git").exists() {
        return;
    }
    for value in HOSTILE {
        let home = Scratch::new("identity");
        let pwned = home.path("pwned");
        let home_path = home.0.to_str().unwrap();
        let line = identity_command(&identity(Some(value), Some(value)));
        let env = [
            ("HOME", home_path),
            ("PATH", "/usr/bin:/bin"),
            ("GIT_CONFIG_NOSYSTEM", "1"),
            ("LC_ALL", "C"),
            ("PWNED", pwned.to_str().unwrap()),
        ];
        let (status, output) = run("/bin/sh", &["-c", &line], &env);
        assert_eq!((status, output.as_str()), (0, "cmux-git: set\n"), "{value}");
        for key in ["user.name", "user.email"] {
            let (_, read) = run("/usr/bin/git", &["config", "--global", "--get", key], &env);
            assert_eq!(read.strip_suffix('\n'), Some(value), "{key} of {value}");
        }
        assert!(!pwned.exists(), "{value} ran a command");
    }
}

#[test]
fn a_quoted_value_round_trips_through_the_shell() {
    for value in HOSTILE {
        let script = format!("printf '%s' {}", shell_quote(value));
        assert_eq!(run("/bin/sh", &["-c", &script], &[("PATH", "/usr/bin:/bin")]).1, value);
    }
}

#[test]
fn a_quote_closes_escapes_and_reopens() {
    assert_eq!(shell_quote("O'Brien; rm -rf /"), r"'O'\''Brien; rm -rf /'");
}

#[test]
fn the_full_command_holds_the_values_only_quoted() {
    let value = HOSTILE[1];
    let command = command(&identity(Some(value), None), false);
    assert_eq!(command.matches(value).count(), 0, "the raw value is in the command");
    assert!(command.contains(&format!("git config --global user.name {}", shell_quote(value))));
    assert!(!command.contains("user.email"));
}

#[test]
fn no_identity_skips_git_config() {
    let none = GitIdentity::default();
    assert_eq!(identity_command(&none), "echo 'cmux-git: skipped'");
    assert!(!command(&none, false).contains("git config"));
    assert_eq!(
        identity_command(&identity(Some("Ann"), Some("a@b.c"))),
        "if git config --global user.name 'Ann' && git config --global user.email 'a@b.c'; then echo 'cmux-git: set'; else echo 'cmux-git: failed'; fi"
    );
    assert_eq!(
        identity_command(&identity(None, Some("a@b.c"))),
        "if git config --global user.email 'a@b.c'; then echo 'cmux-git: set'; else echo 'cmux-git: failed'; fi"
    );
}

// MARK: Values from the Mac

#[test]
fn a_control_character_or_a_long_value_is_refused() {
    let long = "a".repeat(257);
    for value in ["Ann\nrm -rf ~", "Ann\0", "Ann\u{1B}[31m", "Ann\rLee", "Ann\u{7F}", long.as_str()]
    {
        assert_eq!(validated_value(Some(value)), Err(Unsafe), "{value:?}");
        assert_eq!(validated(&identity(Some("Ann"), Some(value))), Err(Unsafe), "{value:?}");
    }
    // The bound counts characters as a person does: 256 of them, however many bytes.
    let at_bound = "🚀".repeat(256);
    assert_eq!(validated_value(Some(&at_bound)), Ok(Some(at_bound.clone())));
    assert_eq!(validated_value(Some(&"é".repeat(257))), Err(Unsafe));
    let flags = "🇫🇷".repeat(256);
    assert_eq!(validated_value(Some(&flags)), Ok(Some(flags.clone())));
}

#[test]
fn gits_trailing_newline_is_trimmed_and_empty_is_unset() {
    assert_eq!(
        validated(&identity(Some("Ann Lee\n"), Some("\n"))),
        Ok(identity(Some("Ann Lee"), None))
    );
    assert_eq!(validated_value(None), Ok(None));
    assert_eq!(validated_value(Some("  \t ")), Ok(None));
    assert_eq!(validated_value(Some("\u{3000}Ann\u{A0}")), Ok(Some("Ann".to_owned())));
}

// MARK: Reading the answer

#[test]
fn a_pending_sign_in_answers_with_the_code_and_githubs_page() {
    let outcome = parse(0, "cmux-git: set\ncmux-gh: pending AB12-CD34\n");
    assert_eq!(
        outcome,
        Outcome {
            identity: IdentityStatus::Set,
            git_hub: GitHubStatus::Pending,
            device_code: Some("AB12-CD34".into()),
            app_not_on_machine: false
        }
    );
    assert!(outcome.ok());
    let fields =
        fields(&outcome, &identity(Some("Ann"), Some("a@b.c")), Some(Fallback::NotConfigured));
    assert_eq!(
        fields,
        object(json!({
            "ok": true, "method": "device", "gh_status": "pending", "fallback_reason": "not_configured",
            "user_name": "Ann", "user_email": "a@b.c", "device_code": "AB12-CD34",
            "verification_uri": "https://github.com/login/device",
        }))
    );
}

#[test]
fn the_result_carries_only_the_agreed_keys() {
    let outcome =
        parse(0, "cmux-git: set\ncmux-gh: pending gho_secret_token\ntoken gho_secret_token\n");
    let fields = fields(&outcome, &identity(Some("Ann"), None), None);
    let allowed = [
        "ok",
        "method",
        "fallback_reason",
        "user_name",
        "user_email",
        "gh_status",
        "device_code",
        "verification_uri",
    ];
    assert!(fields.keys().all(|key| allowed.contains(&key.as_str())));
    assert!(!serde_json::to_string(&fields).unwrap().contains("gho_secret_token"));
    assert_eq!(outcome.git_hub, GitHubStatus::Failed);
}

#[test]
fn already_signed_in_is_ok_with_no_code() {
    let outcome = parse(0, "cmux-git: skipped\ncmux-gh: logged_in\n");
    assert_eq!(outcome, Outcome::new(IdentityStatus::Skipped, GitHubStatus::LoggedIn));
    assert!(outcome.ok());
    assert!(!fields(&outcome, &GitIdentity::default(), None).contains_key("device_code"));
}

#[test]
fn a_missing_gh_is_not_ok() {
    let outcome = parse(0, "cmux-git: set\ncmux-gh: missing\n");
    assert_eq!(outcome.git_hub, GitHubStatus::Missing);
    assert!(!outcome.ok());
}

#[test]
fn a_code_in_any_other_shape_is_a_failure() {
    for line in [
        "cmux-gh: pending",
        "cmux-gh: pending abcd-1234",
        "cmux-gh: pending AB12CD34",
        "cmux-gh: pending https://evil.example/AB12-CD34",
        "cmux-gh: pending AB12-CD34 extra",
        "cmux-gh: pending AB12-CD34-EF56",
        "cmux-gh: pending ÀB12-CD34",
    ] {
        let outcome = parse(0, &format!("cmux-git: set\n{line}\n"));
        assert_eq!(outcome, Outcome::new(IdentityStatus::Set, GitHubStatus::Failed), "{line}");
    }
}

#[test]
fn a_failed_exec_is_a_failure() {
    assert_eq!(
        parse(124, "cmux-git: set\ncmux-gh: pending AB12-CD34\ncmux-app: unavailable\n"),
        Outcome::new(IdentityStatus::Set, GitHubStatus::Failed)
    );
    assert_eq!(
        parse(1, "cmux-git: skipped\n"),
        Outcome::new(IdentityStatus::Failed, GitHubStatus::Failed)
    );
    assert_eq!(parse(0, ""), Outcome::new(IdentityStatus::Failed, GitHubStatus::Failed));
}

#[test]
fn identity_not_set_leaves_the_name_out_of_the_result() {
    let outcome = parse(0, "cmux-git: failed\ncmux-gh: logged_in\n");
    assert!(!outcome.ok());
    let fields = fields(&outcome, &identity(Some("Ann"), Some("a@b.c")), None);
    assert!(!fields.contains_key("user_name"));
    assert!(!fields.contains_key("user_email"));
}

#[test]
fn unknown_words_and_short_lines_are_skipped() {
    let outcome =
        parse(0, "noise\r\ncmux-git: bogus\ncmux-git:\n  cmux-gh:   logged_in  \u{2028}other: x\n");
    assert_eq!(outcome, Outcome::new(IdentityStatus::Failed, GitHubStatus::LoggedIn));
    assert_eq!(parse(0, "cmux-git: set\ncmux-gh: weird\n").git_hub, GitHubStatus::Failed);
    // The last line of each kind wins.
    assert_eq!(parse(0, "cmux-gh: failed\ncmux-gh: app\n").git_hub, GitHubStatus::App);
    let later = parse(0, "cmux-gh: pending AB12-CD34\ncmux-gh: logged_in\n");
    assert_eq!((later.git_hub, later.device_code), (GitHubStatus::LoggedIn, None));
}

#[test]
fn device_code_shape() {
    assert!(is_device_code("AB12-CD34"));
    assert!(is_device_code("0000-ZZZZ"));
    for text in ["AB12-CD3", "AB12--CD34", "-AB12CD34", "ab12-cd34", "AB12-CD34-", "AB 2-CD34", ""]
    {
        assert!(!is_device_code(text), "{text}");
    }
}

// MARK: The cmux GitHub App first

#[test]
fn the_app_runs_before_the_device_flow_only_when_asked() {
    let identity = identity(Some("Ann"), Some("a@b.c"));
    let app = command(&identity, true);
    let helper = app.find(&app_command(AGENT_SOCKET)).expect("the helper is in the command");
    let helper_end = helper + app_command(AGENT_SOCKET).len();
    assert!(helper_end <= app.find("gh auth status").unwrap(), "the App's helper runs first");
    let identity_line = app.find(&identity_command(&identity)).unwrap();
    assert!(identity_line + identity_command(&identity).len() <= helper);
    assert!(!command(&identity, false).contains("cmux github setup"));
    // An earlier sign-in is stopped before the App's helper goes in.
    let stop = app.find(&stop_previous_command()).unwrap();
    assert!(stop + stop_previous_command().len() <= helper);
    let signed_in = "then gh auth setup-git --hostname github.com >/dev/null 2>&1 || { echo 'cmux-gh: failed'; exit 0; }; echo 'cmux-gh: logged_in'";
    assert!(app.contains(signed_in));
    assert!(command(&identity, false).contains(signed_in));
    assert!(app_command(AGENT_SOCKET).contains("/run/cmux-vm-agent/agent.sock"));
    assert!(app.contains(&format!(
        "$s nohup sh -c {} cmux-gh-login \"$d\"",
        shell_quote(&sign_in_body())
    )));
    assert!(unbound_probe().contains("[ $j -lt 16 ]"));
}

/// The whole command, byte for byte as the app has sent it: the exec runs exactly this script.
#[test]
fn the_command_is_the_apps_script() {
    let lines: Vec<String> =
        command(&GitIdentity::default(), false).split('\n').map(str::to_owned).collect();
    assert_eq!(lines[0], "umask 077");
    assert_eq!(lines[3], "echo 'cmux-git: skipped'");
    assert_eq!(lines[4], r#"proc=/proc; d="$HOME/.cache/cmux"; log="$d/gh-login.log""#);
    assert_eq!(
        lines.last().unwrap(),
        r#"if [ -n "$code" ]; then rm -f "$log"; echo "cmux-gh: pending $code"; else echo 'cmux-gh: failed'; fi"#
    );
    // The app's line count: 3 + identity + 2 + stop (16) + 4 + the sign-in (its body's 7) + read code (3).
    assert_eq!(lines.len(), 3 + 1 + 2 + 16 + 4 + 7 + 3);
    assert_eq!(command(&GitIdentity::default(), true).split('\n').count(), lines.len() + 7 + 6);
    // The script parses.
    let (status, _) =
        run("/bin/sh", &["-n", "-c", &command(&identity(Some("A'b"), None), true)], &[]);
    assert_eq!(status, 0);
}

/// The helper line, run by a real `sh` with a stand-in `cmux`: the App when the Cloud agent's socket
/// is there and `cmux github setup` succeeds, else `unavailable` and the device flow follows.
#[test]
fn the_helper_is_used_only_with_the_agent_and_a_working_cmux() {
    for (socket, cmux_exit, expected) in [
        (true, 0, "cmux-gh: app\n"),
        (false, 0, "cmux-app: unavailable\n"),
        (true, 1, "cmux-app: failed\n"),
    ] {
        let root = Scratch::new("app");
        let bin = root.path("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let seen = root.path("seen");
        executable(
            &bin.join("cmux"),
            &format!(
                "#!/bin/sh\necho \"$*\" >>\"$SEEN\"\n[ \"$2\" = credential ] && echo 'cmux github credential: policy.denied: the GitHub connection may not act on cmux-setup-probe/none' >&2\nexit {cmux_exit}\n"
            ),
        );
        let path = root.path("a.sock");
        let _listener = socket.then(|| UnixListener::bind(&path).unwrap());
        let script = app_command(path.to_str().unwrap()) + "\necho 'cmux-gh: logged_in'";
        let bin_path = format!("{}:/usr/bin:/bin", bin.display());
        let (_, output) = run(
            "/bin/sh",
            &["-c", &script],
            &[("PATH", &bin_path), ("SEEN", seen.to_str().unwrap())],
        );
        let tail = if expected.starts_with("cmux-app:") { "cmux-gh: logged_in\n" } else { "" };
        assert_eq!(output, format!("{expected}{tail}"));
        let called = std::fs::read_to_string(&seen).unwrap_or_default();
        assert_eq!(called, if socket { "github credential get\ngithub setup\n" } else { "" });
    }
}

/// An agent not yet bound, unreachable or broken, a deployment without the App, a team with no
/// connection: any probe answer but the policy refusal puts no helper in.
#[test]
fn an_unusable_agent_gets_no_helper() {
    for answer in [
        "vm.unbound: this machine is not bound to cmux Cloud yet",
        "vm.agent_unreachable: connection refused",
        "vm.agent_bad_answer: no token in the answer",
        "integration.unavailable: GitHub did not answer; retry",
        "integration.not_found: this team has no GitHub connection",
        "",
    ] {
        let root = Scratch::new("unbound");
        let bin = root.path("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let seen = root.path("seen");
        executable(
            &bin.join("cmux"),
            &format!(
                "#!/bin/sh\necho \"$*\" >>\"$SEEN\"\n[ \"$2\" = credential ] && echo 'cmux github credential: {answer}' >&2\nexit 0\n"
            ),
        );
        let path = root.path("a.sock");
        let _listener = UnixListener::bind(&path).unwrap();
        let script = app_command(path.to_str().unwrap()) + "\necho 'cmux-gh: logged_in'";
        let bin_path = format!("{}:/usr/bin:/bin", bin.display());
        let (_, output) = run(
            "/bin/sh",
            &["-c", &script],
            &[("PATH", &bin_path), ("SEEN", seen.to_str().unwrap())],
        );
        assert_eq!(output, "cmux-app: unavailable\ncmux-gh: logged_in\n", "{answer}");
        assert_eq!(std::fs::read_to_string(&seen).unwrap(), "github credential get\n", "{answer}");
    }
}

/// A hung agent is stopped after the probe's bound and counts as unavailable.
#[test]
fn a_hung_agent_gets_no_helper_within_the_bound() {
    let root = Scratch::new("hung");
    let bin = root.path("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let seen = root.path("seen");
    executable(
        &bin.join("cmux"),
        "#!/bin/sh\necho \"$*\" >>\"$SEEN\"\n[ \"$2\" = credential ] && exec sleep 60\nexit 0\n",
    );
    let path = root.path("a.sock");
    let _listener = UnixListener::bind(&path).unwrap();
    let script = app_command(path.to_str().unwrap()) + "\necho 'cmux-gh: logged_in'";
    let bin_path = format!("{}:/usr/bin:/bin", bin.display());
    let started = Instant::now();
    let (_, output) =
        run("/bin/sh", &["-c", &script], &[("PATH", &bin_path), ("SEEN", seen.to_str().unwrap())]);
    assert!(started.elapsed() < Duration::from_secs(PROBE_SECONDS + 4));
    assert_eq!(output, "cmux-app: unavailable\ncmux-gh: logged_in\n");
    assert_eq!(std::fs::read_to_string(&seen).unwrap(), "github credential get\n");
}

#[test]
fn the_app_outcome_is_ok_and_names_its_method() {
    let outcome = parse(0, "cmux-git: set\ncmux-gh: app\n");
    assert_eq!(outcome, Outcome::new(IdentityStatus::Set, GitHubStatus::App));
    assert!(outcome.ok());
    let fields = fields(&outcome, &identity(Some("Ann"), None), fallback(App::Ready, &outcome));
    assert_eq!(
        fields,
        object(json!({"ok": true, "method": "app", "gh_status": "app", "user_name": "Ann"}))
    );
}

#[test]
fn the_fallback_says_why() {
    let unavailable = parse(0, "cmux-git: set\ncmux-app: unavailable\ncmux-gh: logged_in\n");
    assert!(unavailable.app_not_on_machine);
    assert_eq!(fallback(App::Ready, &unavailable), Some(Fallback::NotOnMachine));
    assert_eq!(fallback(App::Ready, &parse(1, "")), Some(Fallback::Unknown), "a failed exec");
    assert_eq!(
        fallback(App::Ready, &parse(124, "cmux-app: unavailable\n")),
        Some(Fallback::Unknown),
        "timed out"
    );
    let failed = parse(0, "cmux-git: set\ncmux-app: failed\ncmux-gh: logged_in\n");
    assert_eq!(fallback(App::Ready, &failed), Some(Fallback::Unknown), "the helper failed");
    // The check's own answer wins over what the machine said.
    assert_eq!(fallback(App::NotConfigured, &unavailable), Some(Fallback::NotConfigured));
    assert_eq!(fallback(App::NotConnected, &parse(0, "cmux-gh: app\n")), None);
}

#[test]
fn every_app_check_has_its_reason() {
    assert_eq!(reason(App::Ready), None);
    for app in [App::NotConnected, App::NeedsReauth, App::Linking, App::Error] {
        assert_eq!(reason(app), Some(Fallback::NotConnected), "{app:?}");
    }
    assert_eq!(reason(App::NotConfigured), Some(Fallback::NotConfigured));
    assert_eq!(reason(App::Unknown), Some(Fallback::Unknown));
    let raw: Vec<App> = serde_json::from_value(json!([
        "ready",
        "not_connected",
        "needs_reauth",
        "linking",
        "error",
        "not_configured",
        "unknown"
    ]))
    .unwrap();
    assert_eq!(raw.len(), 7);
    let fallbacks = [
        Fallback::NotConnected,
        Fallback::NotConfigured,
        Fallback::Unknown,
        Fallback::NotOnMachine,
    ];
    for fallback in fallbacks {
        assert_eq!(serde_json::to_value(fallback).unwrap(), json!(fallback.raw()));
    }
    let statuses = [
        GitHubStatus::App,
        GitHubStatus::LoggedIn,
        GitHubStatus::Pending,
        GitHubStatus::Missing,
        GitHubStatus::Failed,
    ];
    for status in statuses {
        assert_eq!(serde_json::to_value(status).unwrap(), json!(status.raw()));
        assert_eq!(GitHubStatus::from_raw(status.raw()), Some(status));
    }
}

// MARK: Stopping an earlier sign-in

/// A fake `/proc` and cache folder for the stop.
struct StopWorld {
    root: Scratch,
}

impl StopWorld {
    fn new(boot: Option<&str>) -> Self {
        let root = Scratch::new("stop");
        std::fs::create_dir_all(root.path("d")).unwrap();
        let random = root.path("proc/sys/kernel/random");
        std::fs::create_dir_all(&random).unwrap();
        if let Some(boot) = boot {
            std::fs::write(random.join("boot_id"), format!("{boot}\n")).unwrap();
        }
        Self { root }
    }

    /// `/proc/<pid>/cmdline`: the arguments, each ended by NUL.
    fn process(&self, pid: &str, argv: &[&str]) {
        let folder = self.root.path("proc").join(pid);
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join("cmdline"),
            argv.iter().map(|arg| format!("{arg}\0")).collect::<String>(),
        )
        .unwrap();
    }

    fn record(&self, name: &str, lines: &[&str]) {
        std::fs::write(
            self.root.path("d").join(name),
            lines.iter().map(|line| format!("{line}\n")).collect::<String>(),
        )
        .unwrap();
    }

    fn stop(&self, shell: &str) -> Vec<String> {
        let script = format!(
            "kill() {{ echo \"$*\" >>\"$KILLED\"; }}\nproc=\"$PROC\"; d=\"$D\"\n{}",
            stop_previous_command()
        );
        let killed = self.root.path("killed");
        let (status, _) = run(
            shell,
            &["-c", &script],
            &[
                ("PATH", "/usr/bin:/bin"),
                ("PROC", self.root.path("proc").to_str().unwrap()),
                ("D", self.root.path("d").to_str().unwrap()),
                ("KILLED", killed.to_str().unwrap()),
            ],
        );
        assert_eq!(status, 0);
        std::fs::read_to_string(killed).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    fn left_files(&self) -> usize {
        std::fs::read_dir(self.root.path("d")).unwrap().count()
    }
}

const SHELL_ARGV: [&str; 5] = ["sh", "-c", "f=...", "cmux-gh-login", "/home/cmux/.cache/cmux"];
const GH_ARGV: [&str; 6] = ["gh", "auth", "login", "--hostname", "github.com", "--web"];

#[test]
fn a_run_from_this_boot_stops_its_shells_group_and_gh() {
    for shell in SHELLS {
        let world = StopWorld::new(Some("boot-a"));
        world.process("4242", &SHELL_ARGV);
        world.process("4243", &GH_ARGV);
        world.record("gh-login.4242.pid", &["boot-a", "4242", "4243"]);
        assert_eq!(world.stop(shell), ["-TERM -4242", "-TERM 4243"], "{shell}");
        assert_eq!(world.left_files(), 0);
    }
}

/// A pid reused by an unrelated process after the sign-in ended without removing its file is never
/// signalled.
#[test]
fn a_stale_file_naming_an_unrelated_process_signals_nothing() {
    for shell in SHELLS {
        let world = StopWorld::new(Some("boot-a"));
        world.process("4242", &["tmux", "new-session", "-s", "work"]);
        world.process("4243", &["/opt/cmux/agent-tools/bin/acpmux", "daemon", "start"]);
        world.record("gh-login.4242.pid", &["boot-a", "4242", "4243"]);
        assert!(world.stop(shell).is_empty(), "{shell}");
        assert_eq!(world.left_files(), 0, "the stale file stays");
    }
}

#[test]
fn a_file_from_another_boot_signals_nothing() {
    for shell in SHELLS {
        let world = StopWorld::new(Some("boot-b"));
        world.process("4242", &SHELL_ARGV);
        world.process("4243", &GH_ARGV);
        world.record("gh-login.4242.pid", &["boot-a", "4242", "4243"]);
        assert!(world.stop(shell).is_empty(), "{shell}");
    }
}

#[test]
fn an_unknown_boot_signals_nothing() {
    for shell in SHELLS {
        let world = StopWorld::new(None);
        world.process("4242", &SHELL_ARGV);
        world.record("gh-login.4242.pid", &["", "4242", ""]);
        assert!(world.stop(shell).is_empty(), "{shell}");
    }
}

/// `kill -TERM -0` is the caller's own group and `-1` or `-0001` every process the user owns.
#[test]
fn zero_one_and_leading_zeros_are_never_signalled() {
    for shell in SHELLS {
        let world = StopWorld::new(Some("boot-a"));
        let pids = ["0", "1", "0001", "01", "00", "-5", "42x", "4 2"];
        for pid in pids.iter().filter(|pid| !pid.contains(' ') && !pid.starts_with('-')) {
            world.process(pid, &SHELL_ARGV);
        }
        for (index, pid) in pids.iter().enumerate() {
            world.record(&format!("gh-login.{index}.pid"), &["boot-a", pid, pid]);
        }
        assert!(world.stop(shell).is_empty(), "{shell}");
    }
}

/// The detached sign-in removes its own file when it ends, so no file outlives its run.
#[test]
fn the_sign_in_removes_its_file_when_it_ends() {
    for shell in SHELLS {
        let world = StopWorld::new(None);
        let bin = world.root.path("bin");
        std::fs::create_dir_all(&bin).unwrap();
        executable(
            &bin.join("gh"),
            "#!/bin/sh\ncase \"$2\" in login) cat \"$D\"/gh-login.*.pid >\"$SEEN\" ;; esac\nexit 0\n",
        );
        let seen = world.root.path("seen");
        let dir = world.root.path("d");
        let bin_path = format!("{}:/usr/bin:/bin", bin.display());
        let (status, _) = run(
            shell,
            &["-c", &sign_in_body(), SIGN_IN_MARKER, dir.to_str().unwrap()],
            &[("PATH", &bin_path), ("D", dir.to_str().unwrap()), ("SEEN", seen.to_str().unwrap())],
        );
        assert_eq!(status, 0, "{shell}");
        let record = std::fs::read_to_string(&seen).unwrap();
        let lines: Vec<&str> = record.split('\n').collect();
        assert!(lines.len() >= 2 && lines[1].parse::<u32>().is_ok(), "the record names the shell");
        assert_eq!(world.left_files(), 0);
    }
}

/// The code is printed once and the log that held it is gone.
#[test]
fn reading_the_code_removes_the_log_that_held_it() {
    let root = Scratch::new("code");
    let log = root.path("gh-login.log");
    std::fs::write(&log, "! First copy your one-time code: AB12-CD34\nOpen this URL to continue\n")
        .unwrap();
    let script = format!("log={}\n{}", shell_quote(log.to_str().unwrap()), read_code_command());
    let (_, output) = run(
        "/bin/sh",
        &["-c", &script],
        &[("HOME", root.0.to_str().unwrap()), ("PATH", "/usr/bin:/bin"), ("LC_ALL", "C")],
    );
    assert_eq!(output, "cmux-gh: pending AB12-CD34\n");
    assert!(!log.exists(), "the code stayed on disk");
}
