//! Part of `Hub`; see `hub/mod.rs`. A chat moved between two of the person's machines that reach
//! each other only through the team hub (lane VMs have no ssh to each other). Leo, 2026-11-20:
//! "we have the notion of being able to move your local chats into cloud and then back to you or
//! into any remote machine back and forth, just with no loss in correctness, no like pausing or
//! whatever of agents". The move is `transfer_out.rs`'s, with the target pulling:
//!
//! 1. The source's client begins the move with `to: {hub: <target daemonId>, host}`; the source
//!    records the target in the move's `to-hub` file.
//! 2. The client asks the source (`_acpmux/transfer_hub`, [`Hub::transfer_hub`]) to send mesh
//!    control op `move` to that daemon: `{version: 1, transferId, sessionId, manifest, folder,
//!    branch?, commit?}`, `folder` one of `{cwd}`, `{home: <path under the home folder>}` or
//!    `{repo, url, branch, subdir}` (made as `session move` makes it over ssh).
//! 3. On the target the control hook (`server/mesh_relay.rs`) admits the op only from a sender the
//!    hub stamped with this machine's own person and only when `meshRelay.controlFrom` lists
//!    `move` (`mesh_relay_config.rs`): off by default. [`Hub::transfer_pull`] then runs as a local
//!    actor: it builds the guard itself, never from the message (`peer` control, this daemon's
//!    `webRoots`), makes or checks the folder under those roots, reads the bundle's pages from the
//!    source through a [`TransferDial`] (the hub carrier's `TransferSource` circuit,
//!    `transfer_service.rs`), and receives, writes and finishes it in process. Its answer is the
//!    control's result: `{sessionId, cwd, branch?, commit?, timings}`, `timings` the freeze's split
//!    on this side (`dialMs`, `pages`, `pageBytes`, `pagesMs`, `finishMs`, `via`). A repeat of a move that
//!    landed answers the same chat and folder without a second import (and no `timings`).
//!    A pre-copied move (`transfer_hub_precopy.rs`) stages the history here before the freeze, and
//!    its `move` names the `stageId`; its control goes over the stage's circuit when the target
//!    parked it (`transfer_park.rs`), else as op `move`.
//! 4. The client commits the move on the source with `movedTo {host, via: "hub", ...}`, or aborts
//!    it on a refusal. A move whose client goes away is ended by the source's watch, which asks
//!    the target with op `move_forget` (`transfer_watch.rs`).
//!
//! The source serves pages only to the machine its move names ([`Hub::transfer_source_page`]):
//! the Noise-proven key of the circuit must equal `to-hub`.
//!
//! A manifest of any size: one hub message holds 64 KiB ([`MAX_BODY`]), and a long chat's
//! manifest is more (a 56-turn lane, 2026-11-24, refused `transfer.size`). A body that fits goes
//! as version 1, as before, so an old target takes it unchanged. One that does not goes as
//! version 2 ([`MANIFEST_PULL_WIRE_VERSION`]): the source writes the manifest into the move's folder
//! ([`MANIFEST_FILE`]) and the body names it by `manifestPull: {transferId, bytes, sha256}`; the
//! target reads it over the same circuit as the pages (method `manifest`, [`pull_manifest`]),
//! checks its size and hash, and goes on as with one sent inline. The precopy's `stage` does the
//! same (`transfer_hub_precopy.rs`). An old target refuses version 2 with
//! [`OLD_VERSION_REFUSAL`]; the source turns that into `transfer.target_too_old` (refused, so
//! the client gives the chat back at once).

use super::transfer_guard::Guard;
use super::transfer_out::{inside, transfers_dir};
use super::*;
use cmux_json::JsonSet as _;
use futures::future::BoxFuture;

/// The file in a move's directory naming the target daemon of a hub move.
pub(super) const TO_HUB: &str = "to-hub";
/// The page a pull asks for: its base64 fits a circuit frame ([`MAX_FRAME`]) with room.
const PULL_PAGE: u64 = 1 << 20;
/// The largest frame of the `TransferSource` circuit, either way.
pub const MAX_FRAME: usize = 4 << 20;
/// How long the source waits for the target's answer to a `move`. The target's hook answers
/// within its own wait, or the hub leases the message again and the ledger answers the repeat.
const MOVE_WAIT: std::time::Duration = std::time::Duration::from_secs(600);

/// The largest control body one hub message carries (`server/mesh_relay.rs` refuses more).
pub const MAX_BODY: usize = 64 * 1024;
/// The control body version of a `move` (or `stage`) whose manifest the target pulls.
pub const MANIFEST_PULL_WIRE_VERSION: u64 = 2;
/// What the control hook answers a body version it does not take: an old build's words exactly,
/// which the source reads as "this target pulls no manifest" ([`too_old`]).
pub const OLD_VERSION_REFUSAL: &str = "unsupported control body version";
/// The file in a move's (or a prepare's) folder holding the manifest a target pulls.
pub(super) const MANIFEST_FILE: &str = "hub-manifest.json";
/// The most bytes a pulled manifest may hold, on either side.
pub const MAX_PULLED_MANIFEST: u64 = 64 << 20;
/// One `manifest` page: its base64 fits a circuit frame ([`MAX_FRAME`]) with room.
const MANIFEST_PAGE: u64 = 1 << 20;

