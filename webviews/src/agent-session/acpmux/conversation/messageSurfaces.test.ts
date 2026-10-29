import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "conversation.css"), "utf8");
const agentRowCss = readFileSync(join(import.meta.dir, "AgentMessageRow.css"), "utf8");
const gallery = readFileSync(join(import.meta.dir, "transcript.gallery.ts"), "utf8");

test("selected message surfaces are borderless while the prompt keeps stronger glass", () => {
  expect(css).toContain("--glass-tint: color-mix(in srgb, var(--cv-fg) 10%, transparent);");
  expect(css).toContain("--glass-edge: transparent;");
  expect(css).toContain(".cv-received__body {");
  expect(css).toContain("background: transparent;");
  expect(css).toContain("box-shadow: none;");
  expect(agentRowCss).toContain(".cv-agentmsg__card {");
  expect(agentRowCss).toContain("background: none;");
  expect(agentRowCss).toContain("box-shadow: none;");
});

test("gallery keeps the bordered before arm and two borderless alternatives", () => {
  expect(gallery).toContain('"message-surfaces-bordered"');
  expect(gallery).toContain('"message-surfaces-soft"');
  expect(gallery).toContain('"message-surfaces-borderless"');
  expect(css).toContain(':root[data-message-surfaces="bordered"]');
  expect(css).toContain(':root[data-message-surfaces="soft"]');
});

/** The rules that set `prop` on `.cv-user__bubble` (no other compound), with their selectors. */
const userBubbleDeclarations = (prop: string) =>
  [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    .map(([, selector, body]) => ({ selector: selector!.replace(/\/\*[\s\S]*?\*\//g, "").trim(), body: body! }))
    .filter(({ selector }) => /(^|\s)\.cv-user__bubble$/.test(selector))
    .flatMap(({ selector, body }) =>
      [...body.matchAll(new RegExp(`${prop}:\\s*([^;]+);`, "g"))].map(([, value]) => ({ selector, value: value!.trim() })),
    );

test("the user bubble draws no rim in Plain, Lens or Spectrum glass", () => {
  const glassCss = readFileSync(join(import.meta.dir, "../../../ui/glass/glass.css"), "utf8");
  // Lens and Spectrum's rim (specular line, lower shade, fringes) scale with --glass-rim; Plain's
  // rim and the last ring of the others are --glass-edge. Both must be off on the bubble itself.
  for (const term of ["--glass-specular", "--glass-shade", "--glass-fringe-red", "--glass-fringe-cyan", "--glass-edge"])
    expect(glassCss).toContain(`var(${term})`);
  for (const scaled of ["--glass-specular:", "--glass-shade:", "--glass-fringe-red: light-dark(", "--glass-fringe-cyan: light-dark("]) {
    const at = glassCss.indexOf(scaled, glassCss.indexOf(":root[data-glass=\"spectrum\"],") * (scaled.includes("fringe") ? 1 : 0));
    expect(at).toBeGreaterThanOrEqual(0);
    expect(glassCss.slice(at, glassCss.indexOf(");", at))).toContain("var(--glass-rim)");
  }
  const selected = (prop: string) =>
    userBubbleDeclarations(prop).filter(({ selector }) => selector === ".cv-user__bubble" || selector === ".acpmux-shell .cv-user__bubble");
  expect(selected("--glass-rim").map(({ value }) => value)).toEqual(["0"]);
  expect(selected("--glass-edge").map(({ value }) => value)).toEqual(["transparent"]);
  // The bubble never sets the rim shadow itself, so the mode rules' shadow reads its zeroed vars.
  expect(userBubbleDeclarations("--glass-rim-shadow")).toEqual([]);
  // The bordered gallery arm alone brings the rim back.
  const bordered = userBubbleDeclarations("--glass-rim").filter(({ selector }) => selector.includes("bordered"));
  expect(bordered.map(({ value }) => value)).toEqual(["inherit"]);
});
