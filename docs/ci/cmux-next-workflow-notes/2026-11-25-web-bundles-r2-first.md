# cmux-next.yml: web bundles, R2 first

Above `web-bundles: Look up the web bundles in R2` and `web-bundles: Setup Bun` in `.github/workflows/cmux-next.yml`.

The web bundles job looks in R2 before the GitHub cache, and an R2 hit ends it. Every feat-cmux-next push
publishes the bundles to R2 under their source key, but the job only looked in the GitHub cache, which missed on
every push run sampled 2026-11-24 09:18-09:38Z: key 727d5510 was rebuilt by four push runs in a row (about 4 min
of `Build the web bundles` each) while the R2 publish answered "already exists". Only 37 of the 118 tip commits in
06:00-09:30Z changed a web input, so most push runs, and every PR head whose web inputs match a published tip's,
find their key in R2. On a hit nothing else in the job runs: the Mac jobs that use the bundles restore from R2
first themselves (`Restore the web bundles from R2`), and R2 already holds the key, so neither the artifact nor
the publish is needed. A miss builds, caches and publishes as before; the lookup is continue-on-error, so a failed
R2 read is a miss.

Setup Bun, the private bun and Setup Node run only on a miss, after both lookups: the source key is python3
alone (the bun pin is read from webviews/package.json, node's from its default), and only the build uses them.
In the 24 h to 2026-11-24T10Z the 1,698 web bundles jobs that built nothing still spent about 55 s each in
those three steps (timing feed, cmux-next.yml, Setup Node 28-32 s and Setup Bun 23-26 s on average).
