//! Untracked files the seed leaves out because they likely hold secrets.
//! The rule lives beside the machine's export, which leaves out the same
//! files on the way back (`cmux_tui_core::git_seed::secrets`).

pub(super) use cmux_tui_core::git_seed::secrets::reason;
