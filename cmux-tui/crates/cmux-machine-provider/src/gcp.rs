//! The Compute Engine adapter: machines in the user's own GCP project.
//!
//! Every mutating call carries a `requestId` derived from the idempotency key
//! (Compute Engine drops a repeat of the same request id), and a created
//! machine's name is derived from the key too, so a create reissued after a
//! lost answer finds its own machine (409, label `cmux-key` matches) instead
//! of making a second one.
//!
//! The VM gets no external address (the first route is SSH over IAP), OS
//! Login, no service account and no provider credential; the guest's idle
//! stop reads its grace from the `cmux-idle-grace-minutes` metadata key.

use crate::contract::{
    CostEstimate, CreateSpec, IdempotencyKey, MachineProvider, MachineState, Op, ProviderError,
    Request,
};
use crate::labs;
use cmux_process::{Command, Stdio};
use serde_json::{Value, json};
use std::fmt;
use std::io::{Read, Write};

const COMPUTE: &str = "https://compute.googleapis.com/compute/v1";

/// An OAuth access token for the user's project. Never printed, never put in
/// argv or the environment; its bytes are overwritten on drop.
pub struct AccessToken(Vec<u8>);

impl AccessToken {
    /// A token as read from the caller's descriptor: printable ASCII, no
    /// whitespace inside (it becomes one header line).
    pub fn new(raw: &[u8]) -> Result<Self, ProviderError> {
        let token = raw.trim_ascii();
        if token.is_empty() || token.len() > 8192 || !token.iter().all(u8::is_ascii_graphic) {
            return Err(ProviderError::Refused("the access token is not a token".into()));
        }
        Ok(Self(token.to_vec()))
    }

    /// Read the token from an open descriptor the caller passed
    /// (`/dev/fd/N`), so it never travels in argv or the environment.
    pub fn from_fd(fd: u32) -> Result<Self, ProviderError> {
        let mut bytes = Vec::new();
        std::fs::File::open(format!("/dev/fd/{fd}"))
            .and_then(|f| f.take(8193).read_to_end(&mut bytes))
            .map_err(|e| ProviderError::Refused(format!("token descriptor {fd}: {e}")))?;
        let token = Self::new(&bytes);
        bytes.fill(0);
        token
    }

    fn header_line(&self) -> Vec<u8> {
        let mut line = b"Authorization: Bearer ".to_vec();
        line.extend_from_slice(&self.0);
        line.push(b'\n');
        line
    }
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("AccessToken(<redacted>)")
    }
}

impl Drop for AccessToken {
    fn drop(&mut self) {
        self.0.fill(0);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportError {
    /// No HTTP answer: the request may or may not have reached the provider.
    NoAnswer(String),
}

/// One HTTPS round trip. Separate so tests and the bench run the adapter
/// against a scripted provider.
pub trait Transport {
    fn send(
        &self,
        method: &str,
        url: &str,
        token: &AccessToken,
        body: Option<&Value>,
    ) -> Result<(u16, Value), TransportError>;
}

/// `curl`, with the Authorization header written to its stdin (`-H @-`).
pub struct CurlTransport {
    pub max_seconds: u32,
}

impl Default for CurlTransport {
    fn default() -> Self {
        Self { max_seconds: 60 }
    }
}

impl Transport for CurlTransport {
    fn send(
        &self,
        method: &str,
        url: &str,
        token: &AccessToken,
        body: Option<&Value>,
    ) -> Result<(u16, Value), TransportError> {
        let mut command = Command::new("curl");
        command
            .args(["-sS", "--max-time", &self.max_seconds.to_string(), "-X", method])
            .args(["-H", "@-", "-H", "Content-Type: application/json"])
            .args(["-w", "\n%{http_code}"]);
        match body {
            Some(body) => {
                command.args(["--data-binary", &body.to_string()]);
            }
            // A POST with no body still says `Content-Length: 0`; Google's
            // front end answers 411 without it.
            None if method == "POST" => {
                command.args(["--data-binary", ""]);
            }
            None => {}
        }
        let mut child = command
            .arg(url)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| TransportError::NoAnswer(format!("curl: {e}")))?;
        let mut header = token.header_line();
        let wrote = child.stdin.take().map(|mut stdin| stdin.write_all(&header));
        header.fill(0);
        if let Some(Err(e)) = wrote {
            return Err(TransportError::NoAnswer(format!("curl stdin: {e}")));
        }
        let output =
            child.wait_with_output().map_err(|e| TransportError::NoAnswer(format!("curl: {e}")))?;
        let text = String::from_utf8_lossy(&output.stdout);
        let (body, code) = text.rsplit_once('\n').unwrap_or(("", &text));
        let status = code.trim().parse::<u16>().unwrap_or(0);
        if !output.status.success() || status == 0 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(TransportError::NoAnswer(format!("curl: {}", stderr.trim())));
        }
        Ok((status, serde_json::from_str(body).unwrap_or(Value::Null)))
    }
}

