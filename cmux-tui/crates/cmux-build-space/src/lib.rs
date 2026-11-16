//! A dev build's cloud data space: `X-Cmux-Build-Space: dev:<slug>`.
//!
//! A tagged dev build sends its tag's slug on every request and WebSocket
//! upgrade to cloud-api and cmux-mobile-api, so it never reads or changes the
//! data of another dev build or of nightly and stable (root CLAUDE.md "Dev
//! builds are separate"). Nightly, stable and standalone processes have no
//! build space and send no header. The app decides (Swift `CMUXBuildSpace`)
//! and tells each Rust child it launches through one variable:
//!
//! | `CMUX_BUILD_SPACE` | Meaning |
//! | --- | --- |
//! | `dev:<slug>` (the backends' pattern) | this dev build's space: every cloud client sends it |
//! | unset | no space (nightly, stable, a Cloud machine, a standalone CLI), unless `CMUX_BUNDLE_ID` and `CMUX_TAG` name a tagged dev build: then refused |
//! | anything else, blank included | refused |
//!
//! "Refused" fails closed: every cloud client of the process refuses to start
//! with [`Unusable`]'s message instead of falling back to nightly's data.
//! `CMUX_MOBILE_BUILD_SPACE` (what cmux-mobile-host read first) still works
//! and means the same; set beside `CMUX_BUILD_SPACE` with another value, it is
//! refused too.
//!
//! [`process`] resolves the variables once per process. Every cloud HTTP
//! client and WebSocket upgrade in the Rust workspace takes the space from it
//! ([`insert`], [`headers`]), never from its own read of the environment.

use std::fmt;
use std::sync::OnceLock;

use cmux_agent_pane_policy::build_identity::{BuildIdentity, BuildKind};

/// The request header the backends read (lowercase, as HTTP/2 sends it).
pub const HEADER: &str = "x-cmux-build-space";
/// The variable the app sets for every Rust child it launches.
pub const ENV: &str = "CMUX_BUILD_SPACE";
/// The older name cmux-mobile-host read; same values, same rules.
pub const MOBILE_ENV: &str = "CMUX_MOBILE_BUILD_SPACE";

/// The longest slug the backends accept.
const MAX_SLUG: usize = 64;

/// A valid build space value (`dev:<slug>`, the backends' pattern
/// `^dev:[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BuildSpace(String);

impl BuildSpace {
    /// `value` when it matches the backends' pattern; `None` otherwise.
    pub fn parse(value: &str) -> Option<Self> {
        let slug = value.strip_prefix("dev:")?;
        let bytes = slug.as_bytes();
        let edge = |b: &u8| b.is_ascii_lowercase() || b.is_ascii_digit();
        let valid = !bytes.is_empty()
            && bytes.len() <= MAX_SLUG
            && bytes.first().is_some_and(edge)
            && bytes.last().is_some_and(edge)
            && bytes.iter().all(|b| edge(b) || *b == b'-');
        valid.then(|| Self(value.to_owned()))
    }

    /// [`Self::parse`] of an optional value (an unset or blank value is no space).
    /// For a value an app hands over in-process (the iPhone app's FFI); a
    /// launched process uses [`resolve`], which refuses what this drops.
    pub fn parse_optional(value: Option<&str>) -> Option<Self> {
        value.map(str::trim).filter(|v| !v.is_empty()).and_then(Self::parse)
    }

    /// The header value, `dev:<slug>`.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The header value as an HTTP header value (always valid: `[a-z0-9:-]`).
    pub fn header_value(&self) -> http::HeaderValue {
        http::HeaderValue::from_str(&self.0).unwrap_or_else(|_| http::HeaderValue::from_static(""))
    }
}

impl fmt::Display for BuildSpace {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Why this process may not call the cloud: its launcher said it is a dev
/// build but gave no usable build space. Sending no header would act on
/// nightly's data, so every cloud client refuses instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unusable(String);

impl Unusable {
    /// What was wrong, without the refusal's preamble.
    pub fn reason(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Unusable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "refusing to call cmux Cloud: {}. A dev build sends {ENV}=dev:<slug> as X-Cmux-Build-Space; without it this process would read and change nightly's data",
            self.0
        )
    }
}

impl std::error::Error for Unusable {}

