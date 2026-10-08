// Render rule (lane 20 one web theme): html paints only --cmux-surface-background (the native
// bootstrap's !important rule; the page's own html rule matches it and never beats it), body and
// every container stay transparent, and only controls and interaction states use the theme's
// --input-bg / --accent-soft.
import { afterAll, expect, test } from "bun:test";
import { installDom, stylesheet } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage } = await import("./testing");

const transparent = new Set(["transparent", "rgba(0, 0, 0, 0)"]);
const surface = "var(--cmux-surface-background, transparent)";
// The bootstrap rule native injects at document start (WebTheme.bootstrapScript).
const bootstrapRule =
  "html{background:var(--cmux-surface-background) !important}body{background:transparent !important}";
// --accent marks an on control (a switch, a default button), never a surface (layout.css).
const allowedFills = new Set(["transparent", "none", "var(--accent-soft)", "var(--input-bg)", "var(--accent)"]);
const containerTags = new Set([
  "HTML",
  "BODY",
  "DIV",
  "MAIN",
  "ASIDE",
  "NAV",
  "SECTION",
  "HEADER",
  "UL",
  "LI",
  "SPAN",
  "H1",
  "H2",
  "H3",
  "P",
  "LABEL",
  "OUTPUT",
  "FIELDSET",
]);

// Selection is interactive feedback: a checked segment may take --accent-soft.
const selectionStates = "[data-swatch], [data-checked], [aria-current], [aria-pressed='true']";

function declarations(css: string): Array<{ selector: string; property: string; value: string }> {
  const out: Array<{ selector: string; property: string; value: string }> = [];
  for (const [, selector, body] of css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    for (const declaration of body!.split(";")) {
      const [property, ...value] = declaration.split(":");
      if (property?.trim() && value.length)
        out.push({ selector: selector!.trim(), property: property.trim(), value: value.join(":").trim() });
    }
  }
  return out;
}

const selectors = (item: { selector: string }) => item.selector.split(",").map((part) => part.trim());

test("the stylesheet paints html only with the one web theme background and keeps body transparent", () => {
  const fills = declarations(stylesheet).filter((item) => item.property === "background");
  expect(fills.filter((item) => selectors(item).includes("html")).map((item) => item.value)).toEqual([surface]);
  expect(fills.filter((item) => selectors(item).includes("body")).map((item) => item.value)).toEqual(["transparent"]);
});

test("no rule declares a background other than transparent or the two interaction tokens", () => {
  const fills = declarations(stylesheet).filter((item) => /^background(-color|-image)?$/.test(item.property));
  expect(fills.length).toBeGreaterThan(0);
  const htmlSurface = (item: { selector: string; value: string }) =>
    item.value === surface && selectors(item).every((part) => part === "html");
  expect(fills.filter((item) => !allowedFills.has(item.value) && !htmlSurface(item))).toEqual([]);
  // Containers never take a token fill; only controls and interaction states do.
  const containers =
    /^(body|#root|\.settings|\.sidebar|\.content|\.section|\.group|\.rows|\.row|\.row-main|\.result-section|\.domain-panel|\.notice|\.banner)$/;
  expect(
    fills.filter((item) => item.value !== "transparent" && selectors(item).some((part) => containers.test(part))),
  ).toEqual([]);
});

test("theme colors read the one web theme first, then the page theme", () => {
  const root = new Map(
    declarations(stylesheet)
      .filter((item) => item.selector === ":root")
      .map((item) => [item.property, item.value.replace(/\s+/g, " ").replace(/\(\s/g, "(")]),
  );
  const expected: Array<[string, string, string]> = [
    ["--text", "--cmux-text", "--app-text"],
    ["--muted-text", "--cmux-text-secondary", "--app-muted-text"],
    ["--soft-text", "--cmux-text-tertiary", "--app-soft-text"],
    ["--border", "--cmux-separator", "--app-border"],
    ["--input-bg", "--cmux-hover", "--app-input-bg"],
    ["--accent-soft", "--cmux-selection", "--app-accent-soft"],
  ];
  for (const [name, cmux, app] of expected) {
    expect(root.get(name)).toStartWith(`var(${cmux}, var(${app},`);
  }
});

test("the rendered page: html carries only the surface background, body and containers none", async () => {
  // Probe: the computed-style check sees stylesheet fills, so a pass below is meaningful.
  const probe = document.createElement("style");
  probe.textContent = ".probe-fill { background-color: rgb(1, 2, 3); }";
  document.head.append(probe);
  const probeElement = document.createElement("div");
  probeElement.className = "probe-fill";
  document.body.append(probeElement);
  expect(getComputedStyle(probeElement).backgroundColor).toBe("rgb(1, 2, 3)");
  probeElement.remove();
  probe.remove();

  const bootstrap = document.createElement("style");
  bootstrap.id = "cmux-theme";
  bootstrap.textContent = bootstrapRule;
  document.head.append(bootstrap);
  document.documentElement.style.setProperty("--cmux-surface-background", "rgb(10, 20, 30)");
  const page = await renderPage({ path: "/settings/appearance" });
  try {
    // jsdom drops declarations whose value is a var(), so html reads as transparent there; the
    // stylesheet test above pins the html rule itself. What matters here: nothing else paints.
    const html = getComputedStyle(document.documentElement).backgroundColor;
    expect(["rgb(10, 20, 30)", "var(--cmux-surface-background)", ...transparent]).toContain(html);
    expect(transparent.has(getComputedStyle(document.body).backgroundColor)).toBe(true);
    const painted = [...document.body.querySelectorAll<HTMLElement>("*")]
      .filter((element) => containerTags.has(element.tagName) && !element.matches(selectionStates))
      .filter((element) => {
        const color = getComputedStyle(element).backgroundColor;
        return color !== "" && !transparent.has(color);
      })
      .map((element) => `${element.tagName}.${element.className}`);
    expect(painted).toEqual([]);
    const inline = [...document.body.querySelectorAll<HTMLElement>("[style]")]
      .filter((element) => /background/i.test(element.getAttribute("style") ?? ""))
      .map((element) => element.tagName);
    expect(inline).toEqual([]);
  } finally {
    page.unmount();
    bootstrap.remove();
    document.documentElement.style.removeProperty("--cmux-surface-background");
  }
});

test("on controls use the neutral accent: no theme hue (no blue) on switches, links or the current section", () => {
  const root = new Map<string, string>();
  for (const { selector, property, value } of declarations(stylesheet)) if (selector === ":root") root.set(property, value);
  for (const name of ["--accent", "--accent-text"]) {
    expect(root.get(name)).toBeDefined();
    expect(root.get(name)).not.toContain("--cmux-app-accent");
    expect(root.get(name)).not.toContain("--cmux-accent");
  }
});
