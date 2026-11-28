#!/usr/bin/env python3
"""Team VM storage spike benchmarks. Usage: bench.py <test> <root> [label]. Appends JSON lines to /root/results.jsonl."""
import json, os, sys, time, statistics, subprocess, threading, random, hashlib
from concurrent.futures import ThreadPoolExecutor

OUT = "/root/results.jsonl"

def stats(xs):
    xs = sorted(xs)
    p = lambda q: xs[min(len(xs) - 1, int(q * len(xs)))]
    return {"n": len(xs), "p50": round(statistics.median(xs), 2), "p95": round(p(0.95), 2), "max": round(xs[-1], 2)}

def emit(test, label, **kv):
    rec = {"test": test, "label": label, "t": time.strftime("%FT%TZ", time.gmtime()), **kv}
    print(json.dumps(rec), flush=True)
    with open(OUT, "a") as f: f.write(json.dumps(rec) + "\n")

def ms(f):
    t = time.perf_counter(); f(); return (time.perf_counter() - t) * 1000

def write_fsync(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o660)
    os.write(fd, data); os.fsync(fd); os.close(fd)

def t_write(root, label):
    d = f"{root}/bench-write"; os.makedirs(d, exist_ok=True)
    for size in (1024, 16384, 262144):
        data = os.urandom(size)
        xs = [ms(lambda i=i: write_fsync(f"{d}/f{size}-{i}", data)) for i in range(40)]
        emit("write_fsync", label, size=size, **stats(xs))
    xs = [ms(lambda i=i: os.rename(f"{d}/f1024-{i}", f"{d}/r1024-{i}")) for i in range(40)]
    emit("rename", label, **stats(xs))

def send(d, i, w):
    tmp = f"{d}/.tmp-{w}-{i}"; write_fsync(tmp, (f"---\nsubject: m{i}\n---\n" + "x" * 800).encode()); os.rename(tmp, f"{d}/m-{w}-{i}.md")

def t_mail(root, label):
    for writers, per in ((1, 100), (8, 40)):
        d = f"{root}/bench-mail-{writers}"; os.makedirs(d, exist_ok=True)
        lat = []; lock = threading.Lock()
        def run(w):
            for i in range(per):
                x = ms(lambda: send(d, i, w))
                with lock: lat.append(x)
        t = time.perf_counter()
        with ThreadPoolExecutor(writers) as ex: list(ex.map(run, range(writers)))
        el = time.perf_counter() - t
        emit("mail_send", label, writers=writers, per_s=round(len(lat) / el, 1), **stats(lat))

def t_oplog(root, label):
    # Stand-in for the cmux-tasks op log: append a batch of ~300-byte records, then one fsync per group commit.
    for batch in (1, 32):
        p = f"{root}/bench-oplog-{batch}.log"
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        xs = []
        for c in range(60):
            buf = b"".join(json.dumps({"seq": c * batch + k, "op": "task.update", "pad": "y" * 220}).encode() + b"\n" for k in range(batch))
            xs.append(ms(lambda: (os.write(fd, buf), os.fsync(fd))))
        os.close(fd)
        s = stats(xs); emit("oplog_commit", label, batch=batch, ops_per_s=round(batch * 1000 / s["p50"], 1), **s)

def mk_corpus(root, n, label):
    d = f"{root}/corpus-{n}"
    words = "agent memory team task mailbox project feedback reference deploy review merge build ssh vm".split()
    def one(i):
        sub = f"{d}/{i % 100:02d}/{(i // 100) % 50:02d}"; os.makedirs(sub, exist_ok=True)
        body = f"---\nname: f{i}\ndescription: fact {i}\n---\n" + " ".join(random.choice(words) for _ in range(500)) + (" NEEDLE42" if i % 997 == 0 else "") + "\n"
        with open(f"{sub}/f{i}.md", "w") as f: f.write(body)
    t = time.perf_counter()
    with ThreadPoolExecutor(64) as ex: list(ex.map(one, range(n)))
    el = time.perf_counter() - t
    emit("corpus_create", label, files=n, seconds=round(el, 1), files_per_s=round(n / el, 1))

def t_rg(root, label, n):
    d = f"{root}/corpus-{n}"
    t = time.perf_counter(); r = subprocess.run(["rg", "-c", "NEEDLE42", d], capture_output=True, text=True); el = time.perf_counter() - t
    emit("rg", label, files=n, seconds=round(el, 3), hits=len(r.stdout.splitlines()))

def t_git(root, label, n):
    d = f"{root}/corpus-{n}"
    env = {**os.environ, "GIT_AUTHOR_NAME": "s", "GIT_AUTHOR_EMAIL": "s@x", "GIT_COMMITTER_NAME": "s", "GIT_COMMITTER_EMAIL": "s@x"}
    run = lambda *a: subprocess.run(["git", "-C", d, *a], capture_output=True, env=env)
    if not os.path.isdir(f"{d}/.git"):
        t = time.perf_counter(); run("init", "-q"); run("add", "-A"); run("commit", "-qm", "init"); emit("git_init_add_commit", label, files=n, seconds=round(time.perf_counter() - t, 1))
    t = time.perf_counter(); run("status", "--porcelain"); emit("git_status", label, files=n, seconds=round(time.perf_counter() - t, 3))
    for i in range(100):
        with open(f"{d}/00/00/f{i * 100}.md" if os.path.exists(f"{d}/00/00/f{i * 100}.md") else f"{d}/extra-{i}.md", "a") as f: f.write("edit\n")
    t = time.perf_counter(); run("add", "-A"); run("commit", "-qm", "edit 100"); emit("git_commit_100", label, files=n, seconds=round(time.perf_counter() - t, 3))

def t_durable(root, label, seconds):
    # Writer for the kill test: append a record, fsync, then print the acknowledged seq and its hash.
    d = f"{root}/durable"; os.makedirs(d, exist_ok=True)
    end = time.time() + seconds; seq = 0
    while time.time() < end:
        data = f"{label}:{seq}:{os.urandom(8).hex()}".encode()
        write_fsync(f"{d}/{label}-{seq:06d}", data)
        print(f"ACK {seq} {hashlib.sha256(data).hexdigest()}", flush=True); seq += 1

if __name__ == "__main__":
    test, root = sys.argv[1], sys.argv[2]; label = sys.argv[3] if len(sys.argv) > 3 else "run"
    {"write": lambda: t_write(root, label), "mail": lambda: t_mail(root, label), "oplog": lambda: t_oplog(root, label),
     "corpus": lambda: mk_corpus(root, int(sys.argv[4]), label), "rg": lambda: t_rg(root, label, int(sys.argv[4])),
     "git": lambda: t_git(root, label, int(sys.argv[4])), "durable": lambda: t_durable(root, label, int(sys.argv[4]))}[test]()
