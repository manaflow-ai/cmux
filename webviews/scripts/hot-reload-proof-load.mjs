// The proof's cold load (hot-reload-proof.mjs): Vite's dependency optimizer can bundle again while the
// agent pane first loads, and the entry's import then fails. These tell that failure apart and wait for
// the optimizer, as the gallery's warm-up does (test/support/galleryFrame.ts).

/** Whether a page error is a module import the browser could not fetch (the optimizer replaced it mid-load). */
export function isDynamicImportFailure(message) {
  return /Failed to fetch dynamically imported module|error loading dynamically imported module|Importing a module script failed/i.test(
    message ?? "",
  );
}

/** Until the dev server's requests are idle and its dependency optimizer has bundled all it found, or `left()` ms. */
export async function optimizerSettled(server, left) {
  const client = server.environments?.client;
  if (!client?.waitForRequestsIdle) return;
  const within = async (work) => {
    let timer;
    try {
      await Promise.race([work, new Promise((resolve) => (timer = setTimeout(resolve, left())))]);
    } finally {
      clearTimeout(timer);
    }
  };
  for (let round = 0; round < 20; round += 1) {
    await within(client.waitForRequestsIdle());
    const pending = Object.values(client.depsOptimizer?.metadata?.discovered ?? {})
      .map((dep) => dep.processing)
      .filter(Boolean);
    if (!pending.length) break;
    await within(Promise.all(pending));
  }
  await new Promise((resolve) => setImmediate(resolve));
}
