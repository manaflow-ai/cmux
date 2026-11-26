//! Start an AutoCloud machine from the terminal (RFD 0139), then chat on it as `--machine ID` does.
//!
//! On by default (Leo, 06:16Z: "it doesnt work if it's not \"on by default\""): a signed-in
//! `cmux autocloud` with no `--machine`, `--host`, `--via`, `--session` or `--local` chats on the
//! person's AutoCloud machine, starting one when there is none. The live probe is the sign-in (no
//! saved session, no Cloud: it chats here as before); the kill switch is
//! `CMUX_AUTOCLOUD_START=0`. `--new-machine` always makes a fresh one.
//!
//! The machine it made last is remembered per API (`machine.json` beside the session) and reused:
//! running, it is dialed; paused, `cloud.machine.start` resumes it; gone or failed, a new one is
//! made.
//!
//! The machine is the one the app's New Cloud Machine makes: `cloud.machine.create` (the
//! `cmux.wire/1` op, `cmux-cloud-client::ops`) at the shipped chat start size, signed in with the
//! saved `login` session. One idempotency key covers every retry, so a lost answer never makes a
//! second machine. Then `cloud.machine.get` until the machine runs on a host, which is when the
//! carrier can reach its acpmux.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, bail};
use cmux_cloud_client::ops::{self, Answer};
use cmux_cloud_wire::{
    CloudMachine, CloudMachineCreateOp, CloudMachineCreateParams, CloudMachineGetOp,
    CloudMachineGetParams, CloudMachineOrigin, CloudMachineSize, CloudMachineStartOp,
    CloudMachineStartParams, CloudMachineStatus,
};
use serde::{Deserialize, Serialize};

/// The kill switch: `0`, `off` or `false` keeps a plain `cmux autocloud` on this machine.
pub const KILL_SWITCH: &str = "CMUX_AUTOCLOUD_START";

/// Whether a chat with no target starts (or reuses) an AutoCloud machine: on unless the kill
/// switch says otherwise and when signed in (the probe).
pub fn on_by_default(kill_switch: Option<&str>, signed_in: bool) -> bool {
    let killed = kill_switch
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no"))
        .unwrap_or(false);
    signed_in && !killed
}

#[derive(Serialize, Deserialize, Default)]
struct Remembered {
    api: String,
    machine: String,
}

fn remembered_path() -> PathBuf {
    crate::login::session_path().with_file_name("machine.json")
}

fn remembered(api: &str) -> Option<String> {
    let raw = std::fs::read_to_string(remembered_path()).ok()?;
    let r: Remembered = serde_json::from_str(&raw).ok()?;
    (r.api == api && !r.machine.is_empty()).then_some(r.machine)
}

fn remember(api: &str, machine: &str) {
    let path = remembered_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let r = Remembered { api: api.to_owned(), machine: machine.to_owned() };
    if let Ok(text) = serde_json::to_string(&r) {
        let _ = std::fs::write(path, format!("{text}\n"));
    }
}

/// The app's chat start size (cpu, memory MB, disk MB): cloud_journey.rs `CHAT_START_SIZE`.
pub const CHAT_START_SIZE: (i64, i64, i64) = (4, 16_384, 65_536);
/// How long a new machine may take to run on a host.
const RUNNING_BUDGET: Duration = Duration::from_secs(600);
const CREATE_TRIES: u32 = 4;

/// The Cloud API a word names: `prod` (the default), `staging`, `dev`, or a URL.
pub fn api_base(word: &str) -> String {
    match word {
        "" | "prod" | "production" => cmux_cloud_environment::PRODUCTION_API.to_owned(),
        "staging" => cmux_cloud_environment::STAGING_API.to_owned(),
        "dev" | "development" => cmux_cloud_environment::DEVELOPMENT_API.to_owned(),
        url => url.trim_end_matches('/').to_owned(),
    }
}

/// The create's params: the chat start size, a name, and who started it.
pub fn create_params(name: &str) -> CloudMachineCreateParams {
    CloudMachineCreateParams {
        name: Some(name.to_owned()),
        size: CloudMachineSize {
            cpu: Some(CHAT_START_SIZE.0),
            memory_mb: Some(CHAT_START_SIZE.1),
            disk_mb: Some(CHAT_START_SIZE.2),
        },
        image: None,
        from_snapshot: None,
        origin: Some(CloudMachineOrigin {
            kind: None,
            label: "cmux autocloud".to_owned(),
            url: None,
            run: None,
            workflow: None,
            lane: None,
        }),
        ttl_seconds: None,
    }
}

