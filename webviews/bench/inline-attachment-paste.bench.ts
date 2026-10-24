import type { Page } from "playwright";

/// Browser harness for the paste-to-last-thumbnail measurement. Run the same function on the
/// merge-base checkout and the inline checkout with counts 1, 5 and 10; the returned milliseconds
/// are the wall time from dispatching one multi-file paste until every thumbnail leaves pending.
/// Native builds stay out of this harness, so it can run on the admitted fleet browser lane.
export async function measureInlineAttachmentPaste(
  page: Page,
  count: number,
  thumbnailSelector = ".acpmux-md-inline-attachment:not(.is-pending) img",
): Promise<number> {
  return page.evaluate(
    async ({ count: total, thumbnailSelector: selector }) => {
      const field = document.querySelector<HTMLElement>(".acpmux-md.ProseMirror");
      if (!field) throw new Error("composer field is not mounted");
      // A 640x480 PNG payload is representative of a screenshot and exercises decode/downsample.
      const pixel = Uint8Array.from(
        atob(
          "iVBORw0KGgoAAAANSUhEUgAAAoAAAAHgCAIAAAC6sdbXAAAACXBIWXMAAAsSAAALEgHS3X78AAABTUlEQVR4nO3VwQkAAAgDINc/9K3hHFQgE5JQm5vZ2V0aW1hZ2U=",
        ),
        (character) => character.charCodeAt(0),
      );
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
  thumbnailSelector = ".acpmux-md-inline-attachment:not(.is-pending) img",
): Promise<Record<1 | 5 | 10, number>> {
  const table = {} as Record<1 | 5 | 10, number>;
  for (const count of [1, 5, 10] as const)
    // The caller must reset the gallery/composer between samples so prior marks do not inflate counts.
    table[count] = await measureInlineAttachmentPaste(page, count, thumbnailSelector);
  return table;
}
