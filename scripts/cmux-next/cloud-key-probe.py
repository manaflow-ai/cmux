#!/usr/bin/env python3
"""The clean-room provider key probe: run on a Cloud machine, it says where a model provider's key sits.

It reads every process's environment and command line, and the files under the homes, /etc, /opt, /srv
and the temp folders, and prints one JSON line (after the `@@keyprobe ` marker) naming each finding by
place and kind: `env` (a process's variable), `cmdline` (a process's arguments) or `file` (a path and
line). It never prints, hashes or sends a value: a finding is the variable's name or the key's kind
("an Anthropic OAuth token"), never any of its characters.

Run as root (the journey runs it under `sudo -n` when the machine allows it) to read every process and
home; as another user it reads what that user may, and says so (`as_root`, `unreadable`).

Usage: python3 -I cloud-key-probe.py [--root DIR] [--budget-s N]
  --root DIR    read DIR/proc, DIR/home, DIR/etc ... instead of the real ones (the tests plant keys there)
  --budget-s N  stop the file walk after N seconds and say so (`truncated`); default 40
"""

import json
import os
import re
import sys
import time

# The kinds of value a model provider issues, by shape. Each pattern is long enough that prose, a
# variable's name or this file's own source never matches it.
SHAPES = [
    ("an Anthropic API key", re.compile(r"sk-ant-api\d\d-[A-Za-z0-9_-]{20,}")),
    ("an Anthropic OAuth token", re.compile(r"sk-ant-oat\d\d-[A-Za-z0-9_-]{20,}")),
    ("an Anthropic refresh token", re.compile(r"sk-ant-ort\d\d-[A-Za-z0-9_-]{20,}")),
    ("an OpenAI project key", re.compile(r"sk-proj-[A-Za-z0-9_-]{20,}")),
    ("an OpenAI service account key", re.compile(r"sk-svcacct-[A-Za-z0-9_-]{20,}")),
    ("an OpenAI admin key", re.compile(r"sk-admin-[A-Za-z0-9_-]{20,}")),
    ("an OpenAI user key", re.compile(r"\bsk-[A-Za-z0-9]{20}T3BlbkFJ[A-Za-z0-9]{20}")),
    ("an OpenRouter key", re.compile(r"sk-or-v1-[0-9a-f]{32,}")),
    ("a Google AI key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}")),
    ("an xAI key", re.compile(r"\bxai-[A-Za-z0-9]{40,}")),
    ("a Groq key", re.compile(r"\bgsk_[A-Za-z0-9]{40,}")),
    ("a Hugging Face token", re.compile(r"\bhf_[A-Za-z0-9]{30,}")),
    ("an AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    # A ChatGPT sign-in (Codex's auth.json) and other OAuth logins: a refresh token in JSON.
    ("an OAuth refresh token", re.compile(r'"refresh_token"\s*:\s*"[^"\s]{20,}"')),
]

# Variables that hold a provider credential by name, whatever their value's shape.
KEY_NAMES = {
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
    "OPENAI_API_KEY", "CODEX_AUTH_JSON", "AZURE_OPENAI_API_KEY",
    "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY",
    "XAI_API_KEY", "GROQ_API_KEY", "OPENROUTER_API_KEY", "MISTRAL_API_KEY",
    "DEEPSEEK_API_KEY", "TOGETHER_API_KEY", "FIREWORKS_API_KEY", "CEREBRAS_API_KEY",
    "PERPLEXITY_API_KEY", "COHERE_API_KEY", "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN",
    "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_BEARER_TOKEN_BEDROCK",
}

# Values that are not keys: the public placeholder every Cloud machine's agents send to the edge
# (web/services/coderouter/vmGuestEnv.ts), which swaps in the real credential outside the machine.
PLACEHOLDERS = {"", "cmux-vm-edge-placeholder"}

# `NAME=value`, `export NAME=value`, `"NAME": "value"` and `NAME: value` lines in a file.
ASSIGN = re.compile(r'["\']?\b([A-Z][A-Z0-9_]*)\b["\']?\s*[:=]\s*["\']?([^"\'\s,;)}]*)')
# In a file a key's name alone is common (code that reads it, docs that name it): only a literal that looks
# like a secret counts there, at least 16 characters of token alphabet with a letter and a digit, and no
# reference (`$X`, `process.env.X`, `os.environ[...]`) or stand-in word.
SECRET_LITERAL = re.compile(r"^(?=[^/]*[0-9])(?=.*[A-Za-z])[A-Za-z0-9_\-.+/=:]{16,}$")
STAND_IN = re.compile(r"placeholder|example|dummy|fake|test|stub|changeme|your|xxxx|\.\.\.|environ|process\.env|getenv", re.I)

# Files that are a provider login by where they are, whatever is in them.
LOGIN_FILES = {
    ".claude/.credentials.json": "a Claude login file",
    ".codex/auth.json": "a Codex login file",
    ".aws/credentials": "an AWS credentials file",
    ".config/gcloud/application_default_credentials.json": "a Google Cloud login file",
}

FILE_ROOTS = ["home", "root", "etc", "opt", "srv", "tmp", "var/tmp", "run/user", "workspace"]
SKIP_DIRS = {"node_modules", ".git", "__pycache__", "proc", "sys", "dev"}
MAX_FILE = 1 << 20