impl From<Unusable> for std::io::Error {
    fn from(error: Unusable) -> Self {
        std::io::Error::new(std::io::ErrorKind::PermissionDenied, error)
    }
}

/// A resolved build space: `Ok(None)` for nightly, stable and standalone
/// processes, `Ok(Some)` for a dev build, `Err` when the process must not
/// call the cloud at all.
pub type Resolved = Result<Option<BuildSpace>, Unusable>;

/// The build space `var` (an environment lookup) gives, by the table in the
/// crate documentation.
pub fn resolve(var: impl Fn(&str) -> Option<String>) -> Resolved {
    let primary = var(ENV);
    let mobile = var(MOBILE_ENV);
    let (name, value) = match (primary, mobile) {
        (Some(primary), Some(mobile)) if primary != mobile => {
            return Err(Unusable(format!(
                "{ENV}={primary:?} and {MOBILE_ENV}={mobile:?} name different build spaces"
            )));
        }
        (Some(value), _) => (ENV, value),
        (None, Some(value)) => (MOBILE_ENV, value),
        (None, None) => return unset(&var),
    };
    match BuildSpace::parse(&value) {
        Some(space) => Ok(Some(space)),
        None => Err(Unusable(format!(
            "{name}={value:?} is not dev:<slug> (^dev:[a-z0-9](?:[a-z0-9-]{{0,62}}[a-z0-9])?$)"
        ))),
    }
}

/// No variable: no space, unless the app identity a cmux app gives its
/// terminals, daemon and agents (`CMUX_BUNDLE_ID`, `CMUX_TAG`) names a tagged
/// dev build, whose launcher must have passed its space.
fn unset(var: &impl Fn(&str) -> Option<String>) -> Resolved {
    let Some(bundle) = var("CMUX_BUNDLE_ID").filter(|b| !b.trim().is_empty()) else {
        return Ok(None);
    };
    let build = BuildIdentity::new(Some(&bundle), var("CMUX_TAG").as_deref());
    let dev = matches!(build.kind(), BuildKind::Dev | BuildKind::Staging);
    match build.tag() {
        Some(tag) if dev => Err(Unusable(format!(
            "CMUX_BUNDLE_ID={bundle:?} is the dev build tagged {tag:?}, but its launcher set no {ENV}"
        ))),
        _ => Ok(None),
    }
}

static PROCESS: OnceLock<Resolved> = OnceLock::new();

/// This process's build space: the environment's ([`resolve`]), read once.
pub fn process() -> Result<Option<&'static BuildSpace>, Unusable> {
    match PROCESS.get_or_init(|| resolve(|name| std::env::var(name).ok())) {
        Ok(space) => Ok(space.as_ref()),
        Err(error) => Err(error.clone()),
    }
}

/// Sets this process's build space before anything reads it (a test binary
/// that checks a client's headers, an embedder that knows better than the
/// environment). False when it was already set or read; the value stays.
pub fn init_process(resolved: Resolved) -> bool {
    PROCESS.set(resolved).is_ok()
}

/// Adds `space`'s header to `headers` (an HTTP request's, a client's default
/// headers or a WebSocket upgrade's); no space adds nothing and removes any
/// header already there, so a nightly request never carries one.
pub fn insert_space(headers: &mut http::HeaderMap, space: Option<&BuildSpace>) {
    match space {
        Some(space) => {
            headers.insert(http::HeaderName::from_static(HEADER), space.header_value());
        }
        None => {
            headers.remove(HEADER);
        }
    }
}

/// [`insert_space`] of this process's space; `Err` (nothing added) when the
/// process must not call the cloud.
pub fn insert(headers: &mut http::HeaderMap) -> Result<(), Unusable> {
    insert_space(headers, process()?);
    Ok(())
}

/// This process's header as a map (empty for nightly), for
/// `reqwest::ClientBuilder::default_headers` and `RequestBuilder::headers`.
pub fn headers() -> Result<http::HeaderMap, Unusable> {
    let mut headers = http::HeaderMap::new();
    insert(&mut headers)?;
    Ok(headers)
}

/// [`headers`] for an explicit space.
pub fn headers_for(space: Option<&BuildSpace>) -> http::HeaderMap {
    let mut headers = http::HeaderMap::new();
    insert_space(&mut headers, space);
    headers
}

#[cfg(feature = "testing")]
pub mod testing;

#[cfg(test)]
mod tests;
