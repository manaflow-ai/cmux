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
const SECRET_WORDS: [&str; 24] = [
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
    "jsessionid",
    "aspsessionid",
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

/// Secrets matched on the key normalized (lower case, without `_`, `-`,
/// `.` and spaces), anywhere in it: run-together keys (`accesstoken`,
/// `IDTOKEN`) have no word boundary to split at. Only words too long to
/// occur by chance inside an ordinary key are here; short ones (`pw`,
/// `sig`, `sid`) stay word matches.
const NORMALIZED_SECRETS: [&str; 18] = [
    "token",
    "secret",
    "password",
    "passwd",
    "credential",
    "signature",
    "apikey",
    "accesskey",
    "privatekey",
    "signingkey",
    "sessionid",
    "sessid",
    "codeverifier",
    "oauthverifier",
    "samlresponse",
    "samlrequest",
    "authorization",
    "cookie",
];

/// Normalized keys that end in a page cursor, not a credential token.
const CURSOR_TOKENS: [&str; 4] = ["pagetoken", "nexttoken", "continuationtoken", "cursortoken"];

fn normalized(key: &str) -> String {
    key.chars()
        .filter(|character| !matches!(character, '_' | '-' | '.' | ' '))
        .map(|character| character.to_ascii_lowercase())
        .collect()
}

/// Whether query, fragment or matrix key `key` names a secret.
///
/// `session` is one: a bare `session=` value is a session id far more
/// often than anything else. OAuth `state` is not: it is a one-time CSRF
/// nonce that grants nothing by itself, and pages also use it for their
/// own UI state, which a reopened tab needs.
fn is_secret_key(key: &str) -> bool {
    let words = words(key);
    if let [only] = words.as_slice()
        && matches!(only.as_str(), "code" | "key" | "session")
    {
        return true;
    }
    let befores = std::iter::once(None).chain(words.iter().map(|word| Some(word.as_str())));
    let by_word = befores.zip(&words).any(|(before, word)| match word.as_str() {
        "token" => !before.is_some_and(|before| CURSOR_WORDS.contains(&before)),
        "key" => before.is_some_and(|before| KEY_OWNERS.contains(&before)),
        "id" => before == Some("session"),
        word => SECRET_WORDS.contains(&word),
    });
    let key = normalized(key);
    let cursor = CURSOR_TOKENS.iter().any(|cursor| key.ends_with(cursor));
    by_word
        || NORMALIZED_SECRETS
            .iter()
            .any(|secret| key.contains(secret) && !(*secret == "token" && cursor))
}

/// Keys whose value is a URL a page sends the user to next; their value is
/// stripped too, one level deep.
const REDIRECT_KEYS: [&str; 14] = [
    "redirect",
    "redirecturi",
    "redirecturl",
    "returnto",
    "returnurl",
    "return",
    "next",
    "continue",
    "callback",
    "callbackurl",
    "target",
    "destination",
    "goto",
    "successurl",
];

/// Percent-decode a query key for the check (`+` is a space).
fn decode_key(key: &str) -> String {
    let hex = |byte: u8| (byte as char).to_digit(16);
    let bytes = key.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while let Some(&byte) = bytes.get(index) {
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

/// Percent-decode a value (a `+` stays a `+`).
fn decode_value(value: &str) -> String {
    decode_key(&value.replace('+', "%2B"))
}

/// Percent-encode everything but the unreserved characters (RFC 3986).
fn encode_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// `url` without its user info (`user:pass@`), its secret path matrix
/// parameters (`;jsessionid=`), and its secret query and fragment keys
/// (`#access_token=`, a hash route's `#/cb?code=`). A redirect value
/// (`?redirect=https%3A…`) is stripped too, one level deep. Only web URLs
/// (`http`, `https`, `ws`, `wss`) are touched, and the kept parts stay byte
/// for byte: the query and fragment are filtered by their raw pairs
/// (separated by `&` or `;`), never re-encoded.
pub(super) fn strip_url(url: &str) -> String {
    strip_url_at(url, false)
}

/// [`strip_url`]; `nested` when `url` is itself a redirect value, which is
/// not followed further.
fn strip_url_at(url: &str, nested: bool) -> String {
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
    let mut stripped = stripped_base(base);
    if let Some(query) = query.and_then(|query| kept_pairs(query, true, nested)) {
        stripped.push('?');
        stripped.push_str(&query);
    }
    if let Some(fragment) = fragment.and_then(|fragment| kept_fragment(fragment, nested)) {
        stripped.push('#');
        stripped.push_str(&fragment);
    }
    stripped
}

/// `base` (scheme, authority and path) without user info in the authority
/// and without secret matrix parameters in the path. A web URL's authority
/// starts after any run of `/` or `\` behind the scheme, as browsers read
/// it: `https:user@h` is `https://user@h`.
fn stripped_base(base: &str) -> String {
    let Some((scheme, rest)) = base.split_once(':') else { return base.to_string() };
    let slashes: String = rest.chars().take_while(|c| matches!(c, '/' | '\\')).collect();
    let after = rest.trim_start_matches(['/', '\\']);
    // The path starts at the first separator; the authority is what comes before it.
    let path = after.trim_start_matches(|c| !matches!(c, '/' | '\\'));
    let authority = after.split(['/', '\\']).next().unwrap_or_default();
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    format!("{scheme}:{slashes}{host}{}", kept_matrix(path))
}

/// `path` without its secret matrix parameters (`/p;jsessionid=X` is
/// `/p`); a parameter without a value stays, and so does everything else,
/// byte for byte.
fn kept_matrix(path: &str) -> String {
    if !path.contains(';') {
        return path.to_string();
    }
    path.split('/')
        .map(|segment| {
            let mut parts = segment.split(';');
            let mut kept = parts.next().unwrap_or("").to_string();
            for parameter in parts {
                let secret = parameter
                    .split_once('=')
                    .is_some_and(|(key, _)| is_secret_key(&decode_key(key)));
                if !secret {
                    kept.push(';');
                    kept.push_str(parameter);
                }
            }
            kept
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// A fragment without its secret keys; None when nothing is left. A hash
/// route (`#/cb?code=abc`, `#!/cb?code=abc`: a fragment that starts with
/// `/` or `!/`) keeps its route, without secret matrix parameters, and
/// filters what follows its `?` as a query. Any other fragment is read as
/// keys, `?` and all (`#access_token=abc&redirect=https://x/?a=b`), and a
/// part is a key only when it has a value (`#section` and `#token` stay).
fn kept_fragment(fragment: &str, nested: bool) -> Option<String> {
    let route = fragment.starts_with('/') || fragment.starts_with("!/");
    if !route {
        return kept_pairs(fragment, false, nested);
    }
    let (path, query) = match fragment.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (fragment, None),
    };
    let mut kept = kept_matrix(path);
    if let Some(query) = query.and_then(|query| kept_pairs(query, true, nested)) {
        kept.push('?');
        kept.push_str(&query);
    }
    (!kept.is_empty()).then_some(kept)
}

/// The pairs of `part` (separated by `&` or `;`) that are not secrets, byte
/// for byte, each kept pair after the separator that preceded it; None when
/// nothing is left. `bare_keys`: a pair without `=` is a key too.
///
/// A `?` in a pair's key starts the pairs of what reads as a query there
/// (`#login?code=xyz`): a secret after it is dropped and the text before it
/// stays (`#login`). A kept redirect value is stripped as a URL unless
/// `nested`.
fn kept_pairs(part: &str, bare_keys: bool, nested: bool) -> Option<String> {
    // Each pair after the separator before it (none before the first).
    let separators = std::iter::once("").chain(part.matches(['&', ';']));
    let pairs: Vec<(&str, &str)> = separators.zip(part.split(['&', ';'])).collect();
    let mut changed = false;
    let mut kept = Vec::with_capacity(pairs.len());
    for (separator, pair) in pairs {
        match kept_pair(pair, bare_keys, nested) {
            Some(new) if new == pair => kept.push((separator, new)),
            Some(new) => {
                changed = true;
                if !new.is_empty() {
                    kept.push((separator, new));
                }
            }
            None => changed = true,
        }
    }
    if !changed {
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

/// One pair as [`kept_pairs`] keeps it: None when it is a secret, else the
/// pair with any secret after a `?` in its key dropped and its redirect
/// value stripped.
fn kept_pair(pair: &str, bare_keys: bool, nested: bool) -> Option<String> {
    let (key, value) = match pair.split_once('=') {
        Some((key, value)) => (key, Some(value)),
        None => (pair, None),
    };
    let keyed = bare_keys || value.is_some();
    // A `?` in the key starts what reads as a query there: before it is
    // text of its own (`#login`), after it the key of this pair (`code`).
    if let Some((lead, tail)) = key.rsplit_once('?') {
        if bare_keys && is_secret_key(&decode_key(lead)) {
            return None;
        }
        if keyed && !tail.is_empty() && is_secret_key(&decode_key(tail)) {
            return Some(lead.to_string());
        }
        return Some(pair.to_string());
    }
    if keyed && is_secret_key(&decode_key(key)) {
        return None;
    }
    let Some(value) = value.filter(|_| !nested) else { return Some(pair.to_string()) };
    if !REDIRECT_KEYS.contains(&normalized(&decode_key(key)).as_str()) {
        return Some(pair.to_string());
    }
    let target = decode_value(value);
    let lower = target.get(..8).unwrap_or(&target).to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Some(pair.to_string());
    }
    let stripped = strip_url_at(&target, true);
    if stripped == target {
        return Some(pair.to_string());
    }
    let value = if value.contains('%') { encode_value(&stripped) } else { stripped };
    Some(format!("{key}={value}"))
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
const SCRUB_VERSION: i64 = 2;

/// Starts that try a failing scrub of one rule version before it gives up.
const SCRUB_ATTEMPTS: i64 = 3;

/// Closed groups written before the current rules keep what those rules
/// strip until something rewrites them: once per store and rule version
/// (`closed_history_scrub`), every `url` in every stored record is
/// stripped again and every `browser_history` with it. Rows that need
/// nothing are not written.
///
/// The scrub never keeps the store from opening. Each start that tries it
/// counts an attempt first; on any error its writes roll back (a savepoint
/// inside the open's transaction) and the error is logged, so a later start
/// tries again, up to [`SCRUB_ATTEMPTS`] times per rule version.
pub(super) fn scrub_closed_groups(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    match scrub_attempt(transaction) {
        Ok(false) => {}
        Ok(true) => {
            if let Err(error) = scrub_in_savepoint(transaction) {
                eprintln!("cmux-tui: closed history scrub failed, retried next start: {error:#}");
            }
        }
        Err(error) => eprintln!("cmux-tui: closed history scrub skipped: {error:#}"),
    }
    Ok(())
}

/// Whether this start scrubs: the version is not done and has attempts
/// left, in which case this one is counted.
fn scrub_attempt(transaction: &Transaction<'_>) -> anyhow::Result<bool> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS closed_history_scrub (
           version INTEGER PRIMARY KEY NOT NULL,
           attempts INTEGER NOT NULL DEFAULT 0,
           done INTEGER NOT NULL DEFAULT 0
         );",
    )?;
    let done: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM closed_history_scrub WHERE version >= ?1 AND done != 0)",
        [SCRUB_VERSION],
        |row| row.get(0),
    )?;
    let attempts: i64 = transaction.query_row(
        "SELECT COALESCE(MAX(attempts), 0) FROM closed_history_scrub WHERE version = ?1",
        [SCRUB_VERSION],
        |row| row.get(0),
    )?;
    if done || attempts >= SCRUB_ATTEMPTS {
        return Ok(false);
    }
    transaction.execute(
        "INSERT INTO closed_history_scrub(version, attempts) VALUES(?1, 1)
         ON CONFLICT(version) DO UPDATE SET attempts = attempts + 1",
        [SCRUB_VERSION],
    )?;
    Ok(true)
}

/// The scrub in a savepoint, rolled back on any error.
fn scrub_in_savepoint(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch("SAVEPOINT closed_history_scrub")?;
    match scrub_rows(transaction) {
        Ok(()) => Ok(transaction.execute_batch("RELEASE closed_history_scrub")?),
        Err(error) => {
            if let Err(rollback) = transaction
                .execute_batch("ROLLBACK TO closed_history_scrub; RELEASE closed_history_scrub")
            {
                eprintln!("cmux-tui: closed history scrub could not roll back: {rollback:#}");
            }
            Err(error)
        }
    }
}

fn scrub_rows(transaction: &Transaction<'_>) -> anyhow::Result<()> {
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
    transaction
        .execute("UPDATE closed_history_scrub SET done = 1 WHERE version = ?1", [SCRUB_VERSION])?;
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
    fn strip_url_reads_the_pairs_after_a_question_mark_in_a_fragment() {
        assert_eq!(strip_url("https://h/p#login?code=xyz"), "https://h/p#login");
        assert_eq!(strip_url("https://h/p#section?token=abc"), "https://h/p#section");
        assert_eq!(strip_url("https://h/p#cb?code="), "https://h/p#cb");
        assert_eq!(strip_url("https://h/p#?code=xyz"), "https://h/p");
    }

    #[test]
    fn strip_url_drops_session_ids_from_the_query_path_and_route() {
        assert_eq!(strip_url("https://h/p?jsessionid=X&a=1"), "https://h/p?a=1");
        assert_eq!(strip_url("https://h/p;jsessionid=X"), "https://h/p");
        assert_eq!(strip_url("https://h/p;jsessionid=X;v=1/q"), "https://h/p;v=1/q");
        assert_eq!(strip_url("https://h/p;JSESSIONID=X?a=1"), "https://h/p?a=1");
        assert_eq!(strip_url("https://h/#/path;jsessionid=X"), "https://h/#/path");
        assert_eq!(strip_url("https://h/#/path;jsessionid=X?x=1"), "https://h/#/path?x=1");
        // A matrix parameter that is not a secret stays.
        assert_eq!(strip_url("https://h/p;v=1/q"), "https://h/p;v=1/q");
    }

    #[test]
    fn strip_url_catches_run_together_and_upper_case_secret_keys() {
        for key in ["accesstoken", "ACCESSTOKEN", "idtoken", "authtoken", "refreshtoken"] {
            assert_eq!(strip_url(&format!("https://h/p?{key}=s&a=1")), "https://h/p?a=1", "{key}");
        }
        for key in ["code_verifier", "oauth_verifier", "SAMLResponse", "session"] {
            assert_eq!(strip_url(&format!("https://h/p?{key}=s&a=1")), "https://h/p?a=1", "{key}");
        }
        // Page cursors and OAuth `state` are not credentials.
        for key in ["pagetoken", "next_page_token", "state"] {
            let url = format!("https://h/p?{key}=s&a=1");
            assert_eq!(strip_url(&url), url, "{key}");
        }
    }

    #[test]
    fn strip_url_strips_one_level_into_an_encoded_redirect() {
        assert_eq!(
            strip_url("https://h/login?redirect=https%3A%2F%2Fx%2Fcb%3Ftoken%3Ds%26a%3D1&b=2"),
            "https://h/login?redirect=https%3A%2F%2Fx%2Fcb%3Fa%3D1&b=2"
        );
        assert_eq!(
            strip_url("https://h/login?return_to=https%3A%2F%2Fu%3Ap%40x%2F"),
            "https://h/login?return_to=https%3A%2F%2Fx%2F"
        );
        // A redirect with nothing to strip stays byte for byte.
        let url = "https://h/login?next=https%3a%2f%2fx%2f%3fa%3d1";
        assert_eq!(strip_url(url), url);
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
