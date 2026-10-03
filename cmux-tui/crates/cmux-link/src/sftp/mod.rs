//! A small SFTP v3 client (transport.md 12c item 1): the link speaks it over
//! the stdio of `ssh -s sftp`, so the target needs no cmux install.

pub mod client;
pub mod proto;

pub use client::{Handle, SftpClient, SftpError};
pub use proto::{Attrs, FileType, NameEntry, StatusCode};
