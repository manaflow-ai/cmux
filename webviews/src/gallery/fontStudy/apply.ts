// Applies a font study pairing (candidates.ts) to a gallery document: declares its faces and sets the
// chrome face (`--font-ui`), the prose face (`--cv-font`, a serif a step larger) and the code face
// (`--cv-mono`), each at its designed spacing as chatUiFont.ts sets a non-Inter face. `inter-tuned`
// keeps today's Inter and its tracking. Resolves once every face has loaded, so no capture shows a
// fallback.
import { FACES, type FaceKey, pairingById } from "./candidates";

/// The type scale's steps with their own letter-spacing token (pages/shared/desktop.css).
const STEPS = ["caption", "detail", "body", "field", "title", "heading"] as const;

const stack = (key: FaceKey) => `"${FACES[key].family}", "Inter", system-ui, sans-serif`;

export async function applyFontStudy(id: string, doc: Document = document): Promise<void> {
  const pairing = pairingById(id);
  if (!pairing) return;
  const keys = [pairing.ui, pairing.prose, pairing.mono].filter(
    (key): key is FaceKey => key !== undefined && key !== "inter-tuned",
  );
  const faces = keys
    .flatMap((key) =>
      FACES[key].files.map(
        (file) =>
          `@font-face{font-family:"${FACES[key].family}";src:url(${file.url}) format("woff2");` +
          `font-weight:${file.weight};font-style:normal;font-display:block}`,
      ),
    )
    .join("");
  const rules: string[] = [];
  if (pairing.ui !== "inter-tuned") {
    rules.push(`--font-ui: ${stack(pairing.ui)};`, "--cv-tracking: 0px;");
    for (const step of STEPS) rules.push(`--text-${step}--letter-spacing: ${pairing.tracking?.[step] ?? 0}em;`);
  }
  if (pairing.prose) rules.push(`--cv-font: ${stack(pairing.prose)};`);
  if (pairing.proseSize)
    rules.push(
      `--cv-font-size: ${pairing.proseSize}px;`,
      `--cv-line-height: ${Math.round(pairing.proseSize * 1.6)}px;`,
    );
  if (pairing.mono) rules.push(`--cv-mono: "${FACES[pairing.mono].family}", ui-monospace, monospace;`);
  const style = doc.createElement("style");
  style.id = "cmux-font-study";
  // Doubled so it wins over the pane's own `:root` sheets, whichever loads last.
  style.textContent = `${faces}:root:root{${rules.join(" ")}}`;
  doc.getElementById(style.id)?.remove();
  doc.head.append(style);
  doc.documentElement.dataset.fontStudy = pairing.id;
  await Promise.all(
    keys.flatMap((key) =>
      FACES[key].files.map((file) =>
        doc.fonts.load(`${file.weight.includes(" ") ? 400 : file.weight} 14px "${FACES[key].family}"`),
      ),
    ),
  ).catch(() => undefined);
}
