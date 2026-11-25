// The twin of one Tailwind stylesheet (dev-server/tailwindOnNewClasses.ts): its compiler and a
// scanner over the same sources @tailwindcss/vite scans. Made in a worker thread, one per
// stylesheet: the first scan of webviews/ takes seconds, and the dev server's thread stays free.
// The worker then answers each save in a few ms: whether it adds CSS to the stylesheet.
import fs from "node:fs";
import path from "node:path";
import { isMainThread, parentPort, workerData } from "node:worker_threads";
import { __unstable__loadDesignSystem as loadDesignSystem, compile } from "@tailwindcss/node";
import { Scanner } from "@tailwindcss/oxide";

/** @typedef {{ scanner: Scanner; design: Awaited<ReturnType<typeof loadDesignSystem>> }} Twin */

/** @param {string} stylesheet @param {string} root @returns {Promise<Twin>} */
export async function twinOf(stylesheet, root) {
  const css = fs.readFileSync(stylesheet, "utf8");
  const base = path.dirname(stylesheet);
  // The compiler only for the sources it names; the design system says what a class compiles to.
  const compiler = await compile(css, { base, onDependency: () => {} });
  // As @tailwindcss/vite builds its scanner: no root is the Vite root, `none` scans nothing.
  const sources = (
    compiler.root === "none"
      ? []
      : compiler.root === null
        ? [{ base: root, pattern: "**/*", negated: false }]
        : [{ ...compiler.root, negated: false }]
  ).concat(compiler.sources);
  const scanner = new Scanner({ sources });
  scanner.scan();
  return { scanner, design: await loadDesignSystem(css, { base }) };
}

/** Whether `content` (a save of a file of kind `extension`) adds CSS to the twin's stylesheet:
 *  a class the scanner has not seen (it returns only those) that compiles to a rule. Most unseen
 *  candidates are words that are no utility. Tailwind's own candidate set holds every class the
 *  scanner has seen, so a seen class adds nothing. @param {Twin} twin @param {string} content
 *  @param {string} extension */
export function addsCss(twin, content, extension) {
  for (const fresh of twin.scanner.scanFiles([{ content, extension }]))
    if (twin.design.candidatesToCss([fresh])[0]) return true;
  return false;
}

if (!isMainThread && workerData?.cmuxTailwindTwin) {
  const port = /** @type {import("node:worker_threads").MessagePort} */ (parentPort);
  /** @type {Twin | undefined} */
  let twin;
  twinOf(workerData.stylesheet, workerData.root).then(
    (made) => {
      twin = made;
      port.postMessage({ ready: true });
    },
    (error) => port.postMessage({ ready: false, error: String(error) }),
  );
  port.on("message", (/** @type {{ id: number; content: string; extension: string }} */ save) => {
    port.postMessage({ id: save.id, adds: twin ? addsCss(twin, save.content, save.extension) : true });
  });
}
