# The MCP store's file writes go through `home_fs`

The writers of the MCP store in `src/hub/mcp_connect.rs` (the record of an approved MCP
connection and its secret) wrote by path with `std::fs`. The store's folder comes from the
daemon's home, so `home_writers_by_path_tests::no_writer_under_the_home_goes_by_path` was red.
It listed four writes in that file: `write_file: fs::create_dir_all`, `write_file: fs::rename`,
`private_folder: fs::create_dir_all` and `private_folder: fs::set_permissions`. Now:

- The record: `write_file` keeps its name, its arguments and its temporary file's name, and makes
  each step through `home_fs` (`create_dirs`, `OpenOptions` with the mode, `rename`). It checks
  the home first (`config::refuse_lost_home`), as the secret's writer does: a home that is gone
  gets no record.
- The secret: the store calls `agent_tools::write_private`, the crate's writer for a 0600 file in
  a 0700 folder. The store's own `write_private` is gone, and so are the two helper functions
  with a Windows arm each (`temp_file_options`, `private_folder`) that the notice
  `2026-11-18-mcp-store-windows-check.md` names. The file has no `cfg` arm outside its test.

What changes for a secret on Unix: the home is checked before the write (a lost home gets no
file), a missing parent folder is made 0700 too, the temporary file is `<stem>.tmp-<pid>` and
opens with `O_NOFOLLOW`, and the folder is synced after the rename. After a write, the writer
also removes a temporary file `<stem>.tmp-<pid>` beside the secret when no process runs with
that pid and the file was last changed a minute or more before. It looks at most once a minute,
at 1,024 names at most. A temporary file that an older build left under its old name
(`.<name>.acpmux.<pid>.tmp`) is not removed. The result is the same: a 0600 file in a 0700
folder.

What changes on Windows: the secrets file is now made with an owner-only access list of its own
(`owner_only::create_new`), not only under its folder's list. That limit of the earlier notice
no longer holds. The Windows code is compiled by the pull request's Windows check, not run.

The write runs once for each approved MCP connection, before the reply to the card's answer.
There, a secret's write now adds the folder sync and the look named above. No other request
path, no timer and no idle work changes.

Known limits that this change does not mend:

- The record's writer takes no turn among writers of one process and can leave its temporary
  file after a failed write, as before.
- A failed write is dropped with no log line (`.ok()?`), as before. With the home check, a
  connection approved while the home is gone connects and is not kept.
- The read of an old record in the same function still goes by path.
