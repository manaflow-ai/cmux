use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use cmux_tui_core::ProviderWorkspaceAuthority;
use cmux_tui_core::provider_management::{self, ClientError};

const UPGRADE_REQUIRED_EXIT: i32 = 78;
const MAX_AUTHORITY_FILE_BYTES: u64 = 513;

struct SensitiveBytes(Vec<u8>);

impl Drop for SensitiveBytes {
    fn drop(&mut self) {
        self.0.fill(0);
    }
}

#[derive(Debug)]
struct InstallArgs {
    socket: PathBuf,
    generation: u64,
    authority_file: PathBuf,
}

pub fn try_run(args: &[String]) -> Option<i32> {
    if args.first().map(String::as_str) != Some("__provider-authority") {
        return None;
    }
    Some(match run(args) {
        Ok(()) => 0,
        Err(CommandError::UpgradeRequired(error)) => {
            eprintln!("cmux-tui: {error}");
            UPGRADE_REQUIRED_EXIT
        }
        Err(CommandError::Other(error)) => {
            eprintln!("cmux-tui: {error}");
            1
        }
    })
}

enum CommandError {
    UpgradeRequired(ClientError),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for CommandError {
    fn from(error: anyhow::Error) -> Self {
        Self::Other(error)
    }
}

fn run(args: &[String]) -> Result<(), CommandError> {
    let args = parse(args).map_err(CommandError::Other)?;
    let result = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if result != 0 {
        return Err(CommandError::Other(io::Error::last_os_error().into()));
    }
    let authority = read_authority(&args.authority_file).map_err(CommandError::Other)?;
    provider_management::install(&args.socket, args.generation, authority).map_err(|error| {
        if matches!(error, ClientError::UpgradeRequired) {
            CommandError::UpgradeRequired(error)
        } else {
            CommandError::Other(error.into())
        }
    })?;
    Ok(())
}

fn parse(args: &[String]) -> anyhow::Result<InstallArgs> {
    if args.get(1).map(String::as_str) != Some("install") {
        anyhow::bail!("invalid internal provider authority command");
    }
    let mut socket = None;
    let mut generation = None;
    let mut authority_file = None;
    let mut cursor = 2;
    while cursor < args.len() {
        let value = args
            .get(cursor + 1)
            .ok_or_else(|| anyhow::anyhow!("{} needs a value", args[cursor]))?;
        match args[cursor].as_str() {
            "--socket" if socket.is_none() => socket = Some(PathBuf::from(value)),
            "--generation" if generation.is_none() => {
                let parsed = value
                    .parse::<u64>()
                    .map_err(|_| anyhow::anyhow!("invalid authority generation"))?;
                if parsed == 0 {
                    anyhow::bail!("authority generation must be positive");
                }
                generation = Some(parsed);
            }
            "--authority-file" if authority_file.is_none() => {
                authority_file = Some(PathBuf::from(value));
            }
            _ => anyhow::bail!("invalid internal provider authority arguments"),
        }
        cursor += 2;
    }
    Ok(InstallArgs {
        socket: socket.ok_or_else(|| anyhow::anyhow!("--socket is required"))?,
        generation: generation.ok_or_else(|| anyhow::anyhow!("--generation is required"))?,
        authority_file: authority_file
            .ok_or_else(|| anyhow::anyhow!("--authority-file is required"))?,
    })
}

fn open_authority(path: &Path) -> anyhow::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| anyhow::anyhow!("cannot open provider authority file: {error}"))?;
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.nlink() != 1
        || metadata.mode() & 0o077 != 0
        || metadata.len() > MAX_AUTHORITY_FILE_BYTES
    {
        anyhow::bail!("provider authority file must be a root-owned, private regular file");
    }
    Ok(file)
}

