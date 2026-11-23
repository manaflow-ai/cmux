# Dynamic inputs in webview test selection

A string naming a package is data unless used by `from`, `import`, or `require`.
The affected-test selector must not classify icon names such as `"vite"` or an
empty `import()` example as an unresolved dependency. Whitespace before a static
import string must not turn it into a computed import through regex backtracking.
The detector is `tests/test_ci_webviews_affected.py`.

The generated frame-site table is a separate dependency from a test module.
`frameOwners.ts` loads `chunks/frame-sites.js` beside the page's own document, and
only `bundle.mjs --frame-sites` writes one. A test with no such bundle gets null;
the one test that writes a table reads files and a browser test uses Playwright,
so both stay always-run on their own. `test/support/domTeardown.ts` requires the
npm package `scheduler`, which `bun.lock` decides. Both are listed in
`RUNTIME_LOADS` at their reviewed content digest: they leave the always-run set,
and any edit to either restores the unresolved fallback. On 2026-11-22's tree
they made 835 of the 2,101 always-run tests.

A deleted source no longer runs every file. A module that imported it and still
does is broken (the type check fails), and one whose import was edited is in the
diff, so the files that still name it in an import specifier stand for it. A
non-code file naming it, or a name under 4 characters, still runs every file. In
the pull request shard pick, a webviews script or baseline that a test reaches by
reading it as data picks the shards of the readers' tests, not every shard; one a
vite or compiler config loads still picks every shard.

`CI_WEBVIEWS_NARROW_SELECTION=0` (a repository variable) turns all three off.

Filesystem readers, browser helpers and process spawns remain conservative.
This is not a claim that all dynamic dependencies are statically resolved.
Pushes to feat-cmux-next and full-ci retain the complete suite. Regression cases
exercise the reader digest, production inputs, reverse imports, changed tests,
computed imports and static imports with whitespace. Count comparisons must use
one tree; production minute comparisons use the controller timing feed and
separate PRs from pushes, runner type, and completed run attempts.
