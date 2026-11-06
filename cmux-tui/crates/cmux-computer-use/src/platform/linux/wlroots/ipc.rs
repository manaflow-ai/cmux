//! Window lists from the compositor's own IPC, where it has one: positions,
//! pids and stacking that wlr-foreign-toplevel does not carry.
//!
//! - Sway (and i3-compatible Wayland compositors): `$SWAYSOCK`, i3-ipc.
//! - Hyprland: `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use crate::desktop::Rect;

/// One window as the compositor's IPC sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct IpcWindow {
    pub id: String,
    pub app_id: String,
    pub pid: u32,
    pub title: String,
    pub rect: Rect,
    pub visible: bool,
    pub focused: bool,
    pub workspace: String,
    /// Stacking within the workspace: 0 tiled, higher floats above.
    pub layer: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ipc {
    Sway(PathBuf),
    Hyprland(PathBuf),
}

impl Ipc {
    pub fn detect() -> Option<Self> {
        if let Ok(p) = std::env::var("SWAYSOCK")
            && !p.is_empty()
        {
            return Some(Ipc::Sway(PathBuf::from(p)));
        }
        let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok().filter(|s| !s.is_empty())?;
        let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_default();
        let new = PathBuf::from(runtime).join("hypr").join(&sig).join(".socket.sock");
        let old = PathBuf::from("/tmp/hypr").join(&sig).join(".socket.sock");
        Some(Ipc::Hyprland(if new.exists() { new } else { old }))
    }

    pub fn name(&self) -> &'static str {
        match self {
            Ipc::Sway(_) => "sway",
            Ipc::Hyprland(_) => "hyprland",
        }
    }

    pub fn windows(&self) -> Result<Vec<IpcWindow>, String> {
        match self {
            Ipc::Sway(p) => {
                let tree = sway_request(p, 4, "")?;
                let mut out = Vec::new();
                sway_walk(&tree, "", 0, true, &mut out);
                Ok(out)
            }
            Ipc::Hyprland(p) => {
                let clients = hypr_json(p, "j/clients")?;
                let monitors = hypr_json(p, "j/monitors")?;
                let active = hypr_json(p, "j/activewindow").unwrap_or(Value::Null);
                Ok(hypr_windows(&clients, &monitors, &active))
            }
        }
    }

    /// Focuses (and raises) a window: the Foreground route, and headless
    /// sessions where no person's focus is taken.
    pub fn focus(&self, id: &str) -> Result<(), String> {
        match self {
            Ipc::Sway(p) => {
                let con = id.strip_prefix("sway:").ok_or("not a sway window")?;
                let r = sway_request(p, 0, &format!("[con_id={con}] focus"))?;
                let ok = r.as_array().and_then(|a| a.first()).and_then(|v| v["success"].as_bool()).unwrap_or(false);
                if ok { Ok(()) } else { Err(format!("sway refused focus: {r}")) }
            }
            Ipc::Hyprland(p) => {
                let addr = id.strip_prefix("hypr:").ok_or("not a Hyprland window")?;
                let r = hypr_raw(p, &format!("dispatch focuswindow address:{addr}"))?;
                if r.trim() == "ok" { Ok(()) } else { Err(format!("Hyprland refused focus: {r}")) }
            }
        }
    }

    /// Output names, to tell a headless session (`HEADLESS-1`).
    pub fn outputs(&self) -> Vec<String> {
        let v = match self {
            Ipc::Sway(p) => sway_request(p, 3, "").ok(),
            Ipc::Hyprland(p) => hypr_json(p, "j/monitors").ok(),
        };
        v.and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|o| o["name"].as_str().map(str::to_string))
            .collect()
    }
}

fn connect(path: &PathBuf) -> Result<UnixStream, String> {
    let s = UnixStream::connect(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let _ = s.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(3)));
    Ok(s)
}

fn sway_request(path: &PathBuf, kind: u32, payload: &str) -> Result<Value, String> {
    let mut s = connect(path)?;
    let mut msg = b"i3-ipc".to_vec();
    msg.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
    msg.extend_from_slice(&kind.to_ne_bytes());
    msg.extend_from_slice(payload.as_bytes());
    s.write_all(&msg).map_err(|e| e.to_string())?;
    let mut head = [0u8; 14];
    s.read_exact(&mut head).map_err(|e| e.to_string())?;
    if &head[..6] != b"i3-ipc" {
        return Err("bad sway IPC reply".into());
    }
    let len = u32::from_ne_bytes([head[6], head[7], head[8], head[9]]) as usize;
    let mut body = vec![0u8; len];
    s.read_exact(&mut body).map_err(|e| e.to_string())?;
    serde_json::from_slice(&body).map_err(|e| e.to_string())
}

