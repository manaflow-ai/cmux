import { afterEach, describe, expect, test } from "bun:test";
import { runChild } from "./helpers/run-child";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DEVBOX_DNS_PATH, DEVBOX_DNS_UNITS, devboxDnsCheckCommand } from "../scripts/devbox-image-common";

// cmux issue 26640: the platform resolver (10.32.0.28) answers SERVFAIL or
// nothing for every name at once, and the platform intercepts every port-53
// packet, so the guest stub must route around it without breaking the names
// only the platform answers.
const script = path.join(import.meta.dirname, "../services/vms/images/devbox/cmux-dns");

const directories: string[] = [];
afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true });
});

function fixture(): string {
  const directory = mkdtempSync(path.join(tmpdir(), "cmux-dns-"));
  directories.push(directory);
  return directory;
}

/** Runs `body` with `dns` (the stub module) and `q(name)`, `reply(query, rcode, answers)` helpers. */
async function python(body: string, ...args: string[]) {
  const result = await runChild("python3", ["-c", String.raw`
import importlib.machinery, importlib.util, struct, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("cmux_dns", sys.argv[1])
spec = importlib.util.spec_from_loader("cmux_dns", loader)
dns = importlib.util.module_from_spec(spec); loader.exec_module(dns)
def q(name, qtype=1, ident=0x1234):
    labels = b"".join(bytes([len(p)]) + p.encode() for p in name.split("."))
    return struct.pack("!HHHHHH", ident, 0x0100, 1, 0, 0, 0) + labels + b"\x00" + struct.pack("!HH", qtype, 1)
def reply(query, rcode, answers=0, tc=False):
    return query[:2] + bytes([0x81 | (0x02 if tc else 0), 0x80 | rcode]) + query[4:6] + struct.pack("!H", answers) + query[8:] + b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04\x0a\x20\x00\x1c" * answers
calls = []
` + body, script, ...args]);
  expect(result.stderr).toBe("");
  expect(result.status).toBe(0);
  return result.stdout.trim().split("\n");
}

