//! cmux app host: one process per running app, one QuickJS-ng VM inside it.
//!
//! The daemon's app supervisor (`cmux-tui-core::apps`) spawns
//! `cmux-app-host` with one end of a Unix socketpair as fd 3, stdin, stdout
//! and stderr on `/dev/null`. The host applies its OS sandbox
//! ([`sandbox`]) before it reads anything, then speaks JSON lines on fd 3
//! (plans/cmux-next/app-platform.md section 13.1). The VM runs the embedded
//! runtime (`js/dist/cmux-app-runtime.js`) and the app's main script and
//! implements the runtime ABI (`js/ABI.md`) natively ([`vm`]).
//!
//! # Protocol (fd 3, one JSON object per line, tag `t`)
//!
//! Supervisor to host ([`protocol::ToHost`]):
//!
//! | `t` | fields | effect |
//! | --- | --- | --- |
//! | `init` | `app {id, version}`, `settings`, `api_version`, `ops`, `known_ops`, `locale?`, `strings`, `main` | first message; evaluates `main`, calls `__cmuxAppInit`; answers `ready` or `init-failed` |
//! | `mount` | `mount`, `export`, `ctx` | `__cmuxAppMount`; the first `scene` batches, then `mounted {mount, error?}` |
//! | `unmount` | `mount` | `__cmuxAppUnmount` |
//! | `dispatch` | `mount`, `node`, `event`, `payload` | `__cmuxAppDispatch`; the supervisor puts the gesture token in `payload.gesture` |
//! | `resolve` | `cb`, `ok`, `body` | answers a `call` (`__cmuxAppResolve`) |
//! | `event` | `sub`, `body` | delivers to a subscription (`__cmuxAppEvent`) |
//! | `settings` | `values` | `__cmuxAppSetSettings` |
//! | `run` | `cb`, `export`, `args` | `__cmuxAppRunCommand`; answered by `done` |
//! | `shutdown` | | exit 0 |
//!
//! Host to supervisor ([`protocol::FromHost`]):
//!
//! | `t` | fields |
//! | --- | --- |
//! | `ready` | `runtime` (runtime version) |
//! | `init-failed` | `error` (the host exits 70) |
//! | `mounted` | `mount`, `error?` |
//! | `call` | `cb`, `name`, `params`, `options` (the supervisor checks scope and grant, fills selectors and idempotency keys, validates `options.gesture`) |
//! | `subscribe` / `unsubscribe` | `sub`, `stream`, `filter` / `sub` |
//! | `scene` | `mount`, `ops` (ABI scene ops) |
//! | `log` | `level`, `message` |
//! | `done` | `cb`, `ok`, `body` |
//! | `fatal` | `reason` (`memory`, `interrupt`, `engine`), `entry`; the host exits 70 right after |
//!
//! Limits per VM ([`vm::Limits`]): 32 MiB of engine memory, 250 ms per entry
//! point (job-queue drain included), 64 calls pending; a call past the cap
//! is answered locally with `app.limit`. Timers live in the host: the read on
//! fd 3 blocks until the next timer is due, never longer, never shorter.
//! Exit codes: [`host_loop::exit`].

#[cfg(feature = "engine")]
pub mod host_loop;
pub mod protocol;
#[cfg(feature = "engine")]
pub mod sandbox;
#[cfg(feature = "engine")]
pub mod vm;

pub use protocol::{AppInfo, FatalReason, FromHost, ToHost};
#[cfg(feature = "engine")]
pub use vm::{AppVm, InitParams, Limits, VmError};
