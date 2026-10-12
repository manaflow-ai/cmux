//! Managed sandbox enrollment (`--managed --enrollment-file <path>`).
//!
//! Byte-compatible port of `packages/relay/bin/managed-enrollment.mjs`. The
//! contract is frozen in production images (the chatmux backend writes the
//! file; see `apps/backend/src/sandbox-terminal.ts`): version 1, fixed
//! client string, fixed backend allowlist, 0600 permissions, and the file is
//! shredded (overwritten then unlinked) after the read — before parsing or
//! networking, so snapshots, clones, and parse failures retain no live
//! claim. Tests mirror `managed-enrollment.test.mjs`.

use std::fs::OpenOptions;
use std::io::{Read, Seek, SeekFrom, Write};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
#[cfg(unix)]
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use url::{Host, Url};

use crate::config::{Config, ManagedEvents, ManagedIdentity};

pub const MANAGED_CLIENT: &str = "cmux-relay-managed-v1";
const ALLOWED_BACKENDS: [&str; 2] = ["https://api.chatmux.dev", "https://api-staging.chatmux.dev"];
const E2E_BACKEND_ENV: &str = "CHATMUX_RELAY_E2E_BACKEND";
/// Enrollment JSON is carried through the relay's bounded frame protocol.
const MAX_ENROLLMENT_BYTES: usize = 4 << 20;

#[cfg(unix)]
static NEXT_CLEANUP_ID: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, PartialEq, Eq)]
pub struct ManagedEnrollmentError(pub String);

impl std::fmt::Display for ManagedEnrollmentError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for ManagedEnrollmentError {}

fn error(message: &str) -> ManagedEnrollmentError {
    ManagedEnrollmentError(message.to_owned())
}

fn read_and_shred(path: &Path) -> Result<String, ManagedEnrollmentError> {
    // Open read-only first. Validation must not require write access: callers
    // may intentionally mount the enrollment file read-only. O_NOFOLLOW keeps
    // this descriptor pinned to a non-symlink inode.
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    let mut file =
        options.open(path).map_err(|_| error("Managed enrollment file is unavailable."))?;
    let metadata = file.metadata().map_err(|_| error("Managed enrollment file is unavailable."))?;
    if !metadata.is_file() {
        return Err(error("Managed enrollment file is unavailable."));
    }
    #[cfg(not(unix))]
    {
        // The current non-Unix toolchain does not expose a stable file
        // identity for checking a pathname before unlinking it. Do not read
        // or return enrollment contents unless cleanup can be tied to the
        // validated inode; callers must fail closed instead.
        return Err(error("Managed enrollment file is unavailable."));
    }
    let mut validation_error = None;
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(error("Managed enrollment file must be owned by the current user."));
        }
        // A hard-linked enrollment inode may have another live pathname. Do
        // not read or overwrite it: shredding would destroy data reachable
        // through that other pathname. Removing only this pathname is safe,
        // but leaves the other link (and its contents) intact.
        if metadata.nlink() != 1 {
            drop(file);
            unlink_if_same_inode(path, &metadata);
            return Err(error("Managed enrollment file is unavailable."));
        }
        if metadata.mode() & 0o777 != 0o600 {
            validation_error = Some(error("Managed enrollment file permissions must be 0600."));
        }
    }

    let mut contents =
        Vec::with_capacity(metadata.len().min((MAX_ENROLLMENT_BYTES as u64) + 1) as usize);
    // `Take` bounds every read from the file. Read one byte past the accepted
    // size so an exact-limit enrollment remains valid and an oversized one is
    // detected without reading the rest of the file.
    let read_result = {
        let mut limited = Read::by_ref(&mut file).take((MAX_ENROLLMENT_BYTES as u64) + 1);
        limited.read_to_end(&mut contents).map(|_| ())
    };
    let oversized = contents.len() > MAX_ENROLLMENT_BYTES;

    // Reopen for writing only after validation and reading. The second open
    // is still O_NOFOLLOW and must resolve to the descriptor's inode before it
    // can shred, so a path replacement cannot redirect writes to another file.
    #[cfg(unix)]
    let mut writable = {
        let mut write_options = OpenOptions::new();
        write_options.read(true).write(true).custom_flags(libc::O_NOFOLLOW);
        write_options.open(path).ok().filter(|candidate| {
            candidate.metadata().ok().is_some_and(|candidate_metadata| {
                file_identity_matches(&candidate_metadata, &metadata)
            })
        })
    };
    #[cfg(not(unix))]
    let mut writable: Option<std::fs::File> = None;

    if let Some(write_file) = writable.as_mut() {
        // Best-effort overwrite through the already-open descriptor. This
        // keeps shredding tied to the inode that was validated above.
        let _ = write_file.seek(SeekFrom::Start(0));
        // Truncation removes all logical contents. Limit the best-effort
        // physical overwrite so a large sparse file cannot force unbounded
        // cleanup I/O or temporary disk allocation.
        let mut remaining = metadata.len().min((MAX_ENROLLMENT_BYTES as u64) + 1);
        let zeros = [0_u8; 4096];
        while remaining > 0 {
            let chunk = remaining.min(zeros.len() as u64) as usize;
            if write_file.write_all(&zeros[..chunk]).is_err() {
                break;
            }
            remaining -= chunk as u64;
        }
        let _ = write_file.set_len(0);
        let _ = write_file.sync_all();
    }
    drop(writable);
    drop(file);
    // The path can be replaced while the file is open. Only unlink it when it
    // still names the validated inode, so a replacement is never deleted.
    unlink_if_same_inode(path, &metadata);
    if let Some(validation_error) = validation_error {
        return Err(validation_error);
    }
    read_result.map_err(|_| error("Managed enrollment file is unavailable."))?;
    if oversized {
        return Err(error("Managed enrollment file is invalid."));
    }
    String::from_utf8(contents).map_err(|_| error("Managed enrollment file is unavailable."))
}

