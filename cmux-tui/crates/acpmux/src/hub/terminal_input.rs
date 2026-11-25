//! Keys a chat types into the cmux terminal its conversation was handed to (Leo, 2026-11-15:
//! "what is our terminal/gui switch lol its not good enough to ship as is it doesnt have the
//! composer or anything?"). The terminal is the one `acpmux resume-here` ran in: the process the
//! kernel proved is the release's caller (`server/chats.rs` `release_to_watch`), and the cmux
//! terminal the environment its exec was given names (`CMUX_TUI_SOCKET`, `CMUX_TUI_TERMINAL_ID`,
//! which the session daemon sets on every terminal it starts and owns: no caller value reaches
//! them), read from the kernel (`/proc/<pid>/environ`, `KERN_PROCARGS2`), never from a request.
//!
//! - Stop: Esc, the key Claude Code and Codex both read as "interrupt the turn". Neither takes an
//!   interrupt from outside its terminal: Claude Code's inbox takes only messages, and the Codex a
//!   terminal runs holds its turn in its own process.
//! - A prompt while Claude Code takes no inbox message (`bridge.no_inbox`): a bracketed paste of
//!   its text, then Return as its own key, written only while that terminal's agent waits at its
//!   prompt in this very session (the session daemon's `expect_agent` check, made right before the
//!   write). Mid-turn it waits for the turn to end (`bridge.rs` `typed_later`), so nothing is lost.
//!
//! Every write goes through the session daemon's `send`, with `expect_foreground` set to the
//! bound process's executable: once that process no longer holds the terminal (it exited, the
//! shell took it back), nothing is written. The terminal is looked up by its id on each write
//! (`resolve-terminal`), so a terminal closed meanwhile refuses rather than another taking it.

use crate::store::TerminalDriver;
use serde_json::{Value, json};
use std::time::Duration;

/// Longest one exchange with the session daemon takes, connecting included.
// timeout: one local request to the cmux session daemon; a daemon that does not answer fails the Stop or send, which the person sees and can retry
const IO_TIMEOUT: Duration = Duration::from_secs(5);
/// The longest reply line read.
const MAX_REPLY: u64 = 256 * 1024;
/// The session daemon's refusal while the terminal's agent works, asks, or is another session.
pub(super) const NOT_WAITING: &str = "agent not waiting";

/// What a typed prompt came to ([`type_prompt`]).
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Typed {
    /// Pasted and submitted.
    Sent,
    /// Nothing written: the agent is not waiting at its prompt (mid-turn, asking).
    Busy,
    /// Nothing written, and trying again will not help: why.
    Failed(String),
}

/// The cmux terminal process `pid` runs in, by the environment its exec was given; none outside
/// one, or when it cannot be read.
#[cfg(unix)]
pub(super) fn of_process(pid: u32) -> Option<crate::store::TerminalInput> {
    let env = crate::agent_host::tree::environ(pid)?;
    let get = |key: &str| {
        env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone()).filter(|v| !v.is_empty())
    };
    Some(crate::store::TerminalInput {
        socket: get("CMUX_TUI_SOCKET")?.into(),
        terminal_id: get("CMUX_TUI_TERMINAL_ID")?,
    })
}

#[cfg(not(unix))]
pub(super) fn of_process(_pid: u32) -> Option<crate::store::TerminalInput> {
    None
}

/// Interrupts the turn the terminal `d` runs: Esc, written while the bound harness holds the
/// terminal. `Err` says why nothing was written.
pub(super) async fn interrupt(d: &TerminalDriver) -> Result<(), String> {
    let esc = base64_of(b"\x1b");
    write(d, json!({"bytes": esc})).await
}

/// Types `text` into the terminal `d` as one prompt of agent session `session`: a bracketed
/// paste, then Return, only while the agent waits at its prompt.
pub(super) async fn type_prompt(d: &TerminalDriver, session: &str, text: &str) -> Typed {
    let params =
        json!({"text": text, "paste": true, "submit": true, "expect_agent": {"session": session}});
    match write(d, params).await {
        Ok(()) => Typed::Sent,
        Err(e) if e.contains(NOT_WAITING) => Typed::Busy,
        Err(e) => Typed::Failed(e),
    }
}

/// One `send` of `params` to the terminal `d`, under the foreground check.
async fn write(d: &TerminalDriver, mut params: Value) -> Result<(), String> {
    let input = d.input.as_ref().ok_or(
        "this chat's terminal is not a cmux terminal, so it takes no keys from the chat: press Esc there",
    )?;
    let pid = d.pid;
    let expected =
        tokio::task::spawn_blocking(move || cmux_tui_platform::platform::process_executable(pid))
            .await
            .ok()
            .flatten()
            .ok_or("the terminal's harness is not running")?;
    let socket = input.socket.clone();
    let terminal = input.terminal_id.clone();
    let run = async move {
        let mut link = Link::connect(&socket).await?;
        let resolved =
            link.call(json!({"cmd": "resolve-terminal", "terminal_id": terminal})).await?;
        let surface = resolved
            .get("surface")
            .filter(|s| !s.is_null())
            .cloned()
            .ok_or("the chat's terminal is not open in cmux now")?;
        if let Some(p) = params.as_object_mut() {
            p.insert("cmd".into(), json!("send"));
            p.insert("surface".into(), surface);
            p.insert("expect_foreground".into(), json!(expected));
        }
        link.call(params).await.map(drop)
    };
    tokio::time::timeout(IO_TIMEOUT, run)
        .await
        .unwrap_or_else(|_| Err("the cmux session daemon did not answer in time".into()))
}

