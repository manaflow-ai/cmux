//! Sending a message through Messages.app, the mirror's second step (opt-in, like the reads).
//!
//! The send runs `osascript` with a fixed AppleScript. The chat id and the text reach the script
//! only as `argv` items, never spliced into its source, so no text can change what the script
//! does. macOS asks Leo once for the Automation permission ("cmux wants to control Messages");
//! a refusal comes back as [`SendError::NotPermitted`].

use std::io::ErrorKind;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// The longest text one send takes, in bytes.
pub const MAX_TEXT_BYTES: usize = 20_000;
/// How long a send may run before the child is stopped. The first send can wait on the
/// Automation prompt, so this is generous.
pub const SEND_TIMEOUT: Duration = Duration::from_secs(120);

/// The script `osascript` runs, one `-e` per line. `item 1 of argv` is the chat guid,
/// `item 2 of argv` the text.
pub const SEND_SCRIPT: [&str; 7] = [
    "on run argv",
    "set chatGuid to item 1 of argv",
    "set messageText to item 2 of argv",
    "tell application \"Messages\"",
    "send messageText to chat id chatGuid",
    "end tell",
    "end run",
];

/// AppleScript error: the user (or policy) refused Automation of Messages.
const ERR_NOT_AUTHORIZED: &str = "(-1743)";
/// AppleScript error: no chat with that id.
const ERR_NO_SUCH_OBJECT: &str = "(-1728)";

/// One message to send to an existing chat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendRequest {
    /// `chat.guid` of the thread (`iMessage;-;+15551234567`, `iMessage;+;chat123`, `SMS;-;...`).
    pub chat_guid: String,
    pub text: String,
}

/// Why a send did not go out.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendError {
    EmptyText,
    TextTooLong,
    /// The chat guid is malformed, or Messages has no chat with it.
    InvalidChat(String),
    /// Automation of Messages is not allowed for cmux.
    NotPermitted(String),
    /// `osascript` is not available (not macOS).
    Unsupported,
    /// The send ran past [`SEND_TIMEOUT`] and was stopped.
    TimedOut,
    /// Messages or osascript reported another failure.
    Failed(String),
}

impl SendError {
    /// A stable, machine-readable code for the wire.
    pub fn code(&self) -> &'static str {
        match self {
            Self::EmptyText => "empty_text",
            Self::TextTooLong => "text_too_long",
            Self::InvalidChat(_) => "invalid_chat",
            Self::NotPermitted(_) => "not_permitted",
            Self::Unsupported => "unsupported",
            Self::TimedOut => "timed_out",
            Self::Failed(_) => "failed",
        }
    }
}

impl std::fmt::Display for SendError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EmptyText => write!(f, "messages send: the text is empty"),
            Self::TextTooLong => {
                write!(f, "messages send: the text is over {MAX_TEXT_BYTES} bytes")
            }
            Self::InvalidChat(detail) => write!(f, "messages send: no such chat: {detail}"),
            Self::NotPermitted(detail) => {
                write!(
                    f,
                    "messages send: cmux may not control Messages (allow it under Automation): {detail}"
                )
            }
            Self::Unsupported => write!(f, "messages send: osascript is not available"),
            Self::TimedOut => write!(f, "messages send: timed out"),
            Self::Failed(detail) => write!(f, "messages send: {detail}"),
        }
    }
}

impl std::error::Error for SendError {}

/// What a finished command reported.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub success: bool,
    pub stderr: String,
}

/// Runs a program; tests substitute a fake.
pub trait CommandRunner {
    fn run(&self, program: &str, args: &[String]) -> std::io::Result<CommandOutput>;
}

/// Runs the program as a child process, stopping it after [`SEND_TIMEOUT`].
pub struct SystemRunner;

impl CommandRunner for SystemRunner {
    fn run(&self, program: &str, args: &[String]) -> std::io::Result<CommandOutput> {
        TimedRunner { timeout: SEND_TIMEOUT }.run(program, args)
    }
}

/// Runs the program as a child process, stopping it after `timeout`.
pub struct TimedRunner {
    pub timeout: Duration,
}

