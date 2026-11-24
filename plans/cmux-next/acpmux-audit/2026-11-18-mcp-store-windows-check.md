# The MCP store's file writes compile for Windows

`write_file` and `write_private` in `src/hub/mcp_connect.rs` used `std::os::unix` (the file mode
on open, the folder mode) with no `cfg`, so `cargo check --target x86_64-pc-windows-gnu -p acpmux`
failed with four errors for every pull request with a Rust change. The Unix parts are now two
small functions with a Windows arm each: `temp_file_options` (Unix: the mode on open; Windows: no
mode) and `private_folder` (Unix: the folder and 0700; Windows: `owner_only::create_dir_all` and
`owner_only::restrict`, the same two calls as `agent_tools::write_private`).

Unix behavior is the same calls in the same order with the same modes; one Unix test guards the
0600 file in the 0700 folder. The write runs once for each approved MCP connection; no request
path, timer or idle work changes.

Limit on Windows: the secrets file has no access list of its own. It is private only through the
owner-only list of its folder, which a file made in that folder takes, and the Windows arm was
compiled, not run.
