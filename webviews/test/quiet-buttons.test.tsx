import { afterEach, describe, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { setExperimentSwitches } from "../src/experiments/switches";
import { Button, defaultButtonVariant } from "../src/ui/Button";

// Design D2 (D-icons-buttons-accent-motion-keyhints.md): "Quiet is the default: no plate
// and no outline at rest". Built behind the default-off quietButtons experiment.
describe("quiet buttons experiment", () => {
  afterEach(() => setExperimentSwitches({}));

  test("switch off keeps today's subtle plate", () => {
    expect(defaultButtonVariant(false)).toBe("subtle");
    expect(renderToString(<Button>Go</Button>)).toContain('data-variant="subtle"');
  });

  test("switch on renders unvarianted buttons quiet", () => {
    setExperimentSwitches({ quietButtons: true });
    expect(defaultButtonVariant(true)).toBe("ghost");
    expect(renderToString(<Button>Go</Button>)).toContain('data-variant="ghost"');
  });

  test("an explicit variant wins either way", () => {
    for (const on of [false, true]) {
      setExperimentSwitches({ quietButtons: on });
      expect(renderToString(<Button variant="solid">Go</Button>)).toContain('data-variant="solid"');
      expect(renderToString(<Button variant="subtle">Go</Button>)).toContain('data-variant="subtle"');
    }
  });
});
