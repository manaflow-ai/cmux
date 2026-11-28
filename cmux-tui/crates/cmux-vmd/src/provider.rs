//! `VmdProvider`: the AutoCloud `MachineProvider` backed by a `cmux-vmd` host over HTTP.
//!
//! One provider talks to one host. Spec labels pick per-machine options the trait has no field
//! for: `cmux.vmd/egress` = `none` (default) | `internet`, `cmux.vmd/vcpus`, `cmux.vmd/mem-mib`.

use std::collections::BTreeMap;
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use cmux_tui_machine_protocol::operations::{
    CreateMachineSpec, ExecOutput, ExecRequest, ExposedPort, ForkLatencyClass, MachineHandle,
    MachineOperation, MachineOperationCapabilities, MachineProvider, MachineProviderError,
    MachineRunState, PortProtocol, SnapshotHandle,
};
use serde_json::{Value, json};

use crate::set_field;

pub struct VmdProvider {
    base: String,
    token: String,
    client: reqwest::Client,
}

impl VmdProvider {
    /// `base` like `http://10.0.0.5:7070`; `token` is the host's bearer token.
    pub fn new(
        base: impl Into<String>,
        token: impl Into<String>,
    ) -> Result<Self, MachineProviderError> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let base = base.into().trim_end_matches('/').to_owned();
        // The operator named this cmux-vmd host, so the egress gate lets it through.
        cmux_egress::allow_named(&base);
        let client = cmux_egress::client_builder("cmux_vmd::provider")
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(3700))
            .build()
            .map_err(|e| MachineProviderError::Backend(format!("http client: {e}")))?;
        Ok(Self { base, token: token.into(), client })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base)
    }

    /// `{base}{path}?path={file}`, the file path query-encoded.
    fn file_url(
        &self,
        machine: &MachineHandle,
        file: &str,
    ) -> Result<reqwest::Url, MachineProviderError> {
        let mut url = reqwest::Url::parse(&self.url(&format!("/v1/machines/{}/files", machine.0)))
            .map_err(|e| MachineProviderError::InvalidInput(format!("bad cmux-vmd url: {e}")))?;
        url.query_pairs_mut().append_pair("path", file);
        Ok(url)
    }

    async fn send(
        &self,
        op: MachineOperation,
        req: reqwest::RequestBuilder,
    ) -> Result<reqwest::Response, MachineProviderError> {
        let (client, req) = req.bearer_auth(&self.token).build_split();
        let req = req.map_err(|e| MachineProviderError::Backend(format!("bad request: {e}")))?;
        let subject = subject_id(req.url());
        let resp = client
            .execute(req)
            .await
            .map_err(|e| MachineProviderError::Backend(format!("cmux-vmd unreachable: {e}")))?;
        if resp.status().is_success() {
            return Ok(resp);
        }
        let status = resp.status();
        let body: Value = resp.json().await.unwrap_or(Value::Null);
        Err(map_error(op, &subject, status.as_u16(), &body))
    }

    async fn json(
        &self,
        op: MachineOperation,
        req: reqwest::RequestBuilder,
    ) -> Result<Value, MachineProviderError> {
        self.send(op, req)
            .await?
            .json()
            .await
            .map_err(|e| MachineProviderError::Backend(format!("bad cmux-vmd reply: {e}")))
    }
}

/// The machine or snapshot id a `/v1/machines/{id}...` or `/v1/snapshots/{id}...` url names.
fn subject_id(url: &reqwest::Url) -> String {
    url.path_segments()
        .and_then(|mut s| {
            s.next();
            s.next();
            s.next()
        })
        .unwrap_or("")
        .to_owned()
}

fn map_error(
    op: MachineOperation,
    subject: &str,
    status: u16,
    body: &Value,
) -> MachineProviderError {
    let code = body.pointer("/error/code").and_then(Value::as_str).unwrap_or("");
    let message = body.pointer("/error/message").and_then(Value::as_str).unwrap_or("").to_owned();
    match (status, code) {
        (_, "machine_not_found") => {
            MachineProviderError::MachineNotFound(MachineHandle(subject.to_owned()))
        }
        (_, "snapshot_not_found") => {
            MachineProviderError::SnapshotNotFound(SnapshotHandle(subject.to_owned()))
        }
        (_, "invalid_input") => MachineProviderError::InvalidInput(message),
        (_, "invalid_state") => {
            let state = if message.contains("paused") {
                MachineRunState::Paused
            } else {
                MachineRunState::Running
            };
            MachineProviderError::InvalidState { operation: op, state }
        }
        _ => MachineProviderError::Backend(format!("cmux-vmd {status}: {message}")),
    }
}