fn read_authority(path: &Path) -> anyhow::Result<ProviderWorkspaceAuthority> {
    let file = open_authority(path)?;
    let mut bytes = SensitiveBytes(Vec::new());
    file.take(MAX_AUTHORITY_FILE_BYTES + 1).read_to_end(&mut bytes.0)?;
    if bytes.0.len() as u64 > MAX_AUTHORITY_FILE_BYTES {
        anyhow::bail!("provider authority file is too large");
    }
    if bytes.0.last() == Some(&b'\n') {
        bytes.0.pop();
    }
    let authority = std::str::from_utf8(&bytes.0)
        .map(str::to_owned)
        .map_err(|_| anyhow::anyhow!("provider authority file is not valid UTF-8"))?;
    ProviderWorkspaceAuthority::new(authority)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn internal_args_never_accept_an_inline_authority() {
        let error = parse(&[
            "__provider-authority".into(),
            "install".into(),
            "--socket".into(),
            "/run/cmux.sock".into(),
            "--generation".into(),
            "1".into(),
            "--authority".into(),
            "do-not-put-secrets-in-argv-00000000".into(),
        ])
        .unwrap_err()
        .to_string();
        assert_eq!(error, "invalid internal provider authority arguments");
        assert!(!error.contains("do-not-put-secrets"));
    }

    #[test]
    fn unavailable_live_management_protocol_is_retryable() {
        if unsafe { libc::geteuid() } != 0 {
            return;
        }
        let suffix = format!("{}-{}", std::process::id(), std::thread::current().name().unwrap());
        let authority_path = std::env::temp_dir().join(format!("cmux-authority-{suffix}"));
        let socket_path = std::env::temp_dir().join(format!("cmux-old-mux-{suffix}.sock"));
        let mut authority = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&authority_path)
            .unwrap();
        authority.write_all(b"old-mux-upgrade-authority-000000000001").unwrap();
        drop(authority);
        let exit = try_run(&[
            "__provider-authority".into(),
            "install".into(),
            "--socket".into(),
            socket_path.display().to_string(),
            "--generation".into(),
            "1".into(),
            "--authority-file".into(),
            authority_path.display().to_string(),
        ])
        .unwrap();
        std::fs::remove_file(authority_path).unwrap();
        assert_eq!(exit, 1);
    }

    #[test]
    fn unresponsive_listener_is_retryable() {
        use std::os::unix::net::UnixListener;

        if unsafe { libc::geteuid() } != 0 {
            return;
        }
        let suffix = format!("old-{}", std::process::id());
        let authority_path = std::env::temp_dir().join(format!("cmux-authority-{suffix}"));
        let socket_path = std::env::temp_dir().join(format!("cmux-old-mux-{suffix}.sock"));
        let mut authority = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&authority_path)
            .unwrap();
        authority.write_all(b"unresponsive-mux-authority-000000000001").unwrap();
        drop(authority);
        let listener = UnixListener::bind(&socket_path).unwrap();
        let exit = try_run(&[
            "__provider-authority".into(),
            "install".into(),
            "--socket".into(),
            socket_path.display().to_string(),
            "--generation".into(),
            "1".into(),
            "--authority-file".into(),
            authority_path.display().to_string(),
        ])
        .unwrap();
        drop(listener);
        std::fs::remove_file(authority_path).unwrap();
        std::fs::remove_file(socket_path).unwrap();
        assert_eq!(exit, 1);
    }

    #[test]
    fn explicit_unsupported_protocol_returns_upgrade_required() {
        use std::io::{BufRead, BufReader};
        use std::os::unix::net::UnixListener;

        if unsafe { libc::geteuid() } != 0 {
            return;
        }
        let suffix = format!("future-{}", std::process::id());
        let authority_path = std::env::temp_dir().join(format!("cmux-authority-{suffix}"));
        let socket_path = std::env::temp_dir().join(format!("cmux-future-mux-{suffix}.sock"));
        let mut authority = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&authority_path)
            .unwrap();
        authority.write_all(b"future-mux-authority-000000000000000001").unwrap();
        drop(authority);
        let listener = UnixListener::bind(&socket_path).unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            assert!(request.contains("\"operation\":\"status\""));
            stream
                .write_all(
                    b"{\"protocol\":2,\"ok\":false,\"error\":{\"code\":\"unsupported_version\",\"message\":\"future protocol\"}}\n",
                )
                .unwrap();
        });
        let exit = try_run(&[
            "__provider-authority".into(),
            "install".into(),
            "--socket".into(),
            socket_path.display().to_string(),
            "--generation".into(),
            "1".into(),
            "--authority-file".into(),
            authority_path.display().to_string(),
        ])
        .unwrap();
        server.join().unwrap();
        std::fs::remove_file(authority_path).unwrap();
        std::fs::remove_file(socket_path).unwrap();
        assert_eq!(exit, UPGRADE_REQUIRED_EXIT);
    }
}
