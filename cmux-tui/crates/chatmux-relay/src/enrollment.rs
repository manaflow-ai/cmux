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
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use url::{Host, Url};

use crate::config::{Config, ManagedEvents, ManagedIdentity};

pub const MANAGED_CLIENT: &str = "cmux-relay-managed-v1";
const ALLOWED_BACKENDS: [&str; 2] = ["https://api.chatmux.dev", "https://api-staging.chatmux.dev"];
const E2E_BACKEND_ENV: &str = "CHATMUX_RELAY_E2E_BACKEND";

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
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW);
    let mut file =
        options.open(path).map_err(|_| error("Managed enrollment file is unavailable."))?;
    let metadata = file.metadata().map_err(|_| error("Managed enrollment file is unavailable."))?;
    if !metadata.is_file() {
        return Err(error("Managed enrollment file is unavailable."));
    }
    let mut validation_error = None;
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(error("Managed enrollment file must be owned by the current user."));
        }
        if metadata.mode() & 0o077 != 0 {
            validation_error = Some(error("Managed enrollment file permissions must be 0600."));
        }
    }

    let mut contents = Vec::new();
    let read_result = file.read_to_end(&mut contents);
    // Best-effort overwrite through the already-open descriptor. This avoids
    // following a replacement symlink and keeps shredding tied to the inode
    // that was validated above.
    let _ = file.seek(SeekFrom::Start(0));
    let mut remaining = metadata.len();
    let zeros = [0_u8; 4096];
    while remaining > 0 {
        let chunk = remaining.min(zeros.len() as u64) as usize;
        if file.write_all(&zeros[..chunk]).is_err() {
            break;
        }
        remaining -= chunk as u64;
    }
    let _ = file.set_len(0);
    let _ = file.sync_all();
    drop(file);
    // The path can be replaced while the file is open. Only unlink it when it
    // still names the validated inode, so a replacement is never deleted.
    let same_file = std::fs::metadata(path)
        .map(|current| {
            #[cfg(unix)]
            {
                current.dev() == metadata.dev() && current.ino() == metadata.ino()
            }
            #[cfg(not(unix))]
            {
                let _ = current;
                true
            }
        })
        .unwrap_or(false);
    if same_file {
        let _ = std::fs::remove_file(path);
    }
    if let Some(validation_error) = validation_error {
        return Err(validation_error);
    }
    read_result.map_err(|_| error("Managed enrollment file is unavailable."))?;
    String::from_utf8(contents).map_err(|_| error("Managed enrollment file is unavailable."))
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NOW: i64 = 1_754_913_600_000; // 2025-08-11T12:00:00.000Z
    const SECRET: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn enrollment() -> Value {
        json!({
            "version": 1,
            "backend": "https://api.chatmux.dev",
            "machineId": "dev_managed1234",
            "token": SECRET,
            "orgId": "org_12345678",
            "targetRef": format!("sbx_{}", "T".repeat(32)),
            "generation": "2025-08-11T11:59:00.000Z",
            "provider": "daytona",
            "expiresAt": "2025-08-11T12:01:00.000Z",
            "client": MANAGED_CLIENT,
        })
    }

    fn fixture(value: &Value, mode: u32, name: &str) -> String {
        let mut dir = std::env::temp_dir();
        dir.push(format!("cmux-managed-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("enrollment.json");
        std::fs::write(&path, serde_json::to_string(value).unwrap()).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
        }
        #[cfg(not(unix))]
        let _ = mode;
        path.to_string_lossy().into_owned()
    }

    #[test]
    fn managed_enrollment_is_0600_fixed_backend_runtime_only_and_deleted() {
        let path = fixture(&enrollment(), 0o600, "valid");
        let loaded = load_managed_enrollment_file(&path, NOW).expect("valid enrollment");
        assert_eq!(loaded.token, SECRET);
        assert_eq!(loaded.device_id, "dev_managed1234");
        assert_eq!(loaded.backend, "https://api.chatmux.dev");
        assert_eq!(loaded.name.as_deref(), Some("managed sandbox"));
        assert_eq!(loaded.trust.as_deref(), Some("supervised"));
        let managed = loaded.managed.expect("managed identity");
        assert_eq!(managed.client, MANAGED_CLIENT);
        assert_eq!(managed.org_id, "org_12345678");
        assert_eq!(managed.provider, "daytona");
        assert!(loaded.events.is_none());
        assert!(!Path::new(&path).exists(), "file must be shredded after the read");
    }

    #[test]
    fn wrong_endpoint_expiry_or_permissions_fail_and_delete_the_file() {
        let mut wrong_backend = enrollment();
        wrong_backend["backend"] = Value::from("https://api.evil.example");
        let path = fixture(&wrong_backend, 0o600, "backend");
        let error = load_managed_enrollment_file(&path, NOW).expect_err("backend refused");
        assert_eq!(error.0, "Managed enrollment file is invalid or expired.");
        assert!(!Path::new(&path).exists());

        let mut expired = enrollment();
        expired["expiresAt"] = Value::from("2025-08-11T11:59:59.000Z");
        let path = fixture(&expired, 0o600, "expired");
        assert!(load_managed_enrollment_file(&path, NOW).is_err());
        assert!(!Path::new(&path).exists());

        #[cfg(unix)]
        {
            let path = fixture(&enrollment(), 0o644, "perms");
            let error = load_managed_enrollment_file(&path, NOW).expect_err("perms refused");
            assert_eq!(error.0, "Managed enrollment file permissions must be 0600.");
            assert!(!Path::new(&path).exists(), "file is deleted even on refusal");
        }

        let mut short_token = enrollment();
        short_token["token"] = Value::from("short");
        let path = fixture(&short_token, 0o600, "token");
        assert!(load_managed_enrollment_file(&path, NOW).is_err());

        let mut wrong_client = enrollment();
        wrong_client["client"] = Value::from("cmux-relay-managed-v2");
        let path = fixture(&wrong_client, 0o600, "client");
        assert!(load_managed_enrollment_file(&path, NOW).is_err());

        assert_eq!(
            load_managed_enrollment_file("", NOW).expect_err("path required").0,
            "Managed enrollment file is required."
        );
        assert_eq!(
            load_managed_enrollment_file("/nonexistent/enroll.json", NOW)
                .expect_err("missing file")
                .0,
            "Managed enrollment file is unavailable."
        );
    }

    #[cfg(unix)]
    #[test]
    fn enrollment_symlink_is_rejected_without_shredding_target() {
        let dir = std::env::temp_dir().join(format!("cmux-managed-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("target.json");
        let link = dir.join("enrollment.json");
        let expected = serde_json::to_string(&enrollment()).unwrap();
        std::fs::write(&target, &expected).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let error = load_managed_enrollment_file(link.to_str().unwrap(), NOW)
            .expect_err("symlink enrollment must be rejected");
        assert_eq!(error.0, "Managed enrollment file is unavailable.");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), expected);
        assert!(std::fs::symlink_metadata(&link).is_ok(), "rejected symlink must not be unlinked");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn valid_v2_keeps_events_runtime_only_and_origin_bound() {
        let mut value = enrollment();
        value["version"] = Value::from(2);
        value["events"] = json!({
            "url": "https://api.chatmux.dev/v2/agent-events",
            "token": "e".repeat(48),
        });
        let path = fixture(&value, 0o600, "v2");
        let loaded = load_managed_enrollment_file(&path, NOW).expect("valid v2 enrollment");
        assert_eq!(
            loaded.events,
            Some(ManagedEvents {
                url: "https://api.chatmux.dev/v2/agent-events".to_owned(),
                token: "e".repeat(48),
            })
        );
    }

    #[test]
    fn malformed_or_expired_v2_is_rejected_and_deleted() {
        for events in [
            json!({"url": "https://attacker.invalid/events", "token": "e"}),
            json!({"url": "not a url", "token": "e"}),
            json!({"url": "https://api.chatmux.dev/events"}),
            json!("https://api.chatmux.dev/events"),
        ] {
            let mut value = enrollment();
            value["version"] = Value::from(2);
            value["events"] = events;
            let path = fixture(&value, 0o600, "v2-invalid");
            let error = load_managed_enrollment_file(&path, NOW).expect_err("invalid events");
            assert_eq!(error.0, "Managed enrollment events endpoint is invalid.");
            assert!(!Path::new(&path).exists());
        }
        let mut expired = enrollment();
        expired["version"] = Value::from(2);
        expired["expiresAt"] = Value::from("2025-08-11T11:59:59.000Z");
        expired["events"] = json!({
            "url": "https://api.chatmux.dev/events",
            "token": "e".repeat(48),
        });
        let path = fixture(&expired, 0o600, "v2-expired");
        assert_eq!(
            load_managed_enrollment_file(&path, NOW).expect_err("expired v2").0,
            "Managed enrollment file is invalid or expired."
        );
        assert!(!Path::new(&path).exists());
    }

    #[test]
    fn v1_ignores_malformed_events_for_backward_compatibility() {
        let mut value = enrollment();
        value["events"] = json!({"url": "https://attacker.invalid/events", "token": "e"});
        let path = fixture(&value, 0o600, "v1-events");
        let loaded = load_managed_enrollment_file(&path, NOW).expect("v1 remains compatible");
        assert!(loaded.events.is_none());
    }

    #[test]
    fn e2e_override_accepts_only_http_loopback_origins() {
        for (raw, expected) in [
            (Some("http://127.0.0.1:8917"), Some("http://127.0.0.1:8917")),
            (Some("http://localhost:8917/path"), Some("http://localhost:8917")),
            (Some("http://[::1]:8917"), Some("http://[::1]:8917")),
        ] {
            assert_eq!(
                e2e_loopback_backend_override(raw),
                expected.map(str::to_owned),
                "unexpected result for {raw:?}",
            );
        }
        for raw in [
            None,
            Some(""),
            Some("not a url"),
            Some("https://127.0.0.1:8917"),
            Some("http://api.evil.example:8917"),
            Some("http://10.0.0.5:8917"),
            Some("http://127.0.0.2:8917"),
        ] {
            assert_eq!(e2e_loopback_backend_override(raw), None, "expected {raw:?} to be refused",);
        }
    }

    #[test]
    fn e2e_override_requires_exact_origin_and_preserves_production_allowlist() {
        let mut loopback = enrollment();
        loopback["version"] = Value::from(2);
        loopback["backend"] = Value::from("http://127.0.0.1:8917");
        loopback["events"] = json!({
            "url": "http://127.0.0.1:8917/v2/agent-events",
            "token": "e".repeat(48),
        });
        let path = fixture(&loopback, 0o600, "e2e-loopback");
        let loaded =
            load_managed_enrollment_file_with_override(&path, NOW, Some("http://127.0.0.1:8917"))
                .expect("matching loopback origin should load");
        assert_eq!(loaded.backend, "http://127.0.0.1:8917");
        assert_eq!(
            loaded.events,
            Some(ManagedEvents {
                url: "http://127.0.0.1:8917/v2/agent-events".to_owned(),
                token: "e".repeat(48),
            })
        );

        let mut mismatched = loopback.clone();
        mismatched["backend"] = Value::from("http://127.0.0.1:9999");
        let path = fixture(&mismatched, 0o600, "e2e-mismatched");
        assert!(
            load_managed_enrollment_file_with_override(&path, NOW, Some("http://127.0.0.1:8917"),)
                .is_err()
        );

        let mut remote = loopback;
        remote["backend"] = Value::from("https://attacker.invalid");
        let path = fixture(&remote, 0o600, "e2e-remote");
        assert!(load_managed_enrollment_file_with_override(&path, NOW, None,).is_err());

        let path = fixture(&enrollment(), 0o600, "e2e-production");
        let loaded =
            load_managed_enrollment_file_with_override(&path, NOW, Some("http://127.0.0.1:8917"))
                .expect("production backend must remain allowed");
        assert_eq!(loaded.backend, "https://api.chatmux.dev");
    }
}
