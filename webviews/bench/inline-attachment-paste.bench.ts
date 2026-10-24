import type { Page } from "playwright";

/// Browser harness for the paste-to-last-thumbnail measurement. Run the same function on the
/// merge-base checkout and the inline checkout with counts 1, 5 and 10; the returned milliseconds
/// are the wall time from dispatching one multi-file paste until every thumbnail leaves pending.
/// Native builds stay out of this harness, so it can run on the admitted fleet browser lane.
export async function measureInlineAttachmentPaste(
  page: Page,
  count: number,
  thumbnailSelector = ".acpmux-composer .acpmux-attachment-image img, .acpmux-composer .acpmux-md-inline-attachment img",
): Promise<number> {
  return page.evaluate(
    async ({ count: total, thumbnailSelector: selector }) => {
      const field = document.querySelector<HTMLElement>(".acpmux-md.ProseMirror");
      if (!field) throw new Error("composer field is not mounted");
      if (document.querySelector(selector)) throw new Error("reset the composer before each sample");
      const canvas = document.createElement("canvas");
      canvas.width = 1920; canvas.height = 1080;
      const context = canvas.getContext("2d");
      if (!context) throw new Error("canvas is unavailable");
      context.fillStyle = "#20242d"; context.fillRect(0, 0, 1920, 1080);
      context.fillStyle = "#8fb4d9"; context.font = "24px monospace";
      for (let row = 0; row < 30; row++) context.fillText(`Screenshot fixture row ${row}: image then caption`, 40, 40 + row * 32);
      const pixel = await new Promise<Blob>((resolve, reject) => canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error("PNG encoding failed")), "image/png"));
      const transfer = new DataTransfer();
      for (let index = 0; index < total; index += 1)
        transfer.items.add(new File([pixel], `inline-paste-${index}.png`, { type: "image/png" }));
      const started = performance.now();
      field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: transfer, bubbles: true, cancelable: true }));
      await new Promise<void>((resolve, reject) => {
        const deadline = performance.now() + 30_000;
        const check = () => {
          const images = [...document.querySelectorAll<HTMLImageElement>(selector)];
          if (
            images.length >= total &&
            images.slice(-total).every((image) => image.complete && image.naturalWidth > 0)
          ) {
            return Promise.all(images.slice(-total).map((image) => image.decode?.().catch(() => undefined))).then(
              () => {
                requestAnimationFrame(() => requestAnimationFrame(() => resolve()));
              },
            );
          }
          if (performance.now() > deadline) return reject(new Error(`timed out waiting for ${total} thumbnails`));
          requestAnimationFrame(check);
        };
        void check();
      });
      return performance.now() - started;
    },
    { count, thumbnailSelector },
  );
}

export async function measureInlineAttachmentPasteTable(
  page: Page,
  reset: () => Promise<void>,
  thumbnailSelector = ".acpmux-composer .acpmux-attachment-image img, .acpmux-composer .acpmux-md-inline-attachment img",
): Promise<Record<1 | 5 | 10, number>> {
  const table = {} as Record<1 | 5 | 10, number>;
  for (const count of [1, 5, 10] as const) {
    await reset();
    table[count] = await measureInlineAttachmentPaste(page, count, thumbnailSelector);
  }
  return table;
}
