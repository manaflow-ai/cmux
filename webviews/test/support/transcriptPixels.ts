// Captured Chromium output, separate from DOM geometry. Screencast delivery can coalesce frames;
// this measures delivered images, not every physical refresh or macOS compositor output.
import { mkdir, writeFile } from "node:fs/promises";
import { PNG } from "pngjs";
import type { Page } from "playwright";

declare global {
  interface Window {
    __flashStop?: () => {
      adds: number;
      removes: number;
      missingFrames: number;
      fadingFrames: number;
      domFrames: number;
    };
  }
}

export async function transcriptPixels(page: Page) {
  const box = await page.locator(".acpmux-scroll").boundingBox();
  if (!box) throw new Error("no transcript capture region");
  // Exclude the preview card and faded edges, keeping real transcript text.
  const composer = (await page.locator(".acpmux-composer").count())
    ? await page.locator(".acpmux-composer").boundingBox()
    : null;
  const bottom = Math.min(box.y + box.height, composer?.y ?? Infinity);
  const crop = {
    x: Math.ceil(box.x + 450),
    y: Math.ceil(box.y + 40),
    width: Math.floor(box.width - 500),
    height: Math.floor(bottom - box.y - 80),
  };
  if (crop.width < 100 || crop.height < 100) throw new Error("capture region too small");
  const cdp = await page.context().newCDPSession(page);
  const frames: { data: string; phase: string }[] = [];
  const errors: string[] = [];
  let phase = "before";
  const receive = (event: { data: string; sessionId: number }) => {
    void cdp
      .send("Page.screencastFrameAck", { sessionId: event.sessionId })
      .catch((error) => errors.push(String(error)));
    if (frames.length >= 600) {
      errors.push("screencast frame limit exceeded");
      return;
    }
    frames.push({ data: event.data, phase });
  };
  const checkpoint = async (name: string) => {
    phase = name;
    const { data } = await cdp.send("Page.captureScreenshot", { format: "png" });
    frames.push({ data, phase });
  };
  cdp.on("Page.screencastFrame", receive);
  try {
    await checkpoint("before");
    await cdp.send("Page.startScreencast", { format: "png", everyNthFrame: 1 });
  } catch (error) {
    cdp.off("Page.screencastFrame", receive);
    await cdp.detach();
    throw error;
  }
  return {
    mark(name: string) {
      phase = name;
    },
    checkpoint,
    async stop(name: string) {
      try {
        await checkpoint("after");
      } finally {
        try {
          await cdp.send("Page.stopScreencast");
        } finally {
          cdp.off("Page.screencastFrame", receive);
          await cdp.detach();
        }
      }
      if (errors.length) throw new Error(errors.join("\n"));
      const samples = frames.map(({ data, phase }) => {
        const png = PNG.sync.read(Buffer.from(data, "base64"));
        const bands = Array.from({ length: Math.ceil(crop.height / 64) }, () => 0);
        for (let y = crop.y; y < crop.y + crop.height; y++) {
          for (let x = crop.x; x < crop.x + crop.width; x++) {
            const offset = (y * png.width + x) * 4;
            if (Math.min(png.data[offset]!, png.data[offset + 1]!, png.data[offset + 2]!) > 110)
              bands[Math.floor((y - crop.y) / 64)]! += 1;
          }
        }
        return { phase, ink: bands.reduce((a, b) => a + b, 0), bands };
      });
      if (samples[0]!.ink < 200) throw new Error("baseline capture has insufficient transcript text");
      const blankFrames = samples.flatMap((sample, i) => (sample.ink < 30 ? [i] : []));
      // A strip loses text then recovers. During scrolling these are only candidates because
      // moving text may legitimately cross the strip boundary.
      const transientFrames = samples.flatMap((sample, i) => {
        const before = samples[i - 1],
          after = samples[i + 1];
        return before &&
          after &&
          sample.bands.some((ink, band) => {
            const reference = Math.min(before.bands[band]!, after.bands[band]!);
            return reference > 100 && ink < reference * 0.15;
          })
          ? [i]
          : [];
      });
      const referenceLossFrames = samples.flatMap((sample, i) =>
        sample.bands.some((ink, band) => {
          const reference = Math.min(samples[0]!.bands[band]!, samples.at(-1)!.bands[band]!);
          return reference > 100 && ink < reference * 0.15;
        })
          ? [i]
          : [],
      );
      const result = { frames: samples.length, blankFrames, transientFrames, referenceLossFrames, crop, samples };
      if (process.env.CMUX_FLASH_EVIDENCE) {
        const directory = `${process.env.CMUX_FLASH_EVIDENCE}/${name}`;
        await mkdir(directory, { recursive: true });
        await Promise.all(
          frames.map((frame, i) =>
            writeFile(`${directory}/${String(i).padStart(4, "0")}.png`, Buffer.from(frame.data, "base64")),
          ),
        );
        await writeFile(`${directory}/counts.json`, JSON.stringify(result, null, 2));
      }
      return result;
    },
  };
}
