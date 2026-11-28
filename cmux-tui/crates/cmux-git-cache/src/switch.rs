//! The per-chat off switch: `CMUX_GIT_CACHE=0` in a chat's environment. git sends no
//! environment to a server, but it runs the proxy's credential helper as its own child, so the
//! helper sees the chat's environment. The proxy answers a ref advertisement that comes with no
//! credential with a challenge (401), git asks the helper, and the helper answers with
//! [`OFF_USER`] when the switch is off, the person's github.com credential when they have one,
//! else [`ANON_USER`]. The proxy passes an [`OFF_USER`] caller's whole clone through to github.com
//! and treats [`ANON_USER`] as no credential. The markers never leave this machine.

pub const ENV: &str = "CMUX_GIT_CACHE";
/// The machine-wide transport switch every cmux rewrite honours (`cmux-transport-rewrite`).
pub const TRANSPORT_ENV: &str = "CMUX_TRANSPORT_REWRITE";
pub const OFF_USER: &str = "cmux-git-cache-off";
pub const ANON_USER: &str = "cmux-git-cache-anon";
/// `Basic base64("cmux-git-cache-off:x")`, what git sends for the helper's [`marker`].
pub const OFF_AUTHORIZATION: &str = "Basic Y211eC1naXQtY2FjaGUtb2ZmOng=";
/// `Basic base64("cmux-git-cache-anon:x")`.
pub const ANON_AUTHORIZATION: &str = "Basic Y211eC1naXQtY2FjaGUtYW5vbjp4";

/// True when `value` turns the cache off (`0`, `off`, `false`, `no`).
pub fn off_value(value: &[u8]) -> bool {
    matches!(
        std::str::from_utf8(value).unwrap_or("").trim().to_ascii_lowercase().as_str(),
        "0" | "off" | "false" | "no"
    )
}

/// This process's switch (the helper's, which is the chat's git's).
pub fn env_off() -> bool {
    [ENV, TRANSPORT_ENV]
        .iter()
        .any(|name| std::env::var_os(name).is_some_and(|v| off_value(v.as_encoded_bytes())))
}

/// The helper's answer with the switch off: the off marker, carrying the person's own
/// credential (`USER:PASSWORD`) as its password so the proxy can hand it to github.com.
pub fn off_answer(filled: Option<&str>) -> String {
    let field = |key: &str| filled?.lines().find_map(|l| l.strip_prefix(key).map(str::to_owned));
    match (field("username="), field("password=")) {
        (user, Some(password)) => format!(
            "username={OFF_USER}\npassword={}:{password}\n",
            user.unwrap_or_else(|| "x-access-token".to_owned())
        ),
        _ => marker(OFF_USER),
    }
}

/// For an off caller, the `Authorization` github.com gets: the person's credential the helper
/// carried, or none.
pub fn off_upstream(authorization: &[u8]) -> Option<String> {
    use base64::Engine as _;
    let b64 = base64::engine::general_purpose::STANDARD;
    let encoded = std::str::from_utf8(authorization).ok()?.strip_prefix("Basic ")?;
    let decoded = String::from_utf8(b64.decode(encoded.trim()).ok()?).ok()?;
    let inner = decoded.strip_prefix(OFF_USER)?.strip_prefix(':')?;
    inner.contains(':').then(|| format!("Basic {}", b64.encode(inner)))
}

fn is_off(authorization: &[u8]) -> bool {
    use base64::Engine as _;
    std::str::from_utf8(authorization)
        .ok()
        .and_then(|v| v.strip_prefix("Basic "))
        .and_then(|e| base64::engine::general_purpose::STANDARD.decode(e.trim()).ok())
        .is_some_and(|d| d.starts_with(format!("{OFF_USER}:").as_bytes()))
}

/// The credential-helper answer for a marker user.
pub fn marker(user: &str) -> String {
    format!("username={user}\npassword=x\n")
}

/// A helper request about one of the markers (git's `store` or `erase` after using it).
pub fn names_marker(request: &str) -> bool {
    request
        .lines()
        .any(|l| l.strip_prefix("username=").is_some_and(|u| u == OFF_USER || u == ANON_USER))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Caller {
    /// No `Authorization`: git has not asked the helper yet.
    Unasked,
    /// The chat turned the cache off.
    Off,
    /// The helper had no credential: anonymous upstream.
    Anon,
    /// A real credential, passed upstream as is.
    Credential,
}

pub fn classify(authorization: Option<&[u8]>) -> Caller {
    match authorization {
        None => Caller::Unasked,
        Some(v) if is_off(v) => Caller::Off,
        Some(v) if v == ANON_AUTHORIZATION.as_bytes() => Caller::Anon,
        Some(_) => Caller::Credential,
    }
}

#[cfg(test)]
#[path = "switch_tests.rs"]
mod tests;
