# path_route: parallel sparse-checkout prefetch

Above `path_route: sparse-checkout` in `.github/workflows/cmux-next.yml`.

The checkout takes two files, scripts/ci/prefetch-sparse-checkout.sh and the pattern list
scripts/ci/path-route-sparse-checkout.txt, and the next step widens it to the router's
paths (note-469). A blob:none checkout of those paths fetched their 33,120 blobs in one request inside
`git checkout`: GitHub spent about 28 s packing them and git 9 s indexing them, 41 s of the job's 58 s
(run 45382362604, 2026-11-24; the job's p50 was 80 s over 14 PR runs). The script fetches the same blobs in 16
parallel requests and then applies the patterns: 7 s for a byte-identical working tree. A blob it missed is
still fetched lazily, so the tree never differs, only the time.
