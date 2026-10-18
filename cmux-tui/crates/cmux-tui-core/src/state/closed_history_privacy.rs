//! What closed history never stores (plans/cmux-next/reopen-closed.md 3.0,
//! 7.5 and 7.17): URL query keys that look like secrets, and the windows of
//! incognito (ephemeral) workspaces. Content of an ephemeral workspace is
//! already left out where groups are captured (`closed_history_store`).

use rusqlite::{Connection, Transaction, params};
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

/// `url` without its user info (`user:pass@`) and its secret query and
/// fragment keys (`#access_token=`, a hash route's `#/cb?code=`). Only web
/// URLs (`http`, `https`, `ws`, `wss`) are touched, and the kept parts stay
/// byte for byte: the query and fragment are filtered by their raw pairs
/// (separated by `&` or `;`), never re-encoded.
pub(super) fn strip_url(url: &str) -> String {
    let lower = url.get(..6).unwrap_or(url).to_ascii_lowercase();
    if !["http:", "https:", "ws:", "wss:"].iter().any(|scheme| lower.starts_with(scheme)) {
        return url.to_string();
    }
    let (before_fragment, fragment) = match url.split_once('#') {
        Some((before, fragment)) => (before, Some(fragment)),
        None => (url, None),
    };
    let (base, query) = match before_fragment.split_once('?') {
        Some((base, query)) => (base, Some(query)),
        None => (before_fragment, None),
    };
    let mut stripped = without_user_info(base);
    if let Some(query) = query.and_then(|query| kept_pairs(query, true)) {
        stripped.push('?');
        stripped.push_str(&query);
    }
    if let Some(fragment) = fragment.and_then(kept_fragment) {
        stripped.push('#');
        stripped.push_str(&fragment);
    }
    stripped
}

/// `base` (scheme, authority and path) without user info in the authority.
/// A web URL's authority starts after any run of `/` or `\` behind the
/// scheme, as browsers read it: `https:user@h` is `https://user@h`.
fn without_user_info(base: &str) -> String {
    let Some(colon) = base.find(':') else { return base.to_string() };
    let slashes = base[colon + 1..].bytes().take_while(|byte| matches!(byte, b'/' | b'\\')).count();
    let start = colon + 1 + slashes;
    let end = base[start..].find(['/', '\\']).map_or(base.len(), |at| start + at);
    match base[start..end].rfind('@') {
        Some(at) => format!("{}{}", &base[..start], &base[start + at + 1..]),
        None => base.to_string(),
    }
}

/// A fragment without its secret keys; None when nothing is left. A hash
/// route (`#/cb?code=abc`, `#!/cb?code=abc`: a fragment that starts with
/// `/` or `!/`) keeps its route and filters what follows its `?` as a
/// query. Any other fragment is read as keys, `?` and all, as before
/// (`#access_token=abc&redirect=https://x/?a=b`), and a part is a key only
/// when it has a value (`#section` and `#token` stay).
fn kept_fragment(fragment: &str) -> Option<String> {
    let route = fragment.starts_with('/') || fragment.starts_with("!/");
    let Some((route, query)) = fragment.split_once('?').filter(|_| route) else {
        return kept_pairs(fragment, false);
    };
    let kept = match kept_pairs(query, true) {
        Some(query) => format!("{route}?{query}"),
        None => route.to_string(),
    };
    (!kept.is_empty()).then_some(kept)
}

/// The pairs of `part` (separated by `&` or `;`) that are not secrets, byte
/// for byte, each kept pair after the separator that preceded it; None when
/// every pair was a secret. `bare_keys`: a pair without `=` is a key too.
fn kept_pairs(part: &str, bare_keys: bool) -> Option<String> {
    let mut pairs = Vec::new();
    let mut start = 0;
    let mut separator = "";
    for (at, character) in part.char_indices() {
        if matches!(character, '&' | ';') {
            pairs.push((separator, &part[start..at]));
            separator = &part[at..at + 1];
            start = at + 1;
        }
    }
    pairs.push((separator, &part[start..]));
    let secret = |pair: &str| {
        (bare_keys || pair.contains('='))
            && is_secret_key(&decode_key(pair.split('=').next().unwrap_or("")))
    };
    let kept = pairs.iter().filter(|(_, pair)| !secret(pair)).collect::<Vec<_>>();
    if kept.len() == pairs.len() {
        return Some(part.to_string());
    }
    let mut joined = String::new();
    for (index, (separator, pair)) in kept.iter().enumerate() {
        if index > 0 {
            joined.push_str(separator);
        }
        joined.push_str(pair);
    }
    (!kept.is_empty()).then_some(joined)
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

/// The version of the rules above that every stored closed group meets.
/// Raise it with a rule that should reach rows written before it.
const SCRUB_VERSION: i64 = 1;

/// Closed groups written before the current rules keep what those rules
/// strip until something rewrites them: once per store and rule version
/// (`closed_history_scrub`), every `url` in every stored record is
/// stripped again and every `browser_history` with it. Rows that need
/// nothing are not written.
///
/// The scrub never keeps the store from opening: on any error its writes
/// roll back (a savepoint inside the open's transaction), the version stays
/// unrecorded so the next start tries again, and the error is logged.
pub(super) fn scrub_closed_groups(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch("SAVEPOINT closed_history_scrub")?;
    match scrub_closed_groups_once(transaction) {
        Ok(()) => transaction.execute_batch("RELEASE closed_history_scrub")?,
        Err(error) => {
            transaction
                .execute_batch("ROLLBACK TO closed_history_scrub; RELEASE closed_history_scrub")?;
            eprintln!("cmux-tui: closed history scrub skipped, retried next start: {error:#}");
        }
    }
    Ok(())
}

fn scrub_closed_groups_once(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS closed_history_scrub (
           version INTEGER PRIMARY KEY NOT NULL
         );",
    )?;
    let done: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM closed_history_scrub WHERE version >= ?1)",
        [SCRUB_VERSION],
        |row| row.get(0),
    )?;
    if done {
        return Ok(());
    }
    let rows = {
        let mut statement = transaction.prepare("SELECT seq, record_json FROM closed_groups")?;
        statement
            .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (seq, record) in rows {
        let Ok(mut parsed) = serde_json::from_str::<Value>(&record) else { continue };
        if scrub_record(&mut parsed) {
            transaction.execute(
                "UPDATE closed_groups SET record_json = ?1 WHERE seq = ?2",
                params![parsed.to_string(), seq],
            )?;
        }
    }
    transaction.execute(
        "INSERT OR IGNORE INTO closed_history_scrub(version) VALUES(?1)",
        [SCRUB_VERSION],
    )?;
    Ok(())
}

