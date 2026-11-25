// l10n-allow-file: test of gallery-only arms.
// The intro walk's gallery arms (walkArms.tsx): each renders, picks stay local, and the shipped
// first-run screen (the default arm) renders exactly as before.
import { afterAll, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { installDom } from "../settings/testDom";
import { createStrings } from "../shared/i18n";
import { WALK_BUNDLES, makeItYoursState } from "./fixtures";
import entry from "./Onboarding.gallery";
import { OnboardingGallery, type OnboardingGalleryProps } from "./galleryFixture";
import table from "./generated/strings.json";
import { OnboardingPage } from "./Onboarding";
import { OnboardingStore } from "./store";

const restore = installDom();
afterAll(restore);

const strings = createStrings(table);
const variants = entry.variants as Record<string, { props: OnboardingGalleryProps }>;
const walkVariants = Object.keys(variants).filter((name) => name.startsWith("walk-"));
const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("intro walk gallery arms", () => {
  test("three or more arms for each contested step, and the footer pair", () => {
    const count = (prefix: string) => walkVariants.filter((name) => name.startsWith(prefix)).length;
    expect(count("walk-look-")).toBeGreaterThanOrEqual(3);
    expect(count("walk-trust-")).toBeGreaterThanOrEqual(3);
    expect(count("walk-tune-")).toBeGreaterThanOrEqual(3);
    expect(count("walk-exit-")).toBeGreaterThanOrEqual(3);
    expect(count("walk-footer-")).toBeGreaterThanOrEqual(2);
  });

  for (const name of walkVariants)
    test(`${name} renders in the onboarding window`, () => {
      const html = renderToStaticMarkup(<OnboardingGallery {...variants[name]!.props} />);
      expect(html).toContain('class="onb-scaffold"');
      expect(html).toContain("onb-walk");
      expect(text(html)).toMatch(/Continue|Start/);
    });

  test("every look arm shows all five bundles, each with a light and a dark face", () => {
    for (const name of ["walk-look-a-grid", "walk-look-b-hero", "walk-look-c-list"]) {
      const html = renderToStaticMarkup(<OnboardingGallery {...variants[name]!.props} />);
      for (const bundle of WALK_BUNDLES) expect(text(html)).toContain(bundle.name);
      expect(html.match(/data-face="light"/g)?.length).toBeGreaterThanOrEqual(WALK_BUNDLES.length);
      expect(html.match(/data-face="dark"/g)?.length).toBeGreaterThanOrEqual(WALK_BUNDLES.length);
    }
  });

  test("trust and noise open on the shipped values", async () => {
    const root = document.createElement("div");
    document.body.append(root);
    const page = createRoot(root);
    await act(async () => page.render(<OnboardingGallery {...variants["walk-trust-a-rows"]!.props} />));
    const picked = Object.fromEntries(
      [...root.querySelectorAll<HTMLInputElement>('input[type="radio"]')]
        .filter((input) => input.checked)
        .map((input) => [input.name, input.value]),
    );
    expect(picked).toEqual({ walkPermission: "fullAccess", walkNoise: "bannersSound" });
    await act(async () => page.unmount());
    root.remove();
  });

  test("the Undo / Redo footer steps back through picks", async () => {
    const root = document.createElement("div");
    document.body.append(root);
    const page = createRoot(root);
    await act(async () => page.render(<OnboardingGallery {...variants["walk-footer-undo-redo"]!.props} />));
    const button = (label: string) =>
      [...root.querySelectorAll<HTMLButtonElement>("button")].find((b) => b.textContent?.startsWith(label))!;
    const look = () => root.querySelector<HTMLInputElement>('input[name="walkLook"]:checked')!.value;
    expect(look()).toBe("house");
    expect(button("Undo").disabled).toBe(false);
    await act(async () => root.querySelector<HTMLInputElement>('input[value="glasshouse"]')!.click());
    expect(look()).toBe("glasshouse");
    await act(async () => button("Undo").click());
    expect(look()).toBe("house");
    expect(button("Redo").disabled).toBe(false);
    await act(async () => button("Redo").click());
    expect(look()).toBe("glasshouse");
    await act(async () => page.unmount());
    root.remove();
  });

  test("the shipped screen is unchanged: the default arm renders as the page alone", () => {
    expect(variants["make-it-yours-cards"]!.props).toEqual({
      step: "makeItYours",
      makeItYours: "fresh",
      makeLook: "cards",
    });
    const gallery = renderToStaticMarkup(<OnboardingGallery {...variants["make-it-yours-cards"]!.props} />);
    const page = renderToStaticMarkup(
      <OnboardingPage
        store={new OnboardingStore(null, makeItYoursState("fresh"))}
        strings={strings}
        makeItYoursLook="cards"
      />,
    );
    // The gallery wraps the page in a display:contents div (its sign-in fixtures click inside it); nothing else differs.
    expect(gallery).toBe(`<div style="display:contents">${page}</div>`);
    expect(gallery).not.toContain("onb-walk");
  });
});