/// How long one hub receipt read waits.
const ANSWER_WAIT: std::time::Duration = std::time::Duration::from_secs(25);
/// How long the source's watch waits for a `move_forget` answer.
const FORGET_WAIT: std::time::Duration = std::time::Duration::from_secs(30);
/// How long a move's answer waits for the heartbeat that lists the chat it moved here.
// timeout: past this the move answers unlisted (the next timed heartbeat lists it); a move never
// fails on it.
const MOVED_LISTED_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

pub(super) fn pull_error(what: &str, message: impl std::fmt::Display) -> RpcError {
    RpcError::new(-32000, format!("transfer.{what}: {message}"))
}

/// The target's refusal of a move, in its words: the client gives the chat back.
pub(super) fn refused(why: &str) -> RpcError {
    pull_error("refused", format!("the target refused the move: {why}"))
        .with_data(json!({"refused": true, "detail": why}))
}

/// No answer from `daemon` to its `op`: the move stays frozen, its watch ends it.
pub(super) fn unanswered(daemon: &str, op: &str) -> RpcError {
    pull_error("unanswered", format!("{daemon} did not answer the {op} in time"))
        .with_data(json!({"reason": "mesh.move_unanswered", "unknown": true}))
}

/// The `manifestPull` reference of a manifest written to `dir` for transfer `transfer_id`: the
/// file the target reads with method `manifest`.
pub(super) fn write_pulled_manifest(
    dir: &Path,
    transfer_id: &str,
    manifest: &Value,
) -> Result<Value, RpcError> {
    let text = manifest.to_string();
    if text.len() as u64 > MAX_PULLED_MANIFEST {
        return Err(pull_error(
            "size",
            format!(
                "the move's manifest is {} MiB, over its {} MiB bound",
                text.len() >> 20,
                MAX_PULLED_MANIFEST >> 20
            ),
        )
        .with_data(json!({"refused": true, "reason": "transfer.size"})));
    }
    crate::home_fs::write(dir.join(MANIFEST_FILE), &text)
        .map_err(|e| RpcError::internal(format!("transfer: manifest: {e}")))?;
    Ok(json!({"transferId": transfer_id, "bytes": text.len(),
              "sha256": crate::sha256::sha256_hex(text.as_bytes())}))
}

/// The error a source gives for a target that refused a version-2 body (`why`, its refusal):
/// `Some` when the target is too old to pull a manifest, `None` for any other refusal.
pub(super) fn too_old(why: &str, host: &str, body_bytes: usize) -> Option<RpcError> {
    (why.trim() == OLD_VERSION_REFUSAL).then(|| {
        pull_error(
            "target_too_old",
            format!(
                "the target's acpmux is too old to take a move manifest over 64 KiB ({} KiB); \
                 update it (`acpmux machine update {host}`) or move a smaller chat",
                body_bytes.div_ceil(1024)
            ),
        )
        .with_data(json!({"refused": true, "reason": "transfer.target_too_old", "detail": why}))
    })
}

/// The manifest `pull` (`{transferId, bytes, sha256}`) names, read page by page from the source
/// and checked against its size and hash.
pub(super) async fn pull_manifest(
    pages: &mut dyn PageSource,
    pull: &Value,
) -> Result<Value, RpcError> {
    use base64::Engine as _;
    let transfer_id = field(pull, "transferId").as_str().unwrap_or("");
    let bytes = field(pull, "bytes").as_u64().unwrap_or(0);
    let sha = field(pull, "sha256").as_str().unwrap_or("");
    if !super::transfer::is_plain_id(transfer_id) || bytes == 0 || sha.len() != 64 {
        return Err(RpcError::invalid_params("move: `manifestPull` names no manifest"));
    }
    if bytes > MAX_PULLED_MANIFEST {
        return Err(pull_error("size", format!("a manifest of {bytes} bytes is over its bound")));
    }
    let mut data = Vec::with_capacity(bytes as usize);
    while (data.len() as u64) < bytes {
        let offset = data.len() as u64;
        let page = pages
            .call(
                "manifest",
                json!({"transferId": transfer_id, "offset": offset,
                                      "limit": MANIFEST_PAGE}),
            )
            .await?;
        let chunk = base64::engine::general_purpose::STANDARD
            .decode(field(&page, "data").as_str().unwrap_or(""))
            .map_err(|e| pull_error("manifest", format!("a page is not base64: {e}")))?;
        if chunk.is_empty() || offset + chunk.len() as u64 > bytes {
            return Err(pull_error("manifest", "the source's manifest is not the size it named"));
        }
        data.extend_from_slice(&chunk);
    }
    if crate::sha256::sha256_hex(&data) != sha {
        return Err(pull_error("manifest", "the pulled manifest does not match its sha256"));
    }
    serde_json::from_slice(&data)
        .map_err(|e| pull_error("manifest", format!("the pulled manifest is not JSON: {e}")))
}

