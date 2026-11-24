//! `machine.chief_resize`: a Chief's own Cloud machine moves up the Chief ladder (included, M, L,
//! XL; [`ChiefSize`]) over the platform's `cloud.machine.resize` (cmux-platform `domain/Power.ts`
//! `resizeIntent`: grow only on every axis, the disk only on a running machine, held to the plan
//! and the spending cap). The daemon serves it as `cloud.machine.chief_resize`, the CLI as
//! `cmux cloud api` with `{"call": "machine.chief_resize", …}` (cmuxterm-hq RFD 0028, "Resize from
//! the app").
//!
//! Args: `machine` (the Chief's machine id, `vm_…`), `key` (1 to 48 of `a-z0-9-`: the resize is
//! sent under `chief-machine-<key>-resize`, so the same key never asks twice) and an optional
//! `size` (`included`, `M`, `L`, `XL`, or `chief_m`, `chief_l`, `chief_xl`). With no `size` the
//! machine moves to the size the person's plan gives a Chief (`cloud.plan.get`'s `chief_size`).
//!
//! The call then reads the machine until it has the new size, up to [`RESIZE_WAIT`]. The answer
//! is `{machine, size, shape: {cpu, memory_mb, disk_mb}, stage}`: `stage` is `done` once the
//! machine has the shape, `pending` while the platform is still growing it.

use std::time::Duration;

use serde_json::{Value, json};

use super::chief_machine::{ChiefSize, Cloud, Session, plan_size};
use super::http::Http;
use super::owner::is_machine_id;
use super::{Auth, Failure, Request, optional_text, text};

/// How long the call reads the machine for its new size (the platform's resize deadline is 4 min).
pub const RESIZE_WAIT: Duration = Duration::from_secs(300);
const POLL: Duration = Duration::from_secs(3);

/// What the call was asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resize {
    pub machine: String,
    pub key: String,
    /// `None`: the size the plan gives a Chief.
    pub size: Option<ChiefSize>,
}

/// The call's args.
pub fn parse(request: &Request) -> Result<Resize, Failure> {
    let args = &request.args;
    let machine = text(args, "machine")?.to_owned();
    if !is_machine_id(&machine) {
        return Err(Failure::Transport("machine: not a Cloud machine id".into()));
    }
    let key = text(args, "key")?.to_owned();
    if !(1..=48).contains(&key.len())
        || !key.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        return Err(Failure::Transport("key: 1 to 48 of a-z, 0-9 and -".into()));
    }
    let size = match optional_text(args, "size") {
        None => None,
        Some(name) => Some(ChiefSize::named(name).ok_or_else(|| {
            Failure::Transport(format!("size {name:?}: one of included, M, L, XL"))
        })?),
    };
    Ok(Resize { machine, key, size })
}

/// `cloud.machine.resize`'s params for a Chief of `size`.
pub fn resize_params(machine: &str, size: ChiefSize) -> Value {
    json!({ "machine": machine, "size": shape_json(size) })
}

fn shape_json(size: ChiefSize) -> Value {
    let (cpu, memory_mb, disk_mb) = size.shape();
    json!({ "cpu": cpu, "memory_mb": memory_mb, "disk_mb": disk_mb })
}

/// Whether a machine row has at least `size`'s shape on every axis.
fn has_shape(row: &Value, size: ChiefSize) -> bool {
    let (cpu, memory_mb, disk_mb) = size.shape();
    let axis = |name: &str| row.pointer(&format!("/size/{name}")).and_then(Value::as_i64);
    axis("cpu").is_some_and(|v| v >= cpu)
        && axis("memory_mb").is_some_and(|v| v >= memory_mb)
        && axis("disk_mb").is_some_and(|v| v >= disk_mb)
}

/// Runs the resize.
pub async fn run<C: Cloud>(cloud: &C, resize: &Resize) -> Result<Value, Failure> {
    let size = match resize.size {
        Some(size) => size,
        None => plan_size(cloud).await,
    };
    let key = format!("chief-machine-{}-resize", resize.key);
    cloud.op("cloud.machine.resize", resize_params(&resize.machine, size), &key).await?;
    let mut waited = Duration::ZERO;
    let stage = loop {
        let got = cloud.read("cloud.machine.get", json!({ "machine": resize.machine })).await?;
        let row = got.get("machine").unwrap_or(&got);
        if has_shape(row, size) {
            break "done";
        }
        if waited >= RESIZE_WAIT {
            break "pending";
        }
        cloud.pause(POLL).await;
        waited += POLL;
    };
    Ok(json!({
        "machine": resize.machine,
        "size": size.name(),
        "shape": shape_json(size),
        "stage": stage,
    }))
}

/// `machine.chief_resize` for [`crate::perform`].
pub(crate) async fn perform(request: &Request, http: &Http) -> Result<Value, Failure> {
    if request.auth == Auth::Stack {
        return Err(Failure::http(
            501,
            Some("cloud.not_available".into()),
            Some("machine.chief_resize is not available on this Cloud".into()),
        ));
    }
    let resize = parse(request)?;
    run(&Session { request, http }, &resize).await
}

#[cfg(test)]
#[path = "chief_resize_tests.rs"]
mod tests;
