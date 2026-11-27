// A gallery stage frame (src/gallery/frame/main.ts) sets <html data-gallery-ready> to "1" once its
// entry has drawn, or to "error" when it cannot draw it (a missing id, an EntryShapeError such as an
// entry with no covers) and writes why into the page. Wait for either: an error fails at once with
// the frame's own text, not after the whole timeout with a bare TimeoutError.

/** Waits until the frame drew `entry`; throws the frame's error text if it could not. */
export async function waitForFrame(page, entry, timeout = 90_000) {
  await page.waitForFunction(() => /^(1|error)$/.test(document.documentElement.dataset.galleryReady ?? ""), undefined, {
    timeout,
  });
  if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) !== "error") return;
  const why = await page.evaluate(() => document.body.innerText);
  throw new Error(`the frame did not draw ${entry}: ${String(why).replace(/\s+/g, " ").trim()}`);
}
