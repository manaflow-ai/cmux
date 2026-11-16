// The theme propagation matrix (src/gallery/theme/propagation.ts), run against the app's own
// document-start script (WebTheme.bootstrapScript, read from the Swift source) and the agent pane's
// applyAgentTheme: every appearance knob is set live, with no reload, and every web surface it
// reaches must pick it up. Also: the gallery sends every variable the app sends (so a stage is drawn
// in the app's material, not a stylesheet fallback), and tooltips and cards keep their contrast
// promise over any backdrop in every shipped theme.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { JSDOM } from "jsdom";
import { readShippedThemes, readWebThemeBootstrap } from "../dev-server/galleryHost";
import { applyAgentTheme } from "../src/agent-session/shared/theme";
import {
  appliedTheme,
  BASE_STATE,
  failures,
  glassContrast,
  KNOBS,
  readSurfaces,
  runPropagationMatrix,
} from "../src/gallery/theme/propagation";
import { themeTokens } from "../src/gallery/theme/web";
import { settleReact } from "./support/domTeardown";

const themes = readShippedThemes();
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  url: "http://localhost/",
  runScripts: "outside-only",
});
const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
  dom.window.eval(readWebThemeBootstrap());
});
afterAll(async () => {
  await settleReact();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  dom.window.close();
});

const cmuxTheme = () => (dom.window as unknown as { cmuxTheme: { apply(payload: unknown): void } }).cmuxTheme;

test("every knob reaches every web surface it should, live, and no other", () => {
  const rows = runPropagationMatrix(
    (applied) => {
      // AgentPaneTheme.script's order: the shared payload, then the pane's own theme.
      cmuxTheme().apply(applied.web);
      applyAgentTheme(applied.agent);
    },
    () => readSurfaces(dom.window.document),
    themes,
  );
  expect(rows).toHaveLength(KNOBS.length);
  expect(failures(rows)).toEqual([]);
  // A theme change reaches the terminal colors code pages and the agent pane's ANSI swatches read.
  const theme = rows.find((row) => row.knob.key === "appearance.theme")!;
  expect(theme.cells.terminal).toBe("live");
});

test("a knob set back restores every surface exactly (no value left behind)", () => {
  const read = () => readSurfaces(dom.window.document);
  const apply = (state: typeof BASE_STATE) => {
    const applied = appliedTheme(state, themes);
    cmuxTheme().apply(applied.web);
    applyAgentTheme(applied.agent);
  };
  apply(BASE_STATE);
  const base = read();
  for (const knob of KNOBS) {
    apply({ ...BASE_STATE, ...knob.to });
    apply(BASE_STATE);
    expect({ knob: knob.key, surfaces: read() }).toEqual({ knob: knob.key, surfaces: base });
  }
});

test("the gallery sends every page variable WebTheme.swift sends", () => {
  const swift = readFileSync(
    path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Windows/WebTheme.swift"),
    "utf8",
  );
  const body = swift.slice(swift.indexOf("variables = ["), swift.indexOf("].merging("));
  const appVariables = [...body.matchAll(/"(--cmux-[a-z-]+)":/g)].map((match) => match[1]!);
  expect(appVariables.length).toBeGreaterThan(20);
  const gallery = Object.keys(appliedTheme(BASE_STATE, themes).web.variables);
  expect(appVariables.filter((name) => !gallery.includes(name))).toEqual([]);
});

test("tooltips and cards keep 4.5:1 over any backdrop in every shipped theme", () => {
  const misses = themes.flatMap((theme) => {
    const measured = glassContrast(themeTokens(theme));
    return [
      measured.tooltip < 4.5 ? `${theme.name} tooltip ${measured.tooltip.toFixed(2)}` : null,
      measured.card < 4.5 ? `${theme.name} card ${measured.card.toFixed(2)}` : null,
    ].filter((miss): miss is string => miss !== null);
  });
  expect(misses).toEqual([]);
});
