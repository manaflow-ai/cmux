# Dynamic inputs in webview test selection

A string naming a package is data unless used by `from`, `import`, or `require`.
The affected-test selector must not classify icon names such as `"vite"` or an
empty `import()` example as an unresolved dependency. Whitespace before a static
import string must not turn it into a computed import through regex backtracking.
The detector is `tests/test_ci_webviews_affected.py`.

The generated frame-site table is a separate dependency from a test module.
`frameOwners.ts` loads `chunks/frame-sites.js` beside a release bundle's page,
emitted from bundle source maps by `webviews/scripts/agent-pane/frameSites.mjs`.
A test that imports the reader has no such file: the import fails and the
reader returns null. The one test that builds the bundle
(`test/agent-pane-frame-sites.test.ts`) spawns a process and runs on its own
anyway. So the reviewed reader is no unresolved input for its importers, at
its exact content digest only; any reader edit restores the fallback. Its real
importers still run when it changes.

A computed require of `require.resolve("<bare npm package>")` (domTeardown.ts's
`scheduler`) loads from node_modules, which bun.lock and package.json pin, so it
is no unresolved input either. Relative, absolute, `cmux:` or computed
specifiers still are, and so is any bare name once webviews/package.json depends
on a repo folder (`file:`, `link:`, `workspace:`, a path).

Filesystem readers, browser helpers and process spawns remain conservative.
This is not a claim that all dynamic dependencies are statically resolved.
Pushes to feat-cmux-next and full-ci retain the complete suite. Regression cases
exercise the reader digest, package and non-package requires, changed tests,
computed imports and static imports with whitespace. Count comparisons must use
one tree; production minute comparisons use the controller timing feed and
separate PRs from pushes, runner type, and completed run attempts.