/// The create/fork body for `spec`.
fn spec_body(spec: &CreateMachineSpec, image: bool) -> Value {
    let label = |k: &str| spec.labels.get(k).map(String::as_str);
    let egress = match label("cmux.vmd/egress") {
        Some("internet") => json!({"mode": "internet"}),
        _ => json!({"mode": "none"}),
    };
    let mut body = json!({"name": spec.name, "labels": spec.labels, "egress": egress});
    if image && let Some(img) = &spec.image {
        set_field(&mut body, "image", json!(img));
    }
    if let Some(v) = label("cmux.vmd/vcpus").and_then(|v| v.parse::<u8>().ok()) {
        set_field(&mut body, "vcpus", json!(v));
    }
    if let Some(v) = label("cmux.vmd/mem-mib").and_then(|v| v.parse::<u32>().ok()) {
        set_field(&mut body, "mem_mib", json!(v));
    }
    body
}

fn id_of(v: &Value, key: &str) -> Result<String, MachineProviderError> {
    v.get(key)
        .and_then(|k| k.get("id"))
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| MachineProviderError::Backend(format!("cmux-vmd reply has no {key}.id")))
}

fn b64(v: &Value, key: &str) -> Result<Vec<u8>, MachineProviderError> {
    B64.decode(v.get(key).and_then(Value::as_str).unwrap_or(""))
        .map_err(|e| MachineProviderError::Backend(format!("bad base64 in {key}: {e}")))
}

#[async_trait]
impl MachineProvider for VmdProvider {
    fn capabilities(&self) -> MachineOperationCapabilities {
        MachineOperationCapabilities {
            create: true,
            snapshot: true,
            fork: true,
            pause_resume: true,
            delete: true,
            fs: true,
            fs_while_paused: false,
            exec: true,
            exposed_ports: true,
            fork_latency: ForkLatencyClass::Immediate,
        }
    }

    async fn create(&self, spec: CreateMachineSpec) -> Result<MachineHandle, MachineProviderError> {
        let v = self
            .json(
                MachineOperation::Create,
                self.client.post(self.url("/v1/machines")).json(&spec_body(&spec, true)),
            )
            .await?;
        Ok(MachineHandle(id_of(&v, "machine")?))
    }

    async fn snapshot(
        &self,
        machine: &MachineHandle,
    ) -> Result<SnapshotHandle, MachineProviderError> {
        let v = self
            .json(
                MachineOperation::Snapshot,
                self.client.post(self.url(&format!("/v1/machines/{}/snapshot", machine.0))),
            )
            .await?;
        Ok(SnapshotHandle(id_of(&v, "snapshot")?))
    }

    async fn fork(
        &self,
        snapshot: &SnapshotHandle,
        spec: CreateMachineSpec,
    ) -> Result<MachineHandle, MachineProviderError> {
        let url = self.url(&format!("/v1/snapshots/{}/fork", snapshot.0));
        let v = self
            .json(MachineOperation::Fork, self.client.post(url).json(&spec_body(&spec, false)))
            .await?;
        Ok(MachineHandle(id_of(&v, "machine")?))
    }

    async fn pause(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        self.send(
            MachineOperation::Pause,
            self.client.post(self.url(&format!("/v1/machines/{}/pause", machine.0))),
        )
        .await
        .map(drop)
    }

    async fn resume(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        self.send(
            MachineOperation::Resume,
            self.client.post(self.url(&format!("/v1/machines/{}/resume", machine.0))),
        )
        .await
        .map(drop)
    }

    async fn delete(&self, machine: &MachineHandle) -> Result<(), MachineProviderError> {
        self.send(
            MachineOperation::Delete,
            self.client.delete(self.url(&format!("/v1/machines/{}", machine.0))),
        )
        .await
        .map(drop)
    }

    async fn read_file(
        &self,
        machine: &MachineHandle,
        path: &str,
    ) -> Result<Vec<u8>, MachineProviderError> {
        let req = self.client.get(self.file_url(machine, path)?);
        let bytes = self
            .send(MachineOperation::FsRead, req)
            .await?
            .bytes()
            .await
            .map_err(|e| MachineProviderError::Backend(e.to_string()))?;
        Ok(bytes.to_vec())
    }

    async fn write_file(
        &self,
        machine: &MachineHandle,
        path: &str,
        contents: &[u8],
    ) -> Result<(), MachineProviderError> {
        let req = self.client.put(self.file_url(machine, path)?).body(contents.to_vec());
        self.send(MachineOperation::FsWrite, req).await.map(drop)
    }

