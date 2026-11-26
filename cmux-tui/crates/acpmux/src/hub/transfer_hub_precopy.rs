//! Part of `Hub`; see `hub/mod.rs`. Pre-copy (`transfer_precopy.rs`) for a chat moved through the
//! team hub (`transfer_pull.rs`), so the freeze moves only the log's tail over the circuit.
//!
//! 1. The client asks its source daemon `_acpmux/transfer_hub {sessionId, stage: {daemon}}`
//!    ([`Hub::transfer_hub_stage`]): the source runs `transfer_prepare`, notes the target in the
//!    prepare's `to-hub` (so only that machine may read its pages) and sends mesh control op
//!    `move` with body `{version: 1, sessionId, stage: {manifest}}`, `manifest` the prepare's
//!    answer. It answers `{prepareId, afterSeq, stageId}`; with `prepare` in place of `stage`,
//!    only the prepare, noted, is made (no message goes out).
//! 2. On the target the control hook admits it as it admits a `move`, and
//!    [`Hub::transfer_pull_op`] runs [`Hub::transfer_pull_stage`] as a local actor: the stage
//!    (`transfer_stage`), the prepare's pages read from the source through the same circuit as a
//!    move's, `transfer_stage_finish`. Its answer is the `stageId`.
//! 3. The client begins with `prepareId`/`afterSeq` and sends `move` with the `stageId`; the
//!    target imports on top of the stage. A `transfer.unstaged` refusal is for the client to
//!    redo in full.
//!
//! A target that is too old to stage refuses the body (it has no `manifest`): no pre-copy, and
//! the move is whole. A hub move is guarded (`peer` control, this daemon's roots), so the staged
//! prefix goes through the guard's per-record rewrite as it is staged (`control` file of the
//! stage, `guarded_record`), and only a receive under that same control takes it.
//! TODO: a chat coming back does not send only the delta (`transfer_base`) over the hub: a
//! guarded stage rewrites every line, so the target's own copy cannot stand in for a base.

use super::transfer_guard::Guard;
use super::transfer_out::transfer_precopy::PREFIX_SCHEMA;
use super::transfer_out::{inside, transfers_dir};
use super::transfer_pull::{plain_daemon, pull_error};
use super::*;

/// How long the source waits for the target to stage a prefix.
const STAGE_WAIT: std::time::Duration = std::time::Duration::from_secs(120);

/// The file in a stage's folder naming the control its records were rewritten for.
pub(super) const CONTROL_FILE: &str = "control";

impl Hub {
    /// `_acpmux/transfer_hub` with `stage` or `prepare` ([module docs](self)).
    pub(super) async fn transfer_hub_stage(
        self: &Arc<Self>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let staging = params.get("stage").filter(|s| s.is_object());
        let named = staging.or_else(|| params.get("prepare")).filter(|s| s.is_object());
        let daemon = named.and_then(|s| s["daemon"].as_str()).unwrap_or("");
        if !plain_daemon(daemon) {
            return Err(RpcError::invalid_params("transfer: a stage names a hub `daemon`"));
        }
        let session =
            self.resolve(params.get("sessionId").and_then(Value::as_str).unwrap_or(""))?;
        let prepared = self.transfer_prepare(&session, None, None)?;
        let prepare_id = field(&prepared, "prepareId").as_str().unwrap_or_default().to_owned();
        let root = inside(&transfers_dir(), &prepare_id)?;
        let noted = crate::home_fs::write(root.join(super::transfer_pull::TO_HUB), daemon);
        if let Err(e) = noted {
            let _ = crate::home_fs::remove_dir_all(&root);
            return Err(RpcError::internal(format!("transfer: prepare: {e}")));
        }
        if staging.is_none() {
            return Ok(prepared);
        }
        let staged = self.send_stage(daemon, &session.id, &prepared).await;
        if staged.is_err() {
            let _ = crate::home_fs::remove_dir_all(&root);
        }
        let stage_id = staged?;
        Ok(json!({"prepareId": prepare_id, "afterSeq": field(&prepared, "afterSeq"),
                  "stageId": stage_id}))
    }