/// One `manifest` page of the move (or prepare) folder `dir` (method `manifest` of the circuit).
fn manifest_page(dir: &Path, params: &Value) -> Result<Value, RpcError> {
    use base64::Engine as _;
    let text = std::fs::read(dir.join(MANIFEST_FILE))
        .map_err(|_| pull_error("unknown", "this move sent its manifest inline"))?;
    let offset = field(params, "offset").as_u64().unwrap_or(0);
    let limit = field(params, "limit").as_u64().unwrap_or(MANIFEST_PAGE).clamp(1, MANIFEST_PAGE);
    let start = (offset.min(text.len() as u64)) as usize;
    let end = (offset.saturating_add(limit).min(text.len() as u64)) as usize;
    Ok(json!({"data": base64::engine::general_purpose::STANDARD.encode(&text[start..end]),
              "next": end, "eof": end == text.len(), "bytes": text.len()}))
}

/// The hub's code for a message to a machine whose credential it revoked with no newer one
/// since: the machine was deleted (or removed from the team) and will never answer as that
/// machine again. Not `machine.revoked`, which is the hub refusing this daemon's own credential.
pub const RECIPIENT_REVOKED: &str = "mesh.recipient_revoked";

/// Whether `hub_control`'s error is the hub refusing the message because its target machine is
/// gone for good, not merely offline (an offline or paused machine is `mesh.unknown_recipient`).
pub(super) fn target_deleted(e: &RpcError) -> bool {
    e.data
        .as_ref()
        .and_then(|d| d.get("code"))
        .and_then(Value::as_str)
        .is_some_and(|code| code == RECIPIENT_REVOKED)
}

/// One connection to a move's source: `read` and `renew` of `_acpmux/transfer_*`, answered.
pub trait PageSource: Send {
    fn call<'a>(
        &'a mut self,
        method: &'a str,
        params: Value,
    ) -> BoxFuture<'a, Result<Value, RpcError>>;
}

/// How this daemon reaches the source of a hub move, by the source's hub `daemonId`.
pub trait TransferDial: Send + Sync {
    fn open<'a>(&'a self, daemon: &'a str) -> BoxFuture<'a, Result<Box<dyn PageSource>, String>>;
}

/// A daemon id as the hub stamps it: base64 of a 32-byte key, or the hub's plain id.
pub(super) fn plain_daemon(id: &str) -> bool {
    (8..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"+/=_-".contains(&b))
}

/// A path relative to the home folder: plain parts only.
fn plain_relative(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && crate::cli::hosts::plain_path(&format!("/{path}"))
        && Path::new(path).components().all(|c| matches!(c, std::path::Component::Normal(_)))
}

/// The folder a `move` names, checked before anything is made of it.
fn named_folder(
    folder: &serde_json::Map<String, Value>,
) -> Result<crate::cli::session_move_plan::Folder, RpcError> {
    use crate::cli::session_move_plan::Folder;
    let text = |k: &str| folder.get(k).and_then(Value::as_str).unwrap_or("");
    let bad = |m: &str| RpcError::invalid_params(format!("move: folder {m}"));
    if folder.contains_key("home") {
        // Empty names the home folder itself (a chat started in `~` on the source): it maps to
        // this machine's home, never outside it. Whether the chat may work there is the guard's
        // call (`Guard::hub_move`: only a machine that is its own VM boundary takes home).
        let rel = text("home");
        if !rel.is_empty() && !plain_relative(rel) {
            return Err(bad("`home` must be a plain path under the home folder"));
        }
        let home = dirs::home_dir().ok_or_else(|| bad("needs a home folder here"))?;
        let cwd = if rel.is_empty() { home } else { home.join(rel) };
        return Ok(Folder::Plain { cwd: cwd.to_string_lossy().into_owned() });
    }
    let (repo, url, branch, subdir) = (text("repo"), text("url"), text("branch"), text("subdir"));
    let mut parts = repo.split('/');
    let repo_ok = repo.len() <= 200
        && parts.clone().count() == 2
        && parts.all(|p| {
            !p.is_empty()
                && !p.starts_with('.')
                && p.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        });
    if !repo_ok {
        return Err(bad("`repo` must be owner/name"));
    }
    let url_ok = url.len() <= 400
        && (url.starts_with("https://") || url.starts_with("ssh://") || url.starts_with("git@"))
        && url.bytes().all(|b| b.is_ascii_graphic());
    if !url_ok {
        return Err(bad("`url` must be an https or ssh git remote"));
    }
    if branch.starts_with('-') || !crate::cli::hosts::plain_path(&format!("/{branch}")) {
        return Err(bad("`branch` is not a plain branch name"));
    }
    if !subdir.is_empty() && !plain_relative(subdir) {
        return Err(bad("`subdir` must be a plain path in the checkout"));
    }
    Ok(Folder::Worktree {
        repo: repo.to_owned(),
        url: url.to_owned(),
        branch: branch.to_owned(),
        subdir: subdir.to_owned(),
        dirty: false,
        snapshot: false,
    })
}

