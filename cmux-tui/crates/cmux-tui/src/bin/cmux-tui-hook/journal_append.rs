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
//! - No loss: a line leaves the queue only when a daemon answered it with a
//!   receipt or a durable rejection. A busy daemon (its busy line, a
//!   retryable answer, a dropped connection) is retried through
//!   `RetryBudget`: full-jitter exponential backoff with the daemon's
//!   `retry_after_ms` as a floor.
//! - No timer decides delivery (rule R-L5): the sender stops when its queue
//!   is empty, or when no daemon listens (the socket is missing or refuses
//!   the connection: the owner stopped, restarts or crashed). Then the lines
//!   stay queued: the next owner sends them when it attaches (`resume`), and
//!   so does the next hook child of any agent of the session (again, with
//!   their idempotency keys; a daemon answers a repeat from its receipt).
//!   On macOS a live daemon whose listen backlog is full also refuses a
//!   connect: the lines then wait for the next hook of the session (seconds
//!   under that load); none is lost. Only `reset-state` ends a session's
//!   queues ([`super::hook_spool`] has the lifecycle).
//! - The provider waits only until its line is on disk (the parent's
//!   `HANDOFF_WAIT` bounds that wait). Where the socket's directory is not
//!   private, there is no queue: the child sends its line directly, and the
//!   provider waits until it is written.
//!
//! The socket helpers at the end serve the single-try inbox requests.

use std::borrow::Cow;

use cmux_tui_core::backoff::RetryBudget;

use super::hook_spool::{DrainLock, Spool};
use super::*;

/// The most the first retry waits, beyond the daemon's `retry_after_ms`. A
/// hook connection holds its slot for one request (milliseconds), so slots
/// free up within this; the draw spreads hooks refused together over it.
const RETRY_INITIAL: Duration = Duration::from_millis(100);
/// The most one retry waits, beyond the daemon's `retry_after_ms`: the
/// longest a sender stays behind a daemon that has a free slot again.
const RETRY_MAX: Duration = Duration::from_secs(1);
/// Tries in a row in which a live daemon took a line and never answered it
/// (it closed on it, or let `RECEIPT_WAIT` pass) before the sender gives the
/// line up and counts it (R-L4: a budget; R-L5: the loss shows). A daemon
/// that stops mid-request costs one; the next connect then finds it gone,
/// which keeps the line instead.
const UNANSWERED_TRIES: u32 = 3;
/// The longest a sender waits for one receipt: past the daemon's own
/// longest wait for a journal append, so a slow but working daemon always
/// answers first (R-L5: the client's deadline is at least the server's).
#[cfg(not(test))]
const RECEIPT_WAIT: Duration =
    cmux_tui_core::diagnostics::JOURNAL_APPEND_LONGEST_WAIT.saturating_add(Duration::from_secs(30));
#[cfg(test)]
const RECEIPT_WAIT: Duration = Duration::from_millis(300);

/// Queues the request line `encoded` (whose id is `request_id`) behind the
/// agent's earlier hook events and, when no other child sends that queue,
/// sends it until it is empty, then the session's other unsent queues.
/// `on_sent` runs once the line is safe: queued, or (with no queue) written
/// to the daemon. An error: no daemon listens, or the daemon rejected this
/// line.
pub(super) fn append_with_receipt(
    socket: &Path,
    request_id: &str,
    encoded: &[u8],
    on_sent: &dyn Fn(),
) -> anyhow::Result<()> {
    let Ok(spool) = Spool::for_request(socket, encoded) else {
        return send_unqueued(socket, encoded, on_sent);
    };
    if spool.append(encoded).is_err() {
        return send_unqueued(socket, encoded, on_sent);
    }
    on_sent();
    let Some(lock) = spool.try_drain().context("lock the agent's hook queue")? else {
        // Another child sends this queue, this line included.
        return Ok(());
    };
    let mut sender = Sender::new(socket);
    let outcome = drain(&spool, lock, &mut sender, request_id);
    if !sender.gone {
        // Best effort: what this child cannot send now waits for the next.
        let _ = send_session_queues_with(socket, Some(&spool), &mut sender);
    }
    outcome
}

/// Sends every queue of the session on `socket` that no child sends: what
/// its new owner runs once it attaches, so events a restart left queued go
/// out without waiting for some agent's next hook.
pub(super) fn send_session_queues(socket: &Path) {
    let _ = send_session_queues_with(socket, None, &mut Sender::new(socket));
}

/// With no private queue directory (or a queue this child could not append
/// to): sends the line itself, as one sender. Such a line can arrive before
/// older lines of its agent that a sender still holds; only a planted file or
/// a full disk gets here. With no daemon, the event is lost and nothing counts
/// it (there is nowhere private to count): this path is the shared-directory
/// and non-Unix one.
fn send_unqueued(socket: &Path, encoded: &[u8], on_sent: &dyn Fn()) -> anyhow::Result<()> {
    match Sender::new(socket).deliver(encoded, on_sent) {
        Delivered::Answered => Ok(()),
        Delivered::Rejected(error) | Delivered::Unanswered(error) | Delivered::Gone(error) => {
            Err(error)
        }
    }
}

