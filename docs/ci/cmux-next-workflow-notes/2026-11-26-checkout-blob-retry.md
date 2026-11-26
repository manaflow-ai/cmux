# Retry a blob-filtered checkout from a fresh repository

Above `path_route` and `generated-files-linux: Discard the workspace repository after a failed checkout` in
`.github/workflows/cmux-next.yml`.

Both check out with `filter: blob:none` on a reused `cmux-linux` workspace. The fetch is already shallow and
blob-less and takes a second; the blobs come later, from the promisor remote during `git checkout`, which
actions/checkout does not retry. On cmux#55016 (runner cmux-runner-pool-s1c-0044) that blob fetch hit
`curl 28 Operation too slow` after 63 s and failed path routing, so every job that needs it skipped and the PR
had no verdict until a re-run. As in swift test (note-184): retry once from a fresh repository.