describe("cmux-dns resolver", () => {
  test("the platform's answer wins while it works, so steered names keep resolving to the edge", async () => {
    expect(await python(String.raw`
def exchange(server, query, timeout, tcp):
    calls.append(server)
    return reply(query, 0, 1)
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=exchange, doh_exchange=lambda *a: calls.append("doh"))
out = r.resolve(q("api.anthropic.com"))
print(dns.rcode(out), out[-4:].hex(), calls)
`)).toEqual(["0 0a20001c ['10.32.0.28']"]);
  });

  test("a platform SERVFAIL is retried, then answered from the last good platform answer", async () => {
    expect(await python(String.raw`
state = {"down": False}
def exchange(server, query, timeout, tcp):
    calls.append("platform")
    return reply(query, 2) if state["down"] else reply(query, 0, 1)
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=exchange, doh_exchange=lambda *a: calls.append("doh"))
r.resolve(q("api.anthropic.com", ident=1))
state["down"] = True
calls.clear()
out = r.resolve(q("api.anthropic.com", ident=7))
print(dns.rcode(out), struct.unpack("!H", out[:2])[0], out[-4:].hex(), calls)
`)).toEqual(["0 7 0a20001c ['platform', 'platform']"]);
  });

  test("a name the platform never answered falls back to DNS-over-HTTPS", async () => {
    expect(await python(String.raw`
def doh(host, path, query, timeout):
    calls.append(host)
    return reply(query, 0, 1)
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda *a: None, doh_exchange=doh)
out = r.resolve(q("github.com", ident=9))
print(dns.rcode(out), struct.unpack("!H", out[:2])[0], calls)
nodata = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda *a: None, doh_exchange=lambda h, p, query, t: reply(query, 0, 0))
print(dns.rcode(nodata.resolve(q("github.com", qtype=28))))
`)).toEqual(["0 9 ['1.1.1.1']", "0"]);
  });

  test("a fallback NXDOMAIN or a total outage answers SERVFAIL, never a missing name", async () => {
    expect(await python(String.raw`
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda s, query, t, tcp: reply(query, 2), doh_exchange=lambda h, p, query, t: reply(query, 3))
out = r.resolve(q("coderouter.cmux.internal"))
print(dns.rcode(out), out[3] & 0x80 != 0, out[12:] == q("coderouter.cmux.internal")[12:])
dead = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda *a: None, doh_exchange=lambda *a: None)
print(dns.rcode(dead.resolve(q("github.com"))))
`)).toEqual(["2 True True", "2"]);
  });

  test("the platform's NXDOMAIN is an answer, not a failure", async () => {
    expect(await python(String.raw`
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda s, query, t, tcp: reply(query, 3), doh_exchange=lambda *a: calls.append("doh"))
print(dns.rcode(r.resolve(q("missing.example"))), calls)
`)).toEqual(["3 []"]);
  });

  test("tries IPv4 platform resolvers before IPv6 when IPv6 is unavailable", async () => {
    expect(await python(String.raw`
def exchange(server, query, timeout, tcp):
    calls.append(server)
    return None if ":" in server else reply(query, 3)
r = dns.Resolver(upstreams=lambda: dns.DEFAULT_UPSTREAMS, exchange=exchange, doh_exchange=lambda *a: calls.append("doh"))
print(dns.rcode(r.resolve(q("missing.example"))), calls)
`)).toEqual(["3 ['8.8.8.8']"]);
  });

  test("a new resolver set drops answers cached under the old one", async () => {
    // A clone resumes with the snapshot's cache; when a TLS rule arrives the
    // platform's answers for steered names change, and a stale one must not
    // send traffic around the edge.
    expect(await python(String.raw`
servers = ["8.8.8.8"]
state = {"down": False}
def exchange(server, query, timeout, tcp):
    return None if state["down"] else reply(query, 0, 1)
r = dns.Resolver(upstreams=lambda: servers, exchange=exchange, doh_exchange=lambda *a: None)
r.resolve(q("api.openai.com"))
servers[:] = ["10.32.0.28"]
state["down"] = True
print(dns.rcode(r.resolve(q("api.openai.com"))))
`)).toEqual(["2"]);
  });

  test("the whole fallback chain stays inside one query budget", async () => {
    expect(await python(String.raw`
now = [0.0]
def exchange(server, query, timeout, tcp):
    now[0] += timeout
    calls.append(round(timeout, 2))
def doh(host, path, query, timeout):
    now[0] += timeout
    calls.append((host, round(timeout, 2)))
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], clock=lambda: now[0], exchange=exchange, doh_exchange=doh)
r.resolve(q("github.com"))
print(calls, now[0] <= dns.QUERY_BUDGET)
`)).toEqual(["[1.0, 1.0, ('1.1.1.1', 1.5)] True"]);
  });

  test("serves real UDP and TCP clients and passes a truncated platform answer through", async () => {
    expect(await python(String.raw`
import socket
def exchange(server, query, timeout, tcp):
    return reply(query, 0, 1, tc=not tcp)
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=exchange, doh_exchange=lambda *a: None)
udp, tcp = dns.serve(r, host="127.0.0.1", port=0)
import threading; threading.Thread(target=udp.serve_forever, daemon=True).start()
c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(5)
c.sendto(q("github.com"), udp.server_address); first = c.recv(4096)
print("udp", dns.rcode(first), first[2] & 0x02 != 0)
s = socket.create_connection(tcp.server_address, timeout=5)
s.sendall(struct.pack("!H", len(q("github.com"))) + q("github.com")); answer = dns.read_framed(s)
print("tcp", dns.rcode(answer), answer[2] & 0x02 != 0)
udp.shutdown(); tcp.shutdown()
`)).toEqual(["udp 0 True", "tcp 0 False"]);
  });
});

