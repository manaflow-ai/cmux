import { expect, setDefaultTimeout, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

setDefaultTimeout(20_000);

async function probe(scenario: string, options: { missingCurl?: boolean } = {}) {
  const directory = await mkdtemp(join(tmpdir(), "iroh-deploy-test-"));
  const state = join(directory, "state.json");
  const calls = join(directory, "calls.log");
  try {
    await writeFile(join(directory, "bun"), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    await writeFile(join(directory, "python3"), "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n", { mode: 0o700 });
    const helperCommands: Array<[string, string]> = [["mktemp", "/usr/bin/mktemp"], ["rm", "/bin/rm"], ["cat", "/bin/cat"]];
    for (const [command, path] of helperCommands) {
      await writeFile(join(directory, command), `#!/bin/sh\nexec ${path} \"$@\"\n`, { mode: 0o700 });
    }
    await writeFile(join(directory, "wrangler"), `#!/usr/bin/env python3
import json, os, pathlib, sys
state_path = pathlib.Path(os.environ['MOCK_STATE'])
calls_path = pathlib.Path(os.environ['MOCK_CALLS'])
args = sys.argv[1:]
with calls_path.open('a') as calls:
    calls.write(' '.join(args) + '\\n')

def status(annotations):
    return {'created_on': '2026-09-15T00:00:00.000Z', 'annotations': annotations,
            'versions': [{'version_id': 'old-version', 'percentage': 100}]}

if args[:2] == ['deployments', 'status']:
    print(state_path.read_text())
elif args[:2] == ['deployments', 'list']:
    print(json.dumps({'deployments': [json.loads(state_path.read_text())]}))
elif args and args[0] == 'deploy':
    marker = args[args.index('--message') + 1]
    annotations = {'workers/message': marker, 'workers/tag': marker}
    if os.environ['PROBE_SCENARIO'] == 'concurrent':
        annotations = {'workers/message': 'someone-else', 'workers/tag': 'someone-else'}
    state_path.write_text(json.dumps(status(annotations)))
elif args and args[0] == 'rollback':
    state_path.write_text(json.dumps(status({'workers/message': 'old', 'workers/tag': 'old'})))
`, { mode: 0o700 });
    if (!options.missingCurl) {
      await writeFile(join(directory, "curl"), `#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if not all(flag in args for flag in ['--connect-timeout', '--max-time', '--max-filesize']): sys.exit(28)
output = pathlib.Path(args[args.index('-o') + 1])
name = output.name.split('.')[0]
calls = pathlib.Path(os.environ['MOCK_CURL_CALLS'])
count = int(calls.read_text() or '0') + 1 if calls.exists() else 1
calls.write_text(str(count))
status = '401' if name == 'production' else '403'
code = 'unauthorized' if name == 'production' else 'environment_mismatch'
if os.environ['PROBE_SCENARIO'] == 'wrong-code' and count > 2: code = 'permission_denied'
if os.environ['PROBE_SCENARIO'] in ('post-failure', 'concurrent') and count > 2: status, code = '500', 'internal_error'
output.write_text(json.dumps({'schemaId': 'error.v1', 'code': code, 'message': 'private-response-marker'}))
print(status, end='')
`, { mode: 0o700 });
    }
    await writeFile(state, JSON.stringify({
      created_on: "2026-09-14T00:00:00.000Z",
      annotations: { "workers/message": "old", "workers/tag": "old" },
      versions: [{ version_id: "old-version", percentage: 100 }],
    }));
    await writeFile(join(directory, "curl-calls"), "0");
    const pathEntries = [directory];
    const result = Bun.spawnSync(["/bin/bash", join(import.meta.dir, "../scripts/deploy-production.sh")], {
      cwd: join(import.meta.dir, ".."),
      env: {
        ...process.env,
        PATH: pathEntries.join(":"),
        CLOUDFLARE_ACCOUNT_ID: "0c1675e0def6de1ab3a50a4e17dc5656",
        PROBE_SCENARIO: scenario,
        MOCK_STATE: state,
        MOCK_CALLS: calls,
        MOCK_CURL_CALLS: join(directory, "curl-calls"),
      },
      stdout: "pipe", stderr: "pipe",
    });
    return {
      exit: result.exitCode,
      output: result.stdout.toString() + result.stderr.toString(),
      calls: await readFile(calls, "utf8").catch(() => ""),
    };
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

test("failed post-deploy verification rolls back the previously verified version", async () => {
  const result = await probe("post-failure");
  expect(result.exit).not.toBe(0);
  expect(result.calls).toContain("rollback old-version");
  expect(result.output).toContain("restored the previously verified Worker version");
});

test("a concurrent replacement prevents an unsafe rollback", async () => {
  const result = await probe("concurrent");
  expect(result.exit).not.toBe(0);
  expect(result.calls).not.toContain("rollback old-version");
  expect(result.output).toContain("rollback was skipped");
});

test("missing curl is rejected before running checks or deployment", async () => {
  const result = await probe("valid", { missingCurl: true });
  expect(result.exit).toBe(2);
  expect(result.output).toContain("required command not found: curl");
});
