//! Freestyle's VM API (`https://api.freestyle.sh/v5/vms`), the calls cmuxterm-hq's freestyle-workflow makes:
//! list, start (a paused or stopped VM), pause, and for `cmux vm runner` create, get, update, resize and exec. Pool VMs carry metadata `purpose: freestyle-pool` and
//! `fsp_runner` (the runner name; hq PR 15371's pool.mjs), and `fsp_runners` (a comma list) when a VM carries
//! more than one runner.

use std::time::Duration;

use reqwest::Method;
use serde_json::Value;

use crate::http::{self, CallError, Result};
use crate::model::{Machine, Power, Provider};

pub const DEFAULT_BASE: &str = "https://api.freestyle.sh";
pub const POOL_PURPOSE: &str = "freestyle-pool";
/// The pool's VM size (hq#15371 `FREESTYLE_POOL_VCPU` default) when a VM does not say.
pub const DEFAULT_VCPU: u32 = 16;
const PAGE: usize = 100;
/// `exec-await` caps one call at 300 s; stay under it.
pub const EXEC_MAX_MS: u64 = 290_000;
const LONG_CALL: Duration = Duration::from_secs(120);

/// The `exec-await` request body.
pub fn exec_body(command: &str, stdin: Option<&[u8]>, timeout_ms: u64) -> Value {
    let mut body =
        serde_json::json!({"command": command, "linuxUser": "root", "timeoutMs": timeout_ms});
    if let (Some(stdin), Some(map)) = (stdin, body.as_object_mut()) {
        map.insert("stdin".to_owned(), Value::String(base64(stdin)));
    }
    body
}

/// Standard base64 with padding (the wire form of `stdin`).
pub fn base64(bytes: &[u8]) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n =
            chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(
                    ABC.get(((n >> (18 - 6 * i)) & 63) as usize).map_or('=', |c| char::from(*c)),
                );
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[derive(Clone)]
pub struct Freestyle {
    pub base: String,
    pub key: String,
    pub purpose: String,
}

/// Debug never shows the key.
impl std::fmt::Debug for Freestyle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Freestyle")
            .field("base", &self.base)
            .field("key", &"<redacted>")
            .field("purpose", &self.purpose)
            .finish()
    }
}

/// One `exec-await` answer: the guest command's exit status (`-1` when it timed out or the exec layer dropped
/// it) and its output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExecOutcome {
    pub code: i64,
    pub stdout: String,
    pub stderr: String,
}

impl Freestyle {
    /// From `FREESTYLE_API_KEY` (and `FREESTYLE_API_URL`), or `None` when no key is set.
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<Self> {
        let key = env("FREESTYLE_API_KEY").filter(|k| !k.is_empty())?;
        let base = env("FREESTYLE_API_URL")
            .filter(|b| !b.is_empty())
            .map(crate::http::named)
            .unwrap_or_else(|| DEFAULT_BASE.to_owned());
        Some(Self {
            base: base.trim_end_matches('/').to_owned(),
            key,
            purpose: POOL_PURPOSE.to_owned(),
        })
    }

    /// A client for `base` with `key` (a user's own key, read in place by the caller).
    pub fn new(base: &str, key: String, purpose: &str) -> Self {
        Self { base: base.trim_end_matches('/').to_owned(), key, purpose: purpose.to_owned() }
    }

    /// Every VM row carrying this client's purpose, as the API gave it (state, resources and metadata).
    pub async fn list_rows(&self, client: &reqwest::Client) -> Result<Vec<Value>> {
        let mut out = Vec::new();
        let mut offset = 0usize;
        loop {
            let url = format!(
                "{}/v5/vms?limit={PAGE}&offset={offset}&metadata=purpose:{}",
                self.base, self.purpose
            );
            let body = http::call(client, Method::GET, &url, &self.key, &[], None).await?;
            let rows = body
                .get("vms")
                .and_then(Value::as_array)
                .ok_or_else(|| CallError(format!("GET {url}: no `vms` list")))?;
            out.extend(
                rows.iter()
                    .filter(|vm| meta(vm, "purpose") == Some(self.purpose.as_str()))
                    .cloned(),
            );
            if rows.len() < PAGE {
                break;
            }
            offset += rows.len();
        }
        Ok(out)
    }

    /// Every VM the account holds in any state (`totalCount` of an unfiltered one-row list): the count the
    /// 4,000-VM limit applies to. `None` when the reply is not a whole count (the caller then creates nothing).
    pub async fn saved_count(&self, client: &reqwest::Client) -> Option<u64> {
        let url = format!("{}/v5/vms?limit=1&offset=0", self.base);
        let body = http::call(client, Method::GET, &url, &self.key, &[], None).await.ok()?;
        let total = body.get("totalCount")?.as_u64()?;
        let states: Vec<Option<u64>> = ["starting", "running", "pausing", "paused", "stopped"]
            .iter()
            .map(|k| body.get(format!("{k}Count")).and_then(Value::as_u64))
            .collect();
        // The per-state counts, when all given, must sum to the total.
        if states.iter().all(Option::is_some) && states.iter().flatten().sum::<u64>() != total {
            return None;
        }
        Some(total)
    }

    /// One VM as the API describes it.
    pub async fn get(&self, client: &reqwest::Client, id: &str) -> Result<Value> {
        let url = format!("{}/v5/vms/{id}", self.base);
        http::call(client, Method::GET, &url, &self.key, &[], None).await
    }