#[cfg(unix)]
fn file_identity_matches(current: &std::fs::Metadata, expected: &std::fs::Metadata) -> bool {
    current.dev() == expected.dev() && current.ino() == expected.ino()
}

fn unlink_if_same_inode(path: &Path, expected: &std::fs::Metadata) {
    #[cfg(unix)]
    {
        // A metadata check followed by remove_file(path) is not atomic: a
        // producer can replace path after the check and have its enrollment
        // deleted. Move the pathname atomically into a private directory
        // first. The moved entry is then the only object we ever consider
        // removing, and the identity check cannot select a replacement at
        // the original pathname.
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let mut quarantine = None;
        for _ in 0..16 {
            let id = NEXT_CLEANUP_ID.fetch_add(1, Ordering::Relaxed);
            let candidate =
                parent.join(format!(".cmux-enrollment-cleanup-{}-{id}", std::process::id()));
            let mut builder = std::fs::DirBuilder::new();
            builder.mode(0o700);
            match builder.create(&candidate) {
                Ok(()) => {
                    quarantine = Some(candidate);
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(_) => return,
            }
        }
        let Some(quarantine) = quarantine else {
            return;
        };
        let moved = quarantine.join("entry");
        if std::fs::rename(path, &moved).is_err() {
            let _ = std::fs::remove_dir(&quarantine);
            return;
        }

        let matches = std::fs::symlink_metadata(&moved)
            .map(|current| current.is_file() && file_identity_matches(&current, expected))
            .unwrap_or(false);
        if matches {
            let _ = std::fs::remove_file(&moved);
            let _ = std::fs::remove_dir(&quarantine);
            return;
        }

        // The pathname was replaced before the rename. Restore the moved
        // object only when the pathname is still absent; hard_link never
        // overwrites a concurrently created replacement.
        if std::fs::hard_link(&moved, path).is_ok() {
            let _ = std::fs::remove_file(&moved);
            let _ = std::fs::remove_dir(&quarantine);
        }
    }

    #[cfg(not(unix))]
    {
        // Windows does not expose a stable file identity on the current
        // toolchain. Failing closed avoids deleting a concurrently replaced
        // pathname.
        let _ = (path, expected);
    }
}

fn string_field(value: &Value, name: &str) -> Option<String> {
    value.get(name).and_then(Value::as_str).map(str::to_owned)
}

/// Return the normalized origin for the conformance harness's backend
/// override. The override is intentionally narrower than the production
/// backend allowlist: only plain HTTP on the local machine is accepted.
///
/// `raw` is passed in by the caller so this validator stays deterministic and
/// unit tests do not need to mutate the process environment.
pub fn e2e_loopback_backend_override(raw: Option<&str>) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    let url = Url::parse(raw).ok()?;
    if url.scheme() != "http" {
        return None;
    }
    let loopback = match url.host()? {
        Host::Domain(host) => host == "localhost",
        Host::Ipv4(host) => host == Ipv4Addr::LOCALHOST,
        Host::Ipv6(host) => host == Ipv6Addr::LOCALHOST,
    };
    if !loopback {
        return None;
    }
    Some(url.origin().ascii_serialization())
}

