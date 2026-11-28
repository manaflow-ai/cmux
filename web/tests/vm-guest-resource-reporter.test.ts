import { expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { GUEST_RESOURCE_SAMPLE_SCRIPT, guestResourceSampleCommand, guestResourceReporterInstallCommand, guestResourceReporterScript } from "../services/vms/guestResourceReporter";

/** Runs the sampling script against fake CPU and memory counters and returns the sample. */
async function runCounterFixture(cpu: string[], meminfo: string) {
  const harness = `import builtins,io,json,os,sys,time,types
fixture=json.loads(sys.argv[1])
counters=iter(fixture['cpu'])
def read(path):
    if path == '/proc/stat': return io.StringIO(next(counters))
    if path == '/proc/meminfo': return io.StringIO(fixture['meminfo'])
    raise AssertionError(path)
builtins.open=read
time.sleep=lambda duration: None
os.statvfs=lambda path: types.SimpleNamespace(f_blocks=10000,f_bfree=4000,f_bavail=3500,f_frsize=4096)
exec(sys.stdin.read())
print(json.dumps(sample()))
`;
  const result = await runChild("python3", ["-c", harness, JSON.stringify({ cpu, meminfo })], {
    input: GUEST_RESOURCE_SAMPLE_SCRIPT,
  });
  expect(result.status).toBe(0);
  return JSON.parse(result.stdout);
}

test("samples CPU deltas without double-counting guest ticks, reclaimable RAM, and root filesystem use", async () => {
  const stats = await runCounterFixture([
    "cpu 100 0 50 800 50 0 0 0 80 0\n",
    "cpu 120 0 60 850 70 0 0 0 90 0\n",
  ], "MemTotal: 4194304 kB\nMemAvailable: 3145728 kB\nCached: 2000000 kB\n");
  expect(stats.cpuPercent).toBeCloseTo(30);
  expect(stats.memoryUsedMb).toBe(1024);
  expect(stats.diskUsedMb).toBe(23);
});

test("counter resets and incomplete memory counters leave those gauges missing", async () => {
  const stats = await runCounterFixture(["cpu 100 0 50 800 50 0 0 0\n", "cpu 10 0 5 80 5 0 0 0\n"], "MemTotal: 4096 kB\n");
  expect(stats).toEqual({ diskUsedMb: 23 });
});

test("the actual reporter posts the sample through the alias and then waits for its cadence", async () => {
  const harness = `import io,json,sys,time,urllib.request
class Finished(BaseException): pass
original_sleep=time.sleep
def sleep(duration):
    if duration == 30: raise Finished()
    original_sleep(duration)
time.sleep=sleep
def post(request,timeout,context):
    print(json.dumps({'url':request.full_url,'method':request.method,'body':json.loads(request.data),'headers':dict(request.headers),'timeout':timeout}))
    response = io.BytesIO(b'')
    response.status = 204
    return response
urllib.request.urlopen=post
try: exec(sys.stdin.read())
except Finished: pass
`;
  const result = await runChild("python3", ["-c", harness], { input: guestResourceReporterScript() });
  expect(result.status).toBe(0);
  const sent = JSON.parse(result.stdout);
  expect(sent.url).toBe("https://coderouter.cmux.internal/api/vm/resource-usage/self");
  expect(sent.method).toBe("POST");
  expect(sent.headers.Authorization).toBe("Bearer cmux-vm-edge-placeholder");
  expect(sent.timeout).toBe(5);
  // Disk is available on macOS too; Linux additionally supplies CPU and RAM.
  expect(sent.body.diskUsedMb).toBeGreaterThanOrEqual(0);
}, 15_000);

test("the journal records reporter transitions and recovery without leaking request or error contents", async () => {
  const harness = `import builtins,io,os,sys,time,urllib.error,urllib.request
class Finished(BaseException): pass
steps = [204, 401, 401, 503, 'transport', 'transport', 'sample', 'sample', 204, 204]
index = 0
posts = []
def sleep(duration):
    global index
    if duration == 30:
        index += 1
        if index == len(steps): raise Finished()
time.sleep = sleep
original_open = builtins.open
original_statvfs = os.statvfs
def read(path, *args, **kwargs):
    if steps[index] == 'sample' and path in ('/proc/stat', '/proc/meminfo'):
        raise OSError('private sample failure')
    return original_open(path, *args, **kwargs)
def disk(path):
    if steps[index] == 'sample': raise OSError('private sample failure')
    return original_statvfs(path)
builtins.open = read
os.statvfs = disk
def post(request, timeout, context):
    step = steps[index]
    posts.append(step)
    if step == 'transport': raise urllib.error.URLError('private transport details')
    if step >= 400:
        raise urllib.error.HTTPError(request.full_url, step, 'private response reason', request.headers, io.BytesIO(b'private content'))
    response = io.BytesIO(b'')
    response.status = step
    return response
urllib.request.urlopen = post
try: exec(sys.stdin.read())
except Finished: pass
assert posts == [step for step in steps if step != 'sample']
`;
  const result = await runChild("python3", ["-c", harness], { input: guestResourceReporterScript() });
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("");
  expect(result.stderr.trim().split("\n")).toEqual([
    "resource reporter: accepted HTTP 204",
    "resource reporter: HTTP 401",
    "resource reporter: HTTP 503",
    "resource reporter: transport failed",
    "resource reporter: sample failed",
    "resource reporter: recovered, accepted HTTP 204",
  ]);
});

test("installer is a valid portable shell program", async () => {
  const result = await runChild("sh", ["-n"], { input: guestResourceReporterInstallCommand() });
  expect(result.status).toBe(0);
});

// Execute the exact shell string sent to Freestyle: a prefix assertion cannot
// catch broken heredoc quoting or literal backslash-n separators.
test("the direct sampling command executes and returns measured gauges", async () => {
  const result = await runChild("sh", ["-c", guestResourceSampleCommand()]);
  expect(result.status).toBe(0);
  expect(JSON.parse(result.stdout).diskUsedMb).toBeGreaterThanOrEqual(0);
});
