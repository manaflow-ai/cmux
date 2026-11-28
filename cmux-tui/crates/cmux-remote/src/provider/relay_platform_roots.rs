//! The platform's TLS roots for relay `wss` connects, read once per process.
//!
//! Given no connector, tokio-tungstenite (`rustls-tls-native-roots`) calls
//! `rustls_native_certs::load_native_certs()` on every connect: on macOS that walks the user,
//! admin and system trust settings (`SecTrustSettingsCopyTrustSettings`, an XML plist parse per
//! certificate). The hub carrier opens relay sockets all the time, and on cosmic-gray
//! (2026-11-27 00:30Z, load 60 on 15 cores) acpmux opened about 76 relay TLS connections a
//! minute; a 3 s `sample` of its daemon (148% CPU) found one tokio worker in that trust-settings
//! read for all 1,131 of its samples, and under the disk load the read failed
//! (`native root CA certificate loading errors ... code: -36`). The roots do not change between
//! connects, so they are read once and the config is shared.
//!
//! A read with errors is used for its own connect but not kept: the next connect reads again,
//! so a partial read under load cannot stick for the life of the daemon. A read that found no
//! root at all returns `None`, and tokio-tungstenite's own read runs (and reports) as before.

use std::sync::{Arc, OnceLock};

/// The shared native-roots client config, or `None` when no root could be read.
pub(super) fn platform_roots() -> Option<Arc<rustls::ClientConfig>> {
    static KEPT: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    if let Some(config) = KEPT.get() {
        return Some(config.clone());
    }
    let loaded = rustls_native_certs::load_native_certs();
    let mut roots = rustls::RootCertStore::empty();
    let (added, _) = roots.add_parsable_certificates(loaded.certs);
    if added == 0 {
        return None;
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .ok()?
        .with_root_certificates(roots)
        .with_no_client_auth();
    let config = Arc::new(config);
    if loaded.errors.is_empty() {
        return Some(KEPT.get_or_init(|| config).clone());
    }
    Some(config)
}
