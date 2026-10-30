//! The hook child's side of `session.journal.append`: every hook event of
//! one agent goes into that agent's queue on disk ([`super::hook_spool`]),
//! and one child at a time sends the queue in order over one connection,
//! waiting for each receipt.
//!
//! Why (#27698): with about 80 agents, every hook call opened its own
//! connection, the daemon refused 55,162 of them in 2.5 h, and the child
//! took the busy line for an invalid answer and dropped the event. A child
//! that failed to connect retried in a `yield_now` spin for 4 s, then gave
//! up and dropped the event too.
//!
//! - Order: one sender per agent (the child holding the queue's drain lock),
//!   lines in the order the provider ran the hooks.
//! - No loss: a line leaves the queue only when the daemon answered it with a
//!   receipt or a durable rejection. A busy daemon (its busy line, a
//!   retryable answer, a dropped connection) is retried through
//!   `RetryBudget`: full-jitter exponential backoff with the daemon's
//!   `retry_after_ms` as a floor.
//! - No timer decides delivery (rule R-L5): the sender stops when the queue is
//!   empty or the daemon is gone. A daemon that refuses the connection but
//!   keeps its socket file did not end its session: the lines stay queued,
//!   and the next hook child of any agent of the session sends them (again,
//!   with their idempotency keys; the daemon answers a repeat from its
//!   receipt). A daemon that removed its socket ended its session: the lines
//!   are dropped and counted where `server-stats` (`hook_queue`) shows them
//!   ([`super::hook_spool`] has the queue's lifecycle).
//! - The provider waits only for its own line to be written to the daemon,
//!   or to be queued behind lines a sender is already working on (the
//!   parent's `HANDOFF_WAIT` bounds that wait).
//!
//! The socket helpers at the end serve the single-try inbox requests.

use std::borrow::Cow;
use std::cell::Cell;

use cmux_tui_core::backoff::RetryBudget;

use super::hook_spool::{DrainLock, Found, Spool};
use super::*;

/// The most the first retry waits, beyond the daemon's `retry_after_ms`. A
/// hook connection holds its slot for one request (milliseconds), so slots
/// free up within this; the draw spreads hooks refused together over it.
const RETRY_INITIAL: Duration = Duration::from_millis(100);
/// The most one retry waits, beyond the daemon's `retry_after_ms`: the
/// longest a sender stays behind a daemon that has a free slot again.
const RETRY_MAX: Duration = Duration::from_secs(1);

/// Queues the request line `encoded` (whose id is `request_id`) behind the
/// agent's earlier hook events and, when no other child sends that queue,
/// sends it until it is empty. `on_sent` runs once: when this line was
/// written to the daemon, or queued behind lines another sender works on.
/// An error: the session is gone, or the daemon rejected this line.
pub(super) fn append_with_receipt(
    socket: &Path,
    request_id: &str,
    encoded: &[u8],
    on_sent: &dyn Fn(),
) -> anyhow::Result<()> {
    if !socket.exists() {
        // No socket: this terminal's session ended. Its queues can never be
        // sent; drop and count them.
        let _ = sweep(socket, None);
        bail!("session socket {} is gone", socket.display());
    }
    let spool = Spool::for_request(socket, encoded).context("open the agent's hook queue")?;
    let signaled = Cell::new(false);
    let signal = || {
        if !signaled.replace(true) {
            on_sent();
        }
    };
    if spool.append(encoded).context("queue the hook event")? {
        signal();
    }
    let Some(lock) = spool.try_drain().context("lock the agent's hook queue")? else {
        // Another child sends this queue, this line included.
        signal();
        return Ok(());
    };
    let mut sender = Sender::new(socket);
    let outcome = drain(&spool, lock, &mut sender, request_id, &signal);
    signal();
    // Best effort: a queue this child cannot clean now is cleaned by the next
    // hook child, and its own event's outcome stands either way.
    let _ = sweep(socket, Some(&spool));
    outcome
}

/// The other queues beside `socket`: sends those of the live session that no
/// child sends, and drops (and counts) those whose session ended.
fn sweep(socket: &Path, except: Option<&Spool>) -> std::io::Result<()> {
    let alive = socket.exists();
    let mut sender = Sender::new(socket);
    for found in super::hook_spool::orphans(socket, except)? {
        let (spool, send) = match found {
            Found::Live(spool) => (spool, alive),
            Found::Ended(spool) => (spool, false),
        };
        let Some(lock) = spool.try_drain()? else {
            // Its sender is at work.
            continue;
        };
        if send {
            // Another agent's events: their outcome is theirs.
            let _ = drain(&spool, lock, &mut sender, "", &|| {});
        } else {
            spool.discard(0, lock)?;
        }
    }
    Ok(())
}