    async fn exec(
        &self,
        machine: &MachineHandle,
        request: ExecRequest,
    ) -> Result<ExecOutput, MachineProviderError> {
        let body = json!({
            "program": request.program,
            "args": request.args,
            "env": request.env.into_iter().collect::<BTreeMap<_, _>>(),
            "cwd": request.cwd,
            "stdin": B64.encode(&request.stdin),
        });
        let v = self
            .json(
                MachineOperation::Exec,
                self.client.post(self.url(&format!("/v1/machines/{}/exec", machine.0))).json(&body),
            )
            .await?;
        Ok(ExecOutput {
            exit_code: v
                .get("exit_code")
                .and_then(Value::as_i64)
                .and_then(|c| i32::try_from(c).ok())
                .unwrap_or(-1),
            stdout: b64(&v, "stdout")?,
            stderr: b64(&v, "stderr")?,
        })
    }

    async fn exposed_ports(
        &self,
        machine: &MachineHandle,
    ) -> Result<Vec<ExposedPort>, MachineProviderError> {
        let v = self
            .json(
                MachineOperation::ExposedPorts,
                self.client.get(self.url(&format!("/v1/machines/{}/ports", machine.0))),
            )
            .await?;
        let ports = v.get("ports").and_then(Value::as_array).cloned().unwrap_or_default();
        Ok(ports
            .iter()
            .filter_map(|p| {
                Some(ExposedPort {
                    port: u16::try_from(p["port"].as_u64()?).ok()?,
                    protocol: if p["protocol"] == "udp" {
                        PortProtocol::Udp
                    } else {
                        PortProtocol::Tcp
                    },
                    url: p["url"].as_str().map(str::to_owned),
                })
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_pick_egress_and_size() {
        let mut spec = CreateMachineSpec {
            name: "a".into(),
            image: Some("img".into()),
            labels: BTreeMap::new(),
        };
        assert_eq!(spec_body(&spec, true)["egress"]["mode"], "none");
        assert_eq!(spec_body(&spec, true)["image"], "img");
        assert!(spec_body(&spec, false).get("image").is_none());
        spec.labels.insert("cmux.vmd/egress".into(), "internet".into());
        spec.labels.insert("cmux.vmd/vcpus".into(), "4".into());
        let b = spec_body(&spec, true);
        assert_eq!(b["egress"]["mode"], "internet");
        assert_eq!(b["vcpus"], 4);
    }

    #[test]
    fn error_codes_map_to_trait_errors() {
        let e = map_error(
            MachineOperation::Delete,
            "m1",
            404,
            &json!({"error": {"code": "machine_not_found", "message": "x"}}),
        );
        assert!(
            matches!(e, MachineProviderError::MachineNotFound(MachineHandle(ref id)) if id == "m1")
        );
        let url = reqwest::Url::parse("http://h:1/v1/snapshots/s9/fork").unwrap();
        assert_eq!(subject_id(&url), "s9");
        let e = map_error(
            MachineOperation::Exec,
            "m1",
            409,
            &json!({"error": {"code": "invalid_state", "message": "cannot exec on a paused machine"}}),
        );
        assert!(matches!(e, MachineProviderError::InvalidState { .. }));
        let e = map_error(MachineOperation::Create, "", 500, &Value::Null);
        assert!(matches!(e, MachineProviderError::Backend(_)));
    }
}

#[cfg(test)]
mod seeded_tests {
    use super::*;

    /// tests/egress_seeded.json names this for the `cmux_vmd::provider` gate site: the host's
    /// bearer rides only in `Authorization`, on each call to the named host.
    #[tokio::test]
    async fn the_host_token_rides_only_in_authorization() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        cmux_egress::capture::install().unwrap();
        let token = "SEEDvmdHostToken-8e3c";
        // Not a reserved name (`.example` is local to the gate, so capture would not see it).
        let vmd = VmdProvider::new("https://vmd.seeded-host.dev", token).unwrap();
        let machine = MachineHandle("m-seeded".into());
        let _ = vmd.pause(&machine).await;
        let _ = vmd.delete(&machine).await;
        let mut places = cmux_egress::capture::leaks(token);
        places.sort();
        assert_eq!(
            places,
            [
                "vmd.seeded-host.dev DELETE /v1/machines/m-seeded: header authorization",
                "vmd.seeded-host.dev POST /v1/machines/m-seeded/pause: header authorization",
            ]
        );
    }
}
