# Terminal backend acceptance evidence

`spec.json` defines the P0 runtime contract. `manifest.schema.json` defines the evidence record. `scripts/verify-terminal-backend-acceptance.py` creates and validates commit-bound evidence outside the source worktree.

Capture starts only from a clean final commit and a tagged app built from that same clean commit. The tagged app embeds `CMUXSourceCommit` and `CMUXSourceDirty`; the manifest hashes its Info.plist, Swift host, terminal backend, and renderer worker. Any source, submodule, app metadata, executable, or artifact mutation invalidates verification.

Use four named roles. The acceptance author, implementer, interaction profiler, and final artifact verifier must all differ.

```bash
./scripts/verify-terminal-backend-acceptance.py capture \
  --tag ctuibk \
  --artifact-root /tmp/cmux-terminal-backend-evidence \
  --acceptance-author acceptance-author \
  --implementer implementer \
  --interaction-profiler interaction-profiler \
  --artifact-verifier artifact-verifier
```

The command prints the manifest path. Launch the tagged app, identify the exact Swift, backend, and renderer PIDs, then bind each live identity. `--build-role` verifies the process executable against the corresponding packaged binary hash.

```bash
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role swift-host --build-role swift-host --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role terminal-backend --build-role terminal-backend --pid <pid>
./scripts/verify-terminal-backend-acceptance.py bind-process \
  --manifest <manifest> --role renderer-worker --build-role renderer-worker --pid <pid>
```

Place every artifact under the manifest directory. Record commands as JSON string arrays, assertions as observed facts, and artifact paths relative to that directory. Artifact PIDs must reference bound process identities.

```bash
./scripts/verify-terminal-backend-acceptance.py record \
  --manifest <manifest> \
  --id PROC-2 \
  --status pass \
  --command-json '["xcrun","xctrace","record","--template","Metal System Trace"]' \
  --assertion 'The Swift PID submitted only the labeled IOSurface blit.' \
  --artifact-json '{"kind":"metal-system-trace","path":"proc-2/metal.trace","pids":[101,202]}'
```

Final verification rejects missing required artifact kinds, failed P0 checks, reused role identities, unbound PIDs, changed hashes, a dirty worktree, or a manifest from a different commit.

```bash
./scripts/verify-terminal-backend-acceptance.py verify \
  --manifest <manifest> \
  --require-final-head \
  --require-all-p0
```
