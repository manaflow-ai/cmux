use std::os::unix::fs::PermissionsExt as _;
use std::sync::{Arc, mpsc};

use serde_json::{Value, json};

use super::super::tests::{
    TOKEN, command, entry, fake, far, mint_answer, never, no_secret, platform,
};
use super::super::{Hooks, RunOptions, run};
use super::*;

/// A platform that mints (recording the mint's body), lists the joined machine and a vault.
fn minting() -> (String, mpsc::Receiver<String>) {
    fake(Arc::new(|request: &str| {
        if request.starts_with("POST /v1/machines/join-tokens ") {
            return (200, mint_answer(far()));
        }
        if request.starts_with("GET /v1/machines/credentials ") {
            return (200, json!([entry("jt_1")]).to_string());
        }
        if request.starts_with("GET /v1/vault/env ") {
            return (
                200,
                json!({"entries": [{"name": "OPENAI_API_KEY", "revision": 1}]}).to_string(),
            );
        }
        (404, "{}".to_owned())
    }))
}

struct Ran {
    code: Result<i32, Failure>,
    out: String,
    plans: Vec<(Vec<String>, Option<String>)>,
    asked: Vec<String>,
}

fn run_add(
    words: &[&str],
    origin: &str,
    output: OutputMode,
    interactive: bool,
    ssh_codes: &[i32],
) -> Ran {
    let command = command(words);
    let platform = platform(origin);
    let mut out = Vec::new();
    let mut asked = Vec::new();
    let mut plans = Vec::new();
    let mut codes = ssh_codes.to_vec();
    let mut confirm = |question: &str| {
        asked.push(question.to_owned());
        true
    };
    let mut read_value = |_: &str| -> Result<Zeroizing<String>, String> { Err("none".into()) };
    let mut ssh = |plan: &SshPlan| -> std::io::Result<i32> {
        plans.push((plan.argv.clone(), plan.stdin.as_ref().map(|s| s.as_str().to_owned())));
        Ok(if codes.is_empty() { 0 } else { codes.remove(0) })
    };
    let mut hooks = Hooks { confirm: &mut confirm, read_value: &mut read_value, ssh: &mut ssh };
    let options = RunOptions { interactive, every: Duration::from_millis(20) };
    let code = run(&command, &platform, output, options, &mut out, &mut hooks, never());
    Ran { code, out: String::from_utf8(out).unwrap(), plans, asked }
}

fn body_of(request: &str) -> Value {
    serde_json::from_str(request.split_once("\r\n\r\n").unwrap().1).unwrap()
}