/// The person's AutoCloud machine, running: the remembered one when it is still there (resumed if
/// paused), else a new one (always with `fresh`). Returns its id. `say` gets each step.
pub async fn ensure_machine(
    api: &str,
    bearer: &str,
    team: Option<&str>,
    name: &str,
    fresh: bool,
    say: &mut dyn FnMut(&str),
) -> Result<String> {
    let ua = concat!("cmux-autocloud/", env!("CARGO_PKG_VERSION"));
    let (base, http) =
        cmux_cloud_client::http(api, Some(bearer), team, ua, Duration::from_secs(120))
            .map_err(|e| anyhow!("the Cloud API client: {e}"))?;

    if !fresh && let Some(id) = remembered(&base) {
        let params = CloudMachineGetParams { machine: id.clone() };
        if let Ok(m) = ops::call::<CloudMachineGetOp>(&http, &base, params, None, None)
            .await
            .and_then(Answer::into_result)
        {
            match m.status {
                CloudMachineStatus::Paused => {
                    say(&format!("Resuming your AutoCloud machine {id}..."));
                    let params = CloudMachineStartParams { machine: id.clone() };
                    let key = cmux_cloud_client::client_key();
                    retried(say, "cloud.machine.start", || async {
                        ops::call::<CloudMachineStartOp>(
                            &http,
                            &base,
                            params.clone(),
                            Some(&key),
                            None,
                        )
                        .await
                        .and_then(Answer::into_result)
                    })
                    .await?;
                    return running(&http, &base, &id, say).await;
                }
                CloudMachineStatus::Failed | CloudMachineStatus::Deleting => {}
                _ => {
                    say(&format!("Using your AutoCloud machine {id}."));
                    return running(&http, &base, &id, say).await;
                }
            }
        }
    }

    say(&format!("Starting an AutoCloud machine ({name}) on {base}..."));
    let key = cmux_cloud_client::client_key();
    let params = create_params(name);
    let created = retried(say, "cloud.machine.create", || async {
        ops::call::<CloudMachineCreateOp>(&http, &base, params.clone(), Some(&key), None)
            .await
            .and_then(Answer::into_result)
    })
    .await?;
    let machine: CloudMachine = created.machine;
    let id = machine.id.clone();
    remember(&base, &id);
    say(&format!("Machine {id}: {}", machine.status.as_str()));
    running(&http, &base, &id, say).await
}

/// One mutation, retried with its one key while the answer says it may be.
async fn retried<T, F, Fut>(say: &mut dyn FnMut(&str), op: &str, mut send: F) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, cmux_cloud_client::ApiError>>,
{
    let mut attempt: u32 = 0;
    loop {
        attempt = attempt.saturating_add(1);
        match send().await {
            Ok(value) => return Ok(value),
            Err(error) if error.retryable && attempt < CREATE_TRIES => {
                say(&format!("{op}: {} (retrying with the same key)", error.message));
                let wait = error.retry_after.unwrap_or(Duration::from_secs(3));
                tokio::time::sleep(wait.min(Duration::from_secs(20))).await;
            }
            Err(error) => {
                bail!("{op} refused: {} {}", error.code.unwrap_or_default(), error.message)
            }
        }
    }
}

/// `cloud.machine.get` until the machine runs on a host, which is when the carrier reaches it.
async fn running(
    http: &reqwest::Client,
    base: &str,
    id: &str,
    say: &mut dyn FnMut(&str),
) -> Result<String> {
    let t0 = Instant::now();
    let mut last = String::new();
    loop {
        let params = CloudMachineGetParams { machine: id.to_owned() };
        match ops::call::<CloudMachineGetOp>(http, base, params, None, None)
            .await
            .and_then(Answer::into_result)
        {
            Ok(m) if m.status == CloudMachineStatus::Running && m.host.is_some() => {
                say(&format!("Machine {id} is running ({} s).", t0.elapsed().as_secs()));
                return Ok(id.to_owned());
            }
            Ok(m) if m.status == CloudMachineStatus::Failed => {
                bail!("machine {id} failed to start: {:?}", m.error)
            }
            Ok(m) => {
                let now = m.status.as_str().to_owned();
                if now != last {
                    say(&format!("Machine {id}: {now}"));
                    last = now;
                }
            }
            Err(error) if error.retryable => {}
            Err(error) => {
                bail!("cloud.machine.get: {} {}", error.code.unwrap_or_default(), error.message)
            }
        }
        if t0.elapsed() > RUNNING_BUDGET {
            bail!(
                "machine {id} was not running within {} s (last {last})",
                RUNNING_BUDGET.as_secs()
            );
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn on_by_default_when_signed_in_unless_killed() {
        assert!(on_by_default(None, true));
        assert!(on_by_default(Some("1"), true));
        assert!(!on_by_default(None, false));
        for off in ["0", "off", "FALSE", " no "] {
            assert!(!on_by_default(Some(off), true), "{off}");
        }
    }

    #[test]
    fn api_words_name_the_backends() {
        assert_eq!(api_base("prod"), cmux_cloud_environment::PRODUCTION_API);
        assert_eq!(api_base(""), cmux_cloud_environment::PRODUCTION_API);
        assert_eq!(api_base("staging"), cmux_cloud_environment::STAGING_API);
        assert_eq!(api_base("https://example.test/"), "https://example.test");
    }

    #[test]
    fn the_create_is_the_chat_start_size_and_says_who_started_it() {
        let p = serde_json::to_value(create_params("autocloud")).unwrap();
        assert_eq!(p["name"], "autocloud");
        assert_eq!(p["size"]["cpu"], 4);
        assert_eq!(p["size"]["memory_mb"], 16_384);
        assert_eq!(p["size"]["disk_mb"], 65_536);
        assert_eq!(p["origin"]["label"], "cmux autocloud");
        assert!(p.get("ttl_seconds").is_none());
    }
}
