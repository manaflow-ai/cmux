use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::cli::Error;
use crate::process;

const SUBROUTER_VERSION: &str = "0.1.56";
const RELEASE_BASE: &str = "https://github.com/manaflow-ai/subrouter/releases/download";

pub fn resolve() -> Result<PathBuf, Error> {
    if let Some(explicit) = std::env::var_os("CODEROUTER_SUBROUTER_BIN") {
        let path = PathBuf::from(explicit);
        if path.is_file() {
            return Ok(path);
        }
        return Err(Error::Backend(format!(
            "CODEROUTER_SUBROUTER_BIN does not point to a file: {}",
            path.display()
        )));
    }

    if let Some(path) = process::find_on_path("subrouter") {
        return Ok(path);
    }

    let managed = managed_binary_path()?;
    if managed.is_file() {
        return Ok(managed);
    }
    install_managed(&managed)?;
    Ok(managed)
}

fn install_managed(destination: &Path) -> Result<(), Error> {
    let asset = release_asset()?;
    let asset_url = format!("{RELEASE_BASE}/v{SUBROUTER_VERSION}/{asset}");
    let expected = release_checksum(&asset).ok_or_else(|| {
        Error::Backend(format!(
            "CodeRouter has no pinned checksum for Subrouter asset {asset}"
        ))
    })?;
    eprintln!("CodeRouter needs its routing engine; installing Subrouter v{SUBROUTER_VERSION}…");

    let client = reqwest::blocking::Client::builder()
        .user_agent(format!("coderouter/{}", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| Error::Backend(error.to_string()))?;
    let mut response = client
        .get(asset_url)
        .send()
        .and_then(reqwest::blocking::Response::error_for_status)
        .map_err(|error| Error::Backend(format!("could not download Subrouter: {error}")))?;
    let parent = destination
        .parent()
        .ok_or_else(|| Error::Backend("invalid managed binary path".into()))?;
    fs::create_dir_all(parent)?;
    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = response.read(&mut buffer).map_err(|error| {
            Error::Backend(format!("could not read Subrouter download: {error}"))
        })?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
        temporary.write_all(&buffer[..count])?;
    }
    let actual = format!("{:x}", hasher.finalize());
    if actual != expected {
        return Err(Error::Backend(format!(
            "Subrouter checksum mismatch: expected {expected}, received {actual}"
        )));
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o755))?;
    }
    temporary
        .persist(destination)
        .map_err(|error| Error::Io(error.error))?;
    eprintln!("Installed {}", destination.display());
    Ok(())
}

fn managed_binary_path() -> Result<PathBuf, Error> {
    let data = dirs::data_local_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| Error::Backend("could not determine a user data directory".into()))?;
    Ok(data.join("coderouter").join("bin").join(if cfg!(windows) {
        "subrouter.exe"
    } else {
        "subrouter"
    }))
}

fn release_asset() -> Result<String, Error> {
    let os = match std::env::consts::OS {
        "macos" => "darwin",
        "linux" => "linux",
        "windows" => "windows",
        other => {
            return Err(Error::Backend(format!(
                "automatic installation is not supported on {other}; install subrouter manually"
            )));
        }
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => {
            return Err(Error::Backend(format!(
                "automatic installation is not supported on {other}; install subrouter manually"
            )));
        }
    };
    let suffix = if os == "windows" { ".exe" } else { "" };
    Ok(format!("subrouter_{SUBROUTER_VERSION}_{os}_{arch}{suffix}"))
}

fn release_checksum(asset: &str) -> Option<&'static str> {
    match asset {
        "subrouter_0.1.56_darwin_amd64" => {
            Some("84e7572b013d3b638bac4353027b075dc9e31a17db550202d721769f0ddcdb42")
        }
        "subrouter_0.1.56_darwin_arm64" => {
            Some("d104bb03476cbcb59fbb207bddaaeef8af7bc5c25ed7c508ffd0506540a41ec4")
        }
        "subrouter_0.1.56_linux_amd64" => {
            Some("19c644dc251b38afd4a0abedb6d4f533f91a3b1f5630821bc431ea807c1a04dc")
        }
        "subrouter_0.1.56_windows_amd64.exe" => {
            Some("b214122e1b4b5311c78722fb05220846336f2126732f2c043507ad22c3033b72")
        }
        _ => None,
    }
}

pub fn ensure_hosted_login(binary: &Path) -> Result<i32, Error> {
    let status = process::output(binary, &["team", "current"])?;
    if status.status.success() {
        return Ok(0);
    }
    process::run_attached(binary, &[process::os("login")], &[])
}

pub fn ensure_ready(binary: &Path) -> Result<i32, Error> {
    let login = ensure_hosted_login(binary)?;
    if login != 0 {
        return Ok(login);
    }

    let storage = process::output(binary, &["storage"])?;
    let hosted = storage.status.success()
        && String::from_utf8_lossy(&storage.stdout)
            .to_ascii_lowercase()
            .contains("hosted");
    if !hosted {
        let selected = process::run_attached(
            binary,
            &[process::os("storage"), process::os("hosted")],
            &[],
        )?;
        if selected != 0 {
            return Ok(selected);
        }
    }

    let daemon = process::output(binary, &["daemon", "status"])?;
    if daemon.status.success() {
        return Ok(0);
    }
    eprintln!("CodeRouter needs one-time local proxy setup.");
    process::run_attached(binary, &[process::os("setup")], &[])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_assets_have_pinned_checksums() {
        let asset = release_asset().expect("supported test platform");
        assert!(release_checksum(&asset).is_some());
    }

    #[test]
    fn rejects_missing_release_checksum() {
        assert_eq!(release_checksum("unknown"), None);
    }
}
