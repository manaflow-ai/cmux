# Windows machine join

`acpmux host join` and `acpmux daemon service` now run on Windows. The join and consent locks
take the file's own lock (`File::try_lock`: flock on Unix, LockFileEx on Windows) in place of
Unix-only `flock`; `recovery::write_durable` writes owner-only and renames or hard-links into
place on Windows, with no folder flush; the consent root on Windows is the profile known folder;
the proposal names `platform: "windows"`. `daemon service` on Windows registers the per-user
logon task `\acpmux` (`schtasks /Create /XML`, falling back to the HKCU Run key) that runs
`acpmux daemon start` at logon.

All of it runs in the join CLI and the service command only, once per join or install. No daemon
request path, timer or idle work changes; Unix behavior is the same calls through `try_lock`.