/// Strip every `url` and `browser_history` string in `value`; whether any
/// changed.
fn scrub_record(value: &mut Value) -> bool {
    match value {
        Value::Object(map) => {
            let mut changed = false;
            for (key, item) in map.iter_mut() {
                match (key.as_str(), &mut *item) {
                    ("url", Value::String(url)) => {
                        let stripped = strip_url(url);
                        if stripped != *url {
                            *url = stripped;
                            changed = true;
                        }
                    }
                    ("browser_history", Value::String(history)) => {
                        let stripped = strip_history(history);
                        if stripped.as_str() != Some(history.as_str()) {
                            *item = stripped;
                            changed = true;
                        }
                    }
                    _ => changed |= scrub_record(item),
                }
            }
            changed
        }
        Value::Array(items) => {
            items.iter_mut().fold(false, |changed, item| scrub_record(item) | changed)
        }
        _ => false,
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
    fn strip_url_drops_secret_keys_of_a_hash_route_query() {
        // A single-page app's route keeps its query in the fragment.
        assert_eq!(strip_url("https://h/#/cb?code=abc"), "https://h/#/cb");
        assert_eq!(strip_url("https://h/#/cb?code=abc&x=1"), "https://h/#/cb?x=1");
        assert_eq!(strip_url("https://h/#/cb?x=1&state=s"), "https://h/#/cb?x=1&state=s");
        assert_eq!(strip_url("https://h/#!/cb?access_token=t"), "https://h/#!/cb");
        assert_eq!(strip_url("https://h/#!/cb?code=x"), "https://h/#!/cb");
    }

    #[test]
    fn strip_url_reads_a_fragment_that_is_not_a_route_as_keys_even_with_a_question_mark() {
        // An OAuth fragment whose value holds a `?` is not a hash route.
        assert_eq!(
            strip_url("https://h/cb#access_token=abc&redirect=https://x/?a=b"),
            "https://h/cb#redirect=https://x/?a=b"
        );
        assert_eq!(strip_url("https://h/cb#token=abc?x"), "https://h/cb");
        assert_eq!(strip_url("https://h/doc#section?x=1"), "https://h/doc#section?x=1");
    }

    #[test]
    fn strip_url_treats_a_semicolon_as_a_query_separator() {
        assert_eq!(strip_url("https://h/p?a=1;token=x"), "https://h/p?a=1");
        assert_eq!(strip_url("https://h/p?token=x;a=1&b=2"), "https://h/p?a=1&b=2");
        assert_eq!(strip_url("https://h/p?a=1;b=2&c=3"), "https://h/p?a=1;b=2&c=3");
    }

    #[test]
    fn strip_url_drops_user_info_without_slashes() {
        // Browsers read `https:user:pass@h/p` as `https://user:pass@h/p`.
        assert_eq!(strip_url("https:user:pass@h/p"), "https:h/p");
        assert_eq!(strip_url("https:/user@h/p"), "https:/h/p");
        assert_eq!(strip_url("https:\\\\user:pass@h/p"), "https:\\\\h/p");
        assert_eq!(strip_url("https:h/@me"), "https:h/@me");
    }

    #[test]
    fn strip_url_leaves_non_web_urls_alone() {
        assert_eq!(strip_url("file:///tmp/a?token=s"), "file:///tmp/a?token=s");
        assert_eq!(strip_url("cmux://history#access_token=t"), "cmux://history#access_token=t");
    }
}
