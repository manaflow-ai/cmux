//! Part of `Hub`; see `hub/mod.rs`. Adopting a harness's own session on
//! `session/new` (`_meta.acpmux.adopt`): the id is checked against the
//! harness store before anything is created, the session runs in the
//! conversation's recorded cwd, one id gets one session, and an agent that
//! started fresh instead of resuming fails creation. A conversation live in
//! another process is refused (`adopt.live`) unless `ifLive` forks it or
//! opens it anyway (`adopt_live.rs`); a Claude Code that this acpmux's own
//! agent host runs for one of its sessions is not another process: that
//! session opens.

use super::*;
use crate::adopt::{AdoptRequest, IfLive};
use std::collections::BTreeMap;

/// What adopting resolved to before a session is created.
pub(super) enum Adoption {
    /// A session already adopted this id; `session/new` returns it.
    Existing(Arc<Session>),
    /// Create a session, in the adopted conversation's recorded cwd if any;
    /// `fork`: a new conversation forked from it (`--fork-session`).
    /// `file`: the adopted conversation's transcript, replayed as history (`adopt_replay`).
    /// `store`: the chat index's store that holds it when the profile's
    /// store does not (cx-vx54).
    Found { cwd: Option<PathBuf>, fork: bool, file: Option<PathBuf>, store: Option<PathBuf> },
}

