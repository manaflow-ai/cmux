//! The page's requests for what a reply links to, and the New Tab page's environment list and
//! remove (`AgentPaneReplyRequest.init`, `AgentPaneEnvironmentRequest.init`): fixed param keys
//! (any other is refused), length caps, and the host checks the value again before any effect.
//! `composer.copy` and `environment.save` build a host type, so the host's decoder keeps them.

use serde_json::{Map, Value, json};

use super::ids::is_uuid;
use super::url::is_web_url;
use super::value::{Params, as_bool, bytes_within, plain_number};
use super::{Decoded, case_with, unsupported};

/// Most paths or URLs in one `link.inspect`.
pub const MAXIMUM_INSPECT: usize = 64;
/// Longest URL any method takes.
pub const MAXIMUM_URL: usize = 2048;
/// Longest path a reply names.
pub const MAXIMUM_PATH: usize = 4096;
/// Longest image name kept (bytes); a longer one is cut, not refused.
pub const MAXIMUM_IMAGE_NAME: usize = 512;
/// Longest `data:` image: base64 of the 32 MiB image cap, plus the header.
pub const MAXIMUM_IMAGE_SOURCE: usize = (32 << 20) / 3 * 4 + 64;
/// Most picked frame times in one `video.frames`.
pub const MAXIMUM_PICKED: usize = 16;
/// Longest picked time: a day, in milliseconds.
pub const MAXIMUM_TIME_MS: i64 = 86_400_000;
/// Largest line `link.openPath` takes.
pub const MAXIMUM_LINE: i64 = 10_000_000;

/// The exact param keys each method takes.
fn known_params(method: &str) -> Option<&'static [&'static str]> {
    Some(match method {
        "link.inspect" => &["paths", "urls"],
        "link.openPath" => &["path", "line"],
        "image.load" => &["src", "auto"],
        "media.load" | "video.info" | "video.probes" | "video.transcript" | "video.quickLook" => {
            &["src"]
        }
        "video.frames" => &["src", "times"],
        "browser.list" | "environment.list" => &[],
        "browser.openIn" => &["url", "browserId"],
        "image.reveal" => &["src", "name", "path"],
        "image.openInPane" | "image.copy" | "image.save" | "image.quickLook" | "image.drag" => {
            &["src", "name"]
        }
        "file.drag" | "link.preview" => &["path"],
        "pr.inspect" => &["url", "cached"],
        "composer.copy" => &["text", "items"],
        "environment.save" => &["environment"],
        "environment.remove" => &["id"],
        _ => return None,
    })
}

/// The decoded request of `method`, or `None` when it is not a reply or environment method (or the
/// host's own decoder keeps it).
pub fn decode(method: &str, params: Params<'_>) -> Option<Decoded> {
    let known = known_params(method)?;
    if matches!(method, "composer.copy" | "environment.save") {
        return None;
    }
    let keys_ok = params.0.is_none_or(|map| map.keys().all(|key| known.contains(&key.as_str())));
    let out = if keys_ok { build(method, params) } else { None };
    Some(Decoded::Case(out.unwrap_or_else(|| unsupported(method))))
}

/// `params[key] as? String`, non-empty, at most `limit` bytes, no NUL.
fn text<'a>(params: Params<'a>, key: &str, limit: usize) -> Option<&'a str> {
    params.string(key).filter(|value| usable(value, limit))
}

fn usable(value: &str, limit: usize) -> bool {
    !value.is_empty() && bytes_within(value, limit) && !value.contains('\0')
}

/// A list of distinct usable strings, in order; a missing key is the empty list.
fn list(params: Params<'_>, key: &str, limit: usize) -> Option<Vec<String>> {
    let Some(raw) = params.get(key) else { return Some(Vec::new()) };
    let values = raw.as_array().filter(|values| values.len() <= MAXIMUM_INSPECT)?;
    let mut out: Vec<String> = Vec::new();
    for value in values {
        let value = value.as_str().filter(|value| usable(value, limit))?;
        if !out.iter().any(|seen| seen == value) {
            out.push(value.to_owned());
        }
    }
    Some(out)
}

/// A whole number's value, from a JSON number that is no boolean.
fn whole(value: &Value) -> Option<i64> {
    let float = plain_number(value)?
        .as_f64()
        .filter(|float| float.is_finite() && float.round() == *float)?;
    format!("{float:.0}").parse().ok()
}

/// `name` cut to at most [`MAXIMUM_IMAGE_NAME`] UTF-8 bytes, on a character boundary.
fn image_name(name: &str) -> String {
    let mut bytes = 0usize;
    let mut kept = String::new();
    for character in name.chars() {
        bytes = bytes.saturating_add(character.len_utf8());
        if bytes > MAXIMUM_IMAGE_NAME {
            break;
        }
        kept.push(character);
    }
    kept
}

fn reply(kind: &str, fields: Vec<(&str, Value)>) -> Value {
    let mut object = Map::new();
    object.insert("case".to_owned(), json!("reply"));
    object.insert("reply".to_owned(), json!(kind));
    for (key, value) in fields {
        object.insert(key.to_owned(), value);
    }
    Value::Object(object)
}

