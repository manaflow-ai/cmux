//! A cached, non-secret projection for machine inventory consumers. Unlike
//! the health control endpoint, this view never checks, rescans or updates.

use serde_json::{Value, json};

use super::HarnessHealth;
use crate::rpc::RpcError;

pub(super) const MAX_HARNESSES: usize = 256;

pub(super) fn visible_rows(rows: &[HarnessHealth]) -> impl Iterator<Item = &HarnessHealth> {
    rows.iter().filter(|row| safe_id(&row.id)).take(MAX_HARNESSES)
}

/// Select fields individually: health diagnostics include paths, commands
/// and arbitrary CLI output, and new health fields are private by default.
pub(crate) fn view(rows: &[HarnessHealth], params: &Value) -> Result<Value, RpcError> {
    let valid = params.as_object().is_some_and(|fields| {
        fields.len() == 1 && fields.get("view").and_then(Value::as_str) == Some("inventory")
    });
    if !valid {
        return Err(RpcError::invalid_params(
            "the cached inventory accepts only {view: inventory}; health controls and machine selectors are not accepted",
        ));
    }
    Ok(snapshot(rows))
}

/// The one bounded projection shared by cached reads and change snapshots.
pub(super) fn snapshot(rows: &[HarnessHealth]) -> Value {
    let harnesses: Vec<Value> = visible_rows(rows)
        .map(|row| {
            let version = safe_version(row.version.as_deref());
            let latest = safe_version(row.latest.as_deref());
            json!({
                "id": row.id,
                "family": cli_family(row),
                "channel": row.channel,
                "version": version,
                "latest": latest,
                "latestCheckedAt": row.latest_checked_at,
                "outdated": row.outdated && version.is_some() && latest.is_some(),
                "auth": row.auth,
                "checkedAt": row.checked_at,
            })
        })
        .collect();
    json!({"view": "inventory", "cached": true, "harnesses": harnesses})
}

pub(super) fn safe_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

/// Uses only evidence saved together by the health check, never a profile
/// name or today's configuration. An adapter's version is not its agent's.
pub(super) fn cli_family(row: &HarnessHealth) -> Option<&'static str> {
    use super::channel::Channel;
    if matches!(row.channel, Channel::Launcher | Channel::Missing)
        || row.path.as_deref().is_none_or(str::is_empty)
    {
        return None;
    }
    let name = std::path::Path::new(&row.program).file_name()?.to_str()?;
    let name = name.strip_suffix(".exe").unwrap_or(name);
    if super::channel::is_launcher(name) || name.ends_with("-acp") {
        return None;
    }
    let program = match name {
        "claude" => Some("claude"),
        "codex" => Some("codex"),
        "opencode" | "opencode2" => Some("opencode"),
        "pi" => Some("pi"),
        "chief" => Some("chief"),
        "gemini" => Some("gemini"),
        "amp" => Some("amp"),
        "copilot" => Some("copilot"),
        "cursor-agent" => Some("cursor"),
        "hermes" => Some("hermes"),
        _ => None,
    };
    let package = match (row.channel, row.package.as_deref()) {
        (Channel::Npm | Channel::Bun | Channel::Native, Some(package)) => match package {
            "@anthropic-ai/claude-code" => Some("claude"),
            "@openai/codex" => Some("codex"),
            "opencode-ai" => Some("opencode"),
            "@earendil-works/pi-coding-agent" => Some("pi"),
            "@google/gemini-cli" => Some("gemini"),
            "@sourcegraph/amp" => Some("amp"),
            "@github/copilot" => Some("copilot"),
            _ => None,
        },
        (Channel::Brew | Channel::BrewCask, Some(package)) => match package {
            "claude-code" => Some("claude"),
            "codex" => Some("codex"),
            "opencode" => Some("opencode"),
            "gemini-cli" => Some("gemini"),
            _ => None,
        },
        _ => None,
    };
    match (program, package) {
        (Some(program), Some(package)) if program != package => None,
        (program, package) => program.or(package),
    }
}

/// A saved cache may predate version parsing. Only a complete version
/// token crosses this boundary; never an error line containing one.
pub(super) fn safe_version(value: Option<&str>) -> Option<&str> {
    static VERSION: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^v?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
            .expect("inventory version pattern") // crash-allow: constant pattern
    });
    value.filter(|v| v.len() <= 64 && VERSION.is_match(v))
}

#[cfg(test)]
mod tests;