/// Sends the queue from its start until it is empty, then lets go of `lock`.
fn drain(
    spool: &Spool,
    mut lock: DrainLock,
    sender: &mut Sender,
    request_id: &str,
    signal: &dyn Fn(),
) -> anyhow::Result<()> {
    let mut offset = 0;
    let mut own_rejection = None;
    loop {
        let Some((line, next)) = spool.line_at(offset)? else {
            match spool.finish(offset, lock)? {
                Some(still_held) => {
                    lock = still_held;
                    continue;
                }
                None => return own_rejection.map_or(Ok(()), Err),
            }
        };
        let own = line_id(&line).as_deref() == Some(request_id);
        match sender.deliver(&line, &|| {
            if own {
                signal();
            }
        }) {
            Delivered::Answered => {}
            Delivered::Rejected(error) if own => own_rejection = Some(error),
            Delivered::Rejected(_) => {}
            Delivered::Gone(error) => {
                if sender.socket.exists() {
                    // Not answering, but its session did not end (a daemon
                    // that stopped without ending it starts it again on the
                    // same socket): the rest waits for the next hook.
                    spool.compact(offset)?;
                } else {
                    // The daemon removed its socket: the session ended, and
                    // nothing can take these events. Count them as dropped.
                    spool.discard(offset, lock)?;
                }
                return Err(error);
            }
        }
        offset = next;
    }
}

/// The `id` of a queued request line.
fn line_id(line: &[u8]) -> Option<String> {
    let request: Value = serde_json::from_slice(line).ok()?;
    request.get("id")?.as_str().map(str::to_owned)
}

/// What became of one queued line.
enum Delivered {
    /// The daemon committed it (or answered a repeat from its receipt).
    Answered,
    /// The daemon (or the line itself) can never take it; it leaves the queue.
    Rejected(anyhow::Error),
    /// The session is gone: the line stays queued.
    Gone(anyhow::Error),
}

/// One connection to the daemon, kept across the lines of a queue.
struct Sender {
    socket: PathBuf,
    connection: Option<BufReader<Box<dyn transport::Stream>>>,
    retries: RetryBudget,
}

impl Sender {
    fn new(socket: &Path) -> Self {
        Self {
            socket: socket.to_path_buf(),
            connection: None,
            retries: RetryBudget::new(RETRY_INITIAL, RETRY_MAX),
        }
    }

    /// Sends `line` until the daemon answers it or is gone. `on_written` runs
    /// after each full write.
    fn deliver(&mut self, line: &[u8], on_written: &dyn Fn()) -> Delivered {
        let Some(request_id) = line_id(line) else {
            return Delivered::Rejected(anyhow!("a queued hook event is not a request line"));
        };
        // A daemon from before `live_prompt` refuses unknown parameters: the event goes once more
        // without the prompt, so a version skew never loses a turn start (the prompt is optional).
        let mut current = Cow::Borrowed(line);
        loop {
            match self.try_once(&current, &request_id, on_written) {
                Ok(()) => {
                    self.retries.reset();
                    return Delivered::Answered;
                }
                Err(Try::Rejected(error)) if error.to_string().contains("unknown parameters") => {
                    match without_live_prompt(&current) {
                        Some(stripped) => current = Cow::Owned(stripped),
                        None => return Delivered::Rejected(error),
                    }
                }
                Err(Try::Rejected(error)) => {
                    self.retries.reset();
                    return Delivered::Rejected(error);
                }
                Err(Try::Gone(error)) => return Delivered::Gone(error),
                Err(Try::Again(error)) => {
                    self.connection = None;
                    let retry_after =
                        error.downcast_ref::<Busy>().and_then(|busy| busy.retry_after);
                    // No budget: a busy daemon is waited out (the module doc).
                    self.retries.sleep(retry_after);
                }
            }
        }
    }

    fn try_once(
        &mut self,
        line: &[u8],
        request_id: &str,
        on_written: &dyn Fn(),
    ) -> Result<(), Try> {
        let mut connection = match self.connection.take() {
            Some(connection) => connection,
            None => BufReader::new(transport::connect(&self.socket).map_err(|error| {
                let retry = matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted
                        | io::ErrorKind::WouldBlock
                        | io::ErrorKind::TimedOut
                );
                let error = anyhow!(error).context(format!("connect to {}", self.socket.display()));
                // No listener: this terminal is not attached to a live cmux-tui
                // now. The line stays queued for the agent's next hook.
                if retry { Try::Again(error) } else { Try::Gone(error) }
            })?),
        };
        let outcome = exchange(&mut connection, line, request_id, on_written);
        if !matches!(outcome, Err(Try::Again(_))) {
            // The daemon answered on it: the next line goes on the same one.
            self.connection = Some(connection);
        }
        outcome
    }
}