pub struct GcpProvider {
    project: String,
    zone: String,
    token: AccessToken,
    transport: Box<dyn Transport>,
    base: String,
    /// Wait for each mutating call's operation to finish (one server-side
    /// wait call) before answering.
    pub wait: bool,
}

impl GcpProvider {
    /// A provider for one project and zone. `labs` is the proof that
    /// `labs.gcpMachineProvider` was on ([`labs::require`]): no provider, and
    /// so no call, exists without it.
    pub fn new(
        _labs: labs::Enabled,
        project: &str,
        zone: &str,
        token: AccessToken,
        transport: Box<dyn Transport>,
    ) -> Result<Self, ProviderError> {
        for (what, value) in [("project", project), ("zone", zone)] {
            if !valid_name(value) {
                return Err(ProviderError::Refused(format!("{what} {value:?} is not a GCP name")));
            }
        }
        Ok(Self {
            project: project.to_owned(),
            zone: zone.to_owned(),
            token,
            transport,
            base: COMPUTE.to_owned(),
            wait: false,
        })
    }

    fn zone_url(&self) -> String {
        format!("{}/projects/{}/zones/{}", self.base, self.project, self.zone)
    }

    fn call(&self, method: &str, url: &str, body: Option<&Value>) -> Result<Value, ProviderError> {
        let (status, body) = self
            .transport
            .send(method, url, &self.token, body)
            .map_err(|TransportError::NoAnswer(m)| ProviderError::Indeterminate(m))?;
        let message =
            || body.pointer("/error/message").and_then(Value::as_str).unwrap_or("").to_owned();
        match status {
            200..=299 => Ok(body),
            401 | 403 => Err(ProviderError::Refused(message())),
            404 => Err(ProviderError::NotFound(message())),
            409 => Err(ProviderError::Conflict(message())),
            408 | 429 | 500..=599 => {
                Err(ProviderError::Indeterminate(format!("{status} {}", message())))
            }
            _ => Err(ProviderError::Api { status, message: message() }),
        }
    }

    /// Wait (server side, up to about two minutes) for an operation, and
    /// turn its error into ours. A wait that ends before the operation does
    /// is indeterminate: the ledger settles it on the next run.
    fn finish(&self, operation: &Value) -> Result<(), ProviderError> {
        // An operation can come back already failed (a retried request id
        // returns the original operation).
        if let Some(message) = operation.pointer("/error/errors/0/message").and_then(Value::as_str)
        {
            return Err(ProviderError::Api { status: 200, message: message.to_owned() });
        }
        if !self.wait {
            return Ok(());
        }
        let Some(name) = operation.get("name").and_then(Value::as_str) else { return Ok(()) };
        let name_ok = name.len() <= 128
            && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if !name_ok {
            return Err(ProviderError::Indeterminate(format!("operation {name:?}")));
        }
        let done =
            self.call("POST", &format!("{}/operations/{name}/wait", self.zone_url()), None)?;
        if done.get("status").and_then(Value::as_str) != Some("DONE") {
            return Err(ProviderError::Indeterminate(format!("operation {name} still running")));
        }
        match done.pointer("/error/errors/0/message").and_then(Value::as_str) {
            Some(message) => Err(ProviderError::Api { status: 200, message: message.to_owned() }),
            None => Ok(()),
        }
    }