    /// Makes one VM and returns its id.
    pub async fn create(&self, client: &reqwest::Client, body: &Value) -> Result<String> {
        let url = format!("{}/v5/vms", self.base);
        let made = http::call(client, Method::POST, &url, &self.key, &[], Some(body)).await?;
        made.get("id")
            .or_else(|| made.get("vmId"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| CallError(format!("POST {url}: no VM id in the answer")))
    }

    /// Changes a VM's display name, metadata or settings (`PATCH /v5/vms/{id}`).
    pub async fn update(&self, client: &reqwest::Client, id: &str, body: &Value) -> Result<()> {
        let url = format!("{}/v5/vms/{id}", self.base);
        http::call(client, Method::PATCH, &url, &self.key, &[], Some(body)).await.map(drop)
    }

    /// Grow-only resize (`cpu`, `memory` MiB, `storage` MiB).
    pub async fn resize(&self, client: &reqwest::Client, id: &str, body: &Value) -> Result<()> {
        let url = format!("{}/v5/vms/{id}/resize", self.base);
        http::call_within(client, Method::POST, &url, &self.key, &[], Some(body), Some(LONG_CALL))
            .await
            .map(drop)
    }

    /// Runs `command` as root in the guest and waits (`/exec-await`, capped at 290 s a call). A secret goes in
    /// `stdin` (base64 on the wire), never in `command`: the command is recorded by Freestyle.
    pub async fn exec(
        &self,
        client: &reqwest::Client,
        id: &str,
        command: &str,
        stdin: Option<&[u8]>,
        timeout_ms: u64,
    ) -> Result<ExecOutcome> {
        let timeout_ms = timeout_ms.clamp(1000, EXEC_MAX_MS);
        let url = format!("{}/v5/vms/{id}/exec-await", self.base);
        let body = exec_body(command, stdin, timeout_ms);
        let within = Duration::from_millis(timeout_ms) + Duration::from_secs(30);
        let got = http::call_within(
            client,
            Method::POST,
            &url,
            &self.key,
            &[],
            Some(&body),
            Some(within),
        )
        .await?;
        Ok(ExecOutcome {
            code: got.get("statusCode").and_then(Value::as_i64).unwrap_or(-1),
            stdout: got.get("stdout").and_then(Value::as_str).unwrap_or_default().to_owned(),
            stderr: got.get("stderr").and_then(Value::as_str).unwrap_or_default().to_owned(),
        })
    }

    /// Every pool VM.
    pub async fn list(&self, client: &reqwest::Client) -> Result<Vec<Machine>> {
        let mut machines = Vec::new();
        let mut offset = 0usize;
        loop {
            let url = format!(
                "{}/v5/vms?limit={PAGE}&offset={offset}&metadata=purpose:{}",
                self.base, self.purpose
            );
            let body = http::call(client, Method::GET, &url, &self.key, &[], None).await?;
            let rows = body
                .get("vms")
                .and_then(Value::as_array)
                .ok_or_else(|| CallError(format!("GET {url}: no `vms` list")))?;
            machines.extend(rows.iter().filter_map(|vm| parse_vm(vm, &self.purpose)));
            if rows.len() < PAGE {
                break;
            }
            offset += rows.len();
        }
        Ok(machines)
    }

    /// Starts a paused or stopped VM (Freestyle resumes a paused one with its memory).
    pub async fn start(&self, client: &reqwest::Client, id: &str) -> Result<()> {
        let url = format!("{}/v5/vms/{id}/start", self.base);
        http::call(client, Method::POST, &url, &self.key, &[], None).await.map(drop)
    }

    /// Pauses a running VM, keeping its memory and disk.
    pub async fn pause(&self, client: &reqwest::Client, id: &str) -> Result<()> {
        let url = format!("{}/v5/vms/{id}/pause", self.base);
        http::call(client, Method::POST, &url, &self.key, &[], None).await.map(drop)
    }
}

fn meta<'a>(vm: &'a Value, key: &str) -> Option<&'a str> {
    vm.get("metadata")?.get(key)?.as_str()
}

/// A pool VM from one `/v5/vms` row; `None` for any other VM (the filter is checked here too, in case the
/// API ignores the query).
pub fn parse_vm(vm: &Value, purpose: &str) -> Option<Machine> {
    if meta(vm, "purpose")? != purpose {
        return None;
    }
    let id = vm.get("id")?.as_str()?.to_owned();
    let state = vm.get("state").and_then(Value::as_str).unwrap_or("unknown").to_owned();
    let name = meta(vm, "fsp_runner")
        .or_else(|| vm.get("name").and_then(Value::as_str))
        .unwrap_or(&id)
        .to_owned();
    let slots = meta(vm, "fsp_runners")
        .map(|list| list.split(',').filter(|s| !s.trim().is_empty()).count())
        .and_then(|n| u32::try_from(n).ok())
        .filter(|&n| n > 0)
        .unwrap_or(1);
    Some(Machine {
        provider: Provider::Freestyle,
        id,
        name,
        zone: None,
        power: Power::of_freestyle(&state),
        state,
        slots,
        vcpu: meta(vm, "fsp_vcpu").and_then(|v| v.trim().parse().ok()).unwrap_or(DEFAULT_VCPU),
        schedule_pause: meta(vm, "cmux_schedule") == Some(crate::model::SCHEDULE_PAUSE),
    })
}
