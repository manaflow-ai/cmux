import { build } from "esbuild";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SHARED_REACT_SPECIFIERS = new Map([
  ["react", "react.js"],
  ["react-dom", "react-dom.js"],
  ["react-dom/client", "react-dom-client.js"],
  ["react/jsx-runtime", "react-jsx-runtime.js"],
  ["react/compiler-runtime", "react-compiler-runtime.js"],
]);

/** Resolve React imports to one same-origin runtime mounted by every native page host. */
export function sharedReactExternalPlugin() {
  const runtimeOut = process.env.CMUX_SHARED_REACT_RUNTIME_OUT;
  return {
    name: "cmux-shared-react-runtime",
    setup(context) {
      if (!runtimeOut) return;
      context.onResolve({ filter: /^react(?:-dom(?:\/client)?|\/jsx-runtime|\/compiler-runtime)?$/ }, (args) => {
        const file = SHARED_REACT_SPECIFIERS.get(args.path);
        return file ? { path: `/__runtime/${file}`, external: true } : undefined;
      });
    },
  };
}

/** The equivalent resolver for Vite/Rolldown's webviews-app graph. */
export function sharedReactVitePlugin() {
  const runtimeOut = process.env.CMUX_SHARED_REACT_RUNTIME_OUT;
  return {
    name: "cmux-shared-react-runtime",
    apply: "build",
    enforce: "pre",
    resolveId(source) {
      if (!runtimeOut) return null;
      const file = SHARED_REACT_SPECIFIERS.get(source);
      return file ? { id: `/__runtime/${file}`, external: true } : null;
    },
  };
}

const exportsByFacade = {
  "react.js": [
    "Activity",
    "Children",
    "Component",
    "Fragment",
    "Profiler",
    "PureComponent",
    "StrictMode",
    "Suspense",
    "cache",
    "cacheSignal",
    "cloneElement",
    "createContext",
    "createElement",
    "createRef",
    "forwardRef",
    "isValidElement",
    "lazy",
    "memo",
    "startTransition",
    "use",
    "useActionState",
    "useCallback",
    "useContext",
    "useDebugValue",
    "useDeferredValue",
    "useEffect",
    "useEffectEvent",
    "useId",
    "useImperativeHandle",
    "useInsertionEffect",
    "useLayoutEffect",
    "useMemo",
    "useOptimistic",
    "useReducer",
    "useRef",
    "useState",
    "useSyncExternalStore",
    "useTransition",
    "version",
  ],
  "react-dom.js": [
    "createPortal",
    "flushSync",
    "preconnect",
    "prefetchDNS",
    "preinit",
    "preinitModule",
    "preload",
    "preloadModule",
    "requestFormReset",
    "unstable_batchedUpdates",
    "useFormState",
    "useFormStatus",
    "version",
  ],
  "react-dom-client.js": ["createRoot", "hydrateRoot", "version"],
  "react-jsx-runtime.js": ["Fragment", "jsx", "jsxs"],
  "react-compiler-runtime.js": ["c"],
};

/** Build one production React graph and tiny import-compatible facades. */
export async function buildSharedReactRuntime(outdir, metafile) {
  await mkdir(outdir, { recursive: true });
  const webviewsRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const entry = [
    'import * as React from "react";',
    'import * as ReactDOM from "react-dom";',
    'import * as ReactDOMClient from "react-dom/client";',
    'import * as JSXRuntime from "react/jsx-runtime";',
    'import * as CompilerRuntime from "react/compiler-runtime";',
    "export { React, ReactDOM, ReactDOMClient, JSXRuntime, CompilerRuntime };",
    "",
  ].join("\n");
  await build({
    stdin: { contents: entry, resolveDir: webviewsRoot, sourcefile: "shared-react-runtime-entry.mjs", loader: "js" },
    bundle: true,
    format: "esm",
    platform: "browser",
    target: "es2022",
    minify: true,
    legalComments: "none",
    outfile: path.join(outdir, "react-runtime.js"),
    metafile: Boolean(metafile),
    logLevel: "warning",
  });
  if (metafile) await writeFile(metafile, JSON.stringify(result.metafile));
  const namespaces = {
    "react.js": "React",
    "react-dom.js": "ReactDOM",
    "react-dom-client.js": "ReactDOMClient",
    "react-jsx-runtime.js": "JSXRuntime",
    "react-compiler-runtime.js": "CompilerRuntime",
  };
  for (const [file, names] of Object.entries(exportsByFacade)) {
    await writeFile(
      path.join(outdir, file),
      `import { ${namespaces[file]} as runtime } from "./react-runtime.js";\nexport default runtime;\nexport const {${names.join(",")}}=runtime;\n`,
    );
  }
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const outdir = args.find((arg) => !arg.startsWith("--"));
  const metafileIndex = args.indexOf("--metafile");
  const metafile = metafileIndex >= 0 ? args[metafileIndex + 1] : undefined;
  if (!outdir) throw new Error("usage: shared-react-runtime.mjs OUTDIR");
  await buildSharedReactRuntime(path.resolve(outdir), metafile && path.resolve(metafile));
}