impl Hub {
    /// Resolve the recorded folder for a prospective adoption before a session
    /// is created. The folder-trust gate uses this to block harness startup.
    pub(crate) async fn adopted_cwd_for_trust(
        &self,
        family: &str,
        agent_session_id: &str,
        remote: bool,
    ) -> Result<Option<String>, RpcError> {
        if family.is_empty() {
            return Ok(None);
        }
        let homes = self.harness_homes.lock().unwrap().clone();
        let family = family.to_owned();
        let id = agent_session_id.to_owned();
        let index = self.chats.get().filter(|_| !remote).cloned();
        let (found, _) = tokio::task::spawn_blocking(move || {
            let others = indexed_stores(index.as_deref(), &family, &id);
            crate::adopt::find_any(&family, &id, &homes, &others)
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(RpcError::invalid_params)?;
        Ok(found.cwd.map(|cwd| cwd.to_string_lossy().into_owned()))
    }

    /// Checks `adopt` against the resolved harness and its store. No adopt
    /// resolves to `Found(None)`. `remote` (a Web-class connection) adopts
    /// only from a profile's store, never from another store of the index.
    pub(super) async fn adoption(
        &self,
        adopt: Option<&AdoptRequest>,
        agent: &str,
        family: &str,
        env: &[&BTreeMap<String, String>],
        remote: bool,
    ) -> Result<Adoption, RpcError> {
        let Some(a) = adopt else {
            return Ok(Adoption::Found { cwd: None, fork: false, file: None, store: None });
        };
        if let Some(asked) = &a.harness
            && asked != agent
            && asked != family
        {
            return Err(RpcError::invalid_params(format!(
                "adopt names harness {asked} but the session resolves to {agent}"
            )));
        }
        if a.if_live == IfLive::Fork && family != "claude" {
            return Err(RpcError::invalid_params(format!(
                "only Claude Code chats fork on adopt; open this {family} chat anyway or close it where it runs"
            )));
        }
        // A fork is a new conversation, never the chat that already adopted (or views) this one.
        if a.if_live != IfLive::Fork
            && let Some(existing) = self.adopted_session(family, &a.agent_session_id)
        {
            return Ok(Adoption::Existing(existing));
        }
        // The store the resuming harness reads: its spawn env's home, else
        // the daemon's, else a store the chat index holds the chat in. The
        // store walk, the record read and the holder check are blocking I/O.
        let homes = self.harness_homes.lock().unwrap().with_env(env);
        let index = self.chats.get().filter(|_| !remote).cloned();
        if a.watch && !matches!(family, "claude" | "codex") {
            return Err(RpcError::invalid_params(format!(
                "only Claude Code and Codex chats can be watched, not {family}"
            )));
        }
        // A watch forks nothing: Take Over chooses that, for a chat still live in its app.
        if a.watch && a.if_live == IfLive::Fork {
            return Err(RpcError::invalid_params(
                "a watched chat is forked by Take Over, not when it opens",
            ));
        }
        // Watching starts nothing on the conversation, so it may watch one that runs elsewhere.
        let check = a.if_live == IfLive::Refuse && !a.watch;
        let (fam, id) = (family.to_owned(), a.agent_session_id.clone());
        let ((found, store), live, own) = tokio::task::spawn_blocking(move || {
            let others = indexed_stores(index.as_deref(), &fam, &id);
            let (found, store) = crate::adopt::find_any(&fam, &id, &homes, &others)?;
            // The holder the harness records in the store that holds the chat; one that has
            // exited does not count (hq#2569 item 7).
            let live = check
                .then(|| match fam.as_str() {
                    "opencode" => {
                        crate::adopt_live::named_use(&id, &crate::adopt_live::processes())
                    }
                    "claude" => {
                        let root = store.clone().unwrap_or_else(|| homes.claude.clone());
                        crate::adopt_live::holder(&fam, &id, &root)
                    }
                    "codex" => {
                        let root = store.clone().unwrap_or_else(|| homes.codex.clone());
                        crate::adopt_live::holder(&fam, &id, &root)
                    }
                    _ => None,
                })
                .flatten();
            // A Claude Code that one of this home's agent hosts runs is this acpmux's own
            // harness, not the chat open elsewhere (every acpmux home shares the registry).
            let own = match &live {
                Some(crate::adopt_live::LiveUse::Registered { pid }) => {
                    crate::adopt_live::own_host_session(
                        *pid,
                        &own_hosts(),
                        &crate::adopt_live::processes(),
                    )
                }
                _ => None,
            };
            Ok::<_, String>(((found, store), live, own))
        })
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?
        .map_err(RpcError::invalid_params)?;
        // This acpmux's own Claude Code session runs the chat: it opens, as for an adopt of
        // the id it records (one chat, one session).
        if let Some(existing) = own
            .and_then(|own| {
                self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&own).cloned()
            })
            .filter(|s| s.meta().family.as_deref() == Some("claude"))
        {
            return Ok(Adoption::Existing(existing));
        }
        // Any other holder (another home's, a host whose session is gone but whose harness
        // still runs) may still write the chat: refused.
        if let Some(live) = live {
            return Err(RpcError::invalid_params(live.refusal(family, &a.agent_session_id))
                .with_data(json!({"reason": "adopt.live", "details": live.details(family)})));
        }
        Ok(Adoption::Found {
            cwd: found.cwd,
            fork: a.if_live == IfLive::Fork,
            file: Some(found.file),
            store,
        })
    }

    /// The session that already adopted `agent_session_id` in `family`, so
    /// adopting twice opens the same session instead of two resuming one.
    /// Any profile of the family counts: they share one store.
    fn adopted_session(&self, family: &str, agent_session_id: &str) -> Option<Arc<Session>> {
        adopted_in(&self.sessions.lock().unwrap(), family, agent_session_id)
    }

    /// An agent that could not load the adopted session started a fresh one
    /// instead; with no acpmux history to rehydrate, that would be a new
    /// conversation posing as the adopted one, so the session is removed.
    pub(super) async fn check_resumed(
        &self,
        session: &Arc<Session>,
        adopt: &AdoptRequest,
        agent: &str,
    ) -> Result<(), RpcError> {
        super::titles::keep_adopted_title(
            &mut session.meta.lock().unwrap_or_else(|e| e.into_inner()),
        );
        if session.meta().agent_session_id.as_deref() == Some(adopt.agent_session_id.as_str()) {
            return Ok(());
        }
        // Another Codex still writing the thread (classic cmux's terminal, a bare `codex` the
        // live check cannot tie to it) refuses the load: say so, not "could not resume" (cx-l7g6k).
        let held = self.load_error(session).is_some_and(|e| e.contains("active writer"));
        let _ = self.kill(session, true).await;
        if held {
            return Err(RpcError::invalid_params(format!(
                "{agent} session {} is still open in another app, such as classic cmux: \
                 quit it there, then open it again",
                adopt.agent_session_id
            )));
        }
        Err(RpcError::internal(format!(
            "{agent} could not resume session {}",
            adopt.agent_session_id
        )))
    }

    /// Records that `session`'s agent refused its `session/load`, with the error's `data`, where
    /// codex-acp says why (its message is "Internal error").
    pub(super) fn note_load_failed(&self, session: &Session, e: &RpcError) {
        let failed = json!({"error": e.message, "data": e.data});
        self.append(session, "mux", "resume_failed", failed);
    }

    /// Why `session`'s agent refused its `session/load`, if it did: the error's message and its
    /// `data` (where codex-acp puts the reason), as one text.
    fn load_error(&self, session: &Session) -> Option<String> {
        let events = self.events(&session.id, 0, 1_000).ok()?;
        let failed = events.iter().rev().find(|e| e.dir == "mux" && e.kind == "resume_failed")?;
        let message = failed.msg.get("error").and_then(Value::as_str).unwrap_or_default();
        Some(format!("{message} {}", failed.msg.get("data").unwrap_or(&Value::Null)))
    }
}

/// This home's agent hosts that may still run (a live or unproven liveness
/// lock), for `adopt_live::own_host_session`.
fn own_hosts() -> Vec<crate::adopt_live::OwnHost> {
    use crate::agent_host::{self, Liveness};
    let dir = agent_host::hosts_dir();
    let Ok((good, _)) = agent_host::load_records(&dir) else { return Vec::new() };
    good.into_iter()
        .filter(|(_, r)| {
            agent_host::liveness(&dir, &r.session_id, &r.start_nonce) != Liveness::Dead
        })
        .map(|(_, r)| crate::adopt_live::OwnHost {
            session_id: r.session_id,
            host_pid: r.host_pid,
            harness_pid: r.harness_pid,
        })
        .collect()
}

/// The stores acpmux's chat index holds the `family` chat `id` in (none
/// before the index starts): a subrouter account home or a root the person
/// added, which adopt may resume from though no profile's store is one.
fn indexed_stores(
    index: Option<&crate::chats::ChatService>,
    family: &str,
    id: &str,
) -> Vec<PathBuf> {
    let harness = match family {
        "claude" => cmux_chat_index::AdapterKind::ClaudeCode,
        "codex" => cmux_chat_index::AdapterKind::Codex,
        "opencode" => cmux_chat_index::AdapterKind::OpenCode,
        _ => return Vec::new(),
    };
    let key = cmux_chat_index::ChatKey { harness, session_id: id.to_owned() };
    index
        .and_then(|index| index.get(&key))
        .map(|chat| crate::chats::store_dirs(&chat))
        .unwrap_or_default()
}

/// The new session's cwd: the one given, else the adopted conversation's
/// recorded one, else home; made absolute and required to be a directory.
/// The second value is the recorded cwd when it is gone and the session runs
/// in the given folder instead (`remapped_cwd`).
pub(super) fn session_cwd(
    cwd: Option<PathBuf>,
    recorded: Option<PathBuf>,
    family: &str,
    cwd_map: &[(PathBuf, PathBuf)],
) -> Result<(PathBuf, Option<PathBuf>), RpcError> {
    let mut remapped_from = None;
    let cwd = match (cwd, recorded) {
        // Claude keeps a conversation under its cwd's project; resuming elsewhere finds nothing.
        // The client's folder is only its default (the page's private agent-home folder), so the
        // conversation's own folder wins while it exists (nxdog93: "cwd mismatch" on an
        // agent-home chat). A gone folder needs the person's pick (`needsFolder`), which must
        // stand in for it: a chat moved from another machine records that machine's folder.
        (Some(given), Some(recorded)) if family == "claude" && !same_dir(&given, &recorded) => {
            if recorded.is_dir() {
                recorded
            } else {
                let home = dirs::home_dir();
                remapped_cwd(&given, &recorded, cwd_map, home.as_deref()).map_err(|why| {
                    RpcError::invalid_params(format!(
                        "cwd {} does not match the adopted session's {}, which is gone: {why}",
                        given.display(),
                        recorded.display()
                    ))
                })?;
                remapped_from = Some(recorded);
                given
            }
        }
        (Some(given), _) => given,
        (None, Some(recorded)) => recorded,
        // Never the home folder by default: an agent there reads every
        // privacy-protected folder in it (LAUNCH-NO-TCC-PROMPTS). The app
        // gives a folder (the workspace's, or agent-home).
        (None, None) => {
            return Err(RpcError::invalid_params(
                "no folder for this session: pass a cwd (the workspace folder or an agent-home folder)",
            ));
        }
    };
    let cwd =
        if cwd.is_absolute() { cwd } else { std::env::current_dir().unwrap_or_default().join(cwd) };
    if !cwd.is_dir() {
        return Err(RpcError::invalid_params(format!("cwd {} is not a directory", cwd.display())));
    }
    Ok((cwd, remapped_from))
}

/// `session_cwd` and that folder's git branch and HEAD as the session starts
/// (`git_state.rs`). Both read the disk, so `session/new` runs this off the
/// async runtime.
pub(super) fn start_folder(
    cwd: Option<PathBuf>,
    recorded: Option<PathBuf>,
    family: &str,
    cwd_map: &[(PathBuf, PathBuf)],
) -> Result<(PathBuf, Option<PathBuf>, crate::git_state::GitState), RpcError> {
    let (cwd, remapped_from) = session_cwd(cwd, recorded, family, cwd_map)?;
    let git = crate::git_state::GitState::read(&cwd);
    Ok((cwd, remapped_from, git))
}

/// Ok when `given` stands in for the gone `recorded` folder of a chat moved
/// from another machine; else why not. `recorded` maps here through the first
/// `cwd_map` entry (`FROM=TO`) that holds it, else through a home swap
/// (`/home/<user>/…` or `/Users/<user>/…` onto `home`). An explicit map
/// accepts the folder it maps to; either way `given` may be another checkout
/// of that folder's repository: the same remote and the same path below the
/// repository root. Another repository or folder is refused.
pub(super) fn remapped_cwd(
    given: &Path,
    recorded: &Path,
    cwd_map: &[(PathBuf, PathBuf)],
    home: Option<&Path>,
) -> Result<(), String> {
    let explicit = cwd_map
        .iter()
        .find_map(|(from, to)| recorded.strip_prefix(from).ok().map(|rest| to.join(rest)));
    let (mapped, explicit) = match explicit {
        Some(mapped) => (mapped, true),
        None => match home.and_then(|home| home_swap(recorded, home)) {
            Some(mapped) => (mapped, false),
            None => return Err("no cwd map (FROM=TO) maps it onto this machine".into()),
        },
    };
    if !mapped.is_dir() {
        return Err(format!("{}, where it maps here, is not a folder either", mapped.display()));
    }
    if explicit && same_dir(&mapped, given) {
        return Ok(());
    }
    match (repo_identity(&mapped), repo_identity(given)) {
        (Some(want), Some(have)) if want == have => Ok(()),
        (Some((want_remote, want_path)), Some((have_remote, have_path))) => Err(format!(
            "{} is {have_remote} at {:?}, not {want_remote} at {:?} as {} is",
            given.display(),
            have_path,
            want_path,
            mapped.display()
        )),
        (None, _) => Err(format!(
            "{} is no git checkout with a remote; pass a cwd map (FROM=TO) to open it",
            mapped.display()
        )),
        (_, None) => Err(format!("{} is no git checkout with a remote", given.display())),
    }
}

/// `recorded` under another machine's home (`/home/<user>`, `/Users/<user>`)
/// moved under `home`.
fn home_swap(recorded: &Path, home: &Path) -> Option<PathBuf> {
    use std::path::Component;
    let mut parts = recorded.components();
    match (parts.next(), parts.next(), parts.next()) {
        (Some(Component::RootDir), Some(Component::Normal(top)), Some(Component::Normal(_)))
            if top == "home" || top == "Users" =>
        {
            Some(home.join(parts.as_path()))
        }
        _ => None,
    }
}

/// A folder's repository: its `origin` remote (else its first remote),
/// normalized, and its path below the repository root. `None` outside a git
/// checkout or without a remote.
fn repo_identity(dir: &Path) -> Option<(String, PathBuf)> {
    let git = |args: &[&str]| -> Option<String> {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            // An inherited repository would answer for every folder.
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        (out.status.success() && !text.is_empty()).then_some(text)
    };
    let top = std::fs::canonicalize(git(&["rev-parse", "--show-toplevel"])?).ok()?;
    let remote = git(&["remote", "get-url", "origin"]).or_else(|| {
        let first = git(&["remote"])?.lines().next()?.to_owned();
        git(&["remote", "get-url", &first])
    })?;
    let path = std::fs::canonicalize(dir).ok()?.strip_prefix(&top).ok()?.to_path_buf();
    Some((normalize_remote(&remote), path))
}

/// `scheme://[user@]host[:port]/path`, `[user@]host:path` and a local path
/// as `host/path`, the host lowercased, without a trailing `/` or `.git`:
/// `git@github.com:o/r.git` and `https://github.com/o/r` are one remote.
fn normalize_remote(url: &str) -> String {
    let url = url.trim();
    let host_of = |authority: &str| {
        let host = authority.rsplit('@').next().unwrap_or(authority);
        host.split(':').next().unwrap_or(host).to_ascii_lowercase()
    };
    let (host, path) = if let Some((_, rest)) = url.split_once("://") {
        let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
        (host_of(authority), path)
    } else if let Some((authority, path)) = url.split_once(':').filter(|(a, _)| !a.contains('/')) {
        (host_of(authority), path)
    } else {
        (String::new(), url)
    };
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path).trim_matches('/');
    format!("{host}/{path}")
}

