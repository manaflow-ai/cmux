//! Initial tree bootstrap, ensure-initial, and agent refresh.

use super::*;

struct EnsureInitialTreeWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    list_requests: usize,
}

struct AgentRefreshWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    agent_requests: usize,
}

impl RemoteMessageWriter for AgentRefreshWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let response = match request.get("cmd").and_then(Value::as_str) {
            Some("list-workspaces") => json!({
                "id": id,
                "ok": true,
                "data": {
                    "workspaces": [{
                        "id": 1,
                        "active": true,
                        "screens": [{
                            "id": 2,
                            "active": true,
                            "active_pane": 3,
                            "layout": {"type": "leaf", "pane": 3},
                            "panes": [{
                                "id": 3,
                                "active_tab": 0,
                                "tabs": [{"surface": 4, "kind": "pty"}],
                            }],
                        }],
                    }],
                },
            }),
            Some("list-agents") => {
                self.agent_requests += 1;
                if self.agent_requests == 1 {
                    json!({
                        "id": id,
                        "ok": true,
                        "data": {
                            "agents": [{
                                "surface": 4,
                                "state": "working",
                                "source": "hook",
                                "session": "agent-session",
                                "updated_at_ms": 1,
                            }],
                        },
                    })
                } else {
                    json!({"id": id, "ok": false, "error": "agent snapshot unavailable"})
                }
            }
            command => {
                return Err(io::Error::other(format!(
                    "unexpected agent refresh command {command:?}"
                )));
            }
        };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let pending = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        pending
            .response
            .send(response)
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl RemoteMessageWriter for EnsureInitialTreeWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let data = match request.get("cmd").and_then(Value::as_str) {
            Some("list-workspaces") => {
                self.list_requests += 1;
                if self.list_requests == 1 {
                    json!({"workspaces": []})
                } else {
                    json!({
                        "workspaces": [{
                            "id": 1,
                            "active": true,
                            "screens": [{
                                "id": 2,
                                "active": true,
                                "active_pane": 3,
                                "layout": {"type": "leaf", "pane": 3},
                                "panes": [{
                                    "id": 3,
                                    "active_tab": 0,
                                    "tabs": [{"surface": 4, "kind": "pty"}],
                                }],
                            }],
                        }],
                    })
                }
            }
            Some("list-agents") => json!({"agents": []}),
            Some("new-workspace") => json!({"surface": 4}),
            command => {
                return Err(io::Error::other(format!(
                    "unexpected ensure-initial command {command:?}"
                )));
            }
        };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        response
            .response
            .send(json!({"id": id, "ok": true, "data": data}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A session whose every workspace lost its screens (the outcome of the
/// startup repair that prunes dead terminals) must get a shell in the
/// active workspace at attach, not render pure emptiness. The writer
/// refuses `new-workspace`, so this also pins that startup must not bolt
/// an extra workspace onto a session that already has four.
struct BareWorkspacesTreeWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    created_in: Arc<Mutex<Option<String>>>,
}

impl RemoteMessageWriter for BareWorkspacesTreeWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let bare = |key: &str, id: u64, active: bool| json!({"id": id, "key": key, "active": active, "screens": []});
        let populated = json!({
            "id": 5,
            "key": "ws-active",
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [{"surface": 4, "kind": "pty"}],
                }],
            }],
        });
        let data = match request.get("cmd").and_then(Value::as_str) {
            Some("list-workspaces") => {
                if self.created_in.lock().unwrap().is_some() {
                    json!({"generation": "gen-1", "terminal_revision": 8, "workspaces": [
                        bare("ws-0", 1, false),
                        populated,
                        bare("ws-2", 9, false),
                    ]})
                } else {
                    json!({"generation": "gen-1", "terminal_revision": 7, "workspaces": [
                        bare("ws-0", 1, false),
                        bare("ws-active", 5, true),
                        bare("ws-2", 9, false),
                    ]})
                }
            }
            Some("list-agents") => json!({"agents": []}),
            Some("create-terminal") => {
                let key = request
                    .get("key")
                    .and_then(Value::as_str)
                    .ok_or_else(|| io::Error::other("create-terminal omitted the workspace key"))?;
                if request.get("mutation_id").and_then(Value::as_str).is_none()
                    || request.get("expected_revision").and_then(Value::as_u64) != Some(7)
                    || request.get("expected_generation").and_then(Value::as_str) != Some("gen-1")
                {
                    return Err(io::Error::other(
                        "bootstrap create arrived without its concurrency guard",
                    ));
                }
                *self.created_in.lock().unwrap() = Some(key.to_string());
                json!({"surface": 4})
            }
            command => {
                return Err(io::Error::other(format!(
                    "bare-workspace attach must not send {command:?}"
                )));
            }
        };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        response
            .response
            .send(json!({"id": id, "ok": true, "data": data}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// The losing side of a concurrent bare-session attach: its guarded
/// create is rejected because the winner already moved the terminal
/// revision, and the follow-up tree read shows the winner's shell.
/// Attach must treat that as success, not as a startup failure.
struct LostBootstrapRaceWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    list_requests: usize,
}

impl RemoteMessageWriter for LostBootstrapRaceWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let populated = json!({
            "id": 5,
            "key": "ws-active",
            "active": true,
            "screens": [{
                "id": 2,
                "active": true,
                "active_pane": 3,
                "layout": {"type": "leaf", "pane": 3},
                "panes": [{
                    "id": 3,
                    "active_tab": 0,
                    "tabs": [{"surface": 4, "kind": "pty"}],
                }],
            }],
        });
        let response = match request.get("cmd").and_then(Value::as_str) {
            Some("list-workspaces") => {
                self.list_requests += 1;
                let data = if self.list_requests <= 2 {
                    json!({"generation": "gen-1", "terminal_revision": 7, "workspaces": [
                        {"id": 5, "key": "ws-active", "active": true, "screens": []},
                    ]})
                } else {
                    json!({"generation": "gen-1", "terminal_revision": 8, "workspaces": [
                        populated,
                    ]})
                };
                json!({"id": id, "ok": true, "data": data})
            }
            Some("list-agents") => json!({"id": id, "ok": true, "data": {"agents": []}}),
            Some("create-terminal") => json!({
                "id": id,
                "ok": false,
                "error": "expected terminal revision 7 does not match 8",
            }),
            command => {
                return Err(io::Error::other(format!(
                    "lost bootstrap race must not send {command:?}"
                )));
            }
        };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let pending = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        pending
            .response
            .send(response)
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn winner_between_snapshots_still_lands_in_the_cache() {
    // The other attach creates the shell between the first tree read and
    // the raw snapshot: no create runs here, and the final refresh must
    // still deliver the winner's tree to this client's cache.
    let session_slot = Arc::new(Mutex::new(None));
    let remote = test_session(Box::new(LostBootstrapRaceWriter {
        session: session_slot.clone(),
        list_requests: 1, // skip one bare read: the snapshot is populated
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
    let session = crate::session::Session::Remote(remote);

    session.ensure_initial(Some((80, 24))).unwrap();

    assert_eq!(
        session.tree().active_surface(),
        Some(4),
        "the stale bare tree survived in the cache"
    );
}

#[test]
fn losing_the_bare_session_bootstrap_race_is_not_a_startup_failure() {
    let session_slot = Arc::new(Mutex::new(None));
    let remote = test_session(Box::new(LostBootstrapRaceWriter {
        session: session_slot.clone(),
        list_requests: 0,
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
    let session = crate::session::Session::Remote(remote);

    session.ensure_initial(Some((80, 24))).unwrap();

    assert_eq!(
        session.tree().active_surface(),
        Some(4),
        "the loser must adopt the winner's shell instead of failing attach"
    );
}

/// A daemon too old to report revision metadata cannot enforce the
/// bootstrap guard, so the client must not send an unguarded create at
/// all: the writer refuses `create-terminal`, and attach must still
/// succeed with the session left bare, exactly as before the bootstrap
/// existed.
struct UnguardableTreeWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
}

impl RemoteMessageWriter for UnguardableTreeWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let data = match request.get("cmd").and_then(Value::as_str) {
            Some("list-workspaces") => json!({"workspaces": [
                {"id": 5, "key": "ws-active", "active": true, "screens": []},
            ]}),
            Some("list-agents") => json!({"agents": []}),
            command => {
                return Err(io::Error::other(format!(
                    "an unguardable daemon must not receive {command:?}"
                )));
            }
        };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let pending = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        pending
            .response
            .send(json!({"id": id, "ok": true, "data": data}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn bootstrap_stays_home_when_the_daemon_cannot_enforce_its_guard() {
    let session_slot = Arc::new(Mutex::new(None));
    let remote = test_session(Box::new(UnguardableTreeWriter { session: session_slot.clone() }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
    let session = crate::session::Session::Remote(remote);

    session.ensure_initial(Some((80, 24))).unwrap();

    assert!(
        session.tree().workspaces().iter().all(|workspace| workspace.screens.is_empty()),
        "an unguarded create must never run"
    );
}

#[test]
fn ensure_initial_creates_a_shell_when_every_restored_workspace_is_bare() {
    let session_slot = Arc::new(Mutex::new(None));
    let created_in = Arc::new(Mutex::new(None));
    let remote = test_session(Box::new(BareWorkspacesTreeWriter {
        session: session_slot.clone(),
        created_in: created_in.clone(),
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
    let session = crate::session::Session::Remote(remote);

    session.ensure_initial(Some((80, 24))).unwrap();

    assert_eq!(
        created_in.lock().unwrap().as_deref(),
        Some("ws-active"),
        "attach did not create a shell in the active bare workspace"
    );
    assert_eq!(
        session.tree().active_surface(),
        Some(4),
        "startup returned before the client could route input to its created terminal"
    );
}

#[test]
fn ensure_initial_populates_remote_cache_after_creating_first_workspace() {
    let session_slot = Arc::new(Mutex::new(None));
    let remote = test_session(Box::new(EnsureInitialTreeWriter {
        session: session_slot.clone(),
        list_requests: 0,
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));
    let session = crate::session::Session::Remote(remote);

    session.ensure_initial(Some((80, 24))).unwrap();

    assert_eq!(
        session.tree().active_surface(),
        Some(4),
        "startup returned before the client could route input to its created terminal"
    );
}

#[test]
fn failed_agent_refresh_clears_last_known_agent_rows() {
    let session_slot = Arc::new(Mutex::new(None));
    let remote = test_session(Box::new(AgentRefreshWriter {
        session: session_slot.clone(),
        agent_requests: 0,
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&remote));

    remote.refresh_tree().unwrap();
    assert_eq!(remote.cached_agents().len(), 1);

    remote.refresh_tree().unwrap();

    assert!(remote.cached_agents().is_empty());
}

#[test]
fn provider_guard_fails_before_writing_to_an_older_remote_server() {
    let session = crate::session::Session::Remote(test_session(Box::new(UnexpectedWriteWriter)));

    let error = session.mark_workspaces_provider_managed().unwrap_err();

    assert_eq!(
        error.to_string(),
        "remote cmux server cannot guard provider-managed workspaces; upgrade the server before attaching"
    );
}

#[test]
fn bounded_json_lines_reject_oversize_and_invalid_utf8() {
    let mut valid = BufReader::with_capacity(2, io::Cursor::new(b"{}\r\nnext\n"));
    assert_eq!(read_bounded_json_line(&mut valid, 8).unwrap().as_deref(), Some("{}"));
    assert_eq!(read_bounded_json_line(&mut valid, 8).unwrap().as_deref(), Some("next"));

    let mut oversized = BufReader::with_capacity(2, io::Cursor::new(b"123456789\n"));
    assert_eq!(
        read_bounded_json_line(&mut oversized, 8).unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
    let mut oversized_unterminated = BufReader::with_capacity(2, io::Cursor::new(b"123456789"));
    assert_eq!(
        read_bounded_json_line(&mut oversized_unterminated, 8).unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
    let mut truncated = BufReader::with_capacity(2, io::Cursor::new(b"{}"));
    assert_eq!(read_bounded_json_line(&mut truncated, 8).unwrap().as_deref(), Some("{}"));
    let mut invalid = BufReader::new(io::Cursor::new([0xff, b'\n']));
    assert_eq!(
        read_bounded_json_line(&mut invalid, 8).unwrap_err().kind(),
        io::ErrorKind::InvalidData
    );
}
