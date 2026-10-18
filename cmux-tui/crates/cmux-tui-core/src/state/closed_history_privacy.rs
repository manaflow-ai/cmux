//! What closed history never stores (plans/cmux-next/reopen-closed.md 3.0,
//! 7.5 and 7.17): URL query keys that look like secrets, and the windows of
//! incognito (ephemeral) workspaces. Content of an ephemeral workspace is
//! already left out where groups are captured (`closed_history_store`).

use rusqlite::Connection;
use serde_json::Value;

/// Words of a query key that make it a secret wherever they appear. A key
/// splits into words at `_`, `-`, `.` and lower-to-upper case changes, so
/// `X-Amz-Security-Token` and `accessToken` both have the word `token`, while
/// `authuser`, `author` and `monkey` have no secret word.
const SECRET_WORDS: [&str; 22] = [
    "token",
    "secret",
    "password",
    "passwd",
    "pass",
    "pwd",
    "pw",
    "signature",
    "sig",
    "hmac",
    "credential",
    "credentials",
    "auth",
    "apikey",
    "jwt",
    "otp",
    "ticket",
    "cookie",
    "sid",
    "sessid",
    "phpsessid",
    "sessionid",
];

/// Words that make a following `token` a page cursor, not a credential.
const CURSOR_WORDS: [&str; 4] = ["page", "next", "continuation", "cursor"];

/// Words that make a following `key` a credential (`api_key`, `accessKey`),
/// unlike `sort_key` or `cache_key`. A key named just `key` is one too.
const KEY_OWNERS: [&str; 7] =
    ["api", "access", "private", "secret", "client", "signing", "license"];

fn words(key: &str) -> Vec<String> {
    let mut words = vec![String::new()];
    let mut previous_lower = false;
    for character in key.chars() {
        if matches!(character, '_' | '-' | '.' | ' ') {
            words.push(String::new());
            previous_lower = false;
            continue;
        }
        if character.is_ascii_uppercase() && previous_lower {
            words.push(String::new());
        }
        previous_lower = character.is_ascii_lowercase() || character.is_ascii_digit();
        if let Some(word) = words.last_mut() {
            word.push(character.to_ascii_lowercase());
        }
    }
    words.retain(|word| !word.is_empty());
    words
}

fn is_secret_key(key: &str) -> bool {
    let words = words(key);
    if words.len() == 1 && matches!(words[0].as_str(), "code" | "key") {
        return true;
    }
    words.iter().enumerate().any(|(index, word)| {
        let before = index.checked_sub(1).map(|previous| words[previous].as_str());
        match word.as_str() {
            "token" => !before.is_some_and(|before| CURSOR_WORDS.contains(&before)),
            "key" => before.is_some_and(|before| KEY_OWNERS.contains(&before)),
            "id" => before == Some("session"),
            word => SECRET_WORDS.contains(&word),
        }
    })
}

