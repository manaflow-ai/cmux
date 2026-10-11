// Loads a gallery frame in a browser lane test. A cold vite dev server re-optimizes its deps on
// the first page it serves and can delete chunks that page is still loading, so the page reports
// "error" or never reports ready; it loads again once the optimizer has settled. Which test file
// meets the cold server depends on the order files run in, so every gallery test loads this way.
import type { Page } from "playwright";

export async function loadGalleryFrame(page: Page, url: string, attempts = 4): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    await page.goto(url);
    const ready = await page
      .waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 20_000 })
      .then((handle) => handle.jsonValue())
      .catch(() => undefined);
    if (ready === "1") return;
    if (attempt >= attempts) throw new Error(`the gallery frame did not load (${String(ready)}): ${url}`);
  }
}
