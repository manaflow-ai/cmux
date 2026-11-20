//! Bounded, one-shot GitHub reads. Log tails retain fixed memory while stdout drains.
use crate::rpc::RpcError;
use std::{collections::VecDeque, path::Path, process::Stdio, time::Duration};
use tokio::io::{AsyncRead, AsyncReadExt};

const JSON_LIMIT: usize = 2 * 1024 * 1024;
const TAIL_LIMIT: usize = 16 * 1024;

async fn capture(mut stream: impl AsyncRead + Unpin, tail: bool) -> std::io::Result<Vec<u8>> {
    let limit = if tail { TAIL_LIMIT } else { JSON_LIMIT };
    let mut bytes = VecDeque::new();
    let mut chunk = [0; 8192];
    loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(bytes.into());
        }
        if !tail && bytes.len() + n > limit {
            return Err(std::io::Error::other("GitHub response exceeds the read limit"));
        }
        bytes.extend(chunk.iter().take(n));
        while bytes.len() > limit {
            bytes.pop_front();
        }
    }
}

pub(super) async fn read(cwd: &Path, args: &[String], tail: bool) -> Result<String, RpcError> {
    let mut child = tokio::process::Command::new("gh")
        .args(args)
        .current_dir(cwd)
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| RpcError::internal(e.to_string()))?;
    let stdout = child.stdout.take().ok_or_else(|| RpcError::internal("no GitHub stdout"))?;
    let stderr = child.stderr.take().ok_or_else(|| RpcError::internal("no GitHub stderr"))?;
    let work =
        async { tokio::try_join!(capture(stdout, tail), capture(stderr, true), child.wait()) };
    let (out, err, status) = tokio::time::timeout(Duration::from_secs(30), work)
        .await
        .map_err(|_| RpcError::internal("GitHub read exceeded 30 seconds"))?
        .map_err(|e| RpcError::internal(e.to_string()))?;
    if !status.success() {
        return Err(RpcError::internal(crate::github_broker::redact_github_tokens(
            &String::from_utf8_lossy(&err),
        )));
    }
    Ok(crate::github_broker::redact_github_tokens(&String::from_utf8_lossy(&out)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn logs_keep_the_end_and_json_refuses_truncation() {
        let mut input = vec![b'a'; JSON_LIMIT + 1];
        input.extend_from_slice(b"\nlast failure\n");
        let tail = capture(input.as_slice(), true).await.unwrap();
        assert_eq!(tail.len(), TAIL_LIMIT);
        assert!(tail.ends_with(b"last failure\n"));
        assert!(capture(input.as_slice(), false).await.is_err());
    }
}