fn rect_of(v: &Value) -> Rect {
    let f = |k: &str| v[k].as_f64().unwrap_or(0.0);
    Rect { x: f("x"), y: f("y"), width: f("width"), height: f("height") }
}

/// Walks a sway tree: views are nodes with a pid (or a `window` for X11).
pub fn sway_walk(node: &Value, workspace: &str, layer: u32, parent_visible: bool, out: &mut Vec<IpcWindow>) {
    let ws = if node["type"] == "workspace" { node["name"].as_str().unwrap_or(workspace) } else { workspace };
    let is_view = node["pid"].as_u64().is_some() && (node["type"] == "con" || node["type"] == "floating_con");
    if is_view {
        let outer = rect_of(&node["rect"]);
        let inner = rect_of(&node["window_rect"]);
        let rect = if inner.width > 0.0 {
            Rect { x: outer.x + inner.x, y: outer.y + inner.y, width: inner.width, height: inner.height }
        } else {
            outer
        };
        let app_id = node["app_id"]
            .as_str()
            .or_else(|| node["window_properties"]["class"].as_str())
            .unwrap_or("")
            .to_string();
        out.push(IpcWindow {
            id: format!("sway:{}", node["id"].as_u64().unwrap_or(0)),
            app_id,
            pid: node["pid"].as_u64().unwrap_or(0) as u32,
            title: node["name"].as_str().unwrap_or("").to_string(),
            rect,
            visible: node["visible"].as_bool().unwrap_or(parent_visible),
            focused: node["focused"].as_bool().unwrap_or(false),
            workspace: ws.to_string(),
            layer,
        });
    }
    let empty = Vec::new();
    for kid in node["nodes"].as_array().unwrap_or(&empty) {
        sway_walk(kid, ws, layer, parent_visible, out);
    }
    for (i, kid) in node["floating_nodes"].as_array().unwrap_or(&empty).iter().enumerate() {
        sway_walk(kid, ws, layer.max(1) + i as u32, parent_visible, out);
    }
}

fn hypr_raw(path: &PathBuf, cmd: &str) -> Result<String, String> {
    let mut s = connect(path)?;
    s.write_all(cmd.as_bytes()).map_err(|e| e.to_string())?;
    let mut out = String::new();
    s.read_to_string(&mut out).map_err(|e| e.to_string())?;
    Ok(out)
}

fn hypr_json(path: &PathBuf, cmd: &str) -> Result<Value, String> {
    serde_json::from_str(&hypr_raw(path, cmd)?).map_err(|e| e.to_string())
}

pub fn hypr_windows(clients: &Value, monitors: &Value, active: &Value) -> Vec<IpcWindow> {
    let active_ws: Vec<i64> = monitors
        .as_array()
        .map(|m| m.iter().filter_map(|m| m["activeWorkspace"]["id"].as_i64()).collect())
        .unwrap_or_default();
    let active_addr = active["address"].as_str().unwrap_or("");
    let empty = Vec::new();
    clients
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .filter(|c| c["mapped"].as_bool().unwrap_or(true))
        .map(|c| {
            let at = |i: usize, k: &str| c[k][i].as_f64().unwrap_or(0.0);
            let addr = c["address"].as_str().unwrap_or("");
            let ws = c["workspace"]["id"].as_i64().unwrap_or(0);
            IpcWindow {
                id: format!("hypr:{addr}"),
                app_id: c["class"].as_str().unwrap_or("").to_string(),
                pid: c["pid"].as_i64().unwrap_or(0).max(0) as u32,
                title: c["title"].as_str().unwrap_or("").to_string(),
                rect: Rect { x: at(0, "at"), y: at(1, "at"), width: at(0, "size"), height: at(1, "size") },
                visible: !c["hidden"].as_bool().unwrap_or(false) && active_ws.contains(&ws),
                focused: !addr.is_empty() && addr == active_addr,
                workspace: ws.to_string(),
                layer: u32::from(c["floating"].as_bool().unwrap_or(false)),
            }
        })
        .collect()
}

/// True when a visible window above `w` on its workspace overlaps it.
pub fn covered(w: &IpcWindow, all: &[IpcWindow]) -> bool {
    all.iter().any(|o| {
        o.id != w.id && o.visible && o.workspace == w.workspace && o.layer > w.layer && o.rect.intersects(&w.rect)
    })
}
