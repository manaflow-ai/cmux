//! Untracked files a seed leaves out because they likely hold secrets. The rule is
//! `cmux_git::secrets`, shared with `acpmux session move --carry-changes`, so a Cloud seed and a
//! move to another machine leave out the same files.

pub use cmux_git::secrets::reason;
