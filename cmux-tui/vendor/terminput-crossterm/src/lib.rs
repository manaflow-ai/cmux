#![deny(missing_docs, clippy::unwrap_used)]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc = include_str!("../README.md")]

#[cfg(any(feature = "crossterm_0_28", feature = "crossterm_0_29"))]
mod mapping;
#[cfg(any(feature = "crossterm_0_28", feature = "crossterm_0_29"))]
pub use mapping::*;
