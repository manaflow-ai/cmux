//! GCE's compute API for the `cmux-runner-pool-*` instances (label `purpose=cmux-runner-pool`): list, resume
//! (SUSPENDED), start (TERMINATED) and suspend. The calls cmuxterm-hq's `fleet_gce.py` `_power` makes, without
//! waiting on the operation: `up` measures when runners come online, not when GCE says RUNNING.

use reqwest::Method;
use serde_json::Value;

use crate::http::{self, CallError, Result};
use crate::model::{Machine, Power, Provider};

pub const API: &str = "https://compute.googleapis.com/compute/v1";
pub const DEFAULT_PROJECT: &str = "manaflow-437420";
pub const POOL_LABEL: &str = "cmux-runner-pool";
/// Metadata naming how many runners a pool VM carries (hq PR 15361's pool-startup.sh).
pub const RUNNERS_KEY: &str = "cmux-runner-pool-runners";
const METADATA_TOKEN: &str =
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

#[derive(Clone, Debug)]
pub struct Gce {
    pub project: String,
    pub token: String,
    pub label: String,
    /// The token came from the metadata server or gcloud (not the environment), so it can be fetched again.
    refreshable: bool,
    fetched: std::time::Instant,
}

impl Gce {
    /// The token from `CLOUDSDK_AUTH_ACCESS_TOKEN` or `GOOGLE_OAUTH_ACCESS_TOKEN`, else this VM's service
    /// account (the metadata server, as the runner-pool service on cmux-linux-scaler reads it), else
    /// `gcloud auth print-access-token`. `None` when none answers.
    pub async fn from_env(
        client: &reqwest::Client,
        env: &dyn Fn(&str) -> Option<String>,
        project: Option<String>,
    ) -> Option<Self> {
        let set = |name: &str| env(name).filter(|v| !v.is_empty());
        let (token, refreshable) =
            match set("CLOUDSDK_AUTH_ACCESS_TOKEN").or_else(|| set("GOOGLE_OAUTH_ACCESS_TOKEN")) {
                Some(token) => (token, false),
                None => (fresh_token(client).await?, true),
            };
        let project = project
            .or_else(|| set("CMUX_VM_POOL_GCP_PROJECT"))
            .unwrap_or_else(|| DEFAULT_PROJECT.to_owned());
        Some(Self {
            project,
            token,
            label: POOL_LABEL.to_owned(),
            refreshable,
            fetched: std::time::Instant::now(),
        })
    }

    /// Fetches a new token when this one is older than `max_age` (metadata and gcloud tokens last about an
    /// hour). A failed fetch keeps the old token and says so.
    pub async fn refresh_if_old(&mut self, client: &reqwest::Client, max_age: std::time::Duration) {
        if !self.refreshable || self.fetched.elapsed() < max_age {
            return;
        }
        match fresh_token(client).await {
            Some(token) => {
                self.token = token;
                self.fetched = std::time::Instant::now();
            }
            None => eprintln!("cmux vm pool: GCE token refresh failed; keeping the old one"),
        }
    }

    /// Every pool instance, in every zone.
    pub async fn list(&self, client: &reqwest::Client) -> Result<Vec<Machine>> {
        let filter = url::form_urlencoded::byte_serialize(
            format!("labels.purpose = \"{}\"", self.label).as_bytes(),
        )
        .collect::<String>();
        let mut machines = Vec::new();
        let mut page: Option<String> = None;
        loop {
            let mut url = format!(
                "{API}/projects/{}/aggregated/instances?maxResults=500&returnPartialSuccess=true&filter={filter}",
                self.project
            );
            if let Some(token) = &page {
                url.push_str("&pageToken=");
                url.push_str(token);
            }
            let body = http::call(client, Method::GET, &url, &self.token, &[], None).await?;
            if let Some(items) = body.get("items").and_then(Value::as_object) {
                for scope in items.values() {
                    if let Some(list) = scope.get("instances").and_then(Value::as_array) {
                        machines.extend(list.iter().filter_map(parse_instance));
                    }
                }
            }
            page = body.get("nextPageToken").and_then(Value::as_str).map(str::to_owned);
            if page.is_none() {
                break;
            }
        }
        Ok(machines)
    }

