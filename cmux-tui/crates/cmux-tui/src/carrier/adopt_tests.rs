use std::sync::Mutex;

use async_trait::async_trait;

use super::super::answer::{CarrierAnswer, ExecReply, SourceError, read_exec};
use super::*;

#[test]
fn the_look_reads_a_legacy_host_a_replaced_link_and_leaves_the_rest() {
    // The 2026-11-04 image's `cmux host` (cmuxterm-hq#7086): no `update` verb.
    assert_eq!(found("arch=x86_64 updater=none\n"), Found::Adopt("x86_64-unknown-linux-musl"));
    assert_eq!(found("arch=aarch64 updater=relink\n"), Found::Adopt("aarch64-unknown-linux-musl"));
    assert_eq!(found("arch=x86_64 updater=on\n"), Found::Leave("updater_on"));
    assert_eq!(found("arch=x86_64 updater=marked\n"), Found::Leave("updates_off"));
    assert_eq!(found("arch=x86_64 updater=unknown\n"), Found::Leave("unknown"));
    assert_eq!(found("arch=riscv64 updater=none\n"), Found::Leave("arch"));
    assert_eq!(found(""), Found::Leave("arch"));
}

/// The look's own shell, run here against canned `cmux host update status` answers.
#[cfg(unix)]
#[test]
fn the_look_script_classifies_each_status_answer() {
    let run = |status: &str| {
        let script = LOOK.replace(
            "sudo -n /opt/cmux/current/bin/cmux host update status",
            "printf '%s' \"$STATUS\"",
        );
        let out = std::process::Command::new("sh")
            .arg("-c")
            .arg(script)
            .env("STATUS", status)
            .output()
            .unwrap();
        found(&String::from_utf8_lossy(&out.stdout))
    };
    let legacy = "cmux host: unknown verb update\nusage: cmux host run [--roles-only] ...";
    assert!(matches!(run(legacy), Found::Adopt(_) | Found::Leave("arch")));
    let on =
        r#"{"channel":"https://files.cmux.com/cmux-tui/channels/cloud-machine.json","off":null}"#;
    assert!(matches!(run(on), Found::Leave("updater_on" | "arch")));
    let marked = r#"{"off":"/etc/cmux/no-self-update exists"}"#;
    // An old outcome line naming the file is not the updater being off now.
    let on_after = r#"{"off":null,"state":{"last":"off: /etc/cmux/no-self-update exists"}}"#;
    assert!(matches!(run(on_after), Found::Leave("updater_on" | "arch")));
    assert!(matches!(run(marked), Found::Leave("updates_off" | "arch")));
    let relink = r#"{"off":"/home/cmux/.cmux/bin/cmux-tui is not the store link"}"#;
    assert!(matches!(run(relink), Found::Adopt(_) | Found::Leave("arch")));
    // On an x86_64 or aarch64 test host the arch reads, and so does each state.
    if matches!(std::env::consts::ARCH, "x86_64" | "aarch64") {
        assert!(matches!(run(legacy), Found::Adopt(_)));
        assert_eq!(run(on), Found::Leave("updater_on"));
        assert_eq!(run(marked), Found::Leave("updates_off"));
        assert!(matches!(run(relink), Found::Adopt(_)));
    }
}

#[test]
fn the_adopt_checks_the_download_then_runs_the_new_builds_adopt() {
    let sha = "a".repeat(64);
    let url = "https://files.cmux.com/cmux-tui/0123/cmux-tui-x86_64-unknown-linux-musl";
    let command = adopt_command(url, &sha);
    let at = |needle: &str| command.find(needle).unwrap_or_else(|| panic!("no {needle}"));
    assert!(at(&format!("'{url}'")) < at("sha256sum"));
    assert!(at("sha256sum") < at("sudo -n install -m 0555"));
    assert!(command.contains(&format!("/opt/cmux/store/{sha}")));
    assert!(
        command.ends_with(&format!("'exec -a cmux \"$0\" host update adopt' \"$e/{CMUX_TUI}\""))
    );
    assert!(command.starts_with("set -eu"));
}

#[test]
fn a_link_counts_as_parked_once_it_waited_unallocated() {
    let now = Instant::now();
    let opened = now.checked_sub(Duration::from_secs(9)).unwrap();
    assert!(parked_for(Some(opened), None, now, PARKED_BEFORE_LOOK));
    assert!(!parked_for(Some(opened), Some(now), now, PARKED_BEFORE_LOOK));
    assert!(!parked_for(Some(now), None, now, PARKED_BEFORE_LOOK));
    assert!(!parked_for(None, None, now, PARKED_BEFORE_LOOK));
}

#[test]
fn each_machine_is_looked_at_once() {
    assert!(claim("vm_adopt_test_once_000"));
    assert!(!claim("vm_adopt_test_once_000"));
    assert!(claim("vm_adopt_test_once_001"));
    unclaim("vm_adopt_test_once_001");
    assert!(claim("vm_adopt_test_once_001"));
}

#[test]
fn an_exec_answer_reads_its_code_and_output_or_its_refusal() {
    let ok = serde_json::json!({"exitCode": 0, "stdout": "arch=x86_64 updater=on\n", "stderr": ""});
    assert_eq!(
        read_exec(200, &ok).unwrap(),
        ExecReply {
            exit_code: 0,
            stdout: "arch=x86_64 updater=on\n".into(),
            stderr: String::new()
        }
    );
    let refused = serde_json::json!({"ok": false, "error": {"code": "vm_forbidden"}});
    assert!(!read_exec(403, &refused).unwrap_err().retryable);
    assert!(read_exec(502, &serde_json::Value::Null).unwrap_err().retryable);
}

/// A source whose exec answers the look with `look`, recording each command.
struct Looks {
    look: &'static str,
    ran: Mutex<Vec<String>>,
}

#[async_trait]
impl CarrierSource for Looks {
    async fn fetch(&self, _: &str, _: Option<&[u8; 32]>) -> Result<CarrierAnswer, SourceError> {
        Err(SourceError::fatal("not here"))
    }

    async fn exec(&self, _: &str, command: &str, _: Duration) -> Result<ExecReply, SourceError> {
        self.ran.lock().unwrap().push(command.to_owned());
        Ok(ExecReply { exit_code: 0, stdout: self.look.to_owned(), stderr: String::new() })
    }
}

#[tokio::test]
async fn a_machine_that_updates_itself_gets_only_the_look() {
    let source = Looks { look: "arch=x86_64 updater=on\n", ran: Mutex::new(Vec::new()) };
    let deadline = Instant::now() + Duration::from_secs(60);
    assert_eq!(look_and_adopt(&source, "vm_x", deadline).await, "updater_on");
    assert_eq!(source.ran.lock().unwrap().as_slice(), [LOOK.to_owned()]);
    let marked = Looks { look: "arch=x86_64 updater=marked\n", ran: Mutex::new(Vec::new()) };
    assert_eq!(look_and_adopt(&marked, "vm_x", deadline).await, "updates_off");
    assert_eq!(marked.ran.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_source_without_exec_adopts_nothing() {
    struct NoExec;
    #[async_trait]
    impl CarrierSource for NoExec {
        async fn fetch(&self, _: &str, _: Option<&[u8; 32]>) -> Result<CarrierAnswer, SourceError> {
            Err(SourceError::fatal("not here"))
        }
    }
    let deadline = Instant::now() + Duration::from_secs(60);
    assert_eq!(look_and_adopt(&NoExec, "vm_x", deadline).await, "look_refused");
    assert!(retryable("look_refused"));
    assert!(!retryable("updater_on"));
}
