//! The pool daemon's socket: one JSON request per line, one JSON answer per
//! line. The pool is per host, shared by every session's MCP server.
//!
//! ```text
//! {"op":"lease","owner":"<session>","spec":{...}}  -> {"ok":true,"lease":{"slot":"s1",...}}
//! {"op":"act","owner":..,"slot":"s1","action":{"type":"click","x":10,"y":20}}
//!                                                  -> {"ok":true,"report":{...},"png_b64":"..."}
//! {"op":"release","owner":..,"slot":"s1"}          -> {"ok":true}
//! {"op":"release_owner","owner":..}                -> {"ok":true,"released":2}
//! {"op":"stats"}                                   -> {"ok":true,"stats":{...}}
//! {"op":"budget","mb":512}                          -> the budget changed and enforced now
//! {"op":"shutdown"}                                -> {"ok":true} and every slot destroyed
//! ```

use crate::at;
use crate::backend::{Action, SlotSpec};
use crate::pool::Pool;
use anyhow::{Context, Result, anyhow};
use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Request {
    Lease {
        owner: String,
        #[serde(default)]
        spec: SlotSpec,
    },
    Act {
        owner: String,
        slot: String,
        action: Action,
    },
    Release {
        owner: String,
        slot: String,
    },
    ReleaseOwner {
        owner: String,
    },
    Stats,
    /// Change the resident budget (MB) and enforce it now.
    Budget {
        mb: u64,
    },
    Shutdown,
}

/// The default socket: `$XDG_RUNTIME_DIR/desktop-lease.sock`, else under /tmp.
pub fn default_socket() -> PathBuf {
    std::env::var_os("DESKTOP_LEASE_SOCKET").map(PathBuf::from).unwrap_or_else(|| {
        let dir = std::env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        dir.join("desktop-lease.sock")
    })
}

pub fn serve(pool: Arc<Pool>, socket: &Path) -> Result<()> {
    if UnixStream::connect(socket).is_ok() {
        return Err(anyhow!("a pool already answers on {}", socket.display()));
    }
    let _ = std::fs::remove_file(socket);
    let listener =
        UnixListener::bind(socket).with_context(|| format!("bind {}", socket.display()))?;
    let stop = Arc::new(AtomicBool::new(false));
    eprintln!("desktop-lease: serving on {}", socket.display());
    for conn in listener.incoming() {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let Ok(conn) = conn else { continue };
        let (owned, stop) = (Arc::clone(&pool), Arc::clone(&stop));
        let socket = socket.to_path_buf();
        pool.background("a pool connection", move || {
            if handle(&owned, conn, &stop).is_ok() && stop.load(Ordering::SeqCst) {
                owned.destroy_all();
                // Wake the accept loop so `serve` returns.
                let _ = UnixStream::connect(&socket);
            }
        });
    }
    pool.close(std::time::Duration::from_secs(5));
    let _ = std::fs::remove_file(socket);
    Ok(())
}

fn handle(pool: &Arc<Pool>, conn: UnixStream, stop: &AtomicBool) -> Result<()> {
    let mut out = conn.try_clone()?;
    for line in BufReader::new(conn).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let answer = match serde_json::from_str::<Request>(&line) {
            Ok(req) => {
                let shutdown = matches!(req, Request::Shutdown);
                let a = answer(pool, req)
                    .unwrap_or_else(|e| json!({"ok": false, "error": format!("{e:#}")}));
                if shutdown {
                    stop.store(true, Ordering::SeqCst);
                }
                a
            }
            Err(e) => json!({"ok": false, "error": format!("bad request: {e}")}),
        };
        writeln!(out, "{answer}")?;
        if stop.load(Ordering::SeqCst) {
            return Ok(());
        }
    }
    Ok(())
}

fn answer(pool: &Arc<Pool>, req: Request) -> Result<Value> {
    Ok(match req {
        Request::Lease { owner, spec } => json!({"ok": true, "lease": pool.lease(&owner, &spec)?}),
        Request::Act { owner, slot, action } => {
            let r = pool.act(&owner, &slot, &action)?;
            let png = base64::engine::general_purpose::STANDARD.encode(&r.png);
            json!({"ok": true, "report": r, "png_b64": png})
        }
        Request::Release { owner, slot } => {
            pool.release(&owner, &slot)?;
            json!({"ok": true})
        }
        Request::ReleaseOwner { owner } => {
            json!({"ok": true, "released": pool.release_owner(&owner)})
        }
        Request::Stats => json!({"ok": true, "stats": pool.stats()}),
        Request::Budget { mb } => {
            pool.set_budget_mb(mb);
            pool.enforce_budget();
            json!({"ok": true, "stats": pool.stats()})
        }
        Request::Shutdown => json!({"ok": true}),
    })
}

/// A client of the pool daemon.
pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

impl Client {
    pub fn connect(socket: &Path) -> Result<Self> {
        let s = UnixStream::connect(socket).with_context(|| {
            format!("no desktop pool on {} (start one: desktop-lease serve)", socket.display())
        })?;
        Ok(Client { reader: BufReader::new(s.try_clone()?), writer: s })
    }

    pub fn call(&mut self, req: &Value) -> Result<Value> {
        writeln!(self.writer, "{req}")?;
        let mut line = String::new();
        self.reader.read_line(&mut line)?;
        let v: Value = serde_json::from_str(&line).context("pool answer")?;
        if at(&v, "/ok").as_bool() != Some(true) {
            return Err(anyhow!("{}", at(&v, "/error").as_str().unwrap_or("pool error")));
        }
        Ok(v)
    }
}
