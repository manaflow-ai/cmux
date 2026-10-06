use std::path::Path;
use std::sync::Arc;
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct InstallFile { pub api_base_url: String, pub pkcs8: String, pub public_jwk: Value, #[serde(default)] pub install: Option<String>, #[serde(default)] pub user: Option<String>, #[serde(default)] pub chief: Option<String>, #[serde(default)] pub conversation: Option<String> }
impl InstallFile {
    pub fn generate(_api: &str) -> Result<Self, String> { todo!("red") }
    pub fn load(_p: &Path) -> Result<Self, String> { todo!("red") }
    pub fn save(&self, _p: &Path) -> Result<(), String> { todo!("red") }
    pub fn sign(&self, _m: &str) -> Result<String, String> { todo!("red") }
    pub fn register_params(&self, _n: &str, _d: &str) -> Value { todo!("red") }
}
pub fn challenge_message(_e: &str, _i: &str, _n: &str) -> String { todo!("red") }
pub fn verify(_jwk: &Value, _m: &str, _s: &str) -> bool { todo!("red") }
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Lease { pub api_base_url: String, pub access_token: String, pub expires_at: u64 }
pub trait TokenSource: Send + Sync { fn mint(&self, agent: Option<&str>) -> Result<Lease, String>; }
pub trait Http: Send + Sync { fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<Value, String>; }
pub struct InstallTokens { _f: InstallFile, _h: Arc<dyn Http> }
impl InstallTokens { pub fn new(file: InstallFile, http: Arc<dyn Http>) -> Self { InstallTokens { _f: file, _h: http } } }
impl TokenSource for InstallTokens { fn mint(&self, _a: Option<&str>) -> Result<Lease, String> { todo!("red") } }
