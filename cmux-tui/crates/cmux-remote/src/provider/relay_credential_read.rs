//! How a relay credential source is read: a ticket file, or a ticket command run under its
//! timeout with its stderr tail summarised (split out of `relay.rs`).

use super::*;

pub(super) async fn read_credential_file(path: &Path) -> Result<Zeroizing<String>, ProviderError> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        crate::secret_file::read_owner_only_string(&path, MAX_RELAY_CREDENTIAL_BYTES)
    })
    .await
    .map_err(|_| credential_source_error("file could not be read"))?
    .map_err(|_| credential_source_error("file could not be read"))
}

pub(super) async fn read_credential_command(
    source: &CommandCredentialSource,
) -> Result<Zeroizing<String>, ProviderError> {
    if source.timeout.is_zero() {
        return Err(credential_source_error("command timeout is invalid"));
    }
    let mut command = Command::new(&source.program);
    command
        .args(&source.args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child =
        command.spawn().map_err(|_| credential_source_error("command could not be started"))?;
    let mut stderr = StderrTail::spawn(child.stderr.take());
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            terminate_child(&mut child).await;
            return Err(credential_source_error("command stdout was unavailable"));
        }
    };
    let result = tokio::time::timeout(source.timeout, async {
        let output = match read_limited_credential(stdout).await {
            Ok(output) => output,
            // An oversized or unreadable answer still names what stderr said.
            Err(ProviderError::Transport(message)) => {
                return Err(ProviderError::Transport(format!(
                    "{message}{}",
                    stderr.describe().await
                )));
            }
            Err(error) => return Err(error),
        };
        let status = child
            .wait()
            .await
            .map_err(|_| credential_source_error("command could not be completed"))?;
        if !status.success() {
            return Err(credential_source_error(&format!(
                "command was unsuccessful ({status}){}",
                stderr.describe().await
            )));
        }
        Ok(output)
    })
    .await;
    match result {
        Ok(Ok(output)) => Ok(output),
        Ok(Err(error)) => {
            terminate_child(&mut child).await;
            Err(error)
        }
        Err(_) => {
            terminate_child(&mut child).await;
            Err(credential_source_error(&format!(
                "command timed out after {} ms{}",
                source.timeout.as_millis(),
                stderr.describe().await
            )))
        }
    }
}

/// The most error codes a summary names.
pub(super) const MAX_STDERR_CODES: usize = 4;

/// What a failed credential command's stderr `tail` may add to its error:
/// `; stderr: N bytes`, then `, codes …` naming up to [`MAX_STDERR_CODES`]
/// distinct error codes and an `HTTP NNN` status found in it, or nothing
/// when it is empty. Free text never reaches the log: stderr can hold a
/// ticket, a header or a JSON body in any shape, and only these allowlisted
/// forms can't be one.
pub(super) fn stderr_summary(tail: &[u8]) -> String {
    if tail.is_empty() {
        return String::new();
    }
    let text = String::from_utf8_lossy(tail);
    let words: Vec<&str> = text.split_whitespace().collect();
    let mut codes: Vec<String> = Vec::new();
    for word in &words {
        if codes.len() == MAX_STDERR_CODES {
            break;
        }
        if let Some(code) = error_code(word)
            && !codes.iter().any(|known| known == code)
        {
            codes.push(code.to_owned());
        }
    }
    let http = words.windows(2).find_map(|pair| {
        let [word, next] = pair else { return None };
        let status = next.trim_end_matches([':', ',', ';', ')']);
        let http = *word == "HTTP" || word.starts_with("HTTP/");
        (http && status.len() == 3 && status.bytes().all(|byte| byte.is_ascii_digit()))
            .then(|| format!("HTTP {status}"))
    });
    codes.extend(http);
    if codes.is_empty() {
        format!("; stderr: {} bytes", tail.len())
    } else {
        format!("; stderr: {} bytes, codes {}", tail.len(), codes.join(", "))
    }
}

/// The error codes a relay ticket command may name in a log: the refusals
/// `cmux host cloud carrier-ticket` prints (cmux-host `cloud/carrier_ticket.rs`)
/// and the platform codes it passes on. Only these exact words are copied out
/// of stderr; any other word, however code-shaped (`dead.beef`), is not.
pub(super) const KNOWN_ERROR_CODES: [&str; 14] = [
    "auth.forbidden",
    "auth.refused",
    "carrier.bad_answer",
    "carrier.busy",
    "carrier.rate_limited",
    "carrier.unavailable",
    "carrier.unreachable",
    "cloud.machine.not_found",
    "owner.unreachable",
    "validation.invalid",
    "vm.agent_bad_answer",
    "vm.agent_stopping",
    "vm.agent_unreachable",
    "vm.unbound",
];

/// `word` without a trailing `:` when it is one of [`KNOWN_ERROR_CODES`].
pub(super) fn error_code(word: &str) -> Option<&'static str> {
    let code = word.strip_suffix(':').unwrap_or(word);
    KNOWN_ERROR_CODES.iter().copied().find(|known| *known == code)
}

/// Kill and reap a credential command on every cancellation or failure path.
/// `kill_on_drop` is best effort and does not guarantee prompt zombie cleanup.
pub(super) async fn terminate_child(child: &mut tokio::process::Child) {
    let _ = child.kill().await;
    let _ = child.wait().await;
}

pub(super) async fn read_limited_credential(
    reader: impl tokio::io::AsyncRead + Unpin,
) -> Result<Zeroizing<String>, ProviderError> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(MAX_RELAY_CREDENTIAL_BYTES.min(256)));
    reader
        .take((MAX_RELAY_CREDENTIAL_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| credential_source_error("could not be read"))?;
    if bytes.len() > MAX_RELAY_CREDENTIAL_BYTES {
        return Err(credential_source_error("was too large"));
    }
    let value = Zeroizing::new(
        std::str::from_utf8(&bytes)
            .map_err(|_| credential_source_error("was not UTF-8"))?
            .to_owned(),
    );
    Ok(value)
}

pub(super) fn credential_source_error(reason: &str) -> ProviderError {
    ProviderError::Transport(format!("{CREDENTIAL_SOURCE_ERROR_PREFIX}{reason}"))
}

/// The credential source (a ticket command, file or callback) failed, as
/// opposed to the relay.
pub(super) fn is_credential_source_error(error: &ProviderError) -> bool {
    matches!(error, ProviderError::Transport(message) if message.starts_with(CREDENTIAL_SOURCE_ERROR_PREFIX))
}