/// Percent-decode a query key for the check (`+` is a space).
fn decode_key(key: &str) -> String {
    let hex = |byte: u8| (byte as char).to_digit(16);
    let bytes = key.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        let escaped = (byte == b'%')
            .then(|| Some((hex(*bytes.get(index + 1)?)?, hex(*bytes.get(index + 2)?)?)))
            .flatten();
        match (byte, escaped) {
            (_, Some((high, low))) => {
                out.push(u8::try_from(high * 16 + low).unwrap_or(b'%'));
                index += 3;
            }
            (b'+', None) => {
                out.push(b' ');
                index += 1;
            }
            (byte, None) => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `url` without its secret query keys. Only web URLs (`http`, `https`,
/// `ws`, `wss`) are touched, and the kept parts stay byte for byte: the
/// query is filtered by its raw `&`-separated pairs, never re-encoded.
pub(super) fn strip_url(url: &str) -> String {
    let lower = url.get(..6).unwrap_or(url).to_ascii_lowercase();
    if !["http:", "https:", "ws:", "wss:"].iter().any(|scheme| lower.starts_with(scheme)) {
        return url.to_string();
    }
    let (before_fragment, fragment) = match url.find('#') {
        Some(at) => url.split_at(at),
        None => (url, ""),
    };
    let Some((base, query)) = before_fragment.split_once('?') else { return url.to_string() };
    let pairs = query.split('&').collect::<Vec<_>>();
    let kept = pairs
        .iter()
        .filter(|pair| !is_secret_key(&decode_key(pair.split('=').next().unwrap_or(""))))
        .copied()
        .collect::<Vec<_>>();
    if kept.len() == pairs.len() {
        return url.to_string();
    }
    if kept.is_empty() {
        format!("{base}{fragment}")
    } else {
        format!("{base}?{}{fragment}", kept.join("&"))
    }
}

/// A frontend browser's opaque session history (a JSON object) with every
/// `url` string in it stripped. History with nothing to strip is kept byte
/// for byte; history that does not parse is dropped.
pub(super) fn strip_history(history: &str) -> Value {
    fn walk(value: &mut Value) -> bool {
        match value {
            Value::Object(map) => {
                let mut changed = false;
                for (key, item) in map.iter_mut() {
                    match item {
                        Value::String(text) if key == "url" => {
                            let stripped = strip_url(text);
                            if stripped != *text {
                                *text = stripped;
                                changed = true;
                            }
                        }
                        _ => changed |= walk(item),
                    }
                }
                changed
            }
            Value::Array(items) => {
                items.iter_mut().fold(false, |changed, item| walk(item) | changed)
            }
            _ => false,
        }
    }
    let Ok(mut parsed) = serde_json::from_str::<Value>(history) else { return Value::Null };
    if walk(&mut parsed) {
        Value::String(parsed.to_string())
    } else {
        Value::String(history.to_string())
    }
}

/// Whether a window record that lists `keys` is an incognito window: every
/// key it lists is a live ephemeral workspace. A key this daemon does not
/// know (another machine's workspace, or one not loaded yet), a closed one,
/// or a window that lists nothing is not incognito.
pub(super) fn is_private_window(connection: &Connection, keys: &[String]) -> anyhow::Result<bool> {
    let mut distinct = keys.to_vec();
    distinct.sort();
    distinct.dedup();
    if distinct.is_empty() {
        return Ok(false);
    }
    let ephemeral: i64 = connection.query_row(
        "SELECT COUNT(DISTINCT rw.workspace_key) FROM resource_workspaces AS rw
         JOIN workspace_state AS ws ON ws.workspace_id = rw.public_id
         WHERE rw.workspace_key IN (SELECT value FROM json_each(?1))
           AND rw.deleted_revision IS NULL AND ws.ephemeral != 0",
        [serde_json::to_string(&distinct)?],
        |row| row.get(0),
    )?;
    Ok(usize::try_from(ephemeral)? == distinct.len())
}

#[cfg(test)]
mod tests {
    use super::strip_url;

    #[test]
    fn strip_url_drops_secret_query_keys_byte_for_byte() {
        assert_eq!(strip_url("https://a.example/p?q=1&token=s"), "https://a.example/p?q=1");
        assert_eq!(strip_url("https://a.example/p?token=s"), "https://a.example/p");
        assert_eq!(strip_url("https://a.example/p?q=a%20b&x"), "https://a.example/p?q=a%20b&x");
    }

    #[test]
    fn strip_url_drops_user_info() {
        assert_eq!(strip_url("https://user:pass@a.example/p"), "https://a.example/p");
        assert_eq!(strip_url("https://user@a.example"), "https://a.example");
        // An `@` in the path is not user info.
        assert_eq!(strip_url("https://a.example/@me"), "https://a.example/@me");
    }

    #[test]
    fn strip_url_drops_secret_fragment_keys() {
        assert_eq!(
            strip_url("https://a.example/cb#access_token=t&x=1"),
            "https://a.example/cb#x=1"
        );
        assert_eq!(strip_url("https://a.example/cb#access_token=t"), "https://a.example/cb");
        // A fragment part without a value is an anchor, not a key.
        assert_eq!(strip_url("https://a.example/doc#token"), "https://a.example/doc#token");
        assert_eq!(strip_url("https://a.example/doc#section"), "https://a.example/doc#section");
    }

    #[test]
    fn strip_url_strips_every_part_together() {
        assert_eq!(
            strip_url("https://user:pass@a.example/p?q=1&token=s#access_token=t&x=1"),
            "https://a.example/p?q=1#x=1"
        );
    }

    #[test]
    fn strip_url_leaves_non_web_urls_alone() {
        assert_eq!(strip_url("file:///tmp/a?token=s"), "file:///tmp/a?token=s");
        assert_eq!(strip_url("cmux://history#access_token=t"), "cmux://history#access_token=t");
    }
}
