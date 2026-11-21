# cmux-pty-keeper protocol v1 (frozen)

A keeper is one small process per terminal. It owns the PTY (Unix) or pseudoconsole (Windows) and is the parent of the terminal's child process. It never reads or writes terminal bytes. Every other part of cmux restarts and upgrades freely. A running keeper never changes, so a shell survives as long as its keeper.

Everything below is a permanent contract. Clients built at any later time must work with a v1 keeper. Additions are allowed only as new frame kinds that old keepers ignore. Never change the meaning of an existing field.

## Launch

```
cmux-pty-keeper <endpoint> <cols> <rows> -- <program> [args...]
```

The keeper inherits its environment and working directory from the spawner and passes both to the child unchanged. All terminal policy (termios, env, rlimits, login shell, shell integration) belongs in `<program>`, which is normally an updatable launcher that `exec`s the real shell.

- Unix `<endpoint>` is a filesystem path for a Unix stream socket. The keeper refuses to start if the path exists. The spawner owns the directory and its permissions.
- Windows `<endpoint>` is a named pipe path starting with `\\.\pipe\`. The keeper creates it as the first instance, rejects remote clients, and grants access only to its own user SID.

The keeper writes exactly one line to stdout and then closes stdout:

- `ready <keeper-pid>\n` when the endpoint is listening and the child has been created.
- `error <message>\n` when it cannot start. It then exits with a non-zero status.

On Unix the process the spawner started forks the long-lived keeper and exits at once, so the spawner reaps it and never owns the keeper. `<keeper-pid>` is the long-lived process. On Windows the started process is the keeper; spawn it detached and outside the spawner's job.

## Frames

Every message in both directions is one 32-byte frame. Integers are little-endian.

| bytes | field | meaning |
| --- | --- | --- |
| 0..8 | magic | ASCII `CMUXKEEP` |
| 8..10 | version | sender's protocol version, `1` |
| 10..12 | kind | frame kind |
| 12..16 | a | u32 argument |
| 16..24 | b | u64 argument |
| 24..32 | c | u64 argument |

A frame with a bad magic closes the connection. A frame with an unknown kind is ignored. Receivers accept any version of 1 or higher.

Keeper to client:

- `1 HELLO`, sent once on connect. `a` = child pid. Unix: the PTY master is attached with `SCM_RIGHTS` while the child runs; no descriptor is attached after it exited. Windows: `b` = pseudoconsole input write handle, `c` = output read handle, both duplicated into the client process, or `0` after the child exited. `b` and `c` are `0` on Unix.
- `3 SIZE`, sent right after `HELLO` and to every client after each applied resize. `a` = `cols | rows << 16`, `b` = `width_px | height_px << 16`, `c` = generation, the number of resizes applied so far. On Unix the keeper reads the size back from the PTY, so it also reflects a client that set it directly.
- `2 EXIT`, sent to every connected client when the child exits, and right after `HELLO` and `SIZE` to clients that connect later. `a` = raw platform status: the Unix `waitpid` status word or the Windows process exit code.

Client to keeper:

- `16 RESIZE`, `a` = `cols | rows << 16`, `b` = `width_px | height_px << 16` (0 when unknown). Sets the terminal size; a zero column or row count is ignored. Every client, including the sender, gets a `SIZE` once the size is applied, so clients that race converge on the last applied size. `SIZE` does not mark a point in the output stream: output produced before the child handled the change can still arrive after it.
- `17 TERMINATE`. Ends the child. Unix: the keeper closes its master and sends `SIGHUP` to the child. Windows: the keeper closes the pseudoconsole, which ends attached processes. `EXIT` follows when the child is gone. On Unix, `SIGTERM` to the keeper does the same.

## Lifetime

The keeper exits once the child exited, at least one client received `EXIT`, and no client is connected. On Unix it removes its socket path when it exits. Until then it waits indefinitely, so a client that returns after any delay still gets the exit status. While no client reads, the kernel blocks the child's writes; no output is lost or buffered by the keeper.

Only clients running as the keeper's user are accepted (Unix peer credentials, Windows pipe DACL). There is no client limit: any process of that user can already end the keeper, so a limit protects nothing. When descriptors run out, the Unix keeper refuses the pending connection with a reserved descriptor instead of spinning.

After the child starts, the keeper changes its own working directory to `/` (Unix) or `%SystemRoot%` (Windows), so it never keeps a user directory or mount busy.

Windows requires Windows 10 1809 or later (ConPTY). The keeper resolves the ConPTY functions at runtime and reports `error` on older systems.
