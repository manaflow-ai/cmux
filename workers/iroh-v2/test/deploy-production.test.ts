import { expect, setDefaultTimeout, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

setDefaultTimeout(20_000);

/** Inherited repository-selection variables must not reach the deployment script's Git calls. */
const GIT_SELECTION_VARIABLES = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"];
const cleanEnvironment = Object.fromEntries(Object.entries(process.env).filter(([key]) => !GIT_SELECTION_VARIABLES.includes(key)));
const MOCK_HEAD = "0123456789abcdef0123456789abcdef01234567";

async function probe(scenario: string, options: { missingCurl?: boolean; dirtyTree?: boolean; environment?: "production" | "staging" } = {}) {
  const directory = await mkdtemp(join(tmpdir(), "iroh-deploy-test-"));
  const state = join(directory, "state.json");
  const calls = join(directory, "calls.log");
  try {
    await writeFile(join(directory, "bun"), "#!/bin/sh\nprintf 'bun %s\\n' \"$*\" >> \"$MOCK_CALLS\"\ncase \"$1\" in scripts/*) exec \"$REAL_BUN\" \"$@\" ;; esac\nexit 0\n", { mode: 0o700 });
    await writeFile(join(directory, "python3"), "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n", { mode: 0o700 });
    const helperCommands: Array<[string, string]> = [
      ["mktemp", "/usr/bin/mktemp"], ["rm", "/bin/rm"], ["cat", "/bin/cat"],
      // scripts/source-revision-vars.sh runs through bash; git is mocked below.
      ["bash", "/bin/bash"],
    ];
    for (const [command, path] of helperCommands) {
      await writeFile(join(directory, command), `#!/bin/sh\nexec ${path} \"$@\"\n`, { mode: 0o700 });
    }
    // A hermetic Git: one fixed HEAD, and a clean or dirty tree per scenario,
    // so the published revision is asserted exactly regardless of the developer's checkout.
    await writeFile(join(directory, "git"), `#!/bin/sh
case "$*" in
  "rev-parse --verify HEAD") exit 0 ;;
  "merge-base --is-ancestor ${MOCK_HEAD} origin/main") [ "$PROBE_SCENARIO" != "unmerged" ] ;;
  "rev-parse HEAD") printf '%s\\n' "${MOCK_HEAD}" ;;
  "status --porcelain -- .") ${options.dirtyTree ? "printf ' M src/index.ts\\n'" : "exit 0"} ;;
  *) exit 1 ;;
esac
`, { mode: 0o700 });
    await writeFile(join(directory, "wrangler"), `#!/usr/bin/env python3
import json, os, pathlib, sys
state_path = pathlib.Path(os.environ['MOCK_STATE'])
calls_path = pathlib.Path(os.environ['MOCK_CALLS'])
args = sys.argv[1:]
with calls_path.open('a') as calls:
    calls.write('wrangler ' + ' '.join(args) + '\\n')

def status(annotations, created='2026-09-15T00:00:00.000Z'):
    return {'created_on': created, 'annotations': annotations,
            'versions': [{'version_id': 'old-version', 'percentage': 100}]}

if args[:2] == ['deployments', 'status']:
    print(state_path.read_text())
elif args[:2] == ['versions', 'view']:
    migration_tag = 'older-tag' if os.environ['PROBE_SCENARIO'] == 'pending-migration' else 'iroh-v2-fresh-storage-1'
    bindings = [{'name':'TEAM_CONTROL','type':'durable_object_namespace','class_name':'TeamControl','namespace_id':'team-ns'},
                {'name':'USER_USAGE','type':'durable_object_namespace','class_name':'UserUsage','namespace_id':'user-ns'},
                {'name':'CMUX_SOURCE_REVISION','type':'plain_text','text':'${MOCK_HEAD}'}]
    if os.environ['PROBE_SCENARIO'] == 'script-migration-resource':
        print(json.dumps({'id': 'old-version', 'resources': {'bindings': bindings, 'script': {'migration_tag': migration_tag}}}))
    else:
        print(json.dumps({'id': 'old-version', 'resources': {'bindings': bindings, 'script_runtime': {'migration_tag': migration_tag}}}))
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
for flag, expected in [('--connect-timeout', '10'), ('--max-time', '30'), ('--max-filesize', '65536')]:
    try:
        if args[args.index(flag) + 1] != expected: sys.exit(28)
    except (ValueError, IndexError):
        sys.exit(28)
url = next(value for value in args if value.startswith('https://'))
if os.environ['PROBE_SCENARIO'] == 'canonical-target' and not any(url.startswith(origin) for origin in ('https://cmux-v2.debussy.workers.dev/v2/', 'https://cmux-v2-staging.debussy.workers.dev/v2/')): sys.exit(97)
if args[-1].endswith('/v2/health'):
    deployment=json.loads(pathlib.Path(os.environ['MOCK_STATE']).read_text())
    deployed=deployment.get('annotations',{}).get('workers/message','') != 'old'
    health={'schemaId':'health.v1','environment':('staging' if 'cmux-v2-staging' in url else 'production'),'sourceRevision':'${MOCK_HEAD}','rules':['cmux.mac-peer-inbound.v1'],'storage':{'maxSchemaVersion':7,'writeSchemaVersion':6}}
    scenario=os.environ['PROBE_SCENARIO']
    status='200'
    if scenario=='unknown-storage' and not deployed: health.pop('storage')
    if scenario=='staging-mismatch' and 'cmux-v2-staging' in url: health['sourceRevision']='f'*40
    if scenario=='post-health-failure' and deployed: health['rules']=[]
    if scenario in ('late-pre-change','late-post-change') and 'cmux-v2-staging' not in url and deployed == (scenario=='late-post-change'):
        deployment['created_on']='2026-09-15T04:00:00.000Z'
        deployment['annotations']={'workers/message':'someone-else'}
        pathlib.Path(os.environ['MOCK_STATE']).write_text(json.dumps(deployment))
    pathlib.Path(args[args.index('-o')+1]).write_text(json.dumps(health))
    print(status,end=''); sys.exit(0)
payload_path = args[args.index('--data-binary') + 1][1:]
payload = json.loads(pathlib.Path(payload_path).read_text())
name = pathlib.Path(args[args.index('-o') + 1]).name.split('.')[0]
identity = payload['device']['identity']
expected = {
    'production': ('production', '9790718f-14cd-4f7e-824d-eaf527a82b82') if os.environ['PROBE_ENVIRONMENT']=='production' else ('staging', '454ecd03-1db2-4050-845e-4ce5b0cd9895'),
    'development': ('development', '454ecd03-1db2-4050-845e-4ce5b0cd9895') if os.environ['PROBE_ENVIRONMENT']=='production' else ('production', '9790718f-14cd-4f7e-824d-eaf527a82b82'),
}[name]
if (identity['environment'], identity['projectId']) != expected: sys.exit(97)
calls = pathlib.Path(os.environ['MOCK_CURL_CALLS'])
count = int(calls.read_text() or '0') + 1 if calls.exists() else 1
calls.write_text(str(count))
if os.environ['PROBE_SCENARIO'] in ('pre-pair-changed', 'pair-changed') and ((os.environ['PROBE_SCENARIO'] == 'pre-pair-changed' and count == 1) or (os.environ['PROBE_SCENARIO'] == 'pair-changed' and count == 3)):
    state = json.loads(pathlib.Path(os.environ['MOCK_STATE']).read_text())
    state['created_on'] = '2026-09-15T01:00:00.000Z'
    state['annotations'] = {'workers/message': 'someone-else', 'workers/tag': 'someone-else'}
    pathlib.Path(os.environ['MOCK_STATE']).write_text(json.dumps(state))
status = '401' if name == 'production' else '403'
code = 'unauthorized' if name == 'production' else 'environment_mismatch'
if os.environ['PROBE_SCENARIO'] == 'wrong-code' and count > 2: code = 'permission_denied'
if os.environ['PROBE_SCENARIO'] in ('post-failure', 'concurrent') and count > 2: status, code = '500', 'internal_error'
output = pathlib.Path(args[args.index('-o') + 1])
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
    const result = Bun.spawnSync(["/bin/bash", join(import.meta.dir, "../scripts/deploy-production.sh"), options.environment ?? "production"], {
      cwd: join(import.meta.dir, ".."),
      env: {
        ...cleanEnvironment,
        PATH: directory,
        REAL_BUN: process.execPath,
        CLOUDFLARE_ACCOUNT_ID: "0c1675e0def6de1ab3a50a4e17dc5656",
        PROBE_SCENARIO: scenario,
        PROBE_ENVIRONMENT: options.environment ?? "production",
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
  const result = await probe("valid");
  expect(result.exit).toBe(0);
  expect(result.calls).toMatch(/--message cmux-prod-guard-[0-9a-f-]{36}/);
  // The health route reports this value; the drift check compares it with main.
  expect(result.calls).toContain(`--var CMUX_SOURCE_REVISION:${MOCK_HEAD}`);
});

test("a dirty tree is refused before any upload", async () => {
  const result = await probe("valid", { dirtyTree: true });
  expect(result.exit).not.toBe(0);
  expect(result.calls).not.toContain("wrangler deploy ");
  expect(result.output).toContain("publishing CMUX_SOURCE_REVISION=unknown");
});

test("matching HTTP status with the wrong error code fails without disclosing the response", async () => {
  const result = await probe("wrong-code");
  expect(result.exit).not.toBe(0);
  expect(result.output).not.toContain("private-response-marker");
});

test("scope probes validate payloads and bound timeout values", async () => {
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
  expect(result.output).toContain("active deployment changed, so rollback was skipped");
});

test("a deployment change during pre-deploy probes aborts before deployment", async () => {
  const result = await probe("pre-pair-changed");
  expect(result.exit).not.toBe(0);
  expect(result.calls).not.toContain("deploy --env production");
  expect(result.output).toContain("active deployment changed");
});

test("a deployment change during post-deploy probes fails without rollback", async () => {
  const result = await probe("pair-changed");
  expect(result.exit).not.toBe(0);
  expect(result.calls).toContain("deploy --env production");
  expect(result.calls).not.toContain("rollback old-version");
  expect(result.output).toContain("active deployment changed");
});

test("pending Durable Object migrations are refused before deployment", async () => {
  const result = await probe("pending-migration");
  expect(result.exit).not.toBe(0);
  expect(result.calls).not.toContain("deploy --env production");
  expect(result.output).toContain("pending Durable Object migration");
});

test("reads the migration tag from the Worker script resource shape", async () => {
  const result = await probe("script-migration-resource");
  expect(result.exit).toBe(0);
  expect(result.calls).toMatch(/--message cmux-prod-guard-[0-9a-f-]{36}/);
});

test("missing curl is rejected before running checks or deployment", async () => {
  const result = await probe("valid", { missingCurl: true });
  expect(result.exit).toBe(2);
  expect(result.output).toContain("required command not found: curl");
  expect(result.calls).toBe("");
});


test("deployment scope checks reach the canonical Worker, never its forwarding alias", async () => {
  const result = await probe("canonical-target");
  expect(result.exit).toBe(0);
  expect(result.calls).toContain("--name cmux-v2");
  expect(result.calls).not.toContain("--name cmux-iroh-v2");
});


test("staging uses the same guards with its own environment and project", async () => {
  const result = await probe("valid", {environment: "staging"});
  expect(result.exit).toBe(0);
  expect(result.calls).toContain("--name cmux-v2-staging");
  expect(result.calls).toContain("wrangler deploy --env staging --keep-vars --strict");
});

test.each(["unknown-storage", "staging-mismatch", "late-pre-change", "unmerged"])("%s refuses before uploading", async scenario => {
  const result = await probe(scenario);
  expect(result.exit).not.toBe(0);
  expect(result.calls).not.toContain("wrangler deploy ");
  expect(result.calls).not.toContain("wrangler rollback ");
});

test("post-deploy missing Mac rule rolls back only to the verified compatible reader", async () => {
  const result = await probe("post-health-failure");
  expect(result.exit).not.toBe(0);
  expect(result.calls).toContain("wrangler rollback old-version");
});

test("a concurrent replacement during health verification is never rolled back", async () => {
  const result = await probe("late-post-change");
  expect(result.exit).not.toBe(0);
  expect(result.calls).not.toContain("wrangler rollback ");
});