    fn instance_url(&self, machine: &Machine, verb: &str) -> Result<String> {
        let zone = machine
            .zone
            .as_deref()
            .ok_or_else(|| CallError(format!("{}: no zone", machine.name)))?;
        Ok(format!("{API}/projects/{}/zones/{zone}/instances/{}/{verb}", self.project, machine.id))
    }

    /// Resumes a SUSPENDED instance or starts a TERMINATED one.
    pub async fn power_on(&self, client: &reqwest::Client, machine: &Machine) -> Result<()> {
        let verb = if machine.power == Power::Paused { "resume" } else { "start" };
        let url = self.instance_url(machine, verb)?;
        http::call(client, Method::POST, &url, &self.token, &[], None).await.map(drop)
    }

    /// Suspends a running instance: memory to disk, the disk and its caches kept.
    pub async fn suspend(&self, client: &reqwest::Client, machine: &Machine) -> Result<()> {
        let url = self.instance_url(machine, "suspend")?;
        http::call(client, Method::POST, &url, &self.token, &[], None).await.map(drop)
    }
}

/// This VM's service-account token from the metadata server, else `gcloud auth print-access-token`.
async fn fresh_token(client: &reqwest::Client) -> Option<String> {
    match metadata_token(client).await {
        Some(token) => Some(token),
        None => gcloud_token().await,
    }
}

async fn metadata_token(client: &reqwest::Client) -> Option<String> {
    let response = client
        .get(METADATA_TOKEN)
        .header("Metadata-Flavor", "Google")
        .timeout(std::time::Duration::from_millis(800))
        .send()
        .await
        .ok()?;
    let body: Value = response.json().await.ok()?;
    body.get("access_token")?.as_str().map(str::to_owned)
}

async fn gcloud_token() -> Option<String> {
    let output = tokio::process::Command::new("gcloud")
        .args(["auth", "print-access-token"])
        .output()
        .await
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let token = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (!token.is_empty()).then_some(token)
}

/// The last path segment of a GCE URL (`.../zones/us-west1-a` → `us-west1-a`).
fn last_segment(url: &str) -> &str {
    url.rsplit('/').next().unwrap_or(url)
}

/// A pool machine from one instance row.
pub fn parse_instance(instance: &Value) -> Option<Machine> {
    let name = instance.get("name")?.as_str()?.to_owned();
    let zone = instance.get("zone").and_then(Value::as_str).map(|z| last_segment(z).to_owned());
    let status = instance.get("status").and_then(Value::as_str).unwrap_or("UNKNOWN").to_owned();
    let slots = instance
        .get("metadata")
        .and_then(|m| m.get("items"))
        .and_then(Value::as_array)
        .and_then(|items| {
            items.iter().find(|item| item.get("key").and_then(Value::as_str) == Some(RUNNERS_KEY))
        })
        .and_then(|item| item.get("value").and_then(Value::as_str))
        .and_then(|v| v.trim().parse::<u32>().ok())
        .filter(|&n| n > 0)
        .unwrap_or(1);
    Some(Machine {
        provider: Provider::Gcp,
        id: name.clone(),
        name,
        zone,
        power: Power::of_gce(&status),
        state: status,
        slots,
        vcpu: machine_type_vcpu(instance.get("machineType").and_then(Value::as_str).unwrap_or("")),
        schedule_pause: instance
            .get("labels")
            .and_then(|l| l.get("cmux-schedule"))
            .and_then(Value::as_str)
            == Some(crate::model::SCHEDULE_PAUSE),
    })
}

/// vCPUs of a GCE machine type URL or name: the number after the family (`n2d-standard-32` -> 32,
/// `custom-8-32768` -> 8); 0 when it does not say.
pub fn machine_type_vcpu(machine_type: &str) -> u32 {
    let name = last_segment(machine_type);
    let parts: Vec<&str> = name.split('-').collect();
    if parts.first() == Some(&"custom") || parts.get(1) == Some(&"custom") {
        return parts.iter().find_map(|p| p.parse().ok()).unwrap_or(0);
    }
    parts.iter().rev().find_map(|p| p.parse().ok()).unwrap_or(0)
}
