//! Freestyle's VM API (`https://api.freestyle.sh/v5/vms`), the calls cmuxterm-hq's freestyle-workflow makes:
//! list, start (a paused or stopped VM) and pause. Pool VMs carry metadata `purpose: freestyle-pool` and
//! `fsp_runner` (the runner name; hq PR 15371's pool.mjs), and `fsp_runners` (a comma list) when a VM carries
//! more than one runner.

use reqwest::Method;
use serde_json::Value;

use crate::http::{self, CallError, Result};
use crate::model::{Machine, Power, Provider};

pub const DEFAULT_BASE: &str = "https://api.freestyle.sh";
pub const POOL_PURPOSE: &str = "freestyle-pool";
/// The pool's VM size (hq#15371 `FREESTYLE_POOL_VCPU` default) when a VM does not say.
pub const DEFAULT_VCPU: u32 = 16;
const PAGE: usize = 100;

#[derive(Clone, Debug)]
pub struct Freestyle {
    pub base: String,
    pub key: String,
    pub purpose: String,
}

impl Freestyle {
    /// From `FREESTYLE_API_KEY` (and `FREESTYLE_API_URL`), or `None` when no key is set.
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>) -> Option<Self> {
        let key = env("FREESTYLE_API_KEY").filter(|k| !k.is_empty())?;
        let base = env("FREESTYLE_API_URL")
            .filter(|b| !b.is_empty())
            .unwrap_or_else(|| DEFAULT_BASE.to_owned());
        Some(Self {
            base: base.trim_end_matches('/').to_owned(),
            key,
            purpose: POOL_PURPOSE.to_owned(),
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
