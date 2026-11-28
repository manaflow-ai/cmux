//! The CA agents trust for intercepted hosts. The daemon keeps its key
//! (0600, beside the certificate) so the next daemon serves the same CA
//! ([`Authority::from_kept`]): an agent reads the CA file once at its start,
//! and outlives daemon restarts. Only the certificate is given to agents.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use rustls::ServerConfig;
use rustls::pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer};

/// Most hosts with a cached leaf; past it the cache starts over.
const MAX_LEAVES: usize = 256;
/// A cached leaf is made again after this long (it is valid for 30 days).
const LEAF_REUSE: Duration = Duration::from_secs(24 * 3600);
/// The CA's subject: a kept certificate with another one is not ours.
const CA_NAME: &str = "cmux vault egress (this machine's agents only)";
/// How long a new CA is valid.
const CA_DAYS: i64 = 397;
/// A kept CA this close to its end is replaced: a leaf (30 days) never
/// outlives the CA that signed it, even in a daemon that runs that long.
pub const CA_RENEW_BEFORE: time::Duration = time::Duration::days(45);

/// Why a kept CA was not used ([`Authority::from_kept`]); a code to log, never key material.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotKept {
    /// The key is not a key rcgen reads.
    Key,
    /// The certificate is not one PEM certificate.
    Certificate,
    /// The certificate is not this CA (subject, CA flag) or not for this key.
    NotOurs,
    /// It ends within [`CA_RENEW_BEFORE`] (or has not begun).
    Expiring,
}

impl NotKept {
    pub fn code(self) -> &'static str {
        match self {
            NotKept::Key => "vault.egress_ca_key_unreadable",
            NotKept::Certificate => "vault.egress_ca_cert_unreadable",
            NotKept::NotOurs => "vault.egress_ca_not_ours",
            NotKept::Expiring => "vault.egress_ca_expiring",
        }
    }
}

pub struct Authority {
    issuer: Issuer<'static, KeyPair>,
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

/// The CA's parameters: path length 0 (it signs leaves only). The issuer
/// built from them and a kept key signs exactly as the first one did (same
/// subject, key usages and key identifier, which comes from the key).
fn ca_params(days: i64) -> Result<CertificateParams, rcgen::Error> {
    let mut params = CertificateParams::new(Vec::<String>::new())?;
    params.distinguished_name = name(CA_NAME);
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
    (params.not_before, params.not_after) = window(days);
    Ok(params)
}

impl Authority {
    /// A new CA, valid for 397 days.
    pub fn generate() -> Result<Authority, rcgen::Error> {
        Self::generate_for(CA_DAYS)
    }

    /// A new CA, valid for `days` (a kept CA's renewal is tested with a short one).
    pub fn generate_for(days: i64) -> Result<Authority, rcgen::Error> {
        let params = ca_params(days)?;
        let key = KeyPair::generate()?;
        let pem = params.self_signed(&key)?.pem();
        Ok(Authority { issuer: Issuer::new(params, key), pem, leaves: Mutex::new(HashMap::new()) })
    }

    /// The CA an earlier process kept: its key ([`Authority::key_pem`]) and
    /// its certificate ([`Authority::pem`]). Refused when they are not this
    /// CA's pair or it ends within [`CA_RENEW_BEFORE`]; the caller then makes
    /// a new one.
    pub fn from_kept(key_pem: &str, cert_pem: &str) -> Result<Authority, NotKept> {
        let key = KeyPair::from_pem(key_pem).map_err(|_| NotKept::Key)?;
        let (_, pem) = x509_parser::pem::parse_x509_pem(cert_pem.as_bytes())
            .map_err(|_| NotKept::Certificate)?;
        if pem.label != "CERTIFICATE" {
            return Err(NotKept::Certificate);
        }
        let cert = pem.parse_x509().map_err(|_| NotKept::Certificate)?;
        let subject = cert.subject().iter_common_name().next().and_then(|cn| cn.as_str().ok());
        // The SubjectPublicKeyInfo ends with the key's public point.
        if !cert.is_ca()
            || subject != Some(CA_NAME)
            || !cert.public_key().raw.ends_with(key.public_key_raw())
        {
            return Err(NotKept::NotOurs);
        }
        let now = time::OffsetDateTime::now_utc();
        let validity = cert.validity();
        if validity.not_before.to_datetime() > now
            || validity.not_after.to_datetime() - CA_RENEW_BEFORE <= now
        {
            return Err(NotKept::Expiring);
        }
        let params = ca_params(CA_DAYS).map_err(|_| NotKept::NotOurs)?;
        Ok(Authority {
            issuer: Issuer::new(params, key),
            pem: cert_pem.to_owned(),
            leaves: Mutex::new(HashMap::new()),
        })
    }

    /// The CA certificate, PEM: what agent processes are told to trust.
    pub fn pem(&self) -> &str {
        &self.pem
    }

    /// The CA's key, PEM, for the daemon to keep (0600) for the next one.
    /// Never log it.
    pub fn key_pem(&self) -> zeroize::Zeroizing<String> {
        zeroize::Zeroizing::new(self.issuer.key().serialize_pem())
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

#[cfg(test)]
#[path = "ca_tests.rs"]
mod tests;
