# The MCP store's file writes go through `home_fs`

The writers of the MCP store in `src/hub/mcp_connect.rs` (the record of an approved MCP
connection and its secret) wrote by path with `std::fs`. The store's folder comes from the
daemon's home, so `home_writers_by_path_tests::no_writer_under_the_home_goes_by_path` listed
four writes in that file and was red. Now:

- The record: `write_file` keeps its name, its arguments and its temporary file's name, and makes
  each step through `home_fs` (`create_dirs`, `OpenOptions` with the mode, `rename`).
- The secret: the store calls `agent_tools::write_private`, the crate's writer for a 0600 file in
  a 0700 folder. The store's own `write_private` is gone, and so are the two helper functions
  with a Windows arm each (`temp_file_options`, `private_folder`) that the notice
  `2026-11-18-mcp-store-windows-check.md` names. The file has no `cfg` arm outside its test.

What changes for a secret on Unix: the home is checked before the write (a lost home gets no
file), a missing parent folder is made 0700 too, the temporary file is `<stem>.tmp-<pid>` and
opens with `O_NOFOLLOW`, the folder is synced after the rename, and a temporary file that a
stopped writer left is removed. The result is the same: a 0600 file in a 0700 folder.

What changes on Windows: the secrets file is now made with an owner-only access list of its own
(`owner_only::create_new`), not only under its folder's list. That limit of the earlier notice
no longer holds. The Windows code was compiled, not run.

The write runs once for each approved MCP connection; no request path, timer or idle work
changes.
