//! The credential fingerprint and the account a pooled session starts
//! under. A pooled session read its login when it started; if the login
//! changed since (a logout, a new account, a new API key), the pool key no
//! longer matches and the entry is discarded rather than serve a session
//! under the old account.
//!
//! The fingerprint names the account, not the token, where the file says
//! which account it is: an OAuth token refresh rewrites the file without
//! changing the account, and the harness refreshes its own tokens. Files
//! with no account field count by size and modification time. Values are
//! hashed in memory and never stored or logged.

use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

/// Env keys that carry credentials or point a harness at another login.
const AUTH_ENV: &[&str] = &[
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CONFIG_DIR",
    "OPENAI_API_KEY",
    "CODEX_HOME",
    "XDG_DATA_HOME",
    "OPENCODE_CONFIG",
];

/// Where one family keeps its login, and how to read the account from it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reader {
    /// `~/.claude.json`: `oauthAccount.accountUuid` and `organizationUuid`.
    ClaudeAccount,
    /// Codex `auth.json`: `auth_mode`, `tokens.account_id`, `OPENAI_API_KEY`.
    CodexAuth,
    /// OpenCode `auth.json`: each provider's type, account and key.
    OpencodeAuth,
    /// No account field: size and modification time.
    Stat,
}

fn files(
    family: &str,
    env: &dyn Fn(&str) -> Option<String>,
    home: &Path,
) -> Vec<(PathBuf, Reader)> {
    match family {
        "claude" => {
            let dir = env("CLAUDE_CONFIG_DIR").map(PathBuf::from);
            let account = match &dir {
                Some(d) => d.join(".claude.json"),
                None => home.join(".claude.json"),
            };
            let creds = dir.unwrap_or_else(|| home.join(".claude")).join(".credentials.json");
            vec![(account, Reader::ClaudeAccount), (creds, Reader::Stat)]
        }
        "codex" => {
            let dir = env("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| home.join(".codex"));
            vec![(dir.join("auth.json"), Reader::CodexAuth)]
        }
        "opencode" | "opencode-v2" => {
            let data = env("XDG_DATA_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local/share"));
            vec![(data.join("opencode/auth.json"), Reader::OpencodeAuth)]
        }
        _ => vec![],
    }
}

/// A parse of a file modified more recently than this is not cached.
const RACY_WINDOW: std::time::Duration = std::time::Duration::from_secs(2);

/// Reads stay off the switch path when nothing changed: a file is parsed
/// again only when its size or modification time moved.
#[derive(Default)]
pub struct AuthCache {
    parsed: Mutex<BTreeMap<PathBuf, (u64, Option<SystemTime>, u64)>>,
}

impl AuthCache {
    /// The fingerprints for a harness of `family` whose spawn env is
    /// `profile_env` (profile env over the daemon's own): (credentials and
    /// env, account). The account part is None when no login file names one.
    pub fn fingerprint(
        &self,
        family: &str,
        profile_env: &BTreeMap<String, String>,
    ) -> (String, Option<String>) {
        let env = |k: &str| {
            profile_env
                .get(k)
                .cloned()
                .or_else(|| std::env::var(k).ok())
                .or_else(|| crate::login_env::var(k))
        };
        let home = dirs::home_dir().unwrap_or_default();
        self.fingerprint_with(family, &env, &home)
    }

    fn fingerprint_with(
        &self,
        family: &str,
        env: &dyn Fn(&str) -> Option<String>,
        home: &Path,
    ) -> (String, Option<String>) {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        let mut account = std::collections::hash_map::DefaultHasher::new();
        let mut named = false;
        family.hash(&mut h);
        for k in AUTH_ENV {
            (k, env(k)).hash(&mut h);
        }
        for (path, reader) in files(family, env, home) {
            path.hash(&mut h);
            let part = self.file_part(&path, reader);
            part.hash(&mut h);
            if reader != Reader::Stat && part != 0 {
                named = true;
                part.hash(&mut account);
            }
        }
        (format!("{:016x}", h.finish()), named.then(|| format!("{:016x}", account.finish())))
    }

    fn file_part(&self, path: &Path, reader: Reader) -> u64 {
        let Ok(md) = std::fs::metadata(path) else { return 0 };
        let (len, mtime) = (md.len(), md.modified().ok());
        if reader == Reader::Stat {
            let mut h = std::collections::hash_map::DefaultHasher::new();
            (len, mtime).hash(&mut h);
            return h.finish() | 1;
        }
        if let Some((l, m, part)) = self.parsed.lock().unwrap().get(path)
            && *l == len
            && *m == mtime
        {
            return *part;
        }
        let part = std::fs::read(path).map(|bytes| account_part(reader, &bytes)).unwrap_or(0);
        // A file written within the timestamp's resolution of this read may
        // change again with the same size and mtime: never trust such a
        // parse later (git's racy-entry rule).
        let settled = mtime
            .and_then(|m| SystemTime::now().duration_since(m).ok())
            .is_some_and(|age| age >= RACY_WINDOW);
        if settled {
            self.parsed.lock().unwrap().insert(path.to_owned(), (len, mtime, part));
        }
        part
    }
}

