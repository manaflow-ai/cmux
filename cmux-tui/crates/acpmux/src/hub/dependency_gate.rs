//! Pre-execution package metadata for the dependency gate.
//!
//! The gate only examines the command in the permission request. It never watches shell output,
//! and a registry outage becomes an explicit card state after a short bounded request.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const REQUEST_TIMEOUT: Duration = Duration::from_millis(1_200);
const MAX_PACKAGES: usize = 8;

#[derive(Debug, Clone, PartialEq, Eq)]
struct PackageSpec {
    ecosystem: &'static str,
    name: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PackageMetadata {
    ecosystem: &'static str,
    name: String,
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    age_days: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    weekly_downloads: Option<u64>,
    maintainers: u64,
    install_scripts: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    lookalike: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NpmResponse {
    #[serde(rename = "dist-tags")]
    dist_tags: Option<NpmDistTags>,
    time: Option<HashMap<String, String>>,
    maintainers: Option<Vec<serde_json::Value>>,
    versions: Option<HashMap<String, NpmVersion>>,
}

#[derive(Debug, Deserialize)]
struct NpmDistTags {
    latest: Option<String>,
}

#[derive(Debug, Deserialize)]
struct NpmVersion {
    scripts: Option<HashMap<String, String>>,
}

#[derive(Debug, Deserialize)]
struct NpmDownloads {
    downloads: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct PyPiResponse {
    info: Option<PyPiInfo>,
    releases: Option<HashMap<String, Vec<PyPiRelease>>>,
}

#[derive(Debug, Deserialize)]
struct PyPiInfo {
    version: Option<String>,
    author: Option<String>,
    maintainers: Option<Vec<serde_json::Value>>,
}

#[derive(Debug, Deserialize)]
struct PyPiRelease {
    upload_time_iso_8601: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CratesResponse {
    #[serde(rename = "crate")]
    krate: Option<CrateInfo>,
}

#[derive(Debug, Deserialize)]
struct CrateInfo {
    created_at: Option<String>,
    max_stable_version: Option<String>,
    downloads: Option<u64>,
}

static CACHE: OnceLock<Mutex<HashMap<String, PackageMetadata>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<String, PackageMetadata>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Adds dependency metadata to an execute permission request. Returns whether a dependency gate
/// card should be shown. A request with no recognized package command is untouched.
pub(crate) async fn inspect(request: &mut Value) -> bool {
    let Some(command) = command(request) else { return false };
    let packages = parse_command(&command);
    if packages.is_empty() {
        return false;
    }

    let mut metadata = Vec::with_capacity(packages.len());
    for package in packages.into_iter().take(MAX_PACKAGES) {
        let key = format!("{}:{}", package.ecosystem, package.name);
        if let Some(cached) = cache().lock().ok().and_then(|cache| cache.get(&key).cloned()) {
            metadata.push(cached);
            continue;
        }
        let fetched = fetch(package.clone()).await;
        if let Ok(mut cache) = cache().lock() {
            cache.insert(key, fetched.clone());
        }
        metadata.push(fetched);
    }

    let status = if metadata.iter().all(|item| item.status == "ok") { "ok" } else { "unavailable" };
    let tool = request.pointer_mut("/toolCall").and_then(Value::as_object_mut);
    let Some(tool) = tool else { return false };
    let meta = tool.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    let Some(meta) = meta.as_object_mut() else { return false };
    let acpmux = meta.entry("acpmux").or_insert_with(|| json!({}));
    if !acpmux.is_object() {
        *acpmux = json!({});
    }
    let Some(acpmux) = acpmux.as_object_mut() else { return false };
    acpmux.insert("dependency".into(), json!({"status": status, "packages": metadata}));
    true
}

fn command(request: &Value) -> Option<String> {
    let value = request.pointer("/toolCall/rawInput/command")?;
    match value {
        Value::String(command) => Some(command.clone()),
        Value::Array(argv) => {
            let values: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            match values.as_slice() {
                [shell, flag, script]
                    if matches!(shell.rsplit('/').next(), Some("sh" | "bash" | "zsh"))
                        && matches!(*flag, "-c" | "-lc") => Some((*script).to_owned()),
                _ => None,
            }
        }
        _ => None,
    }
}

fn parse_command(command: &str) -> Vec<PackageSpec> {
    command
        .split([';', '\n'])
        .flat_map(|part| part.split("&&").flat_map(|part| part.split("||")))
        .flat_map(parse_segment)
        .collect()
}

fn parse_segment(segment: &str) -> Vec<PackageSpec> {
    let words = shell_words(segment);
    let Some((program, args)) = words.split_first() else { return Vec::new() };
    let program = program.rsplit('/').next().unwrap_or(program.as_str());
    let (ecosystem, index) = match program {
        "npm" | "pnpm" | "yarn" | "bun" => {
            let Some(index) = args.iter().position(|arg| matches!(arg.as_str(), "add" | "install" | "i")) else { return Vec::new() };
            ("npm", index + 1)
        }
        "pip" | "pip3" => {
            let Some(index) = args.iter().position(|arg| arg == "install") else { return Vec::new() };
            ("pypi", index + 1)
        }
        "uv" => {
            let Some(index) = args.iter().position(|arg| matches!(arg.as_str(), "add" | "install")) else { return Vec::new() };
            ("pypi", index + 1)
        }
        "poetry" => {
            let Some(index) = args.iter().position(|arg| arg == "add") else { return Vec::new() };
            ("pypi", index + 1)
        }
        "cargo" => {
            let Some(index) = args.iter().position(|arg| arg == "add") else { return Vec::new() };
            ("crates", index + 1)
        }
        "go" => {
            let Some(index) = args.iter().position(|arg| arg == "get") else { return Vec::new() };
            ("go", index + 1)
        }
        "brew" => {
            let Some(index) = args.iter().position(|arg| arg == "install") else { return Vec::new() };
            ("brew", index + 1)
        }
        _ => return Vec::new(),
    };
    args.get(index..)
        .into_iter()
        .flatten()
        .filter_map(|arg| normalize_name(ecosystem, arg))
        .map(|name| PackageSpec { ecosystem, name })
        .collect()
}

fn normalize_name(ecosystem: &str, raw: &str) -> Option<String> {
    if raw.starts_with('-') || raw == "." || raw.starts_with("./") || raw.starts_with("http") {
        return None;
    }
    let raw = raw.trim_matches(|c: char| c == '\'' || c == '"');
    if raw.is_empty() { return None; }
    let name = match ecosystem {
        "npm" if raw.starts_with('@') => raw[1..].find('@').map_or(raw, |at| &raw[..at + 1]),
        "npm" => raw.split_once('@').map_or(raw, |(name, _)| name),
        "pypi" => raw.split(['=', '<', '>', '!']).next().unwrap_or(raw),
        "crates" | "go" => raw.split_once('@').map_or(raw, |(name, _)| name),
        _ => raw,
    }
    .trim_end_matches('/');
    (name.len() >= 2 && name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.@/".contains(c)))
        .then(|| name.to_owned())
}

fn shell_words(input: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    for ch in input.chars() {
        match (quote, ch) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => quote = Some(ch),
            (None, c) if c.is_whitespace() => {
                if !word.is_empty() { words.push(std::mem::take(&mut word)); }
            }
            (None, c) => word.push(c),
        }
    }
    if !word.is_empty() { words.push(word); }
    words
}

async fn fetch(package: PackageSpec) -> PackageMetadata {
    let lookalike = lookalike(package.ecosystem, &package.name);
    let client = match reqwest::Client::builder().timeout(REQUEST_TIMEOUT).build() {
        Ok(client) => client,
        Err(_) => return unavailable(package, lookalike),
    };
    match package.ecosystem {
        "npm" => fetch_npm(&client, package, lookalike).await,
        "pypi" => fetch_pypi(&client, package, lookalike).await,
        "crates" => fetch_crates(&client, package, lookalike).await,
        _ => unavailable(package, lookalike),
    }
}

async fn fetch_npm(client: &reqwest::Client, package: PackageSpec, lookalike: Option<String>) -> PackageMetadata {
    let url = format!("https://registry.npmjs.org/{}", package.name);
    let response = client.get(url).send().await.and_then(|response| response.error_for_status());
    let Ok(response) = response else { return unavailable(package, lookalike) };
    let Ok(body) = response.json::<NpmResponse>().await else { return unavailable(package, lookalike) };
    let version = body.dist_tags.as_ref().and_then(|tags| tags.latest.clone());
    let scripts = version.as_ref().and_then(|version| body.versions.as_ref()?.get(version)?.scripts.as_ref());
    let created = body.time.as_ref().and_then(|time| time.get("created"));
    PackageMetadata { ecosystem: package.ecosystem, name: package.name, status: "ok", version,
        age_days: created.and_then(|value| age_days(value)), weekly_downloads: npm_downloads(client, &package.name).await,
        maintainers: body.maintainers.map_or(0, |maintainers| maintainers.len() as u64),
        install_scripts: scripts.is_some_and(|scripts| scripts.keys().any(|key| matches!(key.as_str(), "preinstall" | "install" | "postinstall"))), lookalike }
}

async fn npm_downloads(client: &reqwest::Client, name: &str) -> Option<u64> {
    let url = format!("https://api.npmjs.org/downloads/point/last-week/{name}");
    client.get(url).send().await.ok()?.json::<NpmDownloads>().await.ok()?.downloads
}

async fn fetch_pypi(client: &reqwest::Client, package: PackageSpec, lookalike: Option<String>) -> PackageMetadata {
    let url = format!("https://pypi.org/pypi/{}/json", package.name);
    let response = client.get(url).send().await.and_then(|response| response.error_for_status());
    let Ok(response) = response else { return unavailable(package, lookalike) };
    let Ok(body) = response.json::<PyPiResponse>().await else { return unavailable(package, lookalike) };
    let info = body.info.unwrap_or(PyPiInfo { version: None, author: None, maintainers: None });
    let version = info.version.clone();
    let created = version.as_ref().and_then(|version| body.releases.as_ref()?.get(version)?.first()?.upload_time_iso_8601.as_deref().map(str::to_owned));
    PackageMetadata { ecosystem: package.ecosystem, name: package.name, status: "ok", version,
        age_days: created.as_deref().and_then(age_days), weekly_downloads: None,
        maintainers: info.maintainers.map_or(u64::from(info.author.is_some()), |maintainers| maintainers.len() as u64), install_scripts: false, lookalike }
}

async fn fetch_crates(client: &reqwest::Client, package: PackageSpec, lookalike: Option<String>) -> PackageMetadata {
    let url = format!("https://crates.io/api/v1/crates/{}", package.name);
    let response = client.get(url).header("User-Agent", "cmux-dependency-gate").send().await.and_then(|response| response.error_for_status());
    let Ok(response) = response else { return unavailable(package, lookalike) };
    let Ok(body) = response.json::<CratesResponse>().await else { return unavailable(package, lookalike) };
    let Some(krate) = body.krate else { return unavailable(package, lookalike) };
    PackageMetadata { ecosystem: package.ecosystem, name: package.name, status: "ok", version: krate.max_stable_version,
        age_days: krate.created_at.as_deref().and_then(age_days), weekly_downloads: krate.downloads, maintainers: 0, install_scripts: false, lookalike }
}

fn unavailable(package: PackageSpec, lookalike: Option<String>) -> PackageMetadata {
    PackageMetadata { ecosystem: package.ecosystem, name: package.name, status: "unavailable", version: None, age_days: None, weekly_downloads: None, maintainers: 0, install_scripts: false, lookalike }
}

fn age_days(timestamp: &str) -> Option<u64> {
    let date = timestamp.get(..10)?;
    let mut parts = date.split('-').filter_map(|part| part.parse::<u64>().ok());
    let (year, month, day) = (parts.next()?, parts.next()?, parts.next()?);
    let days = days_from_civil(year as i64, month as i64, day as i64);
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() / 86_400;
    Some((now as i64).saturating_sub(days).max(0) as u64)
}

// Proleptic Gregorian date to Unix days, using the public-domain civil-date algorithm.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = (if year >= 0 { year } else { year - 399 }) / 400;
    let year_of_era = year - era * 400;
    let month_prime = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * month_prime + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn lookalike(ecosystem: &str, name: &str) -> Option<String> {
    let list: HashMap<String, Vec<String>> = serde_json::from_str(include_str!("../../data/dependency-top-packages.json")).ok()?;
    list.get(ecosystem)?.iter().find(|candidate| candidate.as_str() != name && edit_distance(candidate, name) == 1).cloned()
}

fn edit_distance(left: &str, right: &str) -> usize {
    let mut row: Vec<usize> = (0..=right.chars().count()).collect();
    for (i, a) in left.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, b) in right.chars().enumerate() {
            let above = row[j + 1];
            row[j + 1] = if a == b { diagonal } else { 1 + diagonal.min(row[j]).min(above) };
            diagonal = above;
        }
    }
    row[right.chars().count()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_all_supported_installers() {
        let cases = [
            ("npm install react", "npm", "react"),
            ("pnpm add @scope/pkg@1.0.0", "npm", "@scope/pkg"),
            ("pip install requests>=2", "pypi", "requests"),
            ("uv add httpx", "pypi", "httpx"),
            ("cargo add serde", "crates", "serde"),
            ("go get github.com/acme/tool@latest", "go", "github.com/acme/tool"),
            ("brew install jq", "brew", "jq"),
        ];
        for (command, ecosystem, name) in cases {
            let package = parse_command(command).pop().expect("package");
            assert_eq!((package.ecosystem, package.name.as_str()), (ecosystem, name));
        }
    }

    #[test]
    fn finds_one_edit_lookalike() {
        assert_eq!(lookalike("pypi", "reqeusts"), Some("requests".into()));
        assert_eq!(lookalike("npm", "react"), None);
    }

    #[test]
    fn command_arrays_unwrap_shell() {
        let request = json!({"toolCall":{"rawInput":{"command":["bash","-lc","cargo add serde"]}}});
        assert_eq!(command(&request).as_deref(), Some("cargo add serde"));
    }

    #[test]
    fn registry_fixtures_match_supported_shapes() {
        let npm: NpmResponse = serde_json::from_str(include_str!("../../tests/fixtures/dependency-gate/npm.json")).unwrap();
        assert_eq!(npm.dist_tags.and_then(|tags| tags.latest), Some("1.2.3".into()));
        assert!(npm.versions.unwrap().get("1.2.3").unwrap().scripts.as_ref().unwrap().contains_key("preinstall"));
        let pypi: PyPiResponse = serde_json::from_str(include_str!("../../tests/fixtures/dependency-gate/pypi.json")).unwrap();
        assert_eq!(pypi.info.unwrap().version, Some("2.31.0".into()));
        let crates: CratesResponse = serde_json::from_str(include_str!("../../tests/fixtures/dependency-gate/crates.json")).unwrap();
        assert_eq!(crates.krate.unwrap().downloads, Some(123456));
    }
}
