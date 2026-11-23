# VM file reads

The VM CLI reads saved files without starting a paused or stopped machine. It uses
the VM API's existing file endpoints, with the same VM ownership and `vm:files`
scope as `file stat`. Saved files reflect the disk at the time the machine paused.

```sh
cmux vm file ls VM_ID /workspace --json
cmux vm file stat VM_ID /workspace/build.log --json
cmux vm file read VM_ID /workspace/build.log
cmux vm file read VM_ID /workspace/build.log --range bytes=4096-
cmux vm file read VM_ID /workspace/artifact.bin > artifact.bin
```

The standalone `cmux-vm file` commands accept the same arguments. `file ls` prints
entry kind and name, with control characters escaped; `--json` retains the API's
complete directory response. `file read` streams raw bytes, including binary data,
to stdout and does not support `--json`. It does not buffer the entire file or add
a newline. Errors go to stderr; an interrupted read can leave partial stdout, and
the exit code signals failure. Use `--range bytes=START-END` (inclusive) or
`--range bytes=START-` to read part of a file. A server that ignores a requested
range is refused before any file bytes are written.

Each command makes one file GET. Missing files or unavailable saved disks return
an error; there is no automatic start, resume, guest command, or retry.
