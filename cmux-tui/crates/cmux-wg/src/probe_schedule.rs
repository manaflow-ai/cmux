//! When each path is probed and when it turns quiet: the shared schedule now
//! lives in `cmux-braid-path` (RFD 0164 slice B4), re-exported here so
//! callers that took it from cmux-wg keep their imports.

pub use cmux_braid_path::probe::{PathWatch, ProbeConfig, WatchStep};
