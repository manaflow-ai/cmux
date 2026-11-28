Above `web-bundles: Read the build tree's Node pin`, `daemon-test: Read the build tree's Node pin` and
`cmux-scheme-compile: Read the build tree's Node pin` in `.github/workflows/cmux-next.yml`.

These jobs build the checked-out tree's web bundles, and that tree is `inputs.same_tree_sha` in a
same-tree run, which can predate `.node-version`; setup-node fails on a missing file before the job
starts (#44131 review). They take the tree's own pin, as web-bundle-key.py keys it, and a tree without
the file builds on its PRE_NODE_VERSION_FILE_NODE, so the Node a bundle builds on is the Node its key
names (nightly.yml's `web-node-pin` does the same for the nightly build commit).
