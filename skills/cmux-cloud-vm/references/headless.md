# Cloud machines without the app

Use this when an agent has no cmux app to talk to: CI, a headless agent, a Linux
host. `cmux vm` calls the cmux VM API (https://vm.cmux.dev) directly, so it needs
an API key instead of the app's sign-in. With the app running and signed in, use
`cmux cloud` instead (`cmux cloud --help`); it shares the sidebar's machine list.

`cmux vm` runs the `cmux-vm` program bundled next to `cmux` (`CMUX_VM_BIN`
overrides it). Where only `cmux-vm` is installed, the same commands work with
`cmux-vm` and its own verb names: `create`, `list` and `delete` for `new`, `ls`
and `rm`.

## Give it a key

`cmux vm` reads the key from `CMUX_VM_API_KEY`, else `"apiKey"` in
`~/.config/cmux/vm.json`. Get the key from the person who owns the team. Keep it
in the environment or that file, never in a command argument, a log or a
machine's files. Without a key every command exits 11 ("no API key").

## Provision, run, pause, delete

```sh
cmux vm ls --json
cmux vm new --name scratch --idempotency-key scratch-1 --json
```

`new` answers the VM as JSON. Its `id` (`vm_…`) is what every other verb takes;
`jq -r .id` reads it. If `new` times out or the connection drops, run the same
command with the same `--idempotency-key`: the server returns the VM it already
made instead of making a second one.

```sh
cmux vm exec VM_ID -- uname -a
cmux vm exec VM_ID --timeout-ms 600000 -- 'cd /root && ls -la'
```

`exec` prints the command's stdout, sends its stderr to stderr, and exits 0 only
when the command exited 0 (1 otherwise, naming the status). With `--json` it
prints `exitCode`, `stdout` and `stderr`, and the exit code still says whether
the command succeeded.

```sh
cmux vm pause VM_ID
cmux vm resume VM_ID
cmux vm rm VM_ID --yes
```

`pause` keeps the VM's memory and stops it running; `resume` brings it back.
`rm` deletes the VM and its disk for good. It asks you to type the id at a
terminal, and needs `--yes` everywhere else.

## When something fails

The exit code says what happened, and `--json` puts the error on stderr as JSON:

| Exit | Meaning | Next step |
| --- | --- | --- |
| 2 | usage error | `cmux vm <verb> --help` |
| 3 | the API could not be reached | check the network, then retry |
| 11 | no key, or the key was refused | set `CMUX_VM_API_KEY` |
| 12 | the team's plan does not cover it | tell the person |
| 13 | the key lacks a scope | ask for a key with that scope |
| 14 | not found | `cmux vm ls` |
| 16 | a quota or rate limit (`--json` names it) | wait, or remove VMs you no longer need |

`cmux vm --help` lists every verb, and `cmux vm <verb> --help` its options.