impl CommandRunner for TimedRunner {
    fn run(&self, program: &str, args: &[String]) -> std::io::Result<CommandOutput> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()?;
        let drain = child.stderr.take().map(StderrDrain::start);
        let deadline = Instant::now() + self.timeout;
        loop {
            if let Some(status) = child.try_wait()? {
                // A descendant may still hold stderr open; take what arrived within a short grace.
                let grace =
                    AFTER_EXIT_GRACE.min(deadline.saturating_duration_since(Instant::now()));
                let stderr = drain.map(|drain| drain.collect(grace)).unwrap_or_default();
                return Ok(CommandOutput { success: status.success(), stderr });
            }
            if Instant::now() >= deadline {
                // Our own child: stop it and reap it so nothing is left behind. The drain thread is
                // not waited on: it ends by itself when the last holder of the pipe closes it.
                let _ = child.kill();
                let _ = child.wait();
                drop(drain);
                return Err(std::io::Error::new(ErrorKind::TimedOut, "osascript timed out"));
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

/// How long a finished child's stderr may keep arriving before the send stops reading it.
const AFTER_EXIT_GRACE: Duration = Duration::from_secs(2);

/// Reads a child's stderr on its own thread while the child runs, so a child that fills the pipe
/// buffer never blocks. Stop condition: the thread ends at end of file, when every holder of the
/// pipe (the child and any descendant that inherited it) has closed it. Nothing joins it, so a
/// descendant that keeps the pipe open can never hold up a send.
struct StderrDrain {
    buffer: Arc<Mutex<Vec<u8>>>,
    finished: mpsc::Receiver<()>,
}

impl StderrDrain {
    fn start(mut pipe: std::process::ChildStderr) -> Self {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let (done, finished) = mpsc::channel();
        let sink = Arc::clone(&buffer);
        std::thread::spawn(move || {
            use std::io::Read;
            let mut chunk = [0_u8; 8192];
            loop {
                match pipe.read(&mut chunk) {
                    Ok(0) | Err(_) => break,
                    Ok(read) => {
                        if let (Ok(mut bytes), Some(data)) = (sink.lock(), chunk.get(..read)) {
                            bytes.extend_from_slice(data);
                        }
                    }
                }
            }
            let _ = done.send(());
        });
        Self { buffer, finished }
    }

    /// Waits up to `wait` for end of file, then returns what has arrived so far.
    fn collect(self, wait: Duration) -> String {
        let _ = self.finished.recv_timeout(wait);
        match self.buffer.lock() {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(_) => String::new(),
        }
    }
}

/// Checks a request without sending it.
pub fn validate(request: &SendRequest) -> Result<(), SendError> {
    if request.text.trim().is_empty() {
        return Err(SendError::EmptyText);
    }
    if request.text.len() > MAX_TEXT_BYTES {
        return Err(SendError::TextTooLong);
    }
    if request.text.contains('\0') {
        return Err(SendError::Failed("the text contains a NUL byte".to_string()));
    }
    if !is_chat_guid(&request.chat_guid) {
        return Err(SendError::InvalidChat(request.chat_guid.clone()));
    }
    Ok(())
}

/// The `osascript` arguments for a request: the script lines as `-e` options, then the chat
/// guid and the text as plain arguments (the script's `argv`).
pub fn osascript_args(request: &SendRequest) -> Vec<String> {
    let mut args = Vec::with_capacity(SEND_SCRIPT.len() * 2 + 2);
    for line in SEND_SCRIPT {
        args.push("-e".to_string());
        args.push(line.to_string());
    }
    args.push(request.chat_guid.clone());
    args.push(request.text.clone());
    args
}

/// Validates and sends one message through Messages.app.
pub fn send(request: &SendRequest, runner: &dyn CommandRunner) -> Result<(), SendError> {
    validate(request)?;
    let output = match runner.run("osascript", &osascript_args(request)) {
        Ok(output) => output,
        Err(error) if error.kind() == ErrorKind::NotFound => return Err(SendError::Unsupported),
        Err(error) if error.kind() == ErrorKind::TimedOut => return Err(SendError::TimedOut),
        Err(error) => return Err(SendError::Failed(error.to_string())),
    };
    if output.success {
        return Ok(());
    }
    let detail = output.stderr.trim().to_string();
    let code = terminal_error_code(&detail).map(str::to_owned);
    Err(match code.as_deref() {
        Some(ERR_NOT_AUTHORIZED) => SendError::NotPermitted(detail),
        Some(ERR_NO_SUCH_OBJECT) => SendError::InvalidChat(detail),
        _ => SendError::Failed(detail),
    })
}

/// The AppleScript error code osascript ends its diagnostic with (`... (-1743)`), so a code
/// quoted earlier in the message (inside a chat id, say) never decides the mapping.
fn terminal_error_code(detail: &str) -> Option<&str> {
    let trimmed = detail.trim_end();
    let inner = trimmed.strip_suffix(')')?;
    let open = inner.rfind('(')?;
    let digits = inner.get(open..)?.strip_prefix("(-")?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    trimmed.get(open..=inner.len())
}

/// `service;-;handle` (1:1) or `service;+;room` (group), with no control characters, and not
/// starting with `-` (so `osascript` never reads it as an option).
fn is_chat_guid(guid: &str) -> bool {
    if guid.is_empty()
        || guid.len() > 512
        || guid.starts_with('-')
        || guid.chars().any(char::is_control)
    {
        return false;
    }
    let mut parts = guid.splitn(3, ';');
    let (Some(service), Some(kind), Some(id)) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    !service.is_empty() && (kind == "-" || kind == "+") && !id.is_empty()
}