/// The session's queues (but `except`) that no child sends (their sender
/// died, or their daemon was down): sent to this daemon.
fn send_session_queues_with(
    socket: &Path,
    except: Option<&Spool>,
    sender: &mut Sender,
) -> io::Result<()> {
    for spool in hook_spool::session_queues(socket, except)? {
        let Some(lock) = spool.try_drain()? else {
            // Its sender is at work.
            continue;
        };
        // Another agent's events: their outcome is theirs.
        let _ = drain(&spool, lock, sender, "");
        if sender.gone {
            break;
        }
    }
    Ok(())
}

/// Sends the queue from its start until it is empty, then lets go of `lock`.
/// No daemon: keeps the unsent lines and stops. The error is this child's own
/// line's (`request_id`): rejected, or not sent.
fn drain(
    spool: &Spool,
    mut lock: DrainLock,
    sender: &mut Sender,
    request_id: &str,
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
        match sender.deliver(&line, &|| {}) {
            Delivered::Answered => {}
            Delivered::Rejected(error) if own => own_rejection = Some(error),
            Delivered::Rejected(_) => {}
            Delivered::Unanswered(error) => {
                // Given up: counted where server-stats shows it.
                let _ =
                    cmux_tui_core::diagnostics::add_undeliverable_hook_events(&sender.socket, 1);
                if own {
                    own_rejection = Some(error);
                }
            }
            Delivered::Gone(error) => {
                spool.compact(offset)?;
                return Err(error.context("no daemon answered; the hook event stays queued"));
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
    /// A live daemon took it `UNANSWERED_TRIES` times in a row and never
    /// answered; it leaves the queue and is counted.
    Unanswered(anyhow::Error),
    /// No daemon listens: the line stays queued.
    Gone(anyhow::Error),
}

/// One connection to the daemon, kept across the lines of a queue.
struct Sender {
    socket: PathBuf,
    connection: Option<BufReader<Box<dyn transport::Stream>>>,
    retries: RetryBudget,
    /// No daemon answered a connect: later queues wait for the next owner.
    gone: bool,
}

impl Sender {
    fn new(socket: &Path) -> Self {
        Self {
            socket: socket.to_path_buf(),
            connection: None,
            retries: RetryBudget::new(RETRY_INITIAL, RETRY_MAX),
            gone: false,
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
        let mut unanswered = 0_u32;
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
                Err(Try::Gone(error)) => {
                    self.gone = true;
                    return Delivered::Gone(error);
                }
                Err(Try::Again(error)) => {
                    self.connection = None;
                    let retry_after =
                        error.downcast_ref::<Busy>().and_then(|busy| busy.retry_after);
                    // No budget: a busy daemon is waited out (the module doc).
                    self.retries.sleep(retry_after);
                }
                Err(Try::Unanswered(error)) => {
                    self.connection = None;
                    unanswered = unanswered.saturating_add(1);
                    if unanswered >= UNANSWERED_TRIES {
                        self.retries.reset();
                        return Delivered::Unanswered(error.context(format!(
                            "the daemon took this hook event {UNANSWERED_TRIES} times and never answered"
                        )));
                    }
                    self.retries.sleep(None);
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
                // No listener: the owner stopped, restarts or crashed. The
                // line stays queued for the session's next owner.
                if retry { Try::Again(error) } else { Try::Gone(error) }
            })?),
        };
        // Set while the peer surely still holds the connection: once a daemon
        // has answered and closed, macOS refuses the option. The write gets
        // the same bound: a daemon that never reads a large line (a long
        // `live_prompt`) is one that never answers it.
        let _ = connection.get_ref().set_read_timeout(Some(RECEIPT_WAIT));
        let _ = connection.get_mut().set_write_timeout(Some(RECEIPT_WAIT));
        let outcome = exchange(&mut connection, line, request_id, on_written);
        if !matches!(outcome, Err(Try::Again(_) | Try::Unanswered(_))) {
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
        let stalled = matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut);
        if stalled {
            return Err(Try::Unanswered(
                anyhow!(error).context("the daemon did not read the hook event"),
            ));
        }
        let closed =
            matches!(error.kind(), io::ErrorKind::BrokenPipe | io::ErrorKind::ConnectionReset);
        let busy = closed.then(|| read_reply(connection).ok().flatten()).flatten();
        return Err(Try::Again(match busy.as_deref().and_then(parse_busy) {
            Some(busy) => busy.into(),
            None => anyhow!(error).context("write the hook event"),
        }));
    }
    on_written();
    // The receipt, or the connection's close. `RECEIPT_WAIT` is past the
    // daemon's own longest wait, so only a daemon that will never answer
    // reaches it.
    let reply = read_reply(connection)
        .map_err(|error| Try::Unanswered(anyhow!(error).context("read the journal receipt")))?
        .ok_or_else(|| {
            Try::Unanswered(anyhow!("journal append closed without a complete response"))
        })?;
    check_receipt(&reply, request_id)
}

/// Why one try failed.
enum Try {
    /// Busy, or dropped before the line was written: the same line goes
    /// again after a backoff.
    Again(anyhow::Error),
    /// The line was written and the daemon closed, or let `RECEIPT_WAIT`
    /// pass, with no answer: it goes again, `UNANSWERED_TRIES` at most.
    Unanswered(anyhow::Error),
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