    /// Op `move` with a `stage` to `daemon`, and the `stageId` it answers.
    async fn send_stage(
        &self,
        daemon: &str,
        session_id: &str,
        prepared: &Value,
    ) -> Result<String, RpcError> {
        let body = json!({"version": 1, "sessionId": session_id, "stage": {"manifest": prepared}});
        if body.to_string().len() > 64 * 1024 {
            return Err(pull_error("size", "the prefix's manifest does not fit one hub message"));
        }
        let op = crate::mesh_relay_config::MOVE_OP;
        let key = format!("stage-{}", prepared["prepareId"].as_str().unwrap_or_default());
        match self.hub_control(daemon, op, body, key, STAGE_WAIT).await? {
            Ok(result) => result
                .and_then(|r| serde_json::from_str::<Value>(&r).ok())
                .and_then(|r| field(&r, "stageId").as_str().map(str::to_owned))
                .ok_or_else(|| pull_error("stage", "the target answered no stageId")),
            Err(why) => Err(pull_error("stage_refused", why)),
        }
    }

    /// Op `move`, as the control hook runs it: a move, or a `stage` of one's prefix.
    pub async fn transfer_pull_op(
        self: &Arc<Self>,
        source: &str,
        source_host: Option<&str>,
        body: &Value,
    ) -> Result<Value, RpcError> {
        if body.get("stage").is_some() {
            return self.transfer_pull_stage(source, body).await;
        }
        self.transfer_pull(source, source_host, body).await
    }

    /// A prefix staged here from `source`'s prepare: staged under a guard this daemon builds,
    /// its pages read over the circuit. Answers `{stageId, afterSeq, records}`.
    async fn transfer_pull_stage(
        self: &Arc<Self>,
        source: &str,
        body: &Value,
    ) -> Result<Value, RpcError> {
        let manifest = field(field(body, "stage"), "manifest").clone();
        let prepare_id = field(&manifest, "prepareId").as_str().unwrap_or("");
        let session_id = field(&manifest, "sessionId").as_str().unwrap_or("");
        if *field(&manifest, "schema") != PREFIX_SCHEMA
            || !prepare_id.starts_with("pre-")
            || !super::transfer::is_plain_id(prepare_id)
            || !super::transfer::is_plain_id(session_id)
            || session_id != body["sessionId"].as_str().unwrap_or("")
            || manifest.get("base").is_some_and(|b| !b.is_null())
        {
            return Err(RpcError::invalid_params("move: the stage names no plain prefix"));
        }
        if !plain_daemon(source) {
            return Err(pull_error("source", "the message names no source daemon"));
        }
        let roots = self.config.read().await.web_roots.clone();
        if roots.is_empty() {
            return Err(pull_error(
                "no_roots",
                "this machine names no webRoots, so no moved chat may work here",
            ));
        }
        let guard = Guard::parse(&json!({"control": "peer", "roots": roots})).await?;
        let dial = self.transfer_dial().ok_or_else(|| {
            pull_error("no_route", "this daemon has no hub carrier to the source")
        })?;
        let mut pages = dial.open(source).await.map_err(|e| pull_error("unreachable", e))?;
        let staged = self.transfer_stage(&json!({"manifest": manifest}))?;
        let stage_id = field(&staged, "stageId").as_str().unwrap_or_default().to_owned();
        let dir = inside(&transfers_dir(), &format!("in-{stage_id}"))?;
        let filled = async {
            crate::home_fs::write(dir.join(CONTROL_FILE), guard.control.as_str())
                .map_err(|e| RpcError::internal(format!("transfer: stage: {e}")))?;
            self.pull_files(&mut *pages, &manifest, prepare_id, &json!(stage_id), None).await?;
            self.transfer_stage_finish(&json!({"stageId": stage_id}))
        }
        .await;
        if filled.is_err() {
            let _ = crate::home_fs::remove_dir_all(&dir);
        }
        filled
    }
}

/// The control a stage's records were rewritten for, as its folder notes it.
pub(super) fn stage_control(dir: &Path) -> Option<Control> {
    let text = std::fs::read_to_string(dir.join(CONTROL_FILE)).ok()?;
    [Control::Peer, Control::Web].into_iter().find(|c| c.as_str() == text.trim())
}

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}