/// Writes `line` on `connection` and reads the daemon's answer to it.
fn exchange(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
    line: &[u8],
    request_id: &str,
    on_written: &dyn Fn(),
) -> Result<(), Try> {
    let written = connection.get_mut().write_all(line).and_then(|()| connection.get_mut().flush());
    if let Err(error) = written {
        // A daemon at its limit writes its busy line and closes at once, so
        // the write can fail while the busy line waits to be read.
        let closed =
            matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset);
        let busy = closed.then(|| read_reply(connection).ok().flatten()).flatten();
        return Err(Try::Again(match busy.as_deref().and_then(parse_busy) {
            Some(busy) => busy.into(),
            None => anyhow!(error).context("write the hook event"),
        }));
    }
    on_written();
    // The receipt, or the connection's close: the daemon's answer is the
    // signal, so no timer cuts the wait (a slow daemon still answers).
    let reply = read_reply(connection)
        .map_err(|error| Try::Again(anyhow!(error).context("read the journal receipt")))?
        .ok_or_else(|| Try::Again(anyhow!("journal append closed without a complete response")))?;
    check_receipt(&reply, request_id)
}

/// Why one try failed.
enum Try {
    /// Busy, dropped or unanswered: the same line goes again after a backoff.
    Again(anyhow::Error),
    /// A durable answer: the line can never be taken.
    Rejected(anyhow::Error),
    /// The session is gone.
    Gone(anyhow::Error),
}

/// One reply line, or `None` when the daemon closed first.
fn read_reply(
    connection: &mut BufReader<Box<dyn transport::Stream>>,
) -> io::Result<Option<Vec<u8>>> {
    let mut reply = Vec::new();
    connection.by_ref().take(MAX_RESPONSE_BYTES as u64 + 1).read_until(b'\n', &mut reply)?;
    Ok(reply.ends_with(b"\n").then_some(reply))
}

fn parse_busy(reply: &[u8]) -> Option<Busy> {
    busy_line(&serde_json::from_slice(reply).ok()?)
}

/// What the daemon's answer to `request_id` says.
fn check_receipt(reply: &[u8], request_id: &str) -> Result<(), Try> {
    let response: Value = serde_json::from_slice(reply)
        .map_err(|error| Try::Rejected(anyhow!(error).context("read the journal receipt")))?;
    if let Some(busy) = busy_line(&response) {
        return Err(Try::Again(busy.into()));
    }
    if response.get("protocol").and_then(Value::as_str) != Some("cmux.protocol/2")
        || response.get("type").and_then(Value::as_str) != Some("response")
    {
        return Err(Try::Rejected(anyhow!("journal append returned an invalid response envelope")));
    }
    if response.get("id").and_then(Value::as_str) != Some(request_id) {
        return Err(Try::Rejected(anyhow!("journal append returned a mismatched request id")));
    }
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    let error = response.get("error");
    let message = error
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .unwrap_or("journal append failed");
    if error.and_then(|error| error.get("retryable")).and_then(Value::as_bool) == Some(true) {
        let retry_after_ms = error
            .and_then(|error| error.get("details"))
            .and_then(|details| details.get("retry_after_ms"));
        Err(Try::Again(Busy::from_reply(message, retry_after_ms).into()))
    } else {
        Err(Try::Rejected(anyhow!(message.to_owned())))
    }
}

/// `encoded` (one request line) without its memory-only fields (`live_prompt`, `live_reply`,
/// `live_question`); nil when it has none.
fn without_live_prompt(encoded: &[u8]) -> Option<Vec<u8>> {
    let mut request: Value = serde_json::from_slice(encoded).ok()?;
    let params = request.get_mut("params")?.as_object_mut()?;
    let removed = ["live_prompt", "live_reply", "live_question"]
        .into_iter()
        .filter(|field| params.remove(*field).is_some())
        .count();
    if removed == 0 {
        return None;
    }
    let mut line = serde_json::to_vec(&request).ok()?;
    line.push(b'\n');
    Some(line)
}

/// A failed try of a single-try request (the inbox).
#[derive(Debug)]
pub(super) enum AppendAttemptError {
    Retryable(anyhow::Error),
    Fatal(anyhow::Error),
}

/// The daemon refused the request (its busy line, or a retryable error
/// answer) and may have said when to try again.
#[derive(Debug)]
pub(super) struct Busy {
    message: String,
    retry_after: Option<Duration>,
}

