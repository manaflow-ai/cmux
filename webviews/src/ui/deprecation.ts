// The development warning a deprecated export gives when it is used (ui/STATUS.md). In a dev build
// (`import.meta.env.DEV`: the dev server, the gallery's dev host) the first use of each name logs one
// `console.warn` naming its replacement; later uses of that name stay quiet. A production build
// reads `import.meta.env.DEV` as false, so the call does nothing there and the bundler drops the body.

const warned = new Set<string>();

/** Warns once per `name` in a dev build that `name` is deprecated and `replacement` is its successor. */
export function warnDeprecated(name: string, replacement: string): void {
  if (!import.meta.env?.DEV) return;
  noteDeprecated(name, replacement, console.warn);
}

/** The once-per-name warning itself, with its sink passed in so a test can read it in any build. */
export function noteDeprecated(name: string, replacement: string, warn: (message: string) => void): void {
  if (warned.has(name)) return;
  warned.add(name);
  warn(`cmux ui: ${name} is deprecated. Use ${replacement} instead (webviews/src/ui/STATUS.md).`);
}

/** Forgets which names have warned (tests). */
export function resetDeprecationWarningsForTests(): void {
  warned.clear();
}