fn base64_of(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// One connection to a cmux session daemon (its JSON-line protocol: `{"id","cmd",...}` in,
/// `{"id","ok","data"|"error"}` out).
#[cfg(unix)]
struct Link {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::io::Take<tokio::net::unix::OwnedReadHalf>>>,
    out: tokio::net::unix::OwnedWriteHalf,
    next: u64,
}

#[cfg(unix)]
impl Link {
    async fn connect(socket: &std::path::Path) -> Result<Self, String> {
        use tokio::io::AsyncReadExt as _;
        let stream = tokio::net::UnixStream::connect(socket)
            .await
            .map_err(|e| format!("could not reach the cmux session daemon: {e}"))?;
        let (read, out) = stream.into_split();
        let lines =
            tokio::io::AsyncBufReadExt::lines(tokio::io::BufReader::new(read.take(MAX_REPLY)));
        Ok(Self { lines, out, next: 1 })
    }

    /// Sends `request` and returns its answer's `data`, or its `error`.
    async fn call(&mut self, mut request: Value) -> Result<Value, String> {
        use tokio::io::AsyncWriteExt as _;
        let id = self.next;
        self.next += 1;
        if let Some(r) = request.as_object_mut() {
            r.insert("id".into(), json!(id));
        }
        let mut line = request.to_string();
        line.push('\n');
        self.out
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("could not write to the cmux session daemon: {e}"))?;
        loop {
            let reply = self
                .lines
                .next_line()
                .await
                .map_err(|e| format!("could not read the cmux session daemon: {e}"))?
                .ok_or("the cmux session daemon closed the connection")?;
            let Ok(reply) = serde_json::from_str::<Value>(&reply) else { continue };
            if reply.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if reply.get("ok").and_then(Value::as_bool) == Some(true) {
                return Ok(reply.get("data").cloned().unwrap_or(Value::Null));
            }
            let error = reply.get("error").and_then(Value::as_str).unwrap_or("refused");
            return Err(format!("the cmux session daemon refused: {error}"));
        }
    }
}

#[cfg(not(unix))]
struct Link;

#[cfg(not(unix))]
impl Link {
    async fn connect(_: &std::path::Path) -> Result<Self, String> {
        Err("typing into a cmux terminal is Unix-only".into())
    }

    async fn call(&mut self, _: Value) -> Result<Value, String> {
        Err("typing into a cmux terminal is Unix-only".into())
    }
}

/// Most prompts waiting for a terminal's turn to end before they are typed (per chat).
const MAX_WAITING: usize = 64;
/// How long a waiting prompt sleeps between looks when no turn end woke it: the session daemon's
/// agent state can turn idle a moment after the transcript's end, and an asked question ends
/// with no transcript line.
const RELOOK: Duration = Duration::from_millis(500);

/// Prompts waiting to be typed, per chat id: (delivery uuid, text), oldest first.
static WAITING: std::sync::LazyLock<
    std::sync::Mutex<
        std::collections::HashMap<String, std::collections::VecDeque<(String, String)>>,
    >,
> = std::sync::LazyLock::new(Default::default);
/// Woken whenever a watched turn ends (`watch.rs`), so a waiting prompt is typed at once.
static TURN_ENDED: tokio::sync::Notify = tokio::sync::Notify::const_new();

fn waiting() -> std::sync::MutexGuard<
    'static,
    std::collections::HashMap<String, std::collections::VecDeque<(String, String)>>,
