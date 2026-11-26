# Retry a blob-filtered checkout from a fresh repository

Above `generated-files-linux: Discard the workspace repository after a failed checkout` in
`.github/workflows/cmux-next.yml`.

It checks out with `filter: blob:none` on a reused `cmux-linux` workspace. The fetch is already shallow and
blob-less and takes a second; the blobs come later, from the promisor remote during `git checkout`, which
actions/checkout does not retry. On cmux#55016 (runner cmux-runner-pool-s1c-0044) that blob fetch hit
`curl 28 Operation too slow` after 63 s in path routing, so every job that needs it skipped and the PR had no
verdict until a re-run. Path routing now tries three times with pauses; generated files, the same checkout
shape, retries once from a fresh repository as swift test does (note-184). The retry reuses the first
checkout's `with:` through a YAML anchor, so the two never drift and the workflow stays under GitHub's size limit.
