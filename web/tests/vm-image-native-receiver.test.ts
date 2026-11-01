import { describe, expect, test } from "bun:test";
import { HOST_RUN, hostUnit } from "../scripts/cmux-vm-image/host-agent";

describe("Native image startup", () => {
  test("direct images retain their exact startup, even with a transport environment variable", () => {
    for (const env of [[], ["Environment=CLOUD_VM_TRANSPORT=vm-api"]]) {
      const unit = hostUnit(env, "/opt/cmux/current/bin");
      expect(unit.split("\n").find((line) => line.startsWith("ExecStart="))).toBe(`ExecStart=${HOST_RUN}`);
      expect(unit).not.toContain("--native-receiver");
    }
  });

  test("only an opted-in image starts the root receiver, with no legacy private entry", () => {
    const unit = hostUnit([], "/opt/cmux/current/bin", true);
    expect(unit.split("\n").filter((line) => line.startsWith("ExecStart="))).toEqual([`ExecStart=${HOST_RUN} --native-receiver`]);
    expect(unit.split("\n").filter((line) => line.startsWith("User="))).toEqual(["User=root"]);
    expect(unit).not.toContain("--link-entry");
    expect(unit).not.toContain("--roles-only");
  });
});