> {
    WAITING.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// A watched turn ended: a prompt waiting to be typed tries now.
pub(super) fn turn_ended() {
    TURN_ENDED.notify_waiters();
}

/// Why a prompt that waited to be typed was dropped (`drop_typed`).
pub(super) const WRITABLE_OFF: &str = "Write to a Chat a Terminal Runs was turned off before the \
     terminal's turn ended, so this message was not typed into the terminal; send it there, or \
     take the chat over";

impl super::Hub {
    /// Drops the prompts waiting to be typed into `session`'s terminal (the setting went off,
    /// `release_to_watch.rs`): each one's sender gets the failure with why (the pane keeps the
    /// prompt as a Not sent row with Retry), and every other client a `prompt_refused` notice.
    /// None was typed, so none runs later behind the person's back.
    pub(super) fn drop_typed(&self, session: &super::Session) {
        let dropped = waiting().remove(&session.id).unwrap_or_default();
        for (uuid, _) in dropped {
            self.refuse_writable_off(session, &uuid);
        }
        // The typing loop wakes, finds nothing left and ends.
        turn_ended();
    }

    /// Fails delivery `uuid` as dropped because the setting went off: its sender gets why, every
    /// other client a `prompt_refused` notice. Nothing when it was already answered.
    fn refuse_writable_off(&self, session: &super::Session, uuid: &str) {
        let Some(prompt_id) = super::bridge::fail_delivery_of(uuid, WRITABLE_OFF) else {
            return;
        };
        let error = format!("terminal.writable_off: {WRITABLE_OFF}");
        let data = json!({"reason": "terminal.writable_off"});
        let msg = json!({"promptId": prompt_id, "error": error, "data": data});
        self.append(session, "mux", "prompt_refused", msg);
    }

    /// Types delivery `uuid` (`wire`) into the terminal `d` drives `session` from: now when its
    /// agent waits at its prompt, else once its turn ends, behind any prompt already waiting, so
    /// none is lost or reordered. `Err` only when nothing was or will be typed.
    pub(super) async fn type_into(
        self: &std::sync::Arc<Self>,
        session: &std::sync::Arc<super::Session>,
        d: &TerminalDriver,
        agent_session: &str,
        uuid: &str,
        wire: &str,
    ) -> Result<(), String> {
        if !self.terminal_chat_writable() {
            self.refuse_writable_off(session, uuid);
            return Err(WRITABLE_OFF.to_owned());
        }
        let queued = waiting().get(&session.id).is_some_and(|q| !q.is_empty());
        if !queued {
            match type_prompt(d, agent_session, wire).await {
                Typed::Sent => return Ok(()),
                Typed::Failed(e) => return Err(e),
                Typed::Busy => {}
            }
        }
        let start = {
            let mut all = waiting();
            let q = all.entry(session.id.clone()).or_default();
            if q.len() >= MAX_WAITING {
                return Err("too many prompts already wait for the terminal's turn to end".into());
            }
            q.push_back((uuid.to_owned(), wire.to_owned()));
            q.len() == 1
        };
        // The setting can go off while this send was on its way here, after `drop_typed` emptied
        // the queue: the flag goes off before that drop, so one of the two sees it and drops it.
        if !self.terminal_chat_writable() {
            let mine = waiting().get_mut(&session.id).and_then(|q| {
                let at = q.iter().position(|(u, _)| u == uuid)?;
                q.remove(at)
            });
            if mine.is_some() {
                self.refuse_writable_off(session, uuid);
                turn_ended();
                return Err(WRITABLE_OFF.to_owned());
            }
            // `drop_typed` took it and answered it already.
            return Ok(());
        }
        if start {
            let (session, d, agent_session) =
                (session.clone(), d.clone(), agent_session.to_owned());
            self.scope.spawn_named("terminal-typing", async move {
                type_waiting(&session, &d, &agent_session).await;
            });
        }
        Ok(())
    }

    /// The chat's Stop while a terminal drives it: Esc into that terminal while a watched turn
    /// runs (`interrupt`). `None` for any other chat.
    pub(super) async fn stop_in_terminal(
        &self,
        session: &super::Session,
    ) -> Option<Result<(), crate::rpc::RpcError>> {
        let w = session.meta().watching?;
        let d = w.terminal.filter(|_| self.terminal_chat_writable())?;
        if w.open.is_none() {
            // No turn runs there: an Esc would only clear what the person is typing.
            return Some(Ok(()));
        }
        Some(interrupt(&d).await.map_err(|e| {
            crate::rpc::RpcError::new(-32000, format!("terminal.stop: {e}"))
                .with_data(json!({"reason": "terminal.stop"}))
        }))
    }
}

/// Types the prompts waiting for `session`'s terminal, oldest first, each once its agent waits at
/// its prompt; ends when none waits. One per chat at a time (`type_into` starts it).
async fn type_waiting(session: &super::Session, d: &TerminalDriver, agent_session: &str) {
    loop {
        let head = waiting().get(&session.id).and_then(|q| q.front().cloned());
        let Some((uuid, wire)) = head else {
            waiting().remove(&session.id);
            return;
        };
        let bound = session.meta().watching.and_then(|w| w.terminal).as_ref() == Some(d);
        let typed = if bound {
            type_prompt(d, agent_session, &wire).await
        } else {
            Typed::Failed("the terminal stopped running this chat before it ran".into())
        };
        match typed {
            Typed::Busy => {
                let woken = TURN_ENDED.notified();
                // poll: bounded by the queue's life (the terminal's binding); the session daemon
                // has no event for its agent turning idle, so a missed wake looks again.
                let _ = tokio::time::timeout(RELOOK, woken).await;
                continue;
            }
            Typed::Sent => {}
            Typed::Failed(e) => super::bridge::fail_delivery(&uuid, &e),
        }
        let mut all = waiting();
        if let Some(q) = all.get_mut(&session.id) {
            q.pop_front();
        }
    }
}