fn build(method: &str, params: Params<'_>) -> Option<Value> {
    Some(match method {
        "link.inspect" => {
            let paths = list(params, "paths", MAXIMUM_PATH)?;
            let urls = list(params, "urls", MAXIMUM_URL)?;
            reply("inspect", vec![("paths", json!(paths)), ("urls", json!(urls))])
        }
        "link.openPath" => {
            let path = text(params, "path", MAXIMUM_PATH)?;
            let line = match params.get("line") {
                None => None,
                Some(value) => Some(whole(value).filter(|line| (1..=MAXIMUM_LINE).contains(line))?),
            };
            reply("openPath", vec![("_0", json!(path)), ("line", json!(line))])
        }
        "image.load" => {
            let src = text(params, "src", MAXIMUM_URL)?;
            let auto = match params.get("auto") {
                None => false,
                Some(value) => as_bool(value)?,
            };
            reply("loadImage", vec![("_0", json!(src)), ("auto", json!(auto))])
        }
        "media.load" => reply("loadMedia", vec![("_0", json!(text(params, "src", MAXIMUM_URL)?))]),
        "video.frames" => {
            let src = text(params, "src", MAXIMUM_PATH)?;
            let raw = params
                .get("times")
                .and_then(Value::as_array)
                .filter(|raw| (1..=MAXIMUM_PICKED).contains(&raw.len()))?;
            let mut times = Vec::new();
            for value in raw {
                times.push(whole(value).filter(|time| (0..=MAXIMUM_TIME_MS).contains(time))?);
            }
            reply("videoFrames", vec![("_0", json!(src)), ("times", json!(times))])
        }
        "video.info" | "video.probes" | "video.transcript" | "video.quickLook" => {
            let src = text(params, "src", MAXIMUM_PATH)?;
            let kind = match method {
                "video.info" => "videoInfo",
                "video.probes" => "videoProbes",
                "video.transcript" => "videoTranscript",
                _ => "quickLookVideo",
            };
            reply(kind, vec![("_0", json!(src))])
        }
        "browser.list" => reply("listBrowsers", vec![]),
        "browser.openIn" => {
            let url = text(params, "url", MAXIMUM_URL).filter(|url| is_web_url(url))?;
            let id = text(params, "browserId", 64)?;
            reply("openIn", vec![("url", json!(url)), ("browserId", json!(id))])
        }
        "file.drag" => reply("dragFile", vec![("_0", json!(text(params, "path", MAXIMUM_PATH)?))]),
        "image.reveal" | "image.openInPane" | "image.copy" | "image.save" | "image.quickLook"
        | "image.drag" => {
            let src =
                text(params, "src", MAXIMUM_IMAGE_SOURCE).filter(|src| src.starts_with("data:"))?;
            let name = image_name(params.string("name").filter(|name| !name.contains('\0'))?);
            let kind = match method {
                "image.openInPane" => "openImageInPane",
                "image.copy" => "copyImage",
                "image.save" => "saveImage",
                "image.quickLook" => "quickLookImage",
                "image.drag" => "dragImage",
                _ => {
                    let path = match params.get("path") {
                        Some(_) => Some(text(params, "path", MAXIMUM_PATH)?),
                        None => None,
                    };
                    return Some(reply(
                        "revealImage",
                        vec![("src", json!(src)), ("name", json!(name)), ("path", json!(path))],
                    ));
                }
            };
            reply(kind, vec![("src", json!(src)), ("name", json!(name))])
        }
        "pr.inspect" => {
            let url = text(params, "url", MAXIMUM_URL).and_then(github_item_url)?;
            let cached = match params.get("cached") {
                None => false,
                Some(value) => as_bool(value)?,
            };
            reply("inspectPullRequest", vec![("_0", json!(url)), ("cached", json!(cached))])
        }
        "link.preview" => {
            reply("previewPath", vec![("_0", json!(text(params, "path", MAXIMUM_PATH)?))])
        }
        "environment.list" => case_with("environment", [("kind", json!("list"))]),
        "environment.remove" => {
            let id = params.string("id").filter(|id| is_uuid(id))?;
            case_with("environment", [("kind", json!("remove")), ("id", json!(id))])
        }
        _ => return None,
    })
}

/// A GitHub pull request or issue, `https://github.com/<owner>/<repo>/pull/<n>` (a trailing slash
/// or one tab after a pull number is the same item), rebuilt from its parts; `None` for anything
/// else (another host, user info, a port, a query or fragment, a part that starts with `-`).
pub fn github_item_url(text: &str) -> Option<String> {
    let rest = text.strip_prefix("https://")?;
    let (host, path) = rest.split_once('/')?;
    if !host.eq_ignore_ascii_case("github.com")
        || path.contains(['?', '#'])
        || text.chars().any(char::is_whitespace)
    {
        return None;
    }
    let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
    let [owner, repo, kind, number, tab @ ..] = parts.as_slice() else { return None };
    if tab.len() > 1
        || !matches!(*kind, "pull" | "issues")
        || owner.bytes().all(|b| b == b'.')
        || repo.bytes().all(|b| b == b'.')
    {
        return None;
    }
    let name = |part: &str| {
        !part.is_empty()
            && part.chars().count() <= 100
            && !part.starts_with('-')
            && part.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
    };
    let digits = !number.is_empty()
        && number.len() <= 10
        && number.bytes().all(|b| b.is_ascii_digit())
        && !number.starts_with('0');
    let tab_ok = match tab {
        [] => true,
        [tab] => {
            *kind == "pull"
                && !tab.is_empty()
                && tab.chars().count() <= 20
                && tab.bytes().all(|b| b.is_ascii_lowercase())
        }
        _ => false,
    };
    (name(owner) && name(repo) && digits && tab_ok)
        .then(|| format!("https://github.com/{owner}/{repo}/{kind}/{number}"))
}
