//! The link details from the host (`cmux.host.link.get` and
//! `cmux.host.link.changed`, crate::api::host) and what a connect may do
//! with them. The serve loop's thread is the only writer of [`LinkConfig`]:
//! host frames reach it through the loop's inbox.

use super::argv::{LinkPaths, link_command};
use super::ops::LINK_UNAVAILABLE;
use crate::api::host::{HostError, HostFrame, LINK_CHANGED, LINK_GET};
use crate::connector::frames::{CONNECTOR_CLOSE, CONNECTOR_OPEN};
use crate::api::{CloudError, ControlPlane};
use crate::ops::Server;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The host's link details did not validate: nothing of them is used.
pub const LINK_DETAILS_INVALID: &str = "cmux.cloud.link_details_invalid";

/// `sun_path` is 104 bytes on macOS; the link socket is
/// `<socket_dir>/cmux-link-<12 hex>.sock` (27 bytes after the folder).
const MAX_SOCKET_DIR: usize = 104 - 1 - 27;

/// What the server knows of the link details.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkConfig {
    /// No `link.get` was sent (no serve loop; tests give paths directly).
    Unrequested,
    /// A `link.get` waits for its answer.
    Waiting,
    Ready(LinkPaths),
    /// A valid answer with `hub_socket: null`: no `cmux link` runs. Connect
    /// answers `link_unavailable` until a `link.changed` brings a hub.
    NoHub,
    /// The host answered `host.error`. `retry`: the next connect sends one
    /// new `link.get` (each retryable error allows one; nothing loops).
    HostError {
        error: HostError,
        retry: bool,
    },
    /// The host's details did not validate.
    Invalid(String),
}

fn path(value: &Value, key: &str) -> Result<PathBuf, String> {
    let text = value.get(key).and_then(Value::as_str).ok_or_else(|| format!("{key} is missing"))?;
    let path = Path::new(text);
    if !path.is_absolute() {
        return Err(format!("{key} is not an absolute path"));
    }
    if text.chars().any(char::is_control) || text.len() > 4096 {
        return Err(format!("{key} is not a usable path"));
    }
    if path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
        return Err(format!("{key} has a .. part"));
    }
    Ok(path.to_path_buf())
}

/// A checked `link.get` answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LinkDetails {
    Ready(LinkPaths),
    /// Every other field is valid and `hub_socket` is null.
    NoHub,
}

impl LinkDetails {
    /// [`LinkPaths::decode`], with an explicit `hub_socket: null` read as
    /// "no live `cmux link`" (the rest must still be valid).
    pub fn decode(value: &Value) -> Result<Self, String> {
        if value.get("hub_socket").is_some_and(Value::is_null) {
            let mut probe = value.clone();
            probe["hub_socket"] = json!("/");
            LinkPaths::decode(&probe)?;
            return Ok(Self::NoHub);
        }
        LinkPaths::decode(value).map(Self::Ready)
    }
}

impl LinkPaths {
    /// Checks the host's `{binary, hub_socket, state_dir, socket_dir,
    /// device_name}`: absolute paths only (no `..`, no control
    /// characters), a socket folder short enough for a socket path, and a
    /// device name that is not empty and has no control characters. Any
    /// failure refuses the whole answer.
    pub fn decode(value: &Value) -> Result<Self, String> {
        if !value.is_object() {
            return Err("the link details are not an object".into());
        }
        let socket_dir = path(value, "socket_dir")?;
        if socket_dir.as_os_str().len() > MAX_SOCKET_DIR {
            return Err("socket_dir is too long for a socket path".into());
        }
        let device_name =
            value.get("device_name").and_then(Value::as_str).ok_or("device_name is missing")?;
        // A leading `-` would read as a flag of the link's argv.
        if device_name.trim().is_empty()
            || device_name.starts_with('-')
            || device_name.chars().any(char::is_control)
            || device_name.len() > 128
        {
            return Err(
                "device_name is empty, too long, starts with - or has control characters".into()
            );
        }
        Ok(Self {
            binary: path(value, "binary")?,
            hub_socket: path(value, "hub_socket")?,
            state_dir: path(value, "state_dir")?,
            socket_dir,
            device_name: device_name.to_owned(),
        })
    }
}

impl<C: ControlPlane> Server<C> {
    /// Sends the first `link.get` when no details are known (the serve
    /// loop calls this once before its first op).
    pub(crate) fn request_link_details(&mut self) {
        if self.attach().link == LinkConfig::Unrequested
            && self.host_requests().request(LINK_GET, json!({}))
        {
            self.attach_mut().link = LinkConfig::Waiting;
        }
    }

