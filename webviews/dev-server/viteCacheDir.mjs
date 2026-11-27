// Where Vite keeps its optimized dependencies. scripts/ci/run-webviews-tests.sh gives each test
// file that starts a dev server its own directory, so files that run at once never optimize into
// one node_modules/.vite and lose each other's files. Unset, Vite's default.
export const viteCacheDir = process.env.CMUX_VITE_CACHE_DIR || undefined;
