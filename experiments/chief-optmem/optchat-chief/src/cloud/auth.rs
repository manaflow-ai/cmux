//! The brain host's own cloud identity (brains/DESIGN-cmux-lawrence.md
//! section 2): an ES256 install key registered under the user with
//! `install.register`, and chief tokens minted from it with
//! `POST /v1/auth/challenge` and `POST /v1/auth/token {agent}`. A chief token
//! lives 600 s and acts as `agent_<chief>`; UserDO checks the install, its
//! grant and the chief on every request, so revoking the install stops the
//! brain at once.

use std::io::Write as _;
use std::path::Path;
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use ring::rand::SystemRandom;
use ring::signature::{
    ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _,
    UnparsedPublicKey,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// `$BRAIN/cloud/install.json` (0600): the private key, the public JWK, and
/// what registration and `cloud chief` filled in.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstallFile {
    /// The API origin (`https://host`), the same the daemon lease names.
    pub api_base_url: String,
    /// The private key, PKCS#8 DER, base64url.
    pub pkcs8: String,
    /// `{kty, crv, x, y}`: what `install.register` gets.
    pub public_jwk: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub install: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// The chief this brain answers as (`agent_...`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chief: Option<String>,
    /// The chief's main conversation (`conv_...`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

impl InstallFile {
    /// A new P-256 key for `api_base_url`.
    pub fn generate(api_base_url: &str) -> Result<InstallFile, String> {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
            .map_err(|_| "generating a P-256 key failed".to_owned())?;
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
            .map_err(|_| "reading the new key failed".to_owned())?;
        let point = pair.public_key().as_ref();
        if point.len() != 65 || point[0] != 4 {
            return Err("unexpected public key encoding".into());
        }
        Ok(InstallFile {
            api_base_url: api_base_url.trim_end_matches('/').to_owned(),
            pkcs8: B64.encode(pkcs8.as_ref()),
            public_jwk: json!({"kty": "EC", "crv": "P-256", "x": B64.encode(&point[1..33]), "y": B64.encode(&point[33..65])}),
            install: None,
            user: None,
            chief: None,
            conversation: None,
        })
    }

    pub fn load(path: &Path) -> Result<InstallFile, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// Writes the file 0600 (its directory 0700), replacing it atomically.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        let parent = path.parent().ok_or("install file has no directory")?;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .map_err(|e| format!("{}: {e}", parent.display()))?;
        let tmp = path.with_extension("json.tmp");
        let _ = std::fs::remove_file(&tmp);
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| format!("{}: {e}", tmp.display()))?;
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        file.write_all(text.as_bytes())
            .and_then(|()| file.sync_all())
            .map_err(|e| format!("{}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
    }

    /// ES256 over `message`: raw r||s, base64url (what `/v1/auth/token` takes).
    pub fn sign(&self, message: &str) -> Result<String, String> {
        let rng = SystemRandom::new();
        let der = B64
            .decode(&self.pkcs8)
            .map_err(|e| format!("install key: {e}"))?;
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &rng)
            .map_err(|_| "install key: not a P-256 PKCS#8 key".to_owned())?;
        let sig = pair
            .sign(&rng, message.as_bytes())
            .map_err(|_| "signing failed".to_owned())?;
        Ok(B64.encode(sig.as_ref()))
    }

    /// The `install.register` params (principal: the user's session).
    pub fn register_params(&self, name: &str, device_name: &str) -> Value {
        json!({
            "public_jwk": self.public_jwk,
            "kind": "cli",
            "name": name,
            "device_name": device_name,
            "platform": if cfg!(target_os = "macos") { "macos" } else { "linux" },
        })
    }
}

/// What the install signs: `message_prefix` (`cmux-auth-v1\n<env>\n<install>\n`) + nonce.
pub fn challenge_message(environment: &str, install: &str, nonce: &str) -> String {
    format!("cmux-auth-v1\n{environment}\n{install}\n{nonce}")
}

/// Checks an ES256 raw signature against a public JWK (tests and `cloud check`).
pub fn verify(jwk: &Value, message: &str, signature: &str) -> bool {
    let coord = |k: &str| {
        jwk.get(k)
            .and_then(Value::as_str)
            .and_then(|s| B64.decode(s).ok())
    };
    let (Some(x), Some(y), Ok(sig)) = (coord("x"), coord("y"), B64.decode(signature)) else {
        return false;
    };
    let mut point = vec![4u8];
    point.extend_from_slice(&x);
    point.extend_from_slice(&y);
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, point)
        .verify(message.as_bytes(), &sig)
        .is_ok()
}

