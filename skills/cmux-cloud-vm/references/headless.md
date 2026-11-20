# Cloud machines without the app

Use this when an agent has no cmux app to talk to: CI, a headless agent, a Linux
host. `cmux machine` calls the cmux VM API (https://vm.cmux.dev) directly, so it
needs an API key instead of the app's sign-in. (`cmux vm`, its old name, still
works for every verb.) With the app running and signed in, use
`cmux cloud` instead (`cmux cloud --help`); it shares the sidebar's machine list.

`cmux machine` runs the `cmux-vm` program's code in process. Where only `cmux-vm`
is installed, the same commands work with `cmux-vm` and its own verb names:
`create`, `get`, `list` and `delete` for `new`, `show`, `ls` and `rm`.

## Give it a key

`cmux machine` reads the key from `CMUX_VM_API_KEY`, else from `"apiKey"` in its
config file: `--config PATH`, else `CMUX_VM_CONFIG`, else
`$XDG_CONFIG_HOME/cmux/vm.json` (default `~/.config/cmux/vm.json`). Get the key
from the person who owns the team. Keep it in the environment or that file,
never in a command argument, a log or a machine's files. Without a key, a
command that calls the API exits 11 ("no API key").

## Provision, run, pause, delete

```sh
cmux vm ls --json
cmux machine new --name scratch --idempotency-key scratch-1 --json
```

`cmux vm ls` lists the VM API's machines (`cmux machine ls` lists the machines
this cmux knows; the two lists merge in #29940). `new` answers the VM as JSON. Its `id` (`vm_…`) is what every other verb takes;
`jq -r .id` reads it. If `new` times out or the connection drops, run the same
command with the same `--idempotency-key`: the server returns the VM it already
made instead of making a second one.

```sh
cmux machine exec VM_ID -- uname -a
cmux machine exec VM_ID --timeout-ms 600000 -- 'cd /root && ls -la'
```

`exec` prints the command's stdout and exits 0 when the command exited 0. When
it did not, `exec` exits 1 and its error names the status and carries the
command's stderr; a command that succeeds has its stderr dropped. With `--json`
it prints `exitCode`, `stdout` and `stderr` either way, and the exit code still
says whether the command succeeded.

```sh
cmux machine pause VM_ID
cmux machine resume VM_ID
cmux machine rm VM_ID --yes
```

`pause` keeps the VM's memory and stops it running; `resume` brings it back.
`rm` deletes the VM and its disk for good. It asks you to type the id at a
terminal, and needs `--yes` everywhere else.

## When something fails

The exit code says what happened, and `--json` puts the error on stderr as JSON:

| Exit | Meaning | Next step |
| --- | --- | --- |
| 2 | usage error | `cmux machine <verb> --help` |
| 3 | the API could not be reached | check the network, then retry |
| 11 | no key, or the key was refused | set `CMUX_VM_API_KEY` |
| 12 | the team's plan does not cover it | tell the person |
| 13 | the key lacks a scope | ask for a key with that scope |
| 14 | not found | `cmux vm ls` |
| 16 | a quota or rate limit (`--json` names it) | wait, or remove VMs you no longer need |

`cmux machine --help` lists every verb, and `cmux machine <verb> --help` its options.