fn environment_e2e_loopback_backend_override() -> Option<String> {
    std::env::var(E2E_BACKEND_ENV).ok().and_then(|raw| e2e_loopback_backend_override(Some(&raw)))
}

/// Load, validate, and destroy the one-shot enrollment file. `now_ms` is
/// Unix time in milliseconds (injectable for tests).
pub fn load_managed_enrollment_file(
    path: &str,
    now_ms: i64,
) -> Result<Config, ManagedEnrollmentError> {
    load_managed_enrollment_file_with_override(
        path,
        now_ms,
        environment_e2e_loopback_backend_override().as_deref(),
    )
}

fn load_managed_enrollment_file_with_override(
    path: &str,
    now_ms: i64,
    e2e_backend: Option<&str>,
) -> Result<Config, ManagedEnrollmentError> {
    if path.is_empty() {
        return Err(error("Managed enrollment file is required."));
    }
    let raw = read_and_shred(Path::new(path))?;
    let value: Value =
        serde_json::from_str(&raw).map_err(|_| error("Managed enrollment file is invalid."))?;

    let backend = string_field(&value, "backend").unwrap_or_default();
    let allowed_backend = ALLOWED_BACKENDS.contains(&backend.as_str())
        || e2e_backend.is_some_and(|override_backend| override_backend == backend);
    let token = string_field(&value, "token").unwrap_or_default();
    let expires_at_ms = string_field(&value, "expiresAt")
        .and_then(|raw| OffsetDateTime::parse(&raw, &Rfc3339).ok())
        .and_then(|when| i64::try_from(when.unix_timestamp_nanos() / 1_000_000).ok());

    let version = value.get("version").and_then(Value::as_i64);
    let valid = matches!(version, Some(1 | 2))
        && string_field(&value, "client").as_deref() == Some(MANAGED_CLIENT)
        && allowed_backend
        && token.len() >= 32
        && expires_at_ms.is_some_and(|expiry| expiry > now_ms);
    let (Some(machine_id), Some(org_id), Some(target_ref), Some(generation), Some(provider), true) = (
        string_field(&value, "machineId"),
        string_field(&value, "orgId"),
        string_field(&value, "targetRef"),
        string_field(&value, "generation"),
        string_field(&value, "provider"),
        valid,
    ) else {
        return Err(error("Managed enrollment file is invalid or expired."));
    };

    let events = parse_events(&value, &backend, version == Some(2))?;

    Ok(Config {
        backend,
        device_id: machine_id,
        token,
        name: Some("managed sandbox".to_owned()),
        trust: Some("supervised".to_owned()),
        managed: Some(ManagedIdentity {
            client: MANAGED_CLIENT.to_owned(),
            org_id,
            target_ref,
            generation,
            provider,
        }),
        events,
        ..Config::default()
    })
}

/// Parse the optional v2 journal endpoint. v1 treats it as an unknown field,
/// matching the Node relay's forward-tolerant behavior. A v2 endpoint is
/// accepted only when its origin is exactly the already allowlisted backend
/// origin, so a tampered enrollment cannot exfiltrate journal records.
fn parse_events(
    value: &Value,
    backend: &str,
    strict: bool,
) -> Result<Option<ManagedEvents>, ManagedEnrollmentError> {
    let Some(raw) = value.get("events") else { return Ok(None) };
    if raw.is_null() {
        return Ok(None);
    }
    let Some(object) = raw.as_object() else {
        return if strict {
            Err(error("Managed enrollment events endpoint is invalid."))
        } else {
            Ok(None)
        };
    };
    let Some(url) = object.get("url").and_then(Value::as_str).filter(|url| !url.is_empty()) else {
        return if strict {
            Err(error("Managed enrollment events endpoint is invalid."))
        } else {
            Ok(None)
        };
    };
    let Some(token) = object.get("token").and_then(Value::as_str).filter(|token| !token.is_empty())
    else {
        return if strict {
            Err(error("Managed enrollment events endpoint is invalid."))
        } else {
            Ok(None)
        };
    };
    let same_origin = Url::parse(url)
        .ok()
        .zip(Url::parse(backend).ok())
        .is_some_and(|(events_url, backend_url)| events_url.origin() == backend_url.origin());
    if !same_origin {
        return if strict {
            Err(error("Managed enrollment events endpoint is invalid."))
        } else {
            Ok(None)
        };
    }
    Ok(Some(ManagedEvents { url: url.to_owned(), token: token.to_owned() }))
}
