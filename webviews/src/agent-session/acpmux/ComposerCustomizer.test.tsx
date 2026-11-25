import { afterEach, describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { setExperimentSwitches } from "../../experiments/switches";
import { ComposerCustomizer } from "./ComposerCustomizer";

afterEach(() => setExperimentSwitches({}));

describe("ComposerCustomizer", () => {
  test("draws nothing while experiments.composerCustomizer is off (the default)", () => {
    expect(renderToStaticMarkup(<ComposerCustomizer />)).toBe("");
  });

  test("draws the Customize button once the switch is on", () => {
    setExperimentSwitches({ composerCustomizer: true });
    const html = renderToStaticMarkup(<ComposerCustomizer />);
    expect(html).toContain('class="acpmux-composer-customize"');
    expect(html).toContain('aria-haspopup="menu"');
    expect(html).toContain("Customize");
  });
});
