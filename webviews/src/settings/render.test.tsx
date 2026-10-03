// Render rule: the page paints no background. html and body are transparent, no container
// declares or computes a background color, and only controls and interaction states use the
// theme's --input-bg / --accent-soft.
import { afterAll, expect, test } from "bun:test";
import { installDom, stylesheet } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderPage } = await import("./testing");

const transparent = new Set(["transparent", "rgba(0, 0, 0, 0)"]);
const allowedFills = new Set(["transparent", "none", "var(--accent-soft)", "var(--input-bg)"]);
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

test("the stylesheet makes html and body transparent", () => {
  const html = declarations(stylesheet).filter(
    (item) =>
      item.selector
        .split(",")
        .map((part) => part.trim())
        .includes("body") && item.property === "background",
  );
  expect(html.map((item) => item.value)).toEqual(["transparent"]);
});

test("no rule declares a background other than transparent or the two interaction tokens", () => {
  const fills = declarations(stylesheet).filter((item) => /^background(-color|-image)?$/.test(item.property));
  expect(fills.length).toBeGreaterThan(0);
  expect(fills.filter((item) => !allowedFills.has(item.value))).toEqual([]);
  // Containers never take a token fill; only controls and interaction states do.
  const containers =
    /^(html|body|#root|\.settings|\.sidebar|\.content|\.section|\.group|\.rows|\.row|\.row-main|\.result-section|\.domain-panel|\.notice|\.banner)$/;
  expect(
    fills.filter(
      (item) => item.value !== "transparent" && item.selector.split(",").some((part) => containers.test(part.trim())),
    ),
  ).toEqual([]);
});

test("the rendered page computes no background on html, body or any container", async () => {
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

  const page = await renderPage({ path: "/settings/appearance" });
  try {
    for (const element of [document.documentElement, document.body]) {
      expect(transparent.has(getComputedStyle(element).backgroundColor)).toBe(true);
    }
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
  }
});