describe("cmux-dns resolver edge cases", () => {
  test("names that differ only in label boundaries never share a cache entry", async () => {
    // "github.com" as one label and github + com are different questions.
    expect(await python(String.raw`
one_label = struct.pack("!HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"\x0agithub.com\x00\x00\x01\x00\x01"
print(dns.question_key(one_label) == dns.question_key(q("github.com")), dns.question_key(q("GitHub.COM")) == dns.question_key(q("github.com")))
state = {"down": False}
def exchange(server, query, timeout, tcp):
    return None if state["down"] else reply(query, 3)
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=exchange, doh_exchange=lambda h, p, query, t: reply(query, 0, 1))
r.resolve(one_label)
state["down"] = True
print(dns.rcode(r.resolve(q("github.com"))))
`)).toEqual(["False True", "0"]);
  });

  test("a stale answer is served at most a day, and never across a platform rewrite", async () => {
    // A TLS rule or a resume rewrites resolv.conf with the same resolver
    // (10.32.0.28), yet a steered name may now answer differently.
    expect(await python(String.raw`
now = [0.0]
stamp = [1]
state = {"down": False}
def exchange(server, query, timeout, tcp):
    return None if state["down"] else reply(query, 0, 1)
r = dns.Resolver(source=lambda: (stamp[0], ["10.32.0.28"]), clock=lambda: now[0], exchange=exchange, doh_exchange=lambda *a: None)
r.resolve(q("api.openai.com"))
state["down"] = True
print("same write", dns.rcode(r.resolve(q("api.openai.com"))))
now[0] += dns.STALE_MAX_AGE + 1
print("a day later", dns.rcode(r.resolve(q("api.openai.com"))))
state["down"] = False; now[0] = 0.0; r.resolve(q("api.openai.com")); state["down"] = True
stamp[0] = 2
print("after rewrite", dns.rcode(r.resolve(q("api.openai.com"))))
`)).toEqual(["same write 0", "a day later 2", "after rewrite 2"]);
  });

  test("queued exchanges are cancelled when their caller times out", async () => {
    expect(await python(String.raw`
import concurrent.futures, threading
started = threading.Event()
release = threading.Event()
def occupy():
    started.set()
    release.wait()
with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
    dns._POOL = pool
    running = pool.submit(occupy)
    assert started.wait(10)
    try:
        print(dns.bounded(lambda: calls.append("abandoned"), 0.001))
    finally:
        release.set()
    running.result(timeout=10)
    pool.submit(lambda: None).result(timeout=10)
print(calls)
`)).toEqual(["None", "[]"]);
  });

  test("a blocked exchange cannot hold a query indefinitely", async () => {
    expect(await python(String.raw`
import threading
release = threading.Event()
def hang(*args):
    release.wait()
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=hang, doh_exchange=hang)
result = []
done = threading.Event()
def resolve():
    try:
        result.append(r.resolve(q("github.com")))
    finally:
        done.set()
thread = threading.Thread(target=resolve, daemon=True)
thread.start()
completed = done.wait(15)  # Failure watchdog; the injected clock test checks the budget.
release.set()
thread.join(timeout=15)
assert completed and not thread.is_alive()
print(dns.rcode(result[0]))
`)).toEqual(["2"]);
  }, 35_000);

  test("a reply for another question is discarded", async () => {
    expect(await python(String.raw`
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda s, query, t, tcp: reply(q("evil.example", ident=0x1234), 0, 1), doh_exchange=lambda *a: None)
print(dns.rcode(r.resolve(q("github.com"))))
`)).toEqual(["2"]);
  });

  test("UDP replies respect the client's size: 512 without EDNS, its EDNS size up to 1232", async () => {
    expect(await python(String.raw`
plain = q("github.com")
edns = plain[:10] + b"\x00\x01" + plain[12:] + b"\x00\x00\x29\x10\x00\x00\x00\x00\x00\x00\x00"
small = edns[:-11] + b"\x00\x00\x29\x02\x00\x00\x00\x00\x00\x00\x00"
print(dns.udp_limit(plain), dns.udp_limit(edns), dns.udp_limit(small))
big = reply(plain, 0, 40)
cut = dns.truncated(big, plain)
print(len(big) > 512, dns.rcode(cut), cut[2] & 0x02 != 0, cut[12:] == plain[12:], len(cut) < 512)
`)).toEqual(["512 1232 512", "True 0 True True True"]);
  });

  test("a response or a query without exactly one question gets no answer", async () => {
    expect(await python(String.raw`
r = dns.Resolver(upstreams=lambda: ["10.32.0.28"], exchange=lambda *a: calls.append("platform"), doh_exchange=lambda *a: None)
none = struct.pack("!HHHHHH", 5, 0x0100, 0, 0, 0, 1) + b"\x00\x00\x29\x10\x00\x00\x00\x00\x00\x00\x00"
response = reply(q("github.com"), 0, 1)
print(r.resolve(none), r.resolve(response), calls)
`)).toEqual(["None None []"]);
  });
});

