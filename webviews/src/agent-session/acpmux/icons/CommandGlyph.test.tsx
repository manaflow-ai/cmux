import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { loadHarnessSymbol, setHarnessSymbolHost } from "../../shared/harnessIcons";
import { CommandGlyph } from "./CommandGlyph";

const PNG = "data:image/png;base64,iVBORw0KGgo=";
let release: (() => void) | undefined;
afterEach(() => release?.());

async function hostDraws(...names: string[]) {
  release = setHarnessSymbolHost(async () => PNG);
  for (const name of names) loadHarnessSymbol(name);
  await new Promise<void>((resolve) => queueMicrotask(resolve));
  await Promise.resolve();
}

test("a symbol the cmux pack draws is the pack's icon, even when the host has an image of it", async () => {
  await hostDraws("magnifyingglass");
  const markup = renderToStaticMarkup(<CommandGlyph symbol="magnifyingglass" />);
  expect(markup).toContain('data-icon="search"');
  expect(markup).not.toContain("nt-command-symbol");
});

test("a symbol the pack lacks is the host's image", async () => {
  await hostDraws("tortoise");
  const markup = renderToStaticMarkup(<CommandGlyph symbol="tortoise" />);
  expect(markup).toContain("nt-command-symbol");
});