impl Hub {
    /// How a hub move reaches its source: the hub carrier's circuit, or a test's stand-in.
    pub fn set_transfer_dial(&self, dial: Arc<dyn TransferDial>) {
        *self.transfer_dial.lock().unwrap_or_else(|e| e.into_inner()) = Some(dial);
    }

    pub(super) fn transfer_dial(&self) -> Option<Arc<dyn TransferDial>> {
        self.transfer_dial.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The chat `session_id` when move `transfer_id` landed here already, as a pull answers it.
    fn pulled(&self, session_id: &str, transfer_id: &str) -> Option<Value> {
        let session = self.session_get(session_id)?;
        if self.moved_away(&session) {
            return None;
        }
        let mut landed = false;
        // Its `transferred_in` records, from the kind index, not a parse of the whole log.
        let _ = self.store.scan_kinds(&session.id, &["transferred_in"], &mut |e: EventRecord| {
            landed |= e.kind == "transferred_in" && *field(&e.msg, "transferId") == transfer_id;
            !landed
        });
        landed.then(|| json!({"sessionId": session.id, "cwd": session.meta().cwd}))
    }

    /// The guard of a hub move landing here: this daemon's `webRoots`, and the home folder too
    /// when this machine takes a caller's VM boundary (`vm_boundary.rs`: Linux, `vmHost` not
    /// turned off; never a Mac). Op `move` comes only from the person's own daemons and only
    /// where `meshRelay.controlFrom` lists it, so on a dedicated agent VM the person's own chat
    /// may land in that VM's home, as a fleet placer moving idle chats off a full host needs:
    /// a chat that ran in `~` or under `~/.local/state` there. Refused when it names neither.
    pub(super) async fn hub_move_guard(&self) -> Result<Guard, RpcError> {
        let roots = self.config.read().await.web_roots.clone();
        let home = self.takes_vm_boundary().await;
        if roots.is_empty() && !home {
            return Err(pull_error(
                "no_roots",
                "this machine names no webRoots and is not a VM host, so no moved chat may work here",
            ));
        }
        Guard::hub_move(&roots, home).await
    }

    /// The folder the moved chat runs in here: named outright, or made as `session move` makes
    /// it, and in either case under one of the guard's roots.
    async fn pull_folder(&self, guard: &Guard, folder: Option<&Value>) -> Result<String, RpcError> {
        let folder = folder
            .and_then(Value::as_object)
            .ok_or_else(|| RpcError::invalid_params("move: `folder` is required"))?;
        let path = match folder.get("cwd").and_then(Value::as_str) {
            Some(cwd) => cwd.to_owned(),
            None => {
                let made = named_folder(folder)?;
                tokio::task::spawn_blocking(move || {
                    crate::cli::run::session_move::prepare_folder_here(&made)
                })
                .await
                .map_err(|e| RpcError::internal(format!("move: folder: {e}")))?
                .map_err(|e| pull_error("folder", format!("{e:#}")))?
            }
        };
        match guard.folder(&path).await {
            Some(canonical) => Ok(canonical.to_string_lossy().into_owned()),
            None => Err(pull_error("cwd", format!("{path:?} is not a folder under webRoots here"))),
        }
    }

    /// Op `move` on this daemon: the chat of `body`'s move pulled here from `source` (the hub
    /// `daemonId` the hub stamped on the message; `source_host` its host), imported under a
    /// guard this daemon builds. Answers `{sessionId, cwd, branch?, commit?}`.
    pub async fn transfer_pull(
        self: &Arc<Self>,
        source: &str,
        source_host: Option<&str>,
        body: &Value,
    ) -> Result<Value, RpcError> {
        self.transfer_pull_on(source, source_host, body, None).await
    }

    /// [`Self::transfer_pull`] over `circuit`, a circuit to `source` already open (a stage's,
    /// parked for its move, `transfer_park.rs`), or over one it dials when None.
    pub(super) async fn transfer_pull_on(
        self: &Arc<Self>,
        source: &str,
        source_host: Option<&str>,
        body: &Value,
        circuit: Option<&mut dyn PageSource>,
    ) -> Result<Value, RpcError> {
        let text = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("");
        // Inline (version 1), or pulled from the source once the circuit is open (version 2).
        let pull = body.get("manifestPull").filter(|p| p.is_object());
        let inline = body.get("manifest").filter(|m| m.is_object());
        if pull.is_none() && inline.is_none() {
            return Err(RpcError::invalid_params("move: `manifest` is required"));
        }
        let (transfer_id, session_id) = (text("transferId"), text("sessionId"));
        let names_this_move = |manifest: &Value| {
            let named = |k: &str| manifest.get(k).and_then(Value::as_str).unwrap_or("");
            super::transfer::is_plain_id(transfer_id)
                && super::transfer::is_plain_id(session_id)
                && named("transferId") == transfer_id
                && named("sessionId") == session_id
                && !transfer_id.to_ascii_lowercase().starts_with("in-")
        };
        let other_move = || RpcError::invalid_params("move: the manifest names another move");
        let ids = json!({"transferId": transfer_id, "sessionId": session_id});
        let named = match (inline, pull) {
            (Some(manifest), _) => names_this_move(manifest),
            (None, pull) => pull.is_some_and(|p| field(p, "transferId") == transfer_id),
        };
        if !named || !names_this_move(&ids) {
            return Err(other_move());
        }
        if !plain_daemon(source) {
            return Err(pull_error("source", "the message names no source daemon"));
        }
        let answer = |mut moved: Value| {
            for key in ["branch", "commit"] {
                if let Some(v) = body.get(key).and_then(Value::as_str) {
                    moved.set(key, json!(v));
                }
            }
            moved
        };
        // A repeat of a move that landed (a lost ack, a redelivery the ledger did not keep).
        if let Some(moved) = self.pulled(session_id, transfer_id) {
            return Ok(answer(moved));
        }
        // Built here, from this daemon's own config: the message names no rule.
        let guard = self.hub_move_guard().await?;
        let cwd = self.pull_folder(&guard, body.get("folder")).await?;
        // The freeze's split, in the answer: the circuit's open (relay and handshake; none for
        // a parked one), the pages (one round trip each) and the import.
        let mut dialed: Box<dyn PageSource>;
        let (pages, dial_ms, via): (&mut dyn PageSource, u64, &str) = match circuit {
            Some(circuit) => (circuit, 0, "circuit"),
            None => {
                let dial = self.transfer_dial().ok_or_else(|| {
                    pull_error("no_route", "this daemon has no hub carrier to the source")
                })?;
                let dialing = std::time::Instant::now();
                dialed = dial.open(source).await.map_err(|e| pull_error("unreachable", e))?;
                (&mut *dialed, dialing.elapsed().as_millis() as u64, "hub")
            }
        };
        let paging = std::time::Instant::now();
        let manifest = match (inline, pull) {
            (Some(manifest), _) => manifest.clone(),
            (None, Some(pull)) => pull_manifest(&mut *pages, pull).await?,
            (None, None) => return Err(other_move()),
        };
        if !names_this_move(&manifest) {
            return Err(other_move());
        }
        let manifest = &manifest;
        let epoch = manifest.get("epoch").and_then(Value::as_u64).unwrap_or(0);
        // Op `move` comes only from this person's own daemons (`sameUser`,
        // `mesh_relay_config.rs`), so the chat keeps the origin it had there: their own chat
        // stays theirs, and its local prompts here are owner prompts.
        let received = self
            .receive_guarded(
                &json!({"manifest": manifest, "stageId": body.get("stageId")}),
                Some(guard),
            )
            .await?;
        let receive_id = received.get("receiveId").cloned().unwrap_or(Value::Null);
        let (page_count, page_bytes) =
            self.pull_files(&mut *pages, manifest, transfer_id, &receive_id, Some(epoch)).await?;
        let mut from = json!({"sessionId": session_id, "via": "hub", "daemonId": source});
        if let Some(host) = source_host.filter(|h| !h.is_empty()) {
            from.set("host", json!(host));
        }
        let pages_ms = paging.elapsed().as_millis() as u64;
        let finish = json!({"receiveId": receive_id, "from": from, "epoch": epoch, "cwd": cwd});
        let finishing = std::time::Instant::now();
        let moved = self.transfer_finish(&finish).await?;
        let finish_ms = finishing.elapsed().as_millis() as u64;
        // Listed in the hub's address book before the source hears the move landed, so
        // `HOST/NAME` resolves on the source the moment its move ends (no 30 s heartbeat lag).
        let listing = std::time::Instant::now();
        let listed = self.list_on_mesh_now(MOVED_LISTED_WAIT).await;
        let listed_ms = listing.elapsed().as_millis() as u64;
        let mut moved =
            json!({"sessionId": moved.get("sessionId").cloned().unwrap_or(json!(session_id))});
        moved.set("cwd", json!(cwd));
        moved.set(
            "timings",
            json!({"dialMs": dial_ms, "pages": page_count, "pageBytes": page_bytes,
                   "pagesMs": pages_ms, "finishMs": finish_ms, "via": via,
                   "listedMs": listed.then_some(listed_ms)}),
        );
        Ok(answer(moved))
    }

    /// A mesh heartbeat now, listing this daemon's sessions, waited for at most `within`:
    /// false when no mesh relay runs here. The hub routes `HOST/NAME` only to a session a
    /// heartbeat listed (`mesh.unknown_recipient` otherwise), so a chat moved in through it is
    /// listed before the move answers, as a start through it is (`server/mesh_relay.rs`).
    pub(crate) async fn list_on_mesh_now(&self, within: std::time::Duration) -> bool {
        let beat = self.mesh_beat.lock().unwrap_or_else(|e| e.into_inner()).upgrade();
        let Some(beat) = beat else { return false };
        beat.now(within).await;
        true
    }

    /// Every file `manifest` lists, read page by page from the source's `transfer_id` and
    /// written into the receive `receive_id` here; the pages and their base64 bytes.
    pub(super) async fn pull_files(
        &self,
        pages: &mut dyn PageSource,
        manifest: &Value,
        transfer_id: &str,
        receive_id: &Value,
        epoch: Option<u64>,
    ) -> Result<(u64, u64), RpcError> {
        let (mut page_count, mut page_bytes) = (0u64, 0u64);
        for file in manifest["files"].as_array().into_iter().flatten() {
            let path = file["path"].clone();
            let mut offset = 0u64;
            loop {
                let mut read = json!({"transferId": transfer_id, "path": path, "offset": offset,
                                      "limit": PULL_PAGE});
                if let Some(epoch) = epoch {
                    read.set("epoch", json!(epoch));
                }
                let page = pages.call("read", read).await?;
                page_count += 1;
                page_bytes += field(&page, "data").as_str().map_or(0, |d| d.len() as u64);
                let mut write = json!({"receiveId": receive_id, "path": path, "offset": offset,
                                       "data": field(&page, "data")});
                if let Some(epoch) = epoch {
                    write.set("epoch", json!(epoch));
                }
                self.transfer_write(&write)?;
                let next =
                    field(&page, "next").as_u64().ok_or_else(|| pull_error("read", "no next"))?;
                if next <= offset && *field(&page, "eof") != true {
                    return Err(pull_error("read", "the source's page did not move on"));
                }
                offset = next;
                if *field(&page, "eof") == true {
                    break;
                }
            }
        }
        Ok((page_count, page_bytes))
    }

    /// Op `move_forget`: the source's watch gave the move up. Any receive of it here is dropped
    /// and a later one refused; answers whether the chat landed here.
    pub async fn transfer_pull_forget(&self, body: &Value) -> Result<Value, RpcError> {
        let text = |k: &str| body.get(k).and_then(Value::as_str).unwrap_or("");
        self.transfer_forget(
            &json!({"transferId": text("transferId"), "sessionId": text("sessionId")}),
        )
        .await
    }

    /// A page request of the `TransferSource` circuit from the machine whose Noise-proven hub
    /// key is `from`: served only for a move whose `to-hub` names that machine, and only
    /// `read`, `renew` and `manifest` (a pulled manifest, [`pull_manifest`]).
    pub async fn transfer_source_page(
        self: &Arc<Self>,
        from: &str,
        m: &str,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let transfer_id = params.get("transferId").and_then(Value::as_str).unwrap_or("");
        if transfer_id.to_ascii_lowercase().starts_with("in-") {
            return Err(pull_error("unknown", format!("no move {transfer_id:?} here")));
        }
        let dir = inside(&transfers_dir(), transfer_id)?;
        let to = std::fs::read_to_string(dir.join(TO_HUB)).ok();
        if from.is_empty() || to.as_deref().map(str::trim) != Some(from) {
            return Err(pull_error("not_yours", "this move does not go to the machine that asks"));
        }
        match m {
            "read" | "renew" => {
                self.transfer_request(&format!("_acpmux/transfer_{m}"), params).await
            }
            "manifest" => manifest_page(&dir, params),
            _ => Err(RpcError::method_not_found(m)),
        }
    }

    /// One control message to the daemon `daemon` through the hub, and its answer: `Ok(Ok(result))`
    /// delivered, `Ok(Err(why))` refused, `Err` when it was not answered within `wait`.
    pub(super) async fn hub_control(
        &self,
        daemon: &str,
        op: &str,
        body: Value,
        key: String,
        wait: std::time::Duration,
    ) -> Result<Result<Option<String>, String>, RpcError> {
        use crate::mesh::{Kind, Mode, OutMessage, Sender, Target};
        let mesh = self
            .mesh
            .get()
            .ok_or_else(|| pull_error("no_hub", "this daemon is not joined to a team hub"))?;
        let message = OutMessage {
            to: Target { daemon_id: Some(daemon.to_owned()), ..Target::default() },
            from: Sender { host: Some(crate::pairing::machine_name()), ..Sender::default() },
            kind: Kind::Control,
            op: Some(op.to_owned()),
            body: body.to_string(),
            mode: Mode::Now,
            idempotency_key: key,
        };
        let hub_error = |e: crate::mesh::HubError| {
            pull_error("hub", e.message.clone()).with_data(json!({"code": e.code}))
        };
        let mut receipt = mesh.send(&message).await.map_err(hub_error)?;
        let started = tokio::time::Instant::now();
        loop {
            match receipt.state.as_str() {
                "delivered" => return Ok(Ok(receipt.result)),
                "refused" => {
                    return Ok(Err(receipt.detail.unwrap_or_else(|| "refused".into())));
                }
                "expired" => break,
                _ => {}
            }
            let left = wait.saturating_sub(started.elapsed());
            if left.is_zero() {
                break;
            }
            receipt =
                mesh.answer(&receipt.message_id, left.min(ANSWER_WAIT)).await.map_err(hub_error)?;
        }
        Err(unanswered(daemon, op))
    }

    /// The source's watch asks the hub target `daemon` to give the move up: whether the chat
    /// landed there, or that the hub knows the machine is gone (its credential revoked, so it
    /// can never answer); `Unknown` when it cannot say.
    pub(super) async fn ask_hub_forget(
        &self,
        daemon: &str,
        session_id: &str,
        transfer_id: &str,
    ) -> super::transfer_watch::TargetSays {
        use super::transfer_watch::TargetSays;
        let body = json!({"version": 1, "transferId": transfer_id, "sessionId": session_id});
        let key = format!("forget-{transfer_id}");
        let op = crate::mesh_relay_config::MOVE_FORGET_OP;
        match self.hub_control(daemon, op, body, key, FORGET_WAIT).await {
            Ok(Ok(Some(result))) => serde_json::from_str::<Value>(&result)
                .ok()
                .and_then(|v| v.get("landed").and_then(Value::as_bool))
                .map_or(TargetSays::Unknown, TargetSays::landed),
            Err(e) if target_deleted(&e) => TargetSays::Deleted,
            _ => TargetSays::Unknown,
        }
    }

    /// `_acpmux/transfer_hub` (the local socket only, as every `transfer_*`):
    /// - `{resolve: NAME}`: the person's other machine NAME (its host, or its hub `daemonId`) as
    ///   the hub book lists it: `{daemonId, host}`;
    /// - `{moveOut: DAEMON, sessionId, to, afterTurn?, interrupt?, timeoutSecs?}`: asks the
    ///   remote source daemon to run its own hub move, and waits for its move JSON row. `DAEMON`
    ///   is the source's hub-stamped id, so this local request never trusts a host or session
    ///   field as authority;
    /// - `{sessionId, transferId, epoch, manifest, folder, host?, branch?, commit?}`: sends op `move` for
    ///   that move, begun with `to.hub`, to the daemon it names, and waits for its answer:
    ///   `{moved: {sessionId, cwd, ...}}`. A refusal is an error with `data.refused`; no answer in
    ///   time is one with `data.unknown` (the move stays frozen; its watch ends it).
    pub(super) async fn transfer_hub(self: &Arc<Self>, params: &Value) -> Result<Value, RpcError> {
        let text = |k: &str| params.get(k).and_then(Value::as_str).unwrap_or("");
        if params.get("resolve").is_some() {
            return self.resolve_hub_machine(text("resolve")).await;
        }
        if params.get("stage").is_some() || params.get("prepare").is_some() {
            return self.transfer_hub_stage(params).await;
        }
        if params.get("moveOut").is_some() {
            return self.transfer_hub_move_out(params).await;
        }
        let transfer_id = text("transferId");
        let session = self.resolve(text("sessionId"))?;
        let dir = inside(&transfers_dir(), transfer_id)?;
        let Ok(daemon) = std::fs::read_to_string(dir.join(TO_HUB)) else {
            return Err(pull_error("unknown", "the move was not begun with `to.hub`"));
        };
        let daemon = daemon.trim().to_owned();
        if session.moving().as_deref() != Some(transfer_id) {
            return Err(pull_error("unknown", "the chat is not in this move"));
        }
        let mut body = json!({
            "version": 1,
            "transferId": transfer_id,
            "sessionId": session.id,
            "manifest": params.get("manifest").cloned().unwrap_or(Value::Null),
            "folder": params.get("folder").cloned().unwrap_or(Value::Null),
        });
        for key in ["branch", "commit", "stageId"] {
            if let Some(v) = params.get(key).and_then(Value::as_str) {
                body.set(key, json!(v));
            }
        }
        super::transfer_watch::note_activity(&dir, None);
        // A pre-copied move whose target parked its stage's circuit goes over that circuit, its
        // manifest inline up to a frame (`transfer_park.rs`); else over the hub.
        if let Some(stage_id) = params.get("stageId").and_then(Value::as_str)
            && body.to_string().len() <= MAX_FRAME / 2
            && let Some(answered) =
                self.move_over_circuit(&daemon, stage_id, body.clone(), MOVE_WAIT).await
        {
            return answered;
        }
        // A manifest past one hub message goes by reference: the target pulls it.
        let inline_bytes = body.to_string().len();
        let pulled = inline_bytes > MAX_BODY;
        if pulled {
            let manifest = body.get("manifest").cloned().unwrap_or(Value::Null);
            let reference = write_pulled_manifest(&dir, transfer_id, &manifest)?;
            if let Some(o) = body.as_object_mut() {
                o.remove("manifest");
            }
            body.set("manifestPull", reference);
            body.set("version", json!(MANIFEST_PULL_WIRE_VERSION));
            if body.to_string().len() > MAX_BODY {
                return Err(pull_error(
                    "size",
                    "the move's control body does not fit one hub message",
                )
                .with_data(json!({"refused": true, "reason": "transfer.size"})));
            }
        }
        let op = crate::mesh_relay_config::MOVE_OP;
        let key = format!("move-{transfer_id}");
        // The target's name for the too-old refusal: the client's, else its hub id.
        let host = Some(text("host")).filter(|h| !h.is_empty()).unwrap_or(&daemon).to_owned();
        match self.hub_control(&daemon, op, body, key, MOVE_WAIT).await? {
            Ok(result) => {
                let moved = result
                    .and_then(|r| serde_json::from_str::<Value>(&r).ok())
                    .unwrap_or(Value::Null);
                Ok(json!({"moved": moved, "daemonId": daemon}))
            }
            Err(why) => Err(pulled
                .then(|| too_old(&why, &host, inline_bytes))
                .flatten()
                .unwrap_or_else(|| refused(&why))),
        }
    }

    async fn transfer_hub_move_out(&self, params: &Value) -> Result<Value, RpcError> {
        let source = params
            .get("moveOut")
            .and_then(Value::as_str)
            .filter(|id| plain_daemon(id))
            .ok_or_else(|| RpcError::invalid_params("move_out needs the holder's daemon id"))?;
        let args = crate::mesh_control::MoveOutParams::parse(params.clone(), "moveOut")
            .map_err(RpcError::invalid_params)?;
        let turn_wait = if args.after_turn { args.timeout_secs } else { 0 };
        let mut body = json!(args);
        body.set("version", json!(1));
        if body.to_string().len() > 64 * 1024 {
            return Err(pull_error("size", "the move_out control body is too large"));
        }
        let key = format!("move-out-{}", uuid::Uuid::now_v7());
        // `timeoutSecs` covers the optional after-turn wait. Leave the normal transfer budget in
        // addition to it, saturating so a malformed huge value cannot wrap.
        let wait = MOVE_WAIT
            .saturating_add(super::transfer_hub_precopy::STAGE_WAIT)
            .saturating_add(std::time::Duration::from_secs(turn_wait));
        match self
            .hub_control(source, crate::mesh_relay_config::MOVE_OUT_OP, body, key, wait)
            .await?
        {
            Ok(Some(result)) => serde_json::from_str(&result)
                .map_err(|e| pull_error("answer", format!("move_out returned invalid JSON: {e}"))),
            Ok(None) => Err(pull_error("unknown", "the source did not answer the move_out")),
            Err(why) => Err(pull_error("refused", format!("the source refused move_out: {why}"))
                .with_data(json!({"refused": true, "detail": why}))),
        }
    }

    #[cfg(feature = "hub-carrier")]
    async fn resolve_hub_machine(&self, name: &str) -> Result<Value, RpcError> {
        // Only a just-started daemon waits: later, an unread list is a relay that is off, and a
        // local PARENT/CHILD key (`session_move_hub::holder`) must not wait on it.
        let age = std::time::Duration::from_millis(now_ms().saturating_sub(self.started_at));
        let wait = FIRST_BOOK_READ_WAIT.saturating_sub(age);
        let Some(machines) = self.mesh_book_machines_once_read(wait).await else {
            return Err(RpcError::not_found(format!(
                "{name}: this daemon has not read the team hub's machine list since it started \
                 (is the mesh relay on? a just-started daemon waits up to {} s for its first read)",
                FIRST_BOOK_READ_WAIT.as_secs()
            )));
        };
        let found =
            machines.into_iter().find(|(key, host)| key == name || host.eq_ignore_ascii_case(name));
        match found {
            Some((key, host)) => Ok(json!({"daemonId": key, "host": host})),
            None => Err(RpcError::not_found(format!(
                "{name} is not one of your machines the team hub lists"
            ))),
        }
    }

    #[cfg(not(feature = "hub-carrier"))]
    async fn resolve_hub_machine(&self, name: &str) -> Result<Value, RpcError> {
        Err(RpcError::not_found(format!("{name}: this build has no hub carrier")))
    }
}

/// How long `resolve` waits for a just-started daemon's first read of the hub book: its first
/// heartbeat, then a read of at most 5 s (`server/mesh_relay.rs`).
#[cfg(feature = "hub-carrier")]
const FIRST_BOOK_READ_WAIT: std::time::Duration = std::time::Duration::from_secs(20);

/// `v[k]` without the indexing lint: Null when absent.
fn field<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

#[cfg(test)]
#[path = "transfer_pull_tests.rs"]
mod tests;
