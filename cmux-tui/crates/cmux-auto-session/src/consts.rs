//! The numbers of `plans/cmux-next/auto-mode/DESIGN.md`. The Cloud store holds the same values;
//! change one here only with the store.

/// The holder renews its lease this often.
pub const RENEW_MS: u64 = 10_000;

/// A lease lasts this long from its last renewal. A laptop back within it lost nothing.
pub const LEASE_MS: u64 = 45_000;

/// A laptop that has had no renewal answered for this long stops its Auto chats by itself. It is
/// under [`LEASE_MS`], so the laptop always stops before the Cloud takes the chat over.
pub const SELF_STOP_MS: u64 = 35_000;

/// While a turn streams, a copy goes to the Cloud at most this often.
pub const STREAM_COPY_MS: u64 = 5_000;

/// The largest snapshot chunk, in bytes (1 MiB).
pub const CHUNK_MAX_BYTES: usize = 1 << 20;

/// The most snapshot bytes one chat keeps in the Cloud (512 MiB). Past it the chat stays local.
pub const SNAPSHOT_MAX_BYTES: u64 = 512 << 20;

/// The most events one append carries.
pub const EVENTS_MAX_PER_APPEND: usize = 256;

/// The most bytes one append's body carries (1 MiB).
pub const EVENTS_MAX_BYTES: usize = 1 << 20;

/// The longest the store holds a `wait` or an `assignments` request open.
pub const WAIT_MAX_MS: u64 = 25_000;

/// The snapshot manifest version this build writes and reads.
pub const MANIFEST_VERSION: u32 = 1;

/// The header that names the writer's holder on a chunk upload.
pub const HOLDER_HEADER: &str = "x-cmux-auto-holder";

/// The header that names the writer's epoch on a chunk upload.
pub const EPOCH_HEADER: &str = "x-cmux-auto-epoch";