/// The session in `sessions` that adopted `agent_session_id` in `family`.
pub(super) fn adopted_in(
    sessions: &HashMap<String, Arc<Session>>,
    family: &str,
    agent_session_id: &str,
) -> Option<Arc<Session>> {
    sessions
        .values()
        .find(|s| {
            let m = s.meta();
            m.family.as_deref() == Some(family)
                && m.agent_session_id.as_deref() == Some(agent_session_id)
        })
        .cloned()
}

/// True when both paths name one directory (`/tmp` and `/private/tmp`,
/// a trailing slash, a relative path).
fn same_dir(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

impl Hub {
    /// Appends the adopted conversation's past turns (`adopt_replay::read`) as this session's
    /// history, unless the session already shows some (a harness that sent history after its load).
    pub(super) async fn replay_adopted(&self, session: &Arc<Session>, family: &str, file: PathBuf) {
        // Stops at the first message; no other record is parsed.
        let mut has_history = false;
        let _ = self.store.scan_kinds(
            &session.id,
            &["user_message", "agent_message_chunk"],
            &mut |_| {
                has_history = true;
                false
            },
        );
        if has_history {
            return;
        }
        let fam = family.to_owned();
        let Ok(turns) =
            tokio::task::spawn_blocking(move || crate::adopt_replay::read(&fam, &file)).await
        else {
            return;
        };
        if turns.is_empty() {
            return;
        }
        // The chat's title and counts come from its past, as live turns set them (turns.rs).
        {
            let mut m = session.meta.lock().unwrap();
            if m.title.is_none()
                && let Some(first) = turns[0].prompt.lines().find(|l| !l.trim().is_empty())
            {
                m.title = Some(short_text(first.trim(), 80));
            }
            if let Some(last) = turns.last() {
                let line = super::prompt_line::prompt_line(&last.prompt, "adopt", None);
                m.last_prompt = Some(short_text(&line, 200));
            }
            m.turn_count += turns.len() as u64;
        }
        self.save_meta(session);
        let agent_sid = session.meta().agent_session_id.unwrap_or_default();
        let update = |fields: Value| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": agent_sid, "update": fields}});
        for (i, turn) in turns.iter().enumerate() {
            let turn_id = format!("adopted-{i}");
            let prompt_id = format!("adopted-prompt-{i}");
            // Each record keeps the transcript's time, so a fork through it cuts Claude's
            // transcript there (`fork_at.rs`) and the turn shows its real time. The turn ends
            // with its answer, or its last tool call when that ended later.
            let started = turn.prompt_at;
            let answered = turn.answer_at.or(started);
            let ended = turn.tools.iter().filter_map(|t| t.ended_at).chain(answered).max();
            let turn_seq = self
                .append_at(
                    session,
                    "mux",
                    "turn_started",
                    json!({"prompt": turn.prompt.chars().take(200).collect::<String>(), "client": "adopt", "promptId": prompt_id, "turnId": turn_id, "control": "local"}),
                    None,
                    started,
                )
                .0
                .seq;
            self.append_at(
                session,
                "mux",
                "user_message",
                json!({"text": turn.prompt, "client": "adopt", "promptId": prompt_id, "turnId": turn_id}),
                None,
                started,
            );
            // The turn's tool calls, before its answer, as a live turn sends them: each starts
            // running and its update settles it, so the pane folds them under "Worked for".
            for tool in &turn.tools {
                let start = tool.started_at.or(tool.ended_at).or(started);
                let mut call = tool.call.clone();
                call["sessionUpdate"] = json!("tool_call");
                call["toolCallId"] = json!(tool.id);
                call["status"] = json!("in_progress");
                self.append_at(session, "in", "tool_call", update(call), None, start);
                let mut done = tool.done.clone();
                done["sessionUpdate"] = json!("tool_call_update");
                done["toolCallId"] = json!(tool.id);
                self.append_at(
                    session,
                    "in",
                    "tool_call_update",
                    update(done),
                    None,
                    tool.ended_at.or(start),
                );
            }
            if !turn.answer.is_empty() {
                self.append_at(
                    session,
                    "in",
                    "agent_message_chunk",
                    update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": turn.answer}})),
                    None,
                    answered,
                );
            }
            self.append_at(
                session,
                "mux",
                "turn_end",
                json!({"stopReason": "end_turn", "turnId": turn_id, "turnSeq": turn_seq}),
                None,
                ended,
            );
            // A settled turn: clients and restart recovery read `turn_result`, not `turn_end`.
            self.append_at(
                session,
                "mux",
                "turn_result",
                json!({"status": "completed", "stopReason": "end_turn", "turnSeq": turn_seq, "turnId": turn_id, "promptId": prompt_id}),
                None,
                ended,
            );
        }
    }
}

// The tests name Unix paths of another machine.
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::process::Command;

    /// A fresh folder for one test, canonical (macOS's temp dir is a symlink).
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("acpmux-adopt-cwd-remap-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::canonicalize(dir).unwrap()
    }

    /// A git checkout at `dir` with a `sub` folder and `remote` as origin.
    fn checkout(dir: &Path, remote: &str) {
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        for args in [&["init", "-q"][..], &["remote", "add", "origin", remote]] {
            let ok = Command::new("git")
                .arg("-C")
                .arg(dir)
                .args(args)
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE")
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        }
    }

    /// Another machine's home, gone here.
    const GONE: &str = "/acpmux-gone-host/leo";

    fn map_to(root: &Path) -> Vec<(PathBuf, PathBuf)> {
        vec![(PathBuf::from(GONE), root.to_path_buf())]
    }

    #[test]
    fn adopt_cwd_remap_explicit_map_opens_the_mapped_folder() {
        let root = scratch("explicit");
        let given = root.join("Projects");
        std::fs::create_dir_all(&given).unwrap();
        let recorded = PathBuf::from(GONE).join("Projects");
        let got =
            session_cwd(Some(given.clone()), Some(recorded.clone()), "claude", &map_to(&root))
                .unwrap();
        assert_eq!(got, (given, Some(recorded)));
    }

    #[test]
    fn adopt_cwd_remap_accepts_another_checkout_of_the_same_repo() {
        let root = scratch("same-repo");
        checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
        checkout(&root.join("b"), "https://GitHub.com/manaflow-ai/cmux/");
        let recorded = PathBuf::from(GONE).join("a/sub");
        let given = root.join("b/sub");
        let got =
            session_cwd(Some(given.clone()), Some(recorded.clone()), "claude", &map_to(&root))
                .unwrap();
        assert_eq!(got, (given, Some(recorded)));
    }

    #[test]
    fn adopt_cwd_remap_refuses_another_repo() {
        let root = scratch("other-repo");
        checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
        checkout(&root.join("b"), "git@github.com:manaflow-ai/other.git");
        let recorded = PathBuf::from(GONE).join("a/sub");
        let err = session_cwd(Some(root.join("b/sub")), Some(recorded), "claude", &map_to(&root))
            .unwrap_err();
        assert!(err.message.contains("which is gone"), "{}", err.message);
    }

    #[test]
    fn adopt_cwd_remap_refuses_another_folder_of_the_same_repo() {
        let root = scratch("other-folder");
        checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
        checkout(&root.join("b"), "git@github.com:manaflow-ai/cmux.git");
        let recorded = PathBuf::from(GONE).join("a/sub");
        let err = session_cwd(Some(root.join("b")), Some(recorded), "claude", &map_to(&root))
            .unwrap_err();
        assert!(err.message.contains("which is gone"), "{}", err.message);
    }

    #[test]
    fn adopt_cwd_remap_home_swap_needs_the_same_repo() {
        let root = scratch("home-swap");
        checkout(&root.join("a"), "git@github.com:manaflow-ai/cmux.git");
        std::fs::create_dir_all(root.join("Projects")).unwrap();
        // Another machine's home maps onto this one's, for a checkout of one repo.
        let swapped =
            remapped_cwd(&root.join("a/sub"), Path::new("/home/leo/a/sub"), &[], Some(&root));
        assert_eq!(swapped, Ok(()));
        // A folder that is no checkout needs an explicit map.
        let plain =
            remapped_cwd(&root.join("Projects"), Path::new("/home/leo/Projects"), &[], Some(&root));
        assert!(plain.is_err());
        // A folder under no home maps nowhere.
        assert!(
            remapped_cwd(&root.join("a/sub"), Path::new("/srv/a/sub"), &[], Some(&root)).is_err()
        );
    }

    #[test]
    fn adopt_cwd_remap_gone_folder_without_a_map_is_refused() {
        let root = scratch("no-map");
        let err = session_cwd(
            Some(root.clone()),
            Some(PathBuf::from("/srv/acpmux-gone/x")),
            "claude",
            &[],
        )
        .unwrap_err();
        assert!(err.message.contains("which is gone"), "{}", err.message);
    }

    #[test]
    fn adopt_cwd_remap_reads_the_adopt_cwd_map() {
        let meta =
            json!({"adopt": {"agentSessionId": "abc", "cwdMap": ["/home/leo=/Users/leoli"]}});
        let adopt = AdoptRequest::from_meta(Some(&meta)).unwrap().unwrap();
        assert_eq!(
            adopt.cwd_map,
            vec![(PathBuf::from("/home/leo"), PathBuf::from("/Users/leoli"))]
        );
        let bad = json!({"adopt": {"agentSessionId": "abc", "cwdMap": ["home=/Users/leoli"]}});
        assert!(AdoptRequest::from_meta(Some(&bad)).is_err());
    }
}