fn account_part(reader: Reader, bytes: &[u8]) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(bytes) else {
        // Unreadable JSON: the bytes themselves, so any change counts.
        bytes.hash(&mut h);
        return h.finish() | 1;
    };
    let s = |v: &serde_json::Value, p: &str| v.pointer(p).map(|x| x.to_string());
    match reader {
        Reader::ClaudeAccount => {
            (s(&v, "/oauthAccount/accountUuid"), s(&v, "/oauthAccount/organizationUuid"))
                .hash(&mut h);
        }
        Reader::CodexAuth => {
            (s(&v, "/auth_mode"), s(&v, "/tokens/account_id"), s(&v, "/OPENAI_API_KEY"))
                .hash(&mut h);
        }
        Reader::OpencodeAuth => {
            if let Some(map) = v.as_object() {
                for (provider, entry) in map {
                    (provider, s(entry, "/type"), s(entry, "/accountId"), s(entry, "/key"))
                        .hash(&mut h);
                }
            }
        }
        Reader::Stat => unreachable!(),
    }
    h.finish() | 1
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh private directory under the system temp dir.
    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "acpmux-auth-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn an_account_switch_changes_the_fingerprint_and_a_token_refresh_does_not() {
        let home = scratch("codex");
        let cache = AuthCache::default();
        let no_env = |_: &str| None;
        let auth = home.as_path().join(".codex/auth.json");
        write(
            &auth,
            r#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-1","access_token":"t1"}}"#,
        );
        let first = cache.fingerprint_with("codex", &no_env, home.as_path());
        // A refreshed token for the same account (a longer file, too).
        write(
            &auth,
            r#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-1","access_token":"t2-refreshed"}}"#,
        );
        assert_eq!(cache.fingerprint_with("codex", &no_env, home.as_path()), first);
        write(
            &auth,
            r#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-2","access_token":"t3"}}"#,
        );
        let switched = cache.fingerprint_with("codex", &no_env, home.as_path());
        assert_ne!(switched, first);
        assert!(first.1.is_some(), "the login file names an account");
        assert_ne!(switched.1, first.1, "the account part follows the account");
        std::fs::remove_file(&auth).unwrap();
        let out = cache.fingerprint_with("codex", &no_env, home.as_path());
        assert_ne!(out, switched, "logout counts");
        assert_eq!(out.1, None, "no account after a logout");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn claude_account_and_api_key_env_are_part_of_it() {
        let home = scratch("claude");
        let cache = AuthCache::default();
        let no_env = |_: &str| None;
        let account = home.as_path().join(".claude.json");
        write(
            &account,
            r#"{"numStartups":1,"oauthAccount":{"accountUuid":"a","organizationUuid":"o"}}"#,
        );
        let first = cache.fingerprint_with("claude", &no_env, home.as_path());
        // Claude rewrites its state file on every start; same account.
        write(
            &account,
            r#"{"numStartups":2,"oauthAccount":{"accountUuid":"a","organizationUuid":"o"}}"#,
        );
        assert_eq!(cache.fingerprint_with("claude", &no_env, home.as_path()), first);
        write(
            &account,
            r#"{"numStartups":3,"oauthAccount":{"accountUuid":"b","organizationUuid":"o"}}"#,
        );
        assert_ne!(cache.fingerprint_with("claude", &no_env, home.as_path()), first);
        let key = |k: &str| (k == "ANTHROPIC_API_KEY").then(|| "sk-1".to_owned());
        assert_ne!(
            cache.fingerprint_with("claude", &key, home.as_path()),
            cache.fingerprint_with("claude", &no_env, home.as_path())
        );
    }

    #[test]
    fn opencode_provider_logins_count() {
        let home = scratch("opencode");
        let cache = AuthCache::default();
        let no_env = |_: &str| None;
        let auth = home.as_path().join(".local/share/opencode/auth.json");
        write(&auth, r#"{"openai":{"type":"oauth","accountId":"x","access":"1"}}"#);
        let first = cache.fingerprint_with("opencode", &no_env, home.as_path());
        write(&auth, r#"{"openai":{"type":"oauth","accountId":"x","access":"2"}}"#);
        assert_eq!(cache.fingerprint_with("opencode", &no_env, home.as_path()), first);
        write(
            &auth,
            r#"{"openai":{"type":"oauth","accountId":"x","access":"2"},"zai":{"type":"api","key":"k"}}"#,
        );
        assert_ne!(cache.fingerprint_with("opencode", &no_env, home.as_path()), first);
    }
}