    /// Applies one host frame (from the serve loop's inbox). A frame that
    /// answers nothing or names an op this server does not use is dropped.
    pub fn host_frame(&mut self, line: &Value) {
        let frame = match self.host_requests().accept(line) {
            Ok(frame) => frame,
            Err(why) => {
                eprintln!("cmux-cloud: dropped a host frame: {why}");
                return;
            }
        };
        match frame {
            HostFrame::Result { op, value, .. } if op == LINK_GET => {
                self.apply_link_details(&value);
            }
            HostFrame::Result { op, id, value } if op == CONNECTOR_OPEN => {
                self.frame_link_answer(id, Ok(value));
            }
            HostFrame::Error { op, id, error } if op == CONNECTOR_OPEN => {
                self.frame_link_answer(id, Err(error));
            }
            HostFrame::Event { op, data } if op == CONNECTOR_CLOSE => {
                self.attach_mut().frames.host_closed(&data);
            }
            HostFrame::Event { op, data } if op == LINK_CHANGED => {
                // The event is newer than any waiting link.get: its late
                // answer must not bring older details back.
                self.host_requests().cancel(LINK_GET);
                self.apply_link_details(&data);
            }
            HostFrame::Error { op, error, .. } if op == LINK_GET => {
                let retry = error.retryable;
                self.attach_mut().link = LinkConfig::HostError { error, retry };
            }
            HostFrame::Result { op, .. }
            | HostFrame::Error { op, .. }
            | HostFrame::Event { op, .. } => {
                eprintln!("cmux-cloud: dropped a host frame for {op}");
            }
        }
    }

    /// New details from the host. Valid and different: live links are
    /// respawned with them (the old process ends, a new generation starts;
    /// its forwards close as for any link change). Invalid: new connects
    /// get a typed error; links that run keep their last valid details.
    fn apply_link_details(&mut self, value: &Value) {
        let paths = match LinkDetails::decode(value) {
            Ok(LinkDetails::Ready(paths)) => paths,
            Ok(LinkDetails::NoHub) => {
                // No `cmux link` runs: a link through the old hub cannot
                // carry anything, so every live link ends (the next connect
                // after a hub comes back opens a new one).
                let attach = self.attach_mut();
                attach.link = LinkConfig::NoHub;
                attach.supervisor.pump();
                attach.supervisor.disconnect_all("the cmux link is not running");
                return;
            }
            Err(why) => {
                eprintln!("cmux-cloud: the link details from cmux are not valid: {why}");
                self.attach_mut().link = LinkConfig::Invalid(why);
                return;
            }
        };
        let attach = self.attach_mut();
        let previous = std::mem::replace(&mut attach.link, LinkConfig::Ready(paths.clone()));
        if previous == LinkConfig::Ready(paths.clone()) {
            return;
        }
        attach.supervisor.pump();
        for machine in attach.supervisor.live_machines() {
            let Some(host) = attach.hosts.get(&machine).cloned() else { continue };
            let command = match attach.env.child_env() {
                Ok(env) => link_command(&paths, &machine, &host, &env),
                Err(e) => {
                    eprintln!("cmux-cloud: no private home for the link to {machine}: {e}");
                    attach.supervisor.disconnect(&machine);
                    continue;
                }
            };
            if let Err(failure) = attach.supervisor.respawn(&machine, &command) {
                eprintln!("cmux-cloud: the link to {machine} did not restart: {failure:?}");
            }
        }
    }

    /// The details a connect uses now, or the typed reason it cannot run.
    pub(crate) fn link_paths(&mut self) -> Result<LinkPaths, CloudError> {
        let unavailable = |message: &str, retryable: bool| CloudError {
            retryable,
            ..CloudError::new(LINK_UNAVAILABLE, message)
        };
        match self.attach().link.clone() {
            LinkConfig::Ready(paths) => Ok(paths),
            LinkConfig::Unrequested => Err(unavailable(
                "cmux did not give the Cloud app a link binary and network hub",
                false,
            )),
            LinkConfig::Waiting => Err(unavailable("cmux has not sent the link details yet", true)),
            LinkConfig::NoHub => Err(unavailable("the cmux link is not running", true)),
            LinkConfig::Invalid(why) => Err(CloudError::new(
                LINK_DETAILS_INVALID,
                format!("cmux sent link details that are not valid: {why}"),
            )),
            LinkConfig::HostError { error, retry } => {
                if retry && self.host_requests().request(LINK_GET, json!({})) {
                    self.attach_mut().link = LinkConfig::Waiting;
                }
                Err(CloudError {
                    upstream_code: Some(error.code.clone()),
                    retryable: retry,
                    ..CloudError::new(
                        LINK_UNAVAILABLE,
                        format!("cmux could not give the link details: {}", error.message),
                    )
                })
            }
        }
    }
}
