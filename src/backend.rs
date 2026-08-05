use std::ffi::OsString;
use std::fs;
use std::io::{BufRead, BufReader};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use sha2::{Digest, Sha256};

use crate::cli::Error;
use crate::process;

const SUBROUTER_VERSION: &str = "0.1.60";
const RELEASE_BASE: &str = "https://github.com/manaflow-ai/subrouter/releases/download";
const DEFAULT_API_URL: &str = "https://coderouter.dev";

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
    let data = data_directory()?;
    Ok(data
        .join("coderouter")
        .join("bin")
        .join(format!("v{SUBROUTER_VERSION}"))
        .join(if cfg!(windows) {
            "subrouter.exe"
        } else {
            "subrouter"
        }))
}

fn data_directory() -> Result<PathBuf, Error> {
    if let Some(path) = std::env::var_os("CODEROUTER_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    dirs::data_local_dir()
        .or_else(dirs::home_dir)
        .ok_or_else(|| Error::Backend("could not determine a user data directory".into()))
}

fn cloud_config_path() -> Result<PathBuf, Error> {
    Ok(data_directory()?.join("coderouter").join("cloud.json"))
}

fn child_environment() -> Result<Vec<(OsString, OsString)>, Error> {
    Ok(vec![(
        OsString::from("SUBROUTER_CLOUD_CONFIG"),
        cloud_config_path()?.into_os_string(),
    )])
}

fn api_url() -> Result<String, Error> {
    let value = std::env::var("CODEROUTER_API_URL")
        .unwrap_or_else(|_| DEFAULT_API_URL.to_owned())
        .trim_end_matches('/')
        .to_owned();
    let parsed = reqwest::Url::parse(&value)
        .map_err(|error| Error::Backend(format!("invalid CODEROUTER_API_URL: {error}")))?;
    let loopback = parsed.host_str().is_some_and(|host| {
        host == "localhost"
            || host
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
    });
    if parsed.host_str().is_none()
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || (parsed.path() != "" && parsed.path() != "/")
        || (parsed.scheme() != "https" && !(parsed.scheme() == "http" && loopback))
    {
        return Err(Error::Backend(
            "CODEROUTER_API_URL must be an HTTPS origin (HTTP is allowed only on loopback)".into(),
        ));
    }
    Ok(value)
}

pub fn run_attached(
    binary: &Path,
    args: &[OsString],
    extra_env: &[(&str, &str)],
) -> Result<i32, Error> {
    let mut environment = child_environment()?;
    environment.extend(
        extra_env
            .iter()
            .map(|(key, value)| (OsString::from(key), OsString::from(value))),
    );
    process::run_attached_with_os_env(binary, args, &[], &environment)
}

fn output(binary: &Path, args: &[&str]) -> Result<std::process::Output, Error> {
    process::output_with_os_env(binary, args, &child_environment()?)
}

pub fn login(binary: &Path, extra_args: &[OsString]) -> Result<i32, Error> {
    let mut args = vec![
        process::os("login"),
        process::os("--base-url"),
        process::os(api_url()?),
    ];
    args.extend_from_slice(extra_args);
    run_attached(binary, &args, &[])
}

pub fn login_device(binary: &Path, extra_args: &[OsString]) -> Result<i32, Error> {
    let origin = api_url()?;
    let mut args = vec![
        process::os("login"),
        process::os("--base-url"),
        process::os(&origin),
        process::os("--no-browser"),
    ];
    args.extend_from_slice(extra_args);

    let mut command = Command::new(binary);
    command
        .args(&args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    for (key, value) in child_environment()? {
        command.env(key, value);
    }
    let mut child = command.spawn().map_err(|source| Error::Spawn {
        executable: binary.to_path_buf(),
        source,
    })?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| Error::Backend("could not read the authorization code".into()))?;
    let mut showed_code = false;
    for line in BufReader::new(stdout).lines() {
        let line = line?;
        if line.trim() == "Approve Subrouter at:" {
            continue;
        }
        if let Ok(url) = reqwest::Url::parse(line.trim())
            && let Some(code) = url
                .query_pairs()
                .find_map(|(key, value)| (key == "login_code").then(|| value.into_owned()))
        {
            println!("Open {origin}/authorize");
            println!("Authorization code: {code}");
            showed_code = true;
            continue;
        }
        println!("{line}");
    }
    if !showed_code {
        return Err(Error::Backend(
            "the authorization server did not return a login code".into(),
        ));
    }
    let status = child.wait().map_err(|source| Error::Spawn {
        executable: binary.to_path_buf(),
        source,
    })?;
    Ok(status.code().unwrap_or(1))
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
        "subrouter_0.1.60_darwin_amd64" => {
            Some("5bc8028cc070e59a564636bf45507a548470e41a2134bc0087a1607f9b448dd2")
        }
        "subrouter_0.1.60_darwin_arm64" => {
            Some("769e504b731ef8b43db67e7651dcfe9ae169516570c7d2d2d211a6f997be1a7c")
        }
        "subrouter_0.1.60_linux_amd64" => {
            Some("6a8daa1361030311bdbe25a06cd4940e4dd07a45758c13c2dc8d687e70d87303")
        }
        "subrouter_0.1.60_windows_amd64.exe" => {
            Some("aa4f6121afa73d2ab140f696e92bfdabaf290a7dccac4543b3c68262557e7ad6")
        }
        _ => None,
    }
}

pub fn ensure_hosted_login(binary: &Path) -> Result<i32, Error> {
    let status = output(binary, &["team", "current"])?;
    if status.status.success() {
        return Ok(0);
    }
    login(binary, &[])
}

pub fn ensure_ready(binary: &Path) -> Result<i32, Error> {
    let login = ensure_hosted_login(binary)?;
    if login != 0 {
        return Ok(login);
    }

    let storage = output(binary, &["storage"])?;
    let hosted = storage.status.success()
        && String::from_utf8_lossy(&storage.stdout)
            .to_ascii_lowercase()
            .contains("hosted");
    if !hosted {
        let selected = run_attached(
            binary,
            &[process::os("storage"), process::os("hosted")],
            &[],
        )?;
        if selected != 0 {
            return Ok(selected);
        }
    }

    let marker = data_directory()?.join("coderouter").join("daemon-origin");
    let daemon = output(binary, &["daemon", "status"])?;
    let expected_origin = api_url()?;
    let configured = fs::read_to_string(&marker).is_ok_and(|value| value.trim() == expected_origin);
    if daemon.status.success() && configured {
        return Ok(0);
    }
    eprintln!("CodeRouter needs one-time local proxy setup.");
    let setup = run_attached(
        binary,
        &[process::os("setup"), process::os("--no-config")],
        &[],
    )?;
    if setup == 0 {
        if let Some(parent) = marker.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(marker, format!("{expected_origin}\n"))?;
    }
    Ok(setup)
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