#[test]
fn usb_writes_the_token_only_into_an_owner_only_command_file() {
    for output in [OutputMode::Human, OutputMode::Json, OutputMode::JsonLines, OutputMode::Quiet] {
        let stick = tempfile::tempdir().unwrap();
        let path = stick.path().to_str().unwrap().to_owned();
        let (origin, requests) = minting();
        let ran = run_add(&["machine", "add", "--usb", &path], &origin, output, true, &[]);
        assert_eq!(ran.code, Ok(0), "{output:?}");
        no_secret(&ran.out);
        assert!(ran.plans.is_empty());
        let script_path = stick.path().join(USB_SCRIPT);
        let script = std::fs::read_to_string(&script_path).unwrap();
        assert!(script.starts_with("#!/bin/sh\n"), "{script}");
        assert!(
            script.contains(&format!("curl -fsSL {origin}/v1/machines/join.sh -o \"$f\"")),
            "{script}"
        );
        assert!(
            script.contains(&format!("if CMUX_JOIN={TOKEN} sh \"$f\"; then\n  rm -f -- \"$here\"")),
            "{script}"
        );
        assert_eq!(script.matches(TOKEN).count(), 1, "the token once, in the join's env");
        let mode = std::fs::metadata(&script_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
        let readme = std::fs::read_to_string(stick.path().join(USB_README)).unwrap();
        no_secret(&readme);
        assert!(readme.contains("anyone who holds this stick can join a machine to your team"));
        let entries: Vec<_> = std::fs::read_dir(stick.path()).unwrap().collect();
        assert_eq!(entries.len(), 2, "the script and the README only");
        let mint = requests.recv().unwrap();
        assert_eq!(body_of(&mint), json!({"ttlSeconds": 600}), "the platform's longest line");
        match output {
            OutputMode::Human => {
                assert!(ran.out.contains("Whoever holds this stick can join your team's machines"));
                assert!(ran.out.contains("double-click cmux-setup.command"));
            }
            OutputMode::Json => {
                let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
                assert_eq!(value["usb"]["script"], json!(script_path));
                assert!(value.get("line").is_none() && value.get("token").is_none());
            }
            OutputMode::JsonLines => assert!(ran.out.contains("\"event\":\"written\"")),
            OutputMode::Quiet => assert!(ran.out.is_empty()),
        }
    }
}

#[test]
fn usb_with_vault_asks_first_and_a_bad_path_spends_no_token() {
    let stick = tempfile::tempdir().unwrap();
    let path = stick.path().to_str().unwrap().to_owned();
    let (origin, requests) = minting();
    let ran = run_add(
        &["machine", "add", "--usb", &path, "--vault", "--ttl", "5m"],
        &origin,
        OutputMode::Human,
        true,
        &[],
    );
    assert_eq!(ran.code, Ok(0));
    assert_eq!(
        ran.asked,
        vec!["This machine gets 1 env var from your vault: OPENAI_API_KEY. Continue?"]
    );
    requests.recv().unwrap();
    assert_eq!(body_of(&requests.recv().unwrap()), json!({"ttlSeconds": 300, "vault": true}));
    let readme = std::fs::read_to_string(stick.path().join(USB_README)).unwrap();
    assert!(readme.contains("env vars in your cmux vault"));
    // A second run on the same stick overwrites nothing and makes no token.
    let before = std::fs::read_to_string(stick.path().join(USB_SCRIPT)).unwrap();
    let (origin, requests) = minting();
    let failure =
        run_add(&["machine", "add", "--usb", &path], &origin, OutputMode::Quiet, true, &[])
            .code
            .unwrap_err();
    assert!(failure.message.contains("already exists"), "{}", failure.message);
    assert!(requests.try_recv().is_err(), "no token for a used stick");
    assert_eq!(std::fs::read_to_string(stick.path().join(USB_SCRIPT)).unwrap(), before);
    let missing = stick.path().join("not-there");
    let (origin, requests) = minting();
    let failure = run_add(
        &["machine", "add", "--usb", missing.to_str().unwrap()],
        &origin,
        OutputMode::Human,
        true,
        &[],
    )
    .code
    .unwrap_err();
    assert_eq!(failure.exit, 2);
    assert!(requests.try_recv().is_err(), "no token for a path that is not a folder");
}

#[test]
fn a_used_or_linked_stick_is_refused_and_nothing_is_written_through_a_link() {
    for (name, link) in
        [(USB_SCRIPT, false), (USB_README, false), (USB_SCRIPT, true), (USB_README, true)]
    {
        let stick = tempfile::tempdir().unwrap();
        let elsewhere = stick.path().join("elsewhere");
        std::fs::write(&elsewhere, "keep").unwrap();
        let taken = stick.path().join(name);
        if link {
            std::os::unix::fs::symlink(&elsewhere, &taken).unwrap();
        } else {
            std::fs::write(&taken, "keep").unwrap();
        }
        let path = stick.path().to_str().unwrap().to_owned();
        let (origin, requests) = minting();
        let failure =
            run_add(&["machine", "add", "--usb", &path], &origin, OutputMode::Human, true, &[])
                .code
                .unwrap_err();
        assert_eq!(failure.exit, 2, "{name} link={link}");
        assert!(requests.try_recv().is_err(), "checked before a token is made");
        assert_eq!(std::fs::read_to_string(&elsewhere).unwrap(), "keep");
        // write_usb itself never writes through a link either (O_EXCL), and leaves no half stick.
        assert!(write_usb(stick.path(), "script", "readme").is_err(), "{name} link={link}");
        assert_eq!(std::fs::read_to_string(&elsewhere).unwrap(), "keep");
        assert_eq!(std::fs::read_to_string(&taken).unwrap(), "keep");
    }
    // A dangling link counts as taken too.
    let stick = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(stick.path().join("nowhere"), stick.path().join(USB_README))
        .unwrap();
    assert_eq!(usb_taken(stick.path()).len(), 1);
    assert!(write_usb(stick.path(), "script", "readme").is_err());
    assert!(!stick.path().join("nowhere").exists());
}

/// A fake `curl` that writes `script` to its `-o` file (or stdout) and exits `code`, on a PATH dir
/// of its own.
fn fake_curl(dir: &Path, script: &str, code: i32) -> PathBuf {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let curl = bin.join("curl");
    let log = dir.join("curl-argv");
    std::fs::write(
        &curl,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >>'{}'\n[ {code} = 0 ] || exit {code}\nout=/dev/stdout\nwhile [ $# -gt 0 ]; do [ \"$1\" = -o ] && out=$2; shift; done\ncat >\"$out\" <<'EOS'\n{script}\nEOS\n",
            log.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

#[test]
fn the_usb_command_deletes_itself_only_after_a_join_that_worked() {
    // (what the join does, curl's exit, the .command's exit, whether the .command stays)
    for (served, curl_code, exit, kept) in
        [("exit 0", 0, 0, false), ("exit 3", 0, 3, true), ("exit 0", 22, 1, true)]
    {
        let dir = tempfile::tempdir().unwrap();
        let got = dir.path().join("got");
        let bin = fake_curl(
            dir.path(),
            &format!("printf '%s' \"$CMUX_JOIN\" >'{}'\n{served}", got.display()),
            curl_code,
        );
        let script = usb_script("https://p.example", TOKEN, "on 2026-11-03 at 10:00 UTC");
        let (script_path, _) = write_usb(dir.path(), &script, "readme").unwrap();
        let status = std::process::Command::new("/bin/sh")
            .arg(&script_path)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("TMPDIR", dir.path())
            .stdout(std::process::Stdio::null())
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(exit), "{served} curl={curl_code}");
        assert_eq!(script_path.exists(), kept, "{served} curl={curl_code}");
        if curl_code != 0 {
            assert!(!got.exists(), "a failed download runs nothing");
        } else {
            assert_eq!(
                std::fs::read_to_string(&got).unwrap(),
                TOKEN,
                "the join's sh got it in its env"
            );
        }
        let left: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().starts_with("cmux-join."))
            .collect();
        assert!(left.is_empty(), "the downloaded script is removed");
        let curl_argv = std::fs::read_to_string(dir.path().join("curl-argv")).unwrap();
        assert!(!curl_argv.contains("cmj_"), "{curl_argv}");
    }
}

#[test]
fn the_ssh_plan_carries_the_token_on_stdin_never_in_argv() {
    let plan = join_plan("https://p.example", "leo@mini-9", TOKEN);
    assert_eq!(
        plan.argv[..5],
        ["ssh", "-o", "ConnectTimeout=15", "--", "leo@mini-9"].map(str::to_owned)
    );
    assert!(plan.argv[5].starts_with("sh -c 'IFS= read -r t; "), "{}", plan.argv[5]);
    assert!(
        plan.argv[5].contains("curl -fsSL https://p.example/v1/machines/join.sh -o \"$f\" || {")
    );
    assert!(plan.argv[5].ends_with("CMUX_JOIN=\"$t\" sh \"$f\"'"));
    assert!(plan.argv.iter().all(|a| !a.contains("cmj_")));
    assert_eq!(plan.stdin.as_deref().map(String::as_str), Some(format!("{TOKEN}\n").as_str()));
    assert!(!format!("{plan:?}").contains(TOKEN), "Debug hides stdin");
    let signin = signin_plan("https://p.example", "leo@mini-9");
    assert!(signin.argv.contains(&"-t".to_owned()));
    assert!(signin.stdin.is_none());
    assert!(signin.argv[6].contains("CMUX_JOIN_STEP=signin"));
    for good in ["leo@mini-9", "mini-9.local", "lane_vm", "leo@10.0.0.4"] {
        assert!(valid_host(good), "{good}");
    }
    for bad in ["", "-oProxyCommand=x", "a b", "a;b'c", "a\nb", "a`b`"] {
        assert!(!valid_host(bad), "{bad:?}");
    }
    assert!(!shell_safe_origin("https://p.example/$(x)"));
    assert!(shell_safe_origin("http://127.0.0.1:9"));
}

#[test]
fn run_ssh_writes_the_token_to_ssh_stdin_and_the_remote_sh_gets_it_in_its_env() {
    let dir = tempfile::tempdir().unwrap();
    let got = dir.path().join("got");
    let bin = fake_curl(
        dir.path(),
        &format!("printf '%s' \"$CMUX_JOIN\" >'{}'\nexit 5", got.display()),
        0,
    );
    // A fake ssh: records its argv, then runs the remote command as sshd would (`sh -c`).
    let ssh = dir.path().join("ssh");
    let argv_log = dir.path().join("ssh-argv");
    std::fs::write(
        &ssh,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" >'{}'\nwhile [ \"$1\" != -- ]; do shift; done\nshift 2\nPATH='{}':/usr/bin:/bin exec /bin/sh -c \"$*\"\n",
            argv_log.display(),
            bin.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&ssh, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut plan = join_plan("https://p.example", "leo@mini-9", TOKEN);
    plan.argv[0] = ssh.to_str().unwrap().to_owned();
    assert_eq!(run_ssh(&plan).unwrap(), 5, "the join's own exit code comes back");
    assert_eq!(std::fs::read_to_string(&got).unwrap(), TOKEN);
    let argv = std::fs::read_to_string(&argv_log).unwrap();
    assert!(argv.contains("leo@mini-9") && !argv.contains("cmj_"), "{argv}");
    let curl_argv = std::fs::read_to_string(dir.path().join("curl-argv")).unwrap();
    assert!(!curl_argv.contains("cmj_"), "{curl_argv}");
}

#[test]
fn ssh_join_reports_the_machine_and_offers_the_agents_own_sign_in() {
    let (origin, requests) = minting();
    let ran = run_add(
        &["machine", "add", "leo@mini-9", "--bootstrap"],
        &origin,
        OutputMode::Human,
        true,
        &[0, 0],
    );
    assert_eq!(ran.code, Ok(0), "{}", ran.out);
    no_secret(&ran.out);
    assert!(ran.out.contains("lane-vm-3 joined (machine m_1)."), "{}", ran.out);
    assert_eq!(ran.plans.len(), 2);
    let (join, stdin) = &ran.plans[0];
    assert!(join.iter().all(|a| !a.contains("cmj_")));
    assert_eq!(stdin.as_deref(), Some(format!("{TOKEN}\n").as_str()));
    let (signin, stdin) = &ran.plans[1];
    assert!(signin.contains(&"-t".to_owned()) && stdin.is_none());
    assert!(ran.asked[0].starts_with("Sign in to Claude Code and Codex on leo@mini-9 now"));
    assert_eq!(body_of(&requests.recv().unwrap()), json!({}), "--bootstrap shares no vault");
    // Not on a terminal: no sign-in run, one line that says how.
    let (origin, _requests) = minting();
    let ran = run_add(
        &["machine", "add", "leo@mini-9", "--vault", "--yes"],
        &origin,
        OutputMode::Human,
        false,
        &[0],
    );
    assert_eq!(ran.code, Ok(0));
    assert_eq!(ran.plans.len(), 1);
    assert!(
        ran.out.contains(&format!(
            "To sign in its agents there: ssh -t leo@mini-9 'curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN_STEP=signin sh'"
        )),
        "{}",
        ran.out
    );
    // --no-wait: the join ran, and the machine list is never read.
    let (origin, requests) = minting();
    let ran = run_add(
        &["machine", "add", "leo@mini-9", "--bootstrap", "--no-wait"],
        &origin,
        OutputMode::Json,
        false,
        &[0],
    );
    assert_eq!(ran.code, Ok(0));
    assert!(requests.recv().unwrap().starts_with("POST /v1/machines/join-tokens "));
    assert!(requests.try_recv().is_err(), "no list read with --no-wait");
    let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
    assert_eq!(value["joined"], Value::Null);
    // --json: one object, no token.
    let (origin, _requests) = minting();
    let ran = run_add(
        &["machine", "add", "leo@mini-9", "--bootstrap"],
        &origin,
        OutputMode::Json,
        true,
        &[0],
    );
    let value: Value = serde_json::from_str(ran.out.trim()).unwrap();
    assert_eq!(value["joined"]["machineId"], "m_1");
    no_secret(&ran.out);
}

#[test]
fn ssh_that_cannot_connect_guides_to_remote_login_and_the_pasted_line() {
    let (origin, _requests) = minting();
    let ran = run_add(
        &["machine", "add", "leo@mini-9", "--bootstrap"],
        &origin,
        OutputMode::Human,
        true,
        &[255],
    );
    assert_eq!(ran.code, Ok(4));
    assert!(ran.out.contains("System Settings > General > Sharing > Remote Login"), "{}", ran.out);
    assert!(
        ran.out
            .contains(&format!(" curl -fsSL {origin}/v1/machines/join.sh | CMUX_JOIN={TOKEN} sh"))
    );
    assert_eq!(ran.plans.len(), 1, "no sign-in after a failed join");
    // Another remote failure: an error that names no token.
    let (origin, _requests) = minting();
    let failure = run_add(
        &["machine", "add", "leo@mini-9", "--bootstrap"],
        &origin,
        OutputMode::Json,
        true,
        &[3],
    )
    .code
    .unwrap_err();
    assert_eq!(failure.code, "machine_join.remote_failed");
    no_secret(&failure.message);
}

#[test]
fn a_sticks_expiry_reads_as_a_date() {
    assert_eq!(expiry_date_words(Some(1_793_243_400_250)), "on 2026-10-29 at 03:10 UTC");
    assert_eq!(expiry_date_words(Some(0)), "on 1970-01-01 at 00:00 UTC");
    assert_eq!(expiry_date_words(Some(951_782_400_000)), "on 2000-02-29 at 00:00 UTC");
    assert_eq!(expiry_date_words(None), "soon");
}
