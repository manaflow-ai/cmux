# Agent pane highlighting bundle boundaries

The page's `index.ts` owns the language registry and loads grammars on demand. Pierre sends
resolved grammars and themes to the standalone highlight worker. The worker needs core and
the JavaScript regex engine, but no registry or bundled grammar data.

Keep engine shims independent of `index.ts`. Reexporting even the throwing Oniguruma stub
from that barrel evaluates its highlighter factories and makes esbuild retain every grammar
in the worker. In November 2026 this shipped a second copy of 27 grammar modules (26 supported
languages and an embedded dependency). Moving the stub to its leaf keeps the same exports
without that registry dependency.

Detector: `bun test test/agent-pane-worker-bundle.test.ts` builds the production worker,
checks its emitted inputs for duplicated grammar data and verifies that it has no imports
(the worker's response CSP permits no fetches). It also sends every supported language to
the built worker and checks that each renders successfully. To inspect future growth, run
`scripts/agent-pane/bundle.mjs` with `--metafile FILE` and examine `outputs[*].inputs`.