/// A cloud session lease for the daemon (`cloud-session-set`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Lease {
    pub api_base_url: String,
    pub access_token: String,
    /// Unix milliseconds.
    pub expires_at: u64,
}

/// Where tokens come from: the install key, or a fake in tests.
pub trait TokenSource: Send + Sync {
    /// A token acting as `agent` (a chief id), or as the install itself.
    fn mint(&self, agent: Option<&str>) -> Result<Lease, String>;
}

/// The HTTP the auth and op calls need.
pub trait Http: Send + Sync {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<Value, String>;
}

/// Blocking HTTP through ureq.
pub struct UreqHttp;

impl Http for UreqHttp {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<Value, String> {
        let mut req = ureq::post(url).timeout(std::time::Duration::from_secs(30));
        if let Some(token) = bearer {
            req = req.set("authorization", &format!("Bearer {token}"));
        }
        match req.send_json(body.clone()) {
            Ok(resp) => resp.into_json::<Value>().map_err(|e| format!("{url}: {e}")),
            Err(ureq::Error::Status(code, resp)) => {
                let text = resp.into_string().unwrap_or_default();
                Err(format!(
                    "{url}: HTTP {code}: {}",
                    text.chars().take(500).collect::<String>()
                ))
            }
            Err(e) => Err(format!("{url}: {e}")),
        }
    }
}

/// Tokens minted from the install key.
pub struct InstallTokens {
    file: InstallFile,
    http: Arc<dyn Http>,
}

impl InstallTokens {
    pub fn new(file: InstallFile, http: Arc<dyn Http>) -> InstallTokens {
        InstallTokens { file, http }
    }
}

impl TokenSource for InstallTokens {
    fn mint(&self, agent: Option<&str>) -> Result<Lease, String> {
        let install = self
            .file
            .install
            .as_deref()
            .ok_or("the install is not registered (run `optchat-chief cloud register`)")?;
        let user = self
            .file
            .user
            .as_deref()
            .ok_or("the install file names no user")?;
        let api = &self.file.api_base_url;
        let challenge = self.http.post(
            &format!("{api}/v1/auth/challenge"),
            &json!({"user": user, "install": install}),
            None,
        )?;
        let nonce = challenge
            .get("nonce")
            .and_then(Value::as_str)
            .ok_or("challenge without a nonce")?;
        let prefix = challenge
            .get("message_prefix")
            .and_then(Value::as_str)
            .ok_or("challenge without a message_prefix")?;
        let signature = self.file.sign(&format!("{prefix}{nonce}"))?;
        let mut body =
            json!({"user": user, "install": install, "nonce": nonce, "signature": signature});
        if let Some(agent) = agent {
            body["agent"] = json!(agent);
        }
        let token = self
            .http
            .post(&format!("{api}/v1/auth/token"), &body, None)?;
        Ok(Lease {
            api_base_url: api.clone(),
            access_token: token
                .get("access_token")
                .and_then(Value::as_str)
                .ok_or("token reply without an access_token")?
                .to_owned(),
            expires_at: token
                .get("expires_at")
                .and_then(Value::as_u64)
                .ok_or("token reply without expires_at")?,
        })
    }
}

/// `POST /v1/ops`: one mutation; returns the op's `value` or the owner's error.
pub fn op(
    http: &dyn Http,
    api: &str,
    bearer: &str,
    name: &str,
    params: Value,
    key: &str,
) -> Result<Value, String> {
    let reply = http.post(
        &format!("{api}/v1/ops"),
        &json!({"op": name, "params": params, "idempotency_key": key}),
        Some(bearer),
    )?;
    if reply.get("ok") == Some(&Value::Bool(true)) {
        Ok(reply.get("value").cloned().unwrap_or(Value::Null))
    } else {
        Err(format!(
            "{name}: {}",
            reply.get("error").cloned().unwrap_or(reply)
        ))
    }
}

/// `POST /v1/read`: one read; returns its `value`.
pub fn read(
    http: &dyn Http,
    api: &str,
    bearer: &str,
    name: &str,
    params: Value,
) -> Result<Value, String> {
    let reply = http.post(
        &format!("{api}/v1/read"),
        &json!({"op": name, "params": params}),
        Some(bearer),
    )?;
    reply
        .get("value")
        .cloned()
        .ok_or_else(|| format!("{name}: {reply}"))
}
