import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { GUEST_RESOURCE_SAMPLE_SCRIPT, guestResourceReporterInstallCommand, guestResourceReporterScript } from "../services/vms/guestResourceReporter";

function runCounterFixture(cpu: string[], meminfo: string) {
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
  const result = spawnSync("python3", ["-c", harness, JSON.stringify({ cpu, meminfo })], {
    input: GUEST_RESOURCE_SAMPLE_SCRIPT, encoding: "utf8",
  });
  expect(result.status).toBe(0);
  return JSON.parse(result.stdout);
}

test("samples CPU deltas without double-counting guest ticks, reclaimable RAM, and root filesystem use", () => {
  const stats = runCounterFixture([
    "cpu 100 0 50 800 50 0 0 0 80 0\n",
    "cpu 120 0 60 850 70 0 0 0 90 0\n",
  ], "MemTotal: 4194304 kB\nMemAvailable: 3145728 kB\nCached: 2000000 kB\n");
  expect(stats.cpuPercent).toBeCloseTo(30);
  expect(stats.memoryUsedMb).toBe(1024);
  expect(stats.diskUsedMb).toBe(23);
});

test("counter resets and incomplete memory counters leave those gauges missing", () => {
  const stats = runCounterFixture(["cpu 100 0 50 800 50 0 0 0\n", "cpu 10 0 5 80 5 0 0 0\n"], "MemTotal: 4096 kB\n");
  expect(stats).toEqual({ diskUsedMb: 23 });
});

test("the actual reporter posts the sample through the alias and then waits for its cadence", () => {
  const harness = `import io,json,sys,time,urllib.request
class Finished(BaseException): pass
original_sleep=time.sleep
def sleep(duration):
    if duration == 30: raise Finished()
    original_sleep(duration)
time.sleep=sleep
def post(request,timeout,context):
    print(json.dumps({'url':request.full_url,'method':request.method,'body':json.loads(request.data),'headers':dict(request.headers),'timeout':timeout}))
    return io.BytesIO(b'')
urllib.request.urlopen=post
try: exec(sys.stdin.read())
except Finished: pass
`;
  const result = spawnSync("python3", ["-c", harness], { input: guestResourceReporterScript(), encoding: "utf8" });
  expect(result.status).toBe(0);
  const sent = JSON.parse(result.stdout);
  expect(sent.url).toBe("https://coderouter.cmux.internal/api/vm/resource-usage/self");
  expect(sent.method).toBe("POST");
  expect(sent.headers.Authorization).toBe("Bearer cmux-vm-edge-placeholder");
  expect(sent.timeout).toBe(5);
  // Disk is available on macOS too; Linux additionally supplies CPU and RAM.
  expect(sent.body.diskUsedMb).toBeGreaterThanOrEqual(0);
});

test("installer is a valid portable shell program", () => {
  const result = spawnSync("sh", ["-n"], { input: guestResourceReporterInstallCommand(), encoding: "utf8" });
  expect(result.status).toBe(0);
});
