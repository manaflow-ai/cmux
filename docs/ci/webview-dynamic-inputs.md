# Dynamic inputs in webview test selection

A string naming a package is data unless used by `from`, `import`, or `require`.
The affected-test selector must not classify icon names such as `"vite"` or an
empty `import()` example as an unresolved dependency. Whitespace before a static
import string must not turn it into a computed import through regex backtracking.
The detector is `tests/test_ci_webviews_affected.py`.

The generated frame-site table is a separate dependency from a test module.
`frameOwners.ts` loads `chunks/frame-sites.js`, emitted from bundle source maps by
`webviews/scripts/agent-pane/frameSites.mjs`. Importing the reader does not mean
that changing an isolated test changes the table. The selector exempts this
reviewed reader from the unconditional set only at its exact content digest.
Any reader edit restores the unresolved fallback. Any changed input other than
an isolated test retains all reader consumers; a test with any reverse import
through a non-test module also retains them. This deliberately keeps production
changes conservative while avoiding thousands of unrelated tests on test-only
pull requests. Changed tests and their importers still run.

Filesystem readers, browser helpers and process spawns remain conservative.
This is not a claim that all dynamic dependencies are statically resolved.
Pushes to feat-cmux-next and full-ci retain the complete suite. Regression cases
exercise the reader digest, production inputs, reverse imports, changed tests,
computed imports and static imports with whitespace. Count comparisons must use
one tree; production minute comparisons use the controller timing feed and
separate PRs from pushes, runner type, and completed run attempts.