impl Busy {
    /// A refusal with its `message` and the daemon's `retry_after_ms`, if any.
    fn from_reply(message: &str, retry_after_ms: Option<&Value>) -> Self {
        Self {
            message: message.to_owned(),
            retry_after: retry_after_ms.and_then(Value::as_u64).map(Duration::from_millis),
        }
    }
}

impl std::fmt::Display for Busy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for Busy {}

/// The daemon's busy line (`server/listen.rs` `REFUSED_BUSY_LINE`): it is at
/// its connection limit, read nothing, and closed.
pub(super) fn busy_line(reply: &Value) -> Option<Busy> {
    (reply.get("protocol").and_then(Value::as_str) == Some("cmux.protocol/2")
        && reply.get("type").and_then(Value::as_str) == Some("refused"))
    .then(|| {
        let message = reply.get("message").and_then(Value::as_str).unwrap_or("the session is busy");
        Busy::from_reply(message, reply.get("retry_after_ms"))
    })
}

pub(super) fn remaining_before(deadline: Instant) -> Result<Duration, AppendAttemptError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(AppendAttemptError::Retryable(anyhow!("journal append deadline expired")))
    } else {
        Ok(remaining)
    }
}

pub(super) fn connect_before(
    socket: &Path,
    deadline: Instant,
) -> Result<Box<dyn transport::Stream>, AppendAttemptError> {
    let remaining = remaining_before(deadline)?;
    let socket = socket.to_path_buf();
    let display = socket.display().to_string();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let connector = std::thread::Builder::new()
        .name("journal-hook-connect".into())
        .spawn(move || {
            let _ = sender.send(transport::connect(&socket));
        })
        .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
    let result = match receiver.recv_timeout(remaining) {
        Ok(result) => {
            let _ = connector.join();
            result
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            let _ = connector.join();
            return Err(AppendAttemptError::Retryable(anyhow!(
                "journal socket connector stopped without a result"
            )));
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            // This helper is a short-lived process. Dropping the join handle is
            // safe here because the inbox request ends at this deadline and main
            // exits, which terminates the blocked connector.
            drop(connector);
            return Err(AppendAttemptError::Retryable(anyhow!("connect to {display} timed out")));
        }
    };
    result.map_err(|error| {
        let transient = matches!(
            error.kind(),
            io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
        );
        let error = anyhow!(error).context(format!("connect to {display}"));
        if transient {
            AppendAttemptError::Retryable(error)
        } else {
            // No listener means this terminal is no longer attached to a live
            // cmux-tui. Retrying a stale path only delays synchronous providers.
            AppendAttemptError::Fatal(error)
        }
    })
}

pub(super) fn write_before(
    stream: &mut dyn transport::Stream,
    encoded: &[u8],
    deadline: Instant,
) -> Result<(), AppendAttemptError> {
    let mut offset = 0;
    while offset < encoded.len() {
        stream
            .set_write_timeout(Some(remaining_before(deadline)?))
            .map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        match stream.write(&encoded[offset..]) {
            Ok(0) => {
                return Err(AppendAttemptError::Retryable(
                    io::Error::from(io::ErrorKind::WriteZero).into(),
                ));
            }
            Ok(written) => offset += written,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
    loop {
        // The request is fully written. A fast server may already have
        // answered and closed, which makes macOS refuse the option; the
        // timeout set for the writes still bounds the flush.
        let _ = stream.set_write_timeout(Some(remaining_before(deadline)?));
        match stream.flush() {
            Ok(()) => return Ok(()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(AppendAttemptError::Retryable(error.into())),
        }
    }
}

pub(super) fn read_before(
    stream: Box<dyn transport::Stream>,
    deadline: Instant,
) -> Result<Vec<u8>, AppendAttemptError> {
    let mut reader = BufReader::new(stream);
    let mut response = Vec::new();
    loop {
        // Shrink the bound toward the deadline. A refusal means the server
        // already closed (macOS EINVAL), so the read cannot block; the
        // timeout set before the request was written still applies.
        let _ = reader.get_ref().set_read_timeout(Some(remaining_before(deadline)?));
        let available =
            reader.fill_buf().map_err(|error| AppendAttemptError::Retryable(error.into()))?;
        if available.is_empty() {
            return Err(AppendAttemptError::Retryable(anyhow!(
                "journal append closed without a complete response"
            )));
        }
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |newline| newline + 1);
        if response.len().saturating_add(consumed) > MAX_RESPONSE_BYTES {
            return Err(AppendAttemptError::Fatal(anyhow!(
                "journal append response exceeds 16 MiB"
            )));
        }
        let complete = available[consumed - 1] == b'\n';
        response.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if complete {
            return Ok(response);
        }
    }
}

#[cfg(all(test, unix))]
#[path = "journal_append_tests.rs"]
mod tests;
