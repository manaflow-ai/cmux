// One floating material, web and native (Leo, 2026-11-11: "The point is, the styles mix and they
// don't look good. So they need to look good."). schemas/design-scale/design-scale.json is the one
// source: the page reads it through gen-design-scale (desktop.css), and Swift's GlassMenuMaterial
// carries the same numbers. This fails when the Swift side drifts from the JSON.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

import designScale from "../../schemas/design-scale/design-scale.json";

const repo = (file: string) => readFileSync(new URL(`../../${file}`, import.meta.url), "utf8");
const swift = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/GlassMenu/GlassMenuMaterial.swift");
const menu = designScale.glass.find((level) => level.name === "menu") as { veil?: number; tint: number };
const named = (name: string) => designScale.namedRadii.find((radius) => radius.name === name) as { px: number };
const control = (name: string) => designScale.controls.find((row) => row.name === name) as { px: number };

const swiftNumber = (name: string) => {
  const match = swift.match(new RegExp(`static let ${name}: (?:Double|CGFloat) = ([\\d.]+)`));
  if (!match) throw new Error(`GlassMenuMaterial.${name} is not a number literal`);
  return Number(match[1]);
};

test("the native menu veil is the menu level's veil", () => {
  expect(menu.veil).toBeGreaterThan(0);
  expect(swift).toContain("veilPercent: Double = TransientMaterial.standard.hostVeil * 100");
  expect(designScale.transientMaterial.hostVeil * 100).toBe(menu.veil as number);
});

test("the native menu radius is the popup radius", () => {
  expect(swiftNumber("defaultCornerRadius")).toBe(named("popup").px);
});

test("the native menu row is the row control", () => {
  expect(swift).toContain("public static let rowHeight: CGFloat = DesignTokens.controlRow");
  const tokens = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/DesignTokens.swift");
  expect(tokens).toContain(`static let controlRow: CGFloat = ${control("row").px}`);
});

test("the native menu is the menu glass level", () => {
  expect(swift).toContain("static let level: GlassLevel = .menu");
});

// The App's host surface carries the menu veil (Glass.makeHostSurface: the native menu panel), so the page
// lays none on it and a web menu is the native one to the pixel (Liquid Glass Parity, 2026-11-18).
test("the App's menu panel carries the veil; the page lays none on the App's glass", () => {
  const glass = repo("webviews/src/ui/glass/glass.css");
  expect(glass).toContain("--host-glass-fill: transparent;");
  expect(repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/FloatingGlass/HostGlassSurface.swift")).toContain(
    "return makeMenuPanel(interactive: false)",
  );
  expect(repo("webviews/src/pages/shared/desktop.css")).toContain(
    `--ds-transient-host-veil: ${designScale.transientMaterial.hostVeil};`,
  );
  expect(designScale.transientMaterial.hostVeil * 100).toBe(menu.veil as number);
});

// Popup and dialog corners (Leo, 2026-11-20: "the little curvature, border radius. I don't even know how you
// guys came up with it"). design-scale.json's `popup` radius and `dialog` padding are the one source: the page
// reads them through desktop.css, Swift through DesignTokens, and both draw the same Debug variant
// (PopupCornerLook / DialogCornerLook) through the theme's --cmux-popup-radius and --cmux-dialog-padding.
const dialog = (designScale as unknown as { dialog: { padding: number } }).dialog;

test("the popup radius is the reference launcher's 18, one number native and web", () => {
  expect(named("popup").px).toBe(18);
  const tokens = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/DesignTokens.swift");
  expect(tokens).toContain(`nonisolated static let radiusPopup: CGFloat = ${named("popup").px}`);
  expect(repo("webviews/src/pages/shared/desktop.css")).toContain(
    `--ds-radius-popup: var(--cmux-popup-radius, ${named("popup").px}px);`,
  );
  // The pane radius does not follow: panes stay on the `lg` radius, popups are their own surface.
  const tunables = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tunables/MetricTunables.swift");
  const pane = tunables.match(/"densityPaneCornerRadius"[\s\S]*?compact: ([\d.]+), comfortable: ([\d.]+)\)/);
  const lg = designScale.radii.find((radius) => radius.name === "lg")!.px;
  expect(pane?.slice(1).map(Number)).toEqual([lg, lg]);
});

test("a popup row is concentric with the popup, native and web", () => {
  const popup = repo("webviews/src/ui/popupSurface.css");
  expect(popup).toContain("--ui-row-radius: max(4px, calc(var(--ui-popup-radius) - var(--ui-popup-padding, 4px)));");
  // A menu on AppKit's grid insets its highlight by the menu inset, so its corner is the popup's less that inset.
  expect(popup).toContain(
    "border-radius: max(var(--cmux-menu-highlight-radius), calc(var(--ui-popup-radius) - var(--cmux-menu-highlight-inset)));",
  );
  const style = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/PopupStyle.swift");
  expect(style).toContain("Metrics.cornerRadius(nestedIn: cornerRadius, inset: padding)");
  expect(style).toContain("Metrics.cornerRadius(nestedIn: cornerRadius, inset: MenuMetrics.highlightInset)");
});

test("the native and web dialog are one radius: the button corner plus one padding", () => {
  expect(dialog.padding).toBe(12);
  const tokens = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesignTokens/DesignTokens.swift");
  expect(tokens).toContain(`nonisolated static let dialogPadding: CGFloat = ${dialog.padding}`);
  // Web: corner = --ds-radius-control (the host's button corner) + --ui-dialog-padding (the scale's dialog padding).
  const popup = repo("webviews/src/ui/popupSurface.css");
  expect(popup).toContain("--ui-dialog-padding: var(--ds-dialog-padding);");
  expect(popup).toContain("border-radius: calc(var(--ds-radius-control) + var(--ui-dialog-padding));");
  expect(repo("webviews/src/pages/shared/desktop.css")).toContain(
    `--ds-dialog-padding: var(--cmux-dialog-padding, ${dialog.padding}px);`,
  );
  // Native: corner = Metrics.buttonCornerRadius (the same button corner the host hands the page) + cardPadding,
  // and cardPadding is the same variant's padding the host hands the page as --cmux-dialog-padding.
  const metrics = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Dialog/CmuxDialogButtonView.swift");
  expect(metrics).toContain("static var card: ConcentricContainer { Metrics.buttonContainer(padding: cardPadding) }");
  expect(metrics).toContain(
    "static var cardPadding: CGFloat { DialogCornerLook.current.nativePadding * Typography.userScale }",
  );
  const look = repo("Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Tunables/SurfaceCornerLooks.swift");
  expect(look).toContain("case .reference: DesignTokens.dialogPadding");
  expect(look).toContain('"--cmux-dialog-padding"');
  expect(look).toContain('"--cmux-popup-radius"');
  // The shipped variant's native and web paddings are equal; only the `split` variant (today's look) differs.
  expect(look).toMatch(/var webPadding: CGFloat \{\s*switch self \{\s*case \.reference, \.round: nativePadding/);
});
