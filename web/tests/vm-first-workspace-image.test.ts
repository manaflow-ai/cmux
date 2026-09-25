import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { devboxPrepareTemplateTerminalCommand } from "../scripts/devbox-image-common";

describe("first-workspace image contract", () => {
  test.each([true, false])("only a capable daemon prepares a deferred starter (%s)", (capable) => {
    const root = mkdtempSync(join(tmpdir(), "cmux-first-workspace-image-"));
    try {
      const bin = join(root, "bin");
      const config = join(root, "config");
      const home = join(root, "home");
      for (const dir of [bin, config, join(home, ".cmux/bin")]) mkdirSync(dir, { recursive: true });
      writeFileSync(join(config, "cloud-first-workspace-v1"), "");
      writeFileSync(join(bin, "id"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
      writeFileSync(join(bin, "install"), '#!/bin/sh\nfor arg do target="$arg"; done\nmkdir -p "$target"\n', { mode: 0o755 });
      writeFileSync(join(home, ".cmux/bin/cmux-tui"), `#!/bin/sh
case "$*" in
  *'--json raw command'*identify*) printf '%s\\n' '${JSON.stringify({ capabilities: capable ? ["cloud-first-workspace-v1"] : [] })}' ;;
  *'terminal list'*) printf '%s\\n' '{"terminals":[{"id":"term_builder"}]}' ;;
  *'terminal term_builder close'*) printf '%s\\n' closed >> '${root}/calls' ;;
  *) printf '%s\\n' "unexpected: $*" >&2; exit 1 ;;
esac
`, { mode: 0o755 });
      const command = devboxPrepareTemplateTerminalCommand()
        .replaceAll("/tmp/cmux-", `${root}/cmux-`)
        .replaceAll("/etc/cmux", config)
        .replaceAll("/run/cmux", join(root, "run"))
        .replaceAll("/root", home);
      const result = spawnSync("sh", ["-c", command], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
        encoding: "utf8", timeout: 5_000,
      });
      if (capable) {
        expect({ status: result.status, stderr: result.stderr }).toEqual({ status: 0, stderr: "" });
        expect(result.stdout).toContain("first-workspace-reserved");
        expect(readFileSync(join(root, "calls"), "utf8")).toBe("closed\n");
      } else {
        expect(result.status).not.toBe(0);
        expect(() => readFileSync(join(root, "calls"))).toThrow();
      }
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
