//! The owner's Claude credential a Cloud Chief answers its turns with: what `machine.chief_start`
//! takes from the app and leaves on the Chief's machine.
//!
//! The Mac app reads the person's Claude connection (`_acpmux/connections/credential`, only on its
//! person-proven line) and sends it after the request's first newline, the `cmux cloud api` tail
//! that never sits in argv or in the request JSON (`{"env": {NAME: value}}`, the shape acpmux's
//! `AgentCredential::parse` takes). The start writes it to the machine as [`TURN_ENV_FILE`], a
//! root-owned 0600 file on tmpfs that `cmux-chief.service` reads with its second
//! `EnvironmentFile=-` line, together with `OPTCHAT_CHIEF_TURN_CREDENTIALS=1` (optchat-chief
//! `turn_credential.rs`: the host then hands the credential to its own Claude sessions).
//!
//! The value never goes into a command's text: the bytes travel in `machine.io`'s write body
//! (`data_base64`, Freestyle exec's `stdin` on the direct route, `/fs/write`'s `dataBase64` on the
//! proxy), the same route the app's agent-login transfer writes files with, to [`TURN_ENV_STAGE`];
//! a root command with no secret in it then moves it into place ([`install_script`]). No error,
//! `Debug` or answer here carries the value.

use serde_json::Value;
use zeroize::Zeroizing;

use super::Failure;

/// The file the Chief unit reads its turn credential from (tmpfs: gone on reboot, never on disk).
pub const TURN_ENV_FILE: &str = "/run/cmux-chief/turn.env";
/// Its folder, made by the install itself: root's, 0700. Its own, not `/run/cmux`, which acpmux reads as
/// the `cmux` user (`machine-health.json`).
pub const TURN_ENV_DIR: &str = "/run/cmux-chief";
/// Where the write puts the bytes first, as whichever user the write route runs as (tmpfs too).
pub const TURN_ENV_STAGE: &str = "/dev/shm/cmux-chief-turn.env.stage";
/// The opt-in the host reads (optchat-chief `turn_credential::OPT_IN_ENV`).
pub const OPT_IN_ENV: &str = "OPTCHAT_CHIEF_TURN_CREDENTIALS";
/// The variables taken (optchat-chief `turn_credential::NAMES`, both in acpmux's `NAMES`).
pub const NAMES: [&str; 2] = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"];
/// The longest value taken.
const MAX_VALUE_BYTES: usize = 16 * 1024;

/// One Claude credential variable. Its `Debug` names the variable, never the value; the value is
/// wiped when dropped.
#[derive(Clone, PartialEq, Eq)]
pub struct TurnCredential {
    name: &'static str,
    value: Zeroizing<String>,
}

impl std::fmt::Debug for TurnCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TurnCredential({} = <redacted>)", self.name)
    }
}

fn refused(why: &str) -> Failure {
    // A fixed text: never the tail, never a parser's message (which can quote a value).
    Failure::Transport(format!("turn credential: {why}"))
}

impl TurnCredential {
    /// The variable's name (never its value).
    pub fn name(&self) -> &'static str {
        self.name
    }

    /// The credential a `machine.chief_start` tail carries: none for an empty tail (an app that
    /// sends none, or a person with no Claude connection) or an `env` with none of [`NAMES`] (a
    /// connection for another harness), else the first of [`NAMES`] in `{"env": {NAME: value, ...}}`
    /// (the connection's whole env, as acpmux's credential read gives it), its value token
    /// characters only. A malformed tail or a bad value is refused, never trimmed, and the refusal
    /// names no byte of it.
    pub fn from_tail(tail: &[u8]) -> Result<Option<Self>, Failure> {
        if tail.iter().all(u8::is_ascii_whitespace) {
            return Ok(None);
        }
        let mut value: Value =
            serde_json::from_slice(tail).map_err(|_| refused("not a JSON object"))?;
        let object = value.as_object_mut().ok_or_else(|| refused("not a JSON object"))?;
        if object.keys().any(|k| k != "env") {
            return Err(refused("only `env` is taken"));
        }
        let env = object
            .get_mut("env")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| refused("`env` must be an object"))?;
        let Some(name) = NAMES.iter().copied().find(|n| env.contains_key(*n)) else {
            return Ok(None);
        };
        let slot = env.get_mut(name).ok_or_else(|| refused("`env` changed"))?;
        // Moved out, so the parsed document drops without it.
        let Value::String(text) = slot else { return Err(refused("the value must be a string")) };
        let value = Zeroizing::new(std::mem::take(text));
        if !token_shaped(&value) {
            return Err(refused("the value is not a token"));
        }
        Ok(Some(Self { name, value }))
    }

    /// The env file's bytes: the opt-in, then the variable.
    pub fn env_file(&self) -> Zeroizing<String> {
        Zeroizing::new(format!("{OPT_IN_ENV}=1\n{}={}\n", self.name, self.value.as_str()))
    }
}

/// Printable ASCII token characters, non-empty and bounded (acpmux `agent_credentials`
/// `token_shaped`): no whitespace, quote, `$`, `#` or newline, so systemd's env file parser reads
/// it back as written.
fn token_shaped(value: &str) -> bool {
    (1..=MAX_VALUE_BYTES).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~+/=:".contains(&b))
}

/// The root script that puts the staged file in place: [`TURN_ENV_DIR`] made root's and 0700,
/// the file root's and 0600, the stage removed whatever happens. It prints `changed` when the
/// file is new or differs, `same` when it was already there as is (then nothing is replaced). No
/// secret is in it, and `cmp -s` prints nothing, so its output and errors carry none either.
pub fn install_script() -> String {
    let next = format!("{TURN_ENV_FILE}.next");
    format!(
        "trap 'rm -f {TURN_ENV_STAGE} {next}' EXIT; set -e; umask 077; \
         mkdir -p {TURN_ENV_DIR}; chown root:root {TURN_ENV_DIR}; chmod 0700 {TURN_ENV_DIR}; \
         install -m 0600 -o root -g root {TURN_ENV_STAGE} {next}; \
         if cmp -s {next} {TURN_ENV_FILE}; then echo same; \
         else mv -f {next} {TURN_ENV_FILE}; echo changed; fi"
    )
}
