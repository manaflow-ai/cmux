// The goldens here are copies of cmux-tui/crates/cmux-ui-surfaces/tests/golden/*.json (the gallery's
// UiSurfaceGolden page and uiSurfaceStreamFixture.ts import them; CI's webviews checkout has nothing
// outside webviews/). This only checks their shape: each is `{sample, surfaces: [...]}` and every surface
// reads as a `cmux.ui-surface/1` surface. It does not compare them with Rust's files.
import { expect, test } from "bun:test";
import { readUiSurface } from "../model";
import openingForm from "./10-opening-form.json";
import refineSearch from "./30-refine-search.json";
import homeDashboard from "./60-home-dashboard.json";
import travelerForm from "./70-traveler-form.json";
import cmuxCatalogCards from "./cmux-catalog-cards.json";
import cmuxPending from "./cmux-pending.json";
import contactForm from "./contact_form_example.json";
import mcpAppFrame from "./mcp-app-frame.json";
import restaurantCard from "./restaurant-card.json";

const GOLDENS: Record<string, unknown> = {
  "10-opening-form": openingForm,
  "30-refine-search": refineSearch,
  "60-home-dashboard": homeDashboard,
  "70-traveler-form": travelerForm,
  "cmux-catalog-cards": cmuxCatalogCards,
  "cmux-pending": cmuxPending,
  contact_form_example: contactForm,
  "mcp-app-frame": mcpAppFrame,
  "restaurant-card": restaurantCard,
};

for (const [name, golden] of Object.entries(GOLDENS)) {
  test(`golden ${name} reads as agent UI surfaces`, () => {
    const file = golden as { sample?: unknown; surfaces?: unknown };
    expect(typeof file.sample).toBe("string");
    expect(Array.isArray(file.surfaces)).toBe(true);
    const surfaces = file.surfaces as unknown[];
    expect(surfaces.length).toBeGreaterThan(0);
    for (const value of surfaces) {
      const surface = readUiSurface(value);
      expect(surface).toBeDefined();
      expect(surface?.schema).toBe("cmux.ui-surface/1");
    }
  });
}