def value_finding(value):
    """The kind of key `value` holds, or None. Never the value."""
    for kind, pattern in SHAPES:
        if pattern.search(value):
            return kind
    return None


def scan_env(entries):
    """Findings in one environment: (NAME, kind) pairs. A key name with a real value counts; so does any
    variable whose value has a key's shape."""
    out = []
    for entry in entries:
        name, sep, value = entry.partition("=")
        if not sep:
            continue
        if name in KEY_NAMES and value.strip() not in PLACEHOLDERS:
            out.append((name, value_finding(value) or "a value"))
        else:
            kind = value_finding(value)
            if kind:
                out.append((name, kind))
    return out


def literal_secret(value):
    """Whether a value written after a key's name in a file looks like the key itself."""
    return bool(SECRET_LITERAL.match(value)) and not STAND_IN.search(value)


def scan_text(text):
    """Findings in a file's text: (line number, what) pairs."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        seen = set()
        for kind, pattern in SHAPES:
            if pattern.search(line):
                seen.add(kind)
        for m in ASSIGN.finditer(line):
            if m.group(1) in KEY_NAMES and literal_secret(m.group(2)):
                seen.add(m.group(1))
        out.extend((n, what) for what in sorted(seen))
    return out


def read(path, limit=MAX_FILE):
    with open(path, "rb") as f:
        return f.read(limit)


def scan_processes(root, me, report):
    proc = os.path.join(root, "proc")
    try:
        pids = [p for p in os.listdir(proc) if p.isdigit()]
    except OSError:
        report["unreadable"].append("proc")
        return
    grouped = {}
    for pid in pids:
        if int(pid) in me:
            continue
        base = os.path.join(proc, pid)
        try:
            comm = read(os.path.join(base, "comm"), 64).decode("utf-8", "replace").strip() or "?"
        except OSError:
            continue
        report["scanned"]["processes"] += 1
        try:
            env = read(os.path.join(base, "environ")).decode("utf-8", "replace").split("\0")
        except OSError:
            report["scanned"]["env_unreadable"] += 1
            env = []
        for name, kind in scan_env(env):
            grouped.setdefault(("env", comm, f"{name} ({kind})"), set()).add(pid)
        try:
            args = read(os.path.join(base, "cmdline")).decode("utf-8", "replace").split("\0")
        except OSError:
            args = []
        for arg in args:
            kind = value_finding(arg)
            if kind:
                grouped.setdefault(("cmdline", comm, kind), set()).add(pid)
    for (place, comm, what), ids in sorted(grouped.items()):
        report["findings"].append({"place": place, "where": f"process {comm} ({len(ids)} pid{'s' if len(ids) > 1 else ''})", "what": what})


def scan_files(root, deadline, report):
    for top in FILE_ROOTS:
        start = os.path.join(root, top)
        if not os.path.isdir(start):
            continue
        for dirpath, dirnames, filenames in os.walk(start, onerror=lambda e: report["unreadable"].append(shown(root, e.filename))):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not os.path.islink(os.path.join(dirpath, d))]
            for name in filenames:
                if time.monotonic() > deadline:
                    report["truncated"] = True
                    return
                path = os.path.join(dirpath, name)
                if path == os.path.abspath(__file__) or os.path.islink(path):
                    continue
                where = shown(root, path)
                for suffix, what in LOGIN_FILES.items():
                    if where.endswith("/" + suffix):
                        try:
                            if os.path.getsize(path) > 0:
                                report["findings"].append({"place": "file", "where": where, "what": what})
                        except OSError:
                            pass
                try:
                    if os.path.getsize(path) > MAX_FILE:
                        report["scanned"]["files_too_big"] += 1
                        continue
                    data = read(path)
                except OSError:
                    report["scanned"]["files_unreadable"] += 1
                    continue
                report["scanned"]["files"] += 1
                if b"\0" in data[:4096]:
                    continue
                for line, what in scan_text(data.decode("utf-8", "replace")):
                    report["findings"].append({"place": "file", "where": f"{where}:{line}", "what": what})


def shown(root, path):
    """A path as it is on the machine (without the tests' --root)."""
    rel = os.path.relpath(path, root)
    return "/" + rel if rel != "." else "/"


def main(argv):
    root = "/"
    budget = 40.0
    i = 0
    while i < len(argv):
        if argv[i] == "--root":
            root = argv[i + 1]
            i += 2
        elif argv[i] == "--budget-s":
            budget = float(argv[i + 1])
            i += 2
        else:
            print(__doc__, file=sys.stderr)
            return 2
    t0 = time.monotonic()
    report = {
        "as_root": os.geteuid() == 0,
        "findings": [],
        "scanned": {"processes": 0, "env_unreadable": 0, "files": 0, "files_unreadable": 0, "files_too_big": 0},
        "unreadable": [],
        "truncated": False,
    }
    # This probe and the shell that started it carry no key, and their command lines hold this source.
    me = {os.getpid(), os.getppid()}
    scan_processes(root, me, report)
    scan_files(root, t0 + budget, report)
    report["unreadable"] = sorted(set(report["unreadable"]))[:20]
    report["ms"] = int((time.monotonic() - t0) * 1000)
    print("@@keyprobe " + json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
