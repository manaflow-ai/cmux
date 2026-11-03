import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const agentRowCss = readFileSync(join(import.meta.dir, "AgentMessageRow.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("selected message surfaces are borderless while the prompt keeps stronger glass", () => {
  expect(css).toContain("--glass-tint: color-mix(in srgb, var(--cv-fg) 10%, transparent);");
  expect(css).toContain("--glass-edge: transparent;");
  // Another agent's message is one inline line on base (#27312): no card to restyle.
  expect(css).not.toContain(".cv-received__body {");
  expect(agentRowCss).toContain(".cv-agentmsg__card {");
  expect(agentRowCss).toContain("background: none;");
  expect(agentRowCss).toContain("box-shadow: none;");
});

test("gallery keeps the bordered before arm and two borderless alternatives", () => {
  expect(gallery).toContain('"message-surfaces-bordered"');
  expect(gallery).toContain('"message-surfaces-soft"');
  expect(gallery).toContain('"message-surfaces-borderless"');
  expect(css).toContain(':root[data-message-surfaces="bordered"]');
  expect(agentRowCss).toContain(':root[data-message-surfaces="soft"]');
});

/** Each rule's selector (comments stripped) and body, for a stylesheet's innermost rules. */
const rules = (sheet: string) =>
  [...sheet.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({
    selector: selector!.trim().replace(/\s+/g, " "),
    body: body!,
  }));
const declared = (body: string, prop: string) =>
  [...body.matchAll(new RegExp(`(?:^|;|\\s)${prop}:\\s*([^;]+);`, "g"))].map(([, value]) => value!.trim());

test("the user bubble's rim is off in Plain, Lens and Spectrum glass", () => {
  const glass = rules(readFileSync(join(import.meta.dir, "../../../ui/glass/glass.css"), "utf8"));
  // Every mode's rim shadow is built only from these terms, and each but the edge scales with
  // --glass-rim, so --glass-rim 0 plus a clear edge on the bubble clears it in every mode.
  const scaled = ["--glass-specular", "--glass-shade", "--glass-fringe-red", "--glass-fringe-cyan"];
  const modes = {
    lens: glass.filter(({ selector }) => selector === ":root, .ui-glass"),
    plain: glass.filter(({ selector }) =>
      selector.startsWith(':root:not([data-glass="lens"], [data-glass="spectrum"])'),
    ),
    spectrum: glass.filter(({ selector }) => selector.startsWith(':root[data-glass="spectrum"]')),
  };
  for (const [mode, modeRules] of Object.entries(modes)) {
    expect(modeRules.length, mode).toBeGreaterThan(0);
    for (const { body } of modeRules) {
      for (const shadow of declared(body, "--glass-rim-shadow"))
        for (const [, term] of shadow.matchAll(/var\((--glass-[\w-]+)\)/g))
          expect([...scaled, "--glass-edge"], `${mode} rim term ${term}`).toContain(term);
      for (const term of scaled)
        for (const value of declared(body, term))
          if (value !== "transparent") expect(value, `${mode} ${term}`).toContain("var(--glass-rim)");
    }
  }
  const bubble = rules(css).filter(({ selector }) => /(^|\s)\.cv-user__bubble$/.test(selector));
  const selected = bubble.filter(({ selector }) => !selector.includes("data-message-surfaces"));
  expect(selected.flatMap(({ body }) => declared(body, "--glass-rim"))).toEqual(["0"]);
  expect(selected.flatMap(({ body }) => declared(body, "--glass-edge"))).toEqual(["transparent"]);
  // The bubble never sets a rim shadow or a rim term of its own past the zeroed vars.
  for (const prop of ["--glass-rim-shadow", ...scaled])
    expect(
      bubble.flatMap(({ body }) => declared(body, prop)),
      prop,
    ).toEqual([]);
  // Only the bordered gallery arm brings the page's rim back.
  const bordered = bubble.filter(({ selector }) => selector.includes('[data-message-surfaces="bordered"]'));
  expect(bordered.flatMap(({ body }) => declared(body, "--glass-rim"))).toEqual(["inherit"]);
});
