import { describe, expect, test } from "bun:test";
import { screenLink } from "../app/[locale]/(landing)/deeplink/[kind]/deeplink-screen";

const DEVICE = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";

describe("screen deeplink", () => {
  test("a device and display make the mac-screen link, view-only", () => {
    const link = screenLink({ device: DEVICE, display: "3" });
    expect(link.model?.href).toBe(`cmux://mac-screen?device=${DEVICE}&display=3`);
    expect(link.ignored).toEqual([]);
  });

  test("device alone opens the default display; the id is lowercased", () => {
    const link = screenLink({ device: DEVICE.toUpperCase() });
    expect(link.model?.href).toBe(`cmux://mac-screen?device=${DEVICE}`);
  });

  test("control=1 and a name ride along", () => {
    const link = screenLink({ device: DEVICE, display: "12", control: "1", name: "run 7" });
    expect(link.model?.href).toBe(
      `cmux://mac-screen?device=${DEVICE}&display=12&control=1&name=run%207`,
    );
  });

  test("a missing, bad or repeated device refuses the link", () => {
    expect(screenLink({}).missing).toEqual(["device"]);
    expect(screenLink({ device: "nope" }).invalid).toEqual(["device"]);
    expect(screenLink({ device: [DEVICE, DEVICE] }).duplicates).toEqual(["device"]);
    expect(screenLink({ device: "nope" }).model).toBeNull();
  });

  test("an unusable hint is ignored by name, never echoed, and the link still opens", () => {
    const link = screenLink({
      device: DEVICE,
      display: "abc",
      control: "0",
      name: "<script>",
      "x<y>": "1",
    });
    expect(link.model?.href).toBe(`cmux://mac-screen?device=${DEVICE}`);
    expect(link.ignored).toEqual(["display", "control", "name", "xy"]);
  });
});
