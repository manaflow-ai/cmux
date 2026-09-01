//! Managed sandbox enrollment (`--managed --enrollment-file <path>`).
//!
//! Byte-compatible port of `packages/relay/bin/managed-enrollment.mjs`. The
//! contract is frozen in production images (the chatmux backend writes the
//! file; see `apps/backend/src/sandbox-terminal.ts`): version 1, fixed
//! client string, fixed backend allowlist, 0600 permissions, and the file is
//! shredded (overwritten then unlinked) after the read — before parsing or
//! networking, so snapshots, clones, and parse failures retain no live
//! claim. Tests mirror `managed-enrollment.test.mjs`.

use std::path::Path;

use serde_json::Value;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::config::{Config, ManagedIdentity};

pub const MANAGED_CLIENT: &str = "cmux-relay-managed-v1";
const ALLOWED_BACKENDS: [&str; 2] = ["https://api.chatmux.dev", "https://api-staging.chatmux.dev"];

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
    let raw = (|| -> Result<String, ManagedEnrollmentError> {
        let metadata = std::fs::metadata(path)
            .map_err(|_| error("Managed enrollment file is unavailable."))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            if metadata.mode() & 0o077 != 0 {
                return Err(error("Managed enrollment file permissions must be 0600."));
            }
        }
        let _ = metadata;
        std::fs::read_to_string(path).map_err(|_| error("Managed enrollment file is unavailable."))
    })();
    // Best-effort overwrite then unlink, before parsing or networking.
    if let Ok(contents) = &raw {
        let _ = std::fs::write(path, vec![0_u8; contents.len()]);
    }
    let _ = std::fs::remove_file(path);
    raw
}

fn string_field(value: &Value, name: &str) -> Option<String> {
    value.get(name).and_then(Value::as_str).map(str::to_owned)
}

/// Load, validate, and destroy the one-shot enrollment file. `now_ms` is
/// Unix time in milliseconds (injectable for tests).
pub fn load_managed_enrollment_file(
    path: &str,
    now_ms: i64,
) -> Result<Config, ManagedEnrollmentError> {
    if path.is_empty() {
        return Err(error("Managed enrollment file is required."));
    }
    let raw = read_and_shred(Path::new(path))?;
    let value: Value =
        serde_json::from_str(&raw).map_err(|_| error("Managed enrollment file is invalid."))?;

    let backend = string_field(&value, "backend").unwrap_or_default();
    let allowed_backend = ALLOWED_BACKENDS.contains(&backend.as_str());
    let token = string_field(&value, "token").unwrap_or_default();
    let expires_at_ms = string_field(&value, "expiresAt")
        .and_then(|raw| OffsetDateTime::parse(&raw, &Rfc3339).ok())
        .and_then(|when| i64::try_from(when.unix_timestamp_nanos() / 1_000_000).ok());

    let valid = value.get("version").and_then(Value::as_i64) == Some(1)
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
        ..Config::default()
    })
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
}
