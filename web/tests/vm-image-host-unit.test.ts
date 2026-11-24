import { describe, expect, test } from "bun:test";
import { HOST_RUN, hostUnit } from "../scripts/cmux-vm-image/host-agent";

describe("image host unit", () => {
  test("the host runs as root with its exact startup, even with a transport environment variable", () => {
    for (const env of [[], ["Environment=CLOUD_VM_TRANSPORT=vm-api"]]) {
      const unit = hostUnit(env, "/opt/cmux/current/bin");
      expect(unit.split("\n").filter((line) => line.startsWith("ExecStart="))).toEqual([`ExecStart=${HOST_RUN}`]);
      expect(unit.split("\n").filter((line) => line.startsWith("User="))).toEqual(["User=root"]);
      expect(unit).not.toContain("--native-receiver");
      expect(unit).not.toContain("--roles-only");
    }
  });
});