describe("cmux-dns guard", () => {
  test("points the platform's resolv.conf at the stub and keeps its resolvers after it", async () => {
    const directory = fixture();
    const conf = path.join(directory, "resolv.conf");
    writeFileSync(conf, "# freestyle-tls forwarding resolver\noptions timeout:1 attempts:2\nnameserver 10.32.0.28\n");
    expect(await python(String.raw`
print(dns.guard(sys.argv[2]), dns.guard(sys.argv[2]))
print(dns.upstreams_from(open(sys.argv[2]).read()))
`, conf)).toEqual(["True False", "['10.32.0.28']"]);
    expect(readFileSync(conf, "utf8").split("\n").filter((line) => !line.startsWith("# ") || line.startsWith("# cmux-dns"))).toEqual([
      "# cmux-dns",
      "# cmux-dns upstream 10.32.0.28",
      "nameserver 127.0.0.2",
      "nameserver 10.32.0.28",
      "options timeout:4 attempts:1",
      "",
    ]);
  });

  test("records every base resolver, keeps libc's IPv4 fallback, and keeps other options", async () => {
    // libc reads three nameservers; with the stub first, the two left must be
    // ones every machine can route.
    const directory = fixture();
    const conf = path.join(directory, "resolv.conf");
    writeFileSync(conf, "search corp.example\noptions timeout:1 attempts:2 edns0 trust-ad\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888\nnameserver 8.8.8.8\nnameserver 8.8.4.4\n");
    expect(await python(String.raw`
dns.guard(sys.argv[2])
text = open(sys.argv[2]).read()
print(dns.upstreams_from(text))
print(dns.nameservers(text))
print([line for line in text.splitlines() if line.startswith(("search", "options"))])
`, conf)).toEqual([
      "['2606:4700:4700::1111', '2001:4860:4860::8888', '8.8.8.8', '8.8.4.4']",
      "['127.0.0.2', '8.8.8.8', '8.8.4.4']",
      "['search corp.example', 'options timeout:4 attempts:1 edns0 trust-ad']",
    ]);
  });

  test("leaves a file with no nameserver alone", async () => {
    // A platform write caught half-way has no nameserver yet; its close
    // triggers the guard again.
    const directory = fixture();
    const conf = path.join(directory, "resolv.conf");
    writeFileSync(conf, "options timeout:1\n");
    expect(await python("print(dns.guard(sys.argv[2]))", conf)).toEqual(["False"]);
    expect(readFileSync(conf, "utf8")).toBe("options timeout:1\n");
  });
});

describe("cmux-dns image contract", () => {
  test("the units run the distribution python and re-guard on every resolv.conf change", () => {
    expect(Object.keys(DEVBOX_DNS_UNITS).sort()).toEqual([
      "/etc/systemd/system/cmux-dns-guard.path",
      "/etc/systemd/system/cmux-dns-guard.service",
      "/etc/systemd/system/cmux-dns.service",
    ]);
    expect(DEVBOX_DNS_UNITS["/etc/systemd/system/cmux-dns.service"]).toContain(`ExecStart=/usr/bin/python3 ${DEVBOX_DNS_PATH} serve`);
    expect(DEVBOX_DNS_UNITS["/etc/systemd/system/cmux-dns-guard.path"]).toContain("PathChanged=/etc/resolv.conf");
    expect(devboxDnsCheckCommand).toContain("127.0.0.2");
  });
});
