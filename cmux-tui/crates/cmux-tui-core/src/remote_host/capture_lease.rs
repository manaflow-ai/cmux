//! Durable capture admission. A malformed record holds the host closed, never opens it.
use super::{HostRecord, Paths, mint_secret};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Binding {
    pub lease_id: String,
    pub bundle_id: String,
    pub private_root: PathBuf,
}

impl Binding {
    pub fn parse(value: Value) -> Result<Self, String> {
        let binding: Self = serde_json::from_value(value).map_err(|_| "remote_invalid_binding")?;
        if binding.lease_id.len() != 24
            || !binding.lease_id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || !binding.bundle_id.starts_with("com.cmuxterm.app.debug.")
            || binding.bundle_id.len() <= "com.cmuxterm.app.debug.".len()
            || !binding
                .bundle_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
            || !binding.private_root.is_absolute()
            || binding.private_root == Path::new("/")
        {
            return Err("remote_invalid_binding".into());
        }
        Ok(binding)
    }

    pub fn validate_paths(&self, paths: &Paths, home: &Path) -> Result<(), String> {
        let root = &self.private_root;
        let meta = std::fs::symlink_metadata(root).map_err(|_| "remote_private_home_unverified")?;
        // SAFETY: geteuid has no preconditions; compare only owner metadata of this private root.
        let own = unsafe { libc::geteuid() };
        if home != root
            || !meta.is_dir()
            || meta.uid() != own
            || meta.mode() & 0o077 != 0
            || std::fs::canonicalize(root).ok().as_ref() != Some(root)
            || !paths.state.starts_with(root)
            || paths.state == *root
            || !match std::fs::symlink_metadata(&paths.state) {
                Ok(meta) => {
                    meta.is_dir()
                        && std::fs::canonicalize(&paths.state).ok().as_ref() == Some(&paths.state)
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    paths.state.parent().is_some_and(|parent| {
                        std::fs::canonicalize(parent).ok().as_deref() == Some(parent)
                    })
                }
                Err(_) => false,
            }
        {
            return Err("remote_private_home_unverified".into());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Stamp {
    pub pid: u32,
    pub start_sec: u64,
    pub start_usec: u64,
}

impl Stamp {
    pub fn of_record(record: &HostRecord) -> Self {
        Self { pid: record.pid, start_sec: record.start_sec, start_usec: record.start_usec }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) enum Phase {
    Preparing,
    Prepared,
    Active,
    Cleaning,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Lease {
    pub binding: Binding,
    pub owner: Stamp,
    pub phase: Phase,
    pub host: Option<HostRecord>,
}

#[derive(Clone, Default)]
pub(super) enum Admission {
    #[default]
    Open,
    Held(Lease),
    Unreadable,
}

impl Admission {
    pub fn fenced(&self) -> bool {
        !matches!(self, Self::Open | Self::Held(Lease { phase: Phase::Active, .. }))
    }

    pub fn load(state: &Path) -> Self {
        let path = state.join("capture-supervisor.json");
        let result = (|| {
            let mut file = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(path)?;
            let meta = file.metadata()?;
            // SAFETY: geteuid has no preconditions.
            if !meta.is_file()
                || meta.uid() != unsafe { libc::geteuid() }
                || meta.mode() & 0o077 != 0
                || meta.len() > 16_384
            {
                return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
            }
            let mut bytes = Vec::new();
            Read::by_ref(&mut file).take(16_385).read_to_end(&mut bytes)?;
            serde_json::from_slice::<Lease>(&bytes).map_err(std::io::Error::other)
        })();
        match result {
            Ok(lease)
                if serde_json::to_value(&lease.binding)
                    .ok()
                    .and_then(|value| Binding::parse(value).ok())
                    .is_some()
                    && lease.owner.pid > 0
                    && lease.owner.start_usec < 1_000_000
                    && lease.binding.private_root.is_absolute()
                    && state.starts_with(&lease.binding.private_root)
                    && state != lease.binding.private_root
                    && (lease.phase == Phase::Preparing || lease.host.is_some()) =>
            {
                Self::Held(lease)
            }
            Ok(_) => Self::Unreadable,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Self::Open,
            Err(_) => Self::Unreadable,
        }
    }
}

/// Only this temporary file is removed on error. Publication and directory sync must both succeed.
pub(super) fn persist(state: &Path, lease: &Lease) -> Result<(), String> {
    let temporary = state.join(format!(".capture-supervisor-{}", mint_secret()?));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(lease).map_err(std::io::Error::other)?)?;
        file.sync_all()?;
        std::fs::rename(&temporary, state.join("capture-supervisor.json"))?;
        std::fs::File::open(state)?.sync_all()
    })();
    let _ = std::fs::remove_file(&temporary);
    result.map_err(|_| "remote_capture_fence_unverified".into())
}
