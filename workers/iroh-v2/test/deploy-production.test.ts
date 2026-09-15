import { expect, test } from "bun:test";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

async function probe(scenario: string) {
  const directory = await mkdtemp(join(tmpdir(), "iroh-deploy-test-"));
  try {
    for (const command of ["bun", "wrangler"]) {
      await writeFile(join(directory, command), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    }
    await writeFile(join(directory, "curl"), `#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
output = pathlib.Path(args[args.index('-o') + 1])
name = output.name.split('.')[0]
scenario = os.environ['PROBE_SCENARIO']
status = '401' if name == 'production' else '403'
code = 'unauthorized' if name == 'production' else 'environment_mismatch'
if scenario == 'wrong-code': code = 'permission_denied'
if scenario == 'unbounded' and not all(flag in args for flag in ['--connect-timeout', '--max-time']): sys.exit(28)
output.write_text(json.dumps({'schemaId': 'error.v1', 'code': code, 'message': 'private-response-marker'}))
print(status, end='')
`, { mode: 0o700 });
    const result = Bun.spawnSync(["bash", join(import.meta.dir, "../scripts/deploy-production.sh")], {
      cwd: join(import.meta.dir, ".."),
      env: { ...process.env, PATH: directory + ":" + process.env.PATH,
        CLOUDFLARE_ACCOUNT_ID: "0c1675e0def6de1ab3a50a4e17dc5656", PROBE_SCENARIO: scenario },
      stdout: "pipe", stderr: "pipe",
    });
    return { exit: result.exitCode, output: result.stdout.toString() + result.stderr.toString() };
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test("expected scope failures pass the production configuration check", async () => {
  expect((await probe("valid")).exit).toBe(0);
});

test("matching HTTP status with the wrong error code fails without disclosing the response", async () => {
  const result = await probe("wrong-code");
  expect(result.exit).not.toBe(0);
  expect(result.output).not.toContain("private-response-marker");
});

test("production scope probes bound connection and total request time", async () => {
  expect((await probe("unbounded")).exit).toBe(0);
});