    fn instance(&self, machine: &str) -> Result<Option<Value>, ProviderError> {
        match self.call("GET", &format!("{}/instances/{machine}", self.zone_url()), None) {
            Ok(body) => Ok(Some(body)),
            Err(ProviderError::NotFound(_)) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

/// The machine a `create` with `key` makes.
pub fn machine_name(key: &IdempotencyKey) -> String {
    format!("cmux-{}", key.digest_prefix("machine", 16))
}

/// The Compute Engine `instances.insert` body for `spec` (the setup sheet's
/// preview shows exactly this).
pub fn insert_body(key: &IdempotencyKey, machine: &str, spec: &CreateSpec) -> Value {
    let mut labels: serde_json::Map<String, Value> =
        spec.labels.iter().map(|(k, v)| (k.clone(), json!(v))).collect();
    labels.insert("cmux-machine".into(), json!("true"));
    labels.insert("cmux-key".into(), json!(key_label(key)));
    json!({
        "name": machine,
        "machineType": format!("zones/{}/machineTypes/{}", spec.zone, spec.machine_type),
        "labels": labels,
        "disks": [{
            "boot": true,
            "autoDelete": true,
            "deviceName": machine,
            "initializeParams": {
                "diskName": machine,
                "sourceImage": spec.image,
                "diskSizeGb": spec.disk_gb.to_string(),
            },
        }],
        // No accessConfigs: no external address. Attach goes over IAP.
        "networkInterfaces": [{ "network": "global/networks/default" }],
        "serviceAccounts": [],
        "shieldedInstanceConfig": { "enableSecureBoot": true, "enableVtpm": true },
        "metadata": { "items": [
            { "key": "enable-oslogin", "value": "TRUE" },
            { "key": "cmux-idle-grace-minutes", "value": spec.idle_grace_minutes.to_string() },
        ]},
    })
}

/// List-price estimates for `spec`, each with its source.
pub fn cost_estimate(spec: &CreateSpec) -> CostEstimate {
    // List prices, us-central1, on demand, read 2026-11. A prototype table:
    // the release reads the user's billing catalog instead.
    let per_hour = match spec.machine_type.as_str() {
        "e2-standard-2" => 0.067,
        "e2-standard-4" => 0.134,
        "e2-standard-8" => 0.268,
        "n2-standard-4" => 0.194,
        "n2-standard-8" => 0.388,
        _ => f64::NAN,
    };
    CostEstimate {
        machine_type: spec.machine_type.clone(),
        zone: spec.zone.clone(),
        running_per_hour: per_hour,
        stopped_disk_per_month: 0.04 * f64::from(spec.disk_gb),
        egress_per_gb: 0.12,
        currency: "USD".into(),
        source: "static list-price table, us-central1, 2026-11 (prototype)".into(),
    }
}

impl MachineProvider for GcpProvider {
    fn provider(&self) -> &str {
        "gcp"
    }

    fn project(&self) -> &str {
        &self.project
    }

    fn location(&self) -> &str {
        &self.zone
    }

    fn machine_for(&self, key: &IdempotencyKey) -> String {
        machine_name(key)
    }

    fn apply(
        &self,
        key: &IdempotencyKey,
        request: &Request,
    ) -> Result<(MachineState, Option<String>), ProviderError> {
        let machine = match request.op {
            Op::Create => self.machine_for(key),
            _ => request.machine.clone().unwrap_or_default(),
        };
        if !valid_name(&machine) {
            return Err(ProviderError::Refused(format!("machine {machine:?} is not a GCP name")));
        }
        let rid = request_id(key, request.op);
        let zone = self.zone_url();
        match request.op {
            Op::Create => {
                let spec = request
                    .spec
                    .as_ref()
                    .ok_or_else(|| ProviderError::Refused("create needs a spec".into()))?;
                if spec.zone != self.zone {
                    return Err(ProviderError::Refused(format!(
                        "the spec's zone {} is not this provider's zone {}",
                        spec.zone, self.zone
                    )));
                }
                let body = insert_body(key, &machine, spec);
                match self.call("POST", &format!("{zone}/instances?requestId={rid}"), Some(&body)) {
                    Ok(operation) => {
                        self.finish(&operation)?;
                        Ok((MachineState::Provisioning, None))
                    }
                    Err(ProviderError::Conflict(_)) => {
                        // A machine with our name exists: ours only if it
                        // carries our key's label.
                        let found = self.instance(&machine)?;
                        let label = found.as_ref().and_then(|i| i.pointer("/labels/cmux-key"));
                        if label.and_then(Value::as_str) == Some(key_label(key).as_str()) {
                            Ok((state_of(found.as_ref()), None))
                        } else {
                            Err(ProviderError::Conflict(format!(
                                "{machine} belongs to another key"
                            )))
                        }
                    }
                    Err(e) => Err(e),
                }
            }
            Op::Start | Op::Stop => {
                let verb = if request.op == Op::Start { "start" } else { "stop" };
                let operation = self.call(
                    "POST",
                    &format!("{zone}/instances/{machine}/{verb}?requestId={rid}"),
                    None,
                )?;
                self.finish(&operation)?;
                let state = if !self.wait {
                    if request.op == Op::Start {
                        MachineState::Provisioning
                    } else {
                        MachineState::Stopping
                    }
                } else if request.op == Op::Start {
                    MachineState::Running
                } else {
                    MachineState::Stopped
                };
                Ok((state, None))
            }
            Op::Snapshot => {
                let name = format!("cmux-snap-{}", key.digest_prefix("snapshot", 16));
                let label = key_label(key);
                let body = json!({
                    "name": name,
                    "labels": { "cmux-machine": "true", "cmux-key": label },
                });
                let url = format!("{zone}/disks/{machine}/createSnapshot?requestId={rid}");
                match self.call("POST", &url, Some(&body)) {
                    Ok(operation) => self.finish(&operation)?,
                    // The name exists: ours only if it carries our label.
                    Err(ProviderError::Conflict(_)) => {
                        let url = format!(
                            "{}/projects/{}/global/snapshots/{name}",
                            self.base, self.project
                        );
                        let found = self.call("GET", &url, None)?;
                        if found.pointer("/labels/cmux-key").and_then(Value::as_str)
                            != Some(label.as_str())
                        {
                            return Err(ProviderError::Conflict(format!(
                                "snapshot {name} belongs to another key"
                            )));
                        }
                    }
                    Err(e) => return Err(e),
                }
                Ok((state_of(self.instance(&machine)?.as_ref()), Some(name)))
            }
            Op::Delete => {
                match self.call(
                    "DELETE",
                    &format!("{zone}/instances/{machine}?requestId={rid}"),
                    None,
                ) {
                    Ok(operation) => {
                        self.finish(&operation)?;
                        Ok((
                            if self.wait { MachineState::Deleted } else { MachineState::Deleting },
                            None,
                        ))
                    }
                    Err(ProviderError::NotFound(_)) => Ok((MachineState::Deleted, None)),
                    Err(e) => Err(e),
                }
            }
        }
    }

    fn observe(&self, machine: &str) -> Result<Option<MachineState>, ProviderError> {
        if !valid_name(machine) {
            return Err(ProviderError::Refused(format!("machine {machine:?} is not a GCP name")));
        }
        Ok(self.instance(machine)?.map(|i| state_of(Some(&i))))
    }

    fn cost_estimate(&self, spec: &CreateSpec) -> CostEstimate {
        cost_estimate(spec)
    }
}

fn state_of(instance: Option<&Value>) -> MachineState {
    match instance.and_then(|i| i.get("status")).and_then(Value::as_str) {
        None => MachineState::Deleted,
        Some("PROVISIONING" | "STAGING" | "REPAIRING") => MachineState::Provisioning,
        Some("RUNNING") => MachineState::Running,
        Some("STOPPING" | "SUSPENDING") => MachineState::Stopping,
        Some("TERMINATED" | "STOPPED" | "SUSPENDED") => MachineState::Stopped,
        Some(_) => MachineState::Unknown,
    }
}

/// A GCP resource name: lowercase letters, digits and `-`, 1 to 63, starting
/// with a letter. Every name that goes into a URL path or a file name passes
/// this.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 63
        && name.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

fn key_label(key: &IdempotencyKey) -> String {
    key.digest_prefix("label", 32)
}

/// A UUID (the form Compute Engine's `requestId` takes) derived from the key
/// and op, so a retried call carries the same request id.
pub fn request_id(key: &IdempotencyKey, op: Op) -> String {
    let op = serde_json::to_string(&op).unwrap_or_default();
    // Version 4 at digit 12, variant 8, 9, a or b at digit 16.
    let hex: String = key
        .digest_prefix(&format!("request:{op}"), 32)
        .chars()
        .enumerate()
        .map(|(i, c)| match i {
            12 => '4',
            16 => match u32::from(c) & 3 {
                0 => '8',
                1 => '9',
                2 => 'a',
                _ => 'b',
            },
            _ => c,
        })
        .collect();
    let part = |from: usize, to: usize| hex.get(from..to).unwrap_or_default();
    format!("{}-{}-{}-{}-{}", part(0, 8), part(8, 12), part(12, 16), part(16, 20), part(20, 32))
}
