// cmux-web-test-timeout: 300
// Every icon an existing caller draws keeps its markup: per-layer paint (`layerPaint`, app scene
// symbol rendering modes) is opt-in, so an Icon without it, or with a paint that keeps every layer,
// renders exactly what it did before layerPaint existed. The digests in
// iconDefaultMarkup.snapshot.json were taken from the base before #44904 (feat-cmux-next af7caf271c6),
// one per icon over every pack, accent and prop combination callers use (size, selected, row, fit,
// color, title, className, style). A change to an icon's drawing changes its digest on purpose:
// regenerate with `UPDATE_ICON_MARKUP=1 bun test src/agent-session/acpmux/icons/iconDefaultMarkup.test.tsx`
// and say why in the PR.
import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { renderToStaticMarkup } from "react-dom/server";
import { Icon } from "./Icon";
import { IconsProvider } from "./IconsContext";
import { bundledIconPack, customIconPack } from "./iconPack";
import type { IconAccent, IconPack } from "./types";

const snapshotPath = fileURLToPath(new URL("./iconDefaultMarkup.snapshot.json", import.meta.url));

const contexts: [string, IconPack, IconAccent][] = [
  ["bundled", bundledIconPack, "none"],
  ["bundled", bundledIconPack, "cat"],
  ["custom", customIconPack, "none"],
  ["custom", customIconPack, "cat"],
];
const shapes = [{}, { row: true }, { row: true, fit: true }];
const sizes = [12, 14, 16, 20];
const dressings = [{}, { color: "#ff3b30", title: "Label", className: "cv-icon", style: { opacity: 0.5 } }];

type Extra = Record<string, unknown>;

function iconMarkup(name: string, extra: Extra): string {
  const parts: string[] = [];
  for (const [packName, pack, accent] of contexts)
    for (const selected of [false, true])
      for (const shape of shapes)
        for (const size of sizes)
          for (const dressing of dressings) {
            const props = { name, selected, size, ...shape, ...dressing, ...extra };
            const html = renderToStaticMarkup(
              <IconsProvider pack={pack} accent={accent}>
                <Icon {...(props as Parameters<typeof Icon>[0])} />
              </IconsProvider>,
            );
            parts.push(
              `${packName}/${accent}/${selected}/${JSON.stringify(shape)}/${size}/${dressing === dressings[0]}:${html}`,
            );
          }
  return parts.join("\n");
}

const digest = (text: string) => createHash("sha256").update(text).digest("hex").slice(0, 20);

const names = [...new Set([...Object.keys(bundledIconPack.icons), ...Object.keys(customIconPack.icons)])].sort();

function digests(extra: Extra): Record<string, string> {
  return Object.fromEntries(names.map((name) => [name, digest(iconMarkup(name, extra))]));
}

test("every existing icon renders its base markup without layerPaint", () => {
  const actual = digests({});
  if (process.env.UPDATE_ICON_MARKUP === "1") fs.writeFileSync(snapshotPath, `${JSON.stringify(actual, null, 1)}\n`);
  const base = JSON.parse(fs.readFileSync(snapshotPath, "utf8")) as Record<string, string>;
  expect(names.length).toBeGreaterThan(300);
  const changed = names.filter((name) => base[name] !== undefined && base[name] !== actual[name]);
  expect(changed).toEqual([]);
  // Every icon in the base set is still drawn.
  expect(Object.keys(base).filter((name) => !(name in actual))).toEqual([]);
}, 120_000);

test("a layerPaint that keeps every layer renders the base markup too", () => {
  const base = JSON.parse(fs.readFileSync(snapshotPath, "utf8")) as Record<string, string>;
  const actual = digests({ layerPaint: () => undefined });
  expect(names.filter((name) => base[name] !== undefined && base[name] !== actual[name])).toEqual([]);
}, 120_000);
