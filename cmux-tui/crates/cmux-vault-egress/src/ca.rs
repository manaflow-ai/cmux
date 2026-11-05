//! The CA agents trust for intercepted hosts. Its key is made at start and
//! lives only in this process's memory; only its certificate is written out
//! (by the daemon), for agent processes to trust.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rcgen::{
    BasicConstraints, CertificateParams, CertifiedIssuer, DistinguishedName, DnType,
    ExtendedKeyUsagePurpose, IsCa, KeyPair, KeyUsagePurpose,
};
use rustls::ServerConfig;
use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};

/// Most hosts with a cached leaf; past it the cache starts over.
const MAX_LEAVES: usize = 256;
/// A cached leaf is made again after this long (it is valid for 30 days).
const LEAF_REUSE: Duration = Duration::from_secs(24 * 3600);

pub struct Authority {
    issuer: CertifiedIssuer<'static, KeyPair>,
    pem: String,
    leaves: Mutex<HashMap<String, (Instant, Arc<ServerConfig>)>>,
}

impl std::fmt::Debug for Authority {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Authority(..)")
    }
}

fn name(common: &str) -> DistinguishedName {
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, common);
    dn
}

fn window(days: i64) -> (time::OffsetDateTime, time::OffsetDateTime) {
    let now = time::OffsetDateTime::now_utc();
    (now - time::Duration::hours(1), now + time::Duration::days(days))
}

impl Authority {
    /// A new CA: path length 0 (it signs leaves only), valid for 397 days.
    pub fn generate() -> Result<Authority, rcgen::Error> {
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        params.distinguished_name = name("cmux vault egress (this machine's agents only)");
        params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
        params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
        (params.not_before, params.not_after) = window(397);
        let issuer = CertifiedIssuer::self_signed(params, KeyPair::generate()?)?;
        let pem = issuer.pem();
        Ok(Authority { issuer, pem, leaves: Mutex::new(HashMap::new()) })
    }

    /// The CA certificate, PEM: what agent processes are told to trust.
    pub fn pem(&self) -> &str {
        &self.pem
    }

    /// The TLS server side for `host` (a DNS name), HTTP/1.1 only.
    pub fn server_config(&self, host: &str) -> std::io::Result<Arc<ServerConfig>> {
        let mut leaves = self.leaves.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((made, config)) = leaves.get(host)
            && made.elapsed() < LEAF_REUSE
        {
            return Ok(config.clone());
        }
        let config = self.leaf(host).map_err(std::io::Error::other)?;
        if leaves.len() >= MAX_LEAVES {
            leaves.clear();
        }
        leaves.insert(host.to_owned(), (Instant::now(), config.clone()));
        Ok(config)
    }

    fn leaf(
        &self,
        host: &str,
    ) -> Result<Arc<ServerConfig>, Box<dyn std::error::Error + Send + Sync>> {
        let mut params = CertificateParams::new(vec![host.to_owned()])?;
        params.distinguished_name = name(host);
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        params.use_authority_key_identifier_extension = true;
        (params.not_before, params.not_after) = window(30);
        let key = KeyPair::generate()?;
        let cert = params.signed_by(&key, &self.issuer)?;
        let private = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut config = ServerConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(vec![cert.der().clone()], private)?;
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        Ok(Arc::new(config))
    }
}
