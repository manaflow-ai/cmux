//! Values out of what a command or an app prints: `use`'s env and streaming mask.

use super::*;

/// Replaces every occurrence of `values` in `text` with [`MASK`].
pub(in crate::cli) fn mask_text(text: &str, values: &[&str]) -> String {
    let mut out = text.to_owned();
    for value in values.iter().filter(|v| !v.is_empty()) {
        out = out.replace(value, MASK);
    }
    out
}

/// `value` with every string in it masked, keys included.
pub(in crate::cli) fn mask_json(value: &Value, secrets: &[&str]) -> Value {
    match value {
        Value::String(text) => Value::String(mask_text(text, secrets)),
        Value::Array(items) => Value::Array(items.iter().map(|v| mask_json(v, secrets)).collect()),
        Value::Object(fields) => Value::Object(
            fields.iter().map(|(k, v)| (mask_text(k, secrets), mask_json(v, secrets))).collect(),
        ),
        other => other.clone(),
    }
}

/// Masks values in a byte stream that arrives in pieces: it holds back the last bytes that could
/// start a value until the next piece shows whether they do.
pub(in crate::cli) struct Masker {
    needles: Vec<Zeroizing<Vec<u8>>>,
    keep: usize,
    pending: Zeroizing<Vec<u8>>,
}

impl Masker {
    pub(in crate::cli) fn new(values: &[&str]) -> Self {
        let mut needles: Vec<Zeroizing<Vec<u8>>> = values
            .iter()
            .filter(|v| !v.is_empty())
            .map(|v| Zeroizing::new(v.as_bytes().to_vec()))
            .collect();
        // Longest first, so a value that contains another masks whole.
        needles.sort_by_key(|n| std::cmp::Reverse(n.len()));
        let keep = needles.first().map_or(0, |n| n.len() - 1);
        Self { needles, keep, pending: Zeroizing::new(Vec::new()) }
    }

    /// The bytes of `piece` (after what came before) that are safe to print now.
    pub(in crate::cli) fn push(&mut self, piece: &[u8]) -> Vec<u8> {
        self.pending.extend_from_slice(piece);
        // Only a start that leaves `keep` bytes after it can be decided now.
        let decidable = self.pending.len().saturating_sub(self.keep);
        self.drain(decidable)
    }

    /// What is left at the end of the stream.
    pub(in crate::cli) fn finish(&mut self) -> Vec<u8> {
        self.drain(self.pending.len())
    }

    /// Masks and takes the pending bytes that start before `upto`; the rest stays pending.
    fn drain(&mut self, upto: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.pending.len());
        let mut i = 0;
        while i < upto {
            let rest = self.pending.get(i..).unwrap_or_default();
            if let Some(len) = self.needles.iter().find(|n| rest.starts_with(n)).map(|n| n.len()) {
                out.extend_from_slice(MASK.as_bytes());
                i += len;
            } else if let Some(&byte) = rest.first() {
                out.push(byte);
                i += 1;
            } else {
                break;
            }
        }
        let rest = self.pending.get(i..).unwrap_or_default().to_vec();
        self.pending = Zeroizing::new(rest);
        out
    }
}

/// Copies `from` to `to` through a [`Masker`] until the end.
pub(super) fn pump(mut from: impl std::io::Read, mut to: impl std::io::Write, values: &[&str]) {
    let mut masker = Masker::new(values);
    let mut buf = Zeroizing::new(vec![0u8; 16 * 1024]);
    loop {
        match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                let out = masker.push(buf.get(..n).unwrap_or_default());
                if to.write_all(&out).and_then(|()| to.flush()).is_err() {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    let _ = to.write_all(&masker.finish());
    let _ = to.flush();
}

/// Runs `run.argv` with each key's value in its env var, stdin passed through, and (unless
/// `--no-mask`) every value masked in what it prints. The command's exit code, or 128 plus its
/// signal.
pub(in crate::cli) fn run_use(
    paths: &Paths,
    vault: &dyn KeyVault,
    run: &Use,
    stdout: impl std::io::Write + Send + 'static,
    stderr: impl std::io::Write + Send + 'static,
) -> Result<i32, String> {
    let mut values = Vec::new();
    for (name, var) in &run.keys {
        let (_, value) = value_of(paths, vault, name)?;
        values.push((name.clone(), var.clone(), value));
    }
    let Some((first, rest)) = run.argv.split_first() else {
        return Err("no command after --".to_owned());
    };
    let program =
        Path::new(first).file_name().and_then(|n| n.to_str()).unwrap_or("command").to_owned();
    for (name, var, _) in &values {
        record(paths, name, &format!("env:{var} for {program}"), false)?;
    }
    let mut command = cmux_process::Command::new(first);
    command.args(rest);
    for (_, var, value) in &values {
        command.env(var, value.as_str());
    }
    if !run.mask {
        command.stdin(cmux_process::Stdio::inherit());
        let mut child = command.spawn().map_err(|e| format!("cannot run {first}: {e}"))?;
        drop(values);
        return child.wait().map(exit_code).map_err(|e| e.to_string());
    }
    command
        .stdin(cmux_process::Stdio::inherit())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped());
    let mut child = command.spawn().map_err(|e| format!("cannot run {first}: {e}"))?;
    let secrets: Vec<Zeroizing<String>> = values.into_iter().map(|(_, _, v)| v).collect();
    let out = child.stdout.take();
    let err = child.stderr.take();
    let threads = std::thread::scope(|scope| {
        let refs: Vec<&str> = secrets.iter().map(|s| s.as_str()).collect();
        let a = out.map(|pipe| {
            let refs = refs.clone();
            scope.spawn(move || pump(pipe, stdout, &refs))
        });
        let b = err.map(|pipe| {
            let refs = refs.clone();
            scope.spawn(move || pump(pipe, stderr, &refs))
        });
        let status = child.wait();
        for handle in [a, b].into_iter().flatten() {
            let _ = handle.join();
        }
        status
    });
    drop(secrets);
    threads.map(exit_code).map_err(|e| e.to_string())
}

pub(super) fn exit_code(status: cmux_process::ExitStatus) -> i32 {
    use std::os::unix::process::ExitStatusExt as _;
    status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0))
}
