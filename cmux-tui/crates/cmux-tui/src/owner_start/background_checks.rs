//! The owner's network checks at start (plans/cmux-next/tui-tester-rollout.md #8, #10):
//! the signed invite-wave flags (`feature_flags`) and the daily registry
//! check for npm and PyPI installs (`update_notice`). One thread, off the
//! start path; each logs one outcome line (`feature-flags: …`,
//! `update-check: …`) to the client log. A failed fetch keeps the cache.

use crate::{feature_flags, update_notice};

const LOG_AREA: &str = "background-checks";

/// Starts the checks on a thread of their own.
pub(super) fn spawn() {
    // supervise-allow: one best-effort pass (flags, then the update check) that owns no shared state; a panic loses only this pass's log lines, as offline does.
    let _ = cmux_threads::spawn("background-checks", cmux_threads::ThreadQos::Utility, || {
        let line = flags();
        crate::client_log::info(LOG_AREA, &format!("feature-flags: {line}"));
        let line = update_check();
        crate::client_log::info(LOG_AREA, &format!("update-check: {line}"));
    });
}

fn flags() -> String {
    let Some(root) = feature_flags::state_root() else { return "off (no state root)".into() };
    #[cfg(debug_assertions)]
    let url = std::env::var(feature_flags::TEST_URL_ENV)
        .ok()
        .filter(|url| !url.is_empty())
        .unwrap_or_else(|| feature_flags::FLAGS_URL.to_string());
    #[cfg(not(debug_assertions))]
    let url = feature_flags::FLAGS_URL.to_string();
    let fetched = get(&url).and_then(|data| get(&format!("{url}.sig")).map(|sig| (data, sig)));
    match fetched {
        Ok((data, signature)) => {
            match feature_flags::store(&root, &data, &signature, &feature_flags::public_key()) {
                Ok(()) => "updated".into(),
                Err(why) => format!("rejected ({why})"),
            }
        }
        Err(error) => format!("kept cache ({error})"),
    }
}

fn update_check() -> String {
    let channel = update_notice::channel();
    if let update_notice::Check::Off(why) = update_notice::decision(channel) {
        return format!("off ({why})");
    }
    let Some(root) = feature_flags::state_root() else { return "off (no state root)".into() };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or_default();
    if !update_notice::due(update_notice::read_cache(&root).as_ref(), channel, now_ms) {
        return "not due".into();
    }
    let Some(url) = update_notice::registry_url(channel) else {
        return "off (no registry for this install)".into();
    };
    let latest = match get(&url) {
        Ok(body) => match update_notice::parse_latest(&body) {
            Some(latest) => latest,
            None => return "failed (no version in the registry answer)".into(),
        },
        Err(error) => return format!("failed ({error})"),
    };
    // npm's next tag (tester rollout #8): a missing tag is no next, not a failure.
    let next = update_notice::next_url(channel, &url)
        .and_then(|next_url| get(&next_url).ok())
        .and_then(|body| update_notice::parse_latest(&body));
    let summary = match &next {
        Some(next) => format!("latest={latest} next={next}"),
        None => format!("latest={latest}"),
    };
    let cached = update_notice::Cached {
        checked_at_ms: now_ms,
        latest,
        next,
        channel: channel.as_str().to_string(),
    };
    match update_notice::write_cache(&root, &cached) {
        Ok(()) => summary,
        Err(error) => format!("failed ({error})"),
    }
}

/// One small GET with a 10 second timeout.
#[cfg(unix)]
fn get(url: &str) -> Result<Vec<u8>, String> {
    // reqwest's rustls-no-provider build needs the workspace's ring provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = cmux_threads::tokio::builder(
        "background-checks",
        cmux_threads::ThreadQos::Background,
        cmux_threads::tokio::Flavor::CurrentThread,
    )
    .build()
    .map_err(|error| format!("runtime: {error}"))?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| format!("http client: {error}"))?;
    cmux_threads::tokio::block_on(&runtime, async {
        let response = client.get(url).send().await.map_err(|error| error.to_string())?;
        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status()));
        }
        response.bytes().await.map(|bytes| bytes.to_vec()).map_err(|error| error.to_string())
    })
}

#[cfg(not(unix))]
fn get(_url: &str) -> Result<Vec<u8>, String> {
    Err("unsupported platform".into())
}
