//! A per-machine git smart-HTTP cache.
//!
//! Nothing intercepted an agent's `git clone https://github.com/...`, so every one went to
//! GitHub. With this crate's include in the machine's git config (`gitconfig`), git's
//! `url.<proxy>.insteadOf` sends `https://github.com/`, `git@github.com:` and
//! `ssh://git@github.com/` fetches to `http://127.0.0.1:PORT/github.com/OWNER/REPO`, and the
//! proxy answers them in this order:
//!
//! 1. this machine's mirror (`<cache>/<tenant>/github.com/<owner>/<repo>.git`, a full,
//!    non-partial bare clone, so a present commit has its whole closure);
//! 2. a fleet peer's proxy (`--peer URL`, the same protocol, which checks the caller itself);
//! 3. GitHub (or the platform edge), only for what nobody has.
//!
//! Tenant safety: the ref advertisement (`GET info/refs`) and `ls-refs` always go upstream
//! under the caller's credentials. A cached object is served only after the upstream answered
//! 200 to that caller for that repository (`auth::AuthCache`, keyed by the hash of the
//! caller's `Authorization` value, the tenant and the repository, for a short TTL); a caller
//! upstream refuses gets upstream's refusal and nothing from the cache. Tokens are never
//! logged or written: only a short hash prefix appears in logs.
//!
//! Visible and switchable: a pack served from the mirror ends with a sideband line, so the
//! clone itself prints `remote: cmux git cache: served by cache, N s`. Any error of the
//! cache's (upstream unreachable for the ref advertisement, a mirror short of objects, a
//! local upload-pack failure) falls back to github.com and counts in `fallbacks`, which goes
//! with the other counters to `stats.json` beside the include (and `/_cmux/git-cache/health`)
//! for NOW. `CMUX_GIT_CACHE=0` in one chat's environment sends that chat's git to github.com
//! (`switch`: the proxy's credential helper, which git runs in the chat's environment, says
//! so); `/etc/cmux/git-cache.disabled` turns the whole machine's proxy off.
//!
//! Pushes never come here (`pushInsteadOf` keeps them on their own URL), and a proxy that is
//! not listening has no include file, so git goes straight to GitHub as before.

pub mod auth;
pub mod cli;
pub mod credential;
pub mod gitconfig;
pub mod mirror;
pub mod pkt;
pub mod route;
pub mod server;
pub mod switch;

pub use server::{Config, State, app, router};
