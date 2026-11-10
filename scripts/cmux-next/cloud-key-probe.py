#!/usr/bin/env python3
"""The clean-room provider key probe: run on a Cloud machine, it says where a model provider's key sits.

It reads every process's environment and command line, and every file under the homes, /etc, /opt, /srv
and the temp folders (whole, binary ones too), and prints one JSON line (after the `@@keyprobe ` marker)
naming each finding by place and kind: `env` (a process's variable), `cmdline` (a process's arguments) or
`file` (a path, and the line in a text file). It never prints, hashes or sends a value: a finding is the
variable's name or the key's kind ("an Anthropic OAuth token"), never any of its characters. Every string it
prints (a path, a process name) has its key-shaped parts replaced by their kind first, since a file or process
can be named with a key.

Matches inside installed software (`shipped`) are listed apart from `findings`: /opt, which the image build
writes and every fresh machine shares, the harnesses' plugin caches, and the programs cmux and Codex install in a
home (only when the file there is a program). There a key shape is public text: an
SDK's documented example, a scanner's list of known public keys, a harness's own redaction pattern. A clean
check counts `findings` only; a key in a home, a workspace (its node_modules too) or a temp folder is a finding.

`complete` says whether "no finding" means "no key": it is true only when the probe ran as root, read
every live process's environment and command line, read every file and directory, and finished the walk
inside its budget. Anything less is listed (`gaps`), and a clean check must treat it as unknown.

Usage: python3 -I cloud-key-probe.py [--root DIR] [--budget-s N]
  --root DIR    read DIR/proc, DIR/home, DIR/etc ... instead of the real ones (the tests plant keys there)
  --budget-s N  stop the file walk after N seconds and say so (`truncated`); default 90
  --as-root     count the run as root (the tests' planted tree is read as its owner)
"""

import json
import os
import re
import stat
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
    ("an OAuth refresh token", re.compile(r'"refresh_token"\s*:\s*"([^"\s]{20,})"')),
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

# Installed software, by place: what the image build put in /opt, and the harnesses' plugin caches.
SHIPPED = re.compile(r"^/opt/|/\.codex/\.tmp/plugins/|/\.claude/plugins/")
# Programs the machine's installers put in its home, matched only when the file is a program (ELF): acpmux and
# cmux carry gitleaks' list of known public Google keys, and Codex copies its own program to arg0/apply_patch.
SHIPPED_PROGRAM = re.compile(r"^/home/[^/]+/(\.local/bin/(acpmux|cmux|cmux-tui)|\.local/share/cmux-tui/builds/[^/]+/bin/[^/]+|"
                             r"\.codex/tmp/arg0/[^/]+/apply_patch)$")


def is_shipped(where, path):
    """Whether a file's matches are installed software's public text, by where it is (and, for a program in a
    home, that it is one)."""
    if SHIPPED.search(where):
        return True
    if not SHIPPED_PROGRAM.search(where):
        return False
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False
# The stand-in AWS documents its examples with (AKIAIOSFODNN7EXAMPLE); a real id is random and never spells it.
PUBLIC_VALUE = re.compile(r"EXAMPLE")

FILE_ROOTS = ["home", "root", "etc", "opt", "srv", "tmp", "var/tmp", "run/user", "workspace"]
# The walk skips only pseudo file systems, by their mount points (a folder named `dev` in a project is walked), and
# follows symbolic links, each real folder and file once: a key behind a link is still a key on the machine.
PSEUDO_FS = {"proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs", "debugfs", "tracefs", "configfs",
             "fusectl", "mqueue", "pstore", "bpf", "binfmt_misc", "hugetlbfs", "autofs", "efivarfs", "rpc_pipefs", "nsfs"}
CHUNK = 4 << 20
OVERLAP = 256
# How far past a prefilter hit a binary file's shapes are checked: longer than any key the shapes need to see.
HIT_SPAN = 512

# Cheap byte prefilter: a line or chunk without one of these holds no finding, so only those get the full checks.
PREFILTER = re.compile(
    rb"sk-|AIza|xai-|gsk_|hf_|AKIA|ASIA|refresh_token|" + b"|".join(re.escape(n.encode()) for n in sorted(KEY_NAMES))
)
# A key's name as a command-line word: `NAME=value`, `--name=value`, or `--name` then the value as the next word,
# in any case, with `-` for `_`. Inside a longer word (a `sh -c` script) only the `NAME=value` form.
ARG_ASSIGN = re.compile(r"^-{0,2}([A-Za-z][A-Za-z0-9_-]*)=(.*)$", re.S)
ARG_NAME = re.compile(r"^-{1,2}([A-Za-z][A-Za-z0-9_-]*)$")
INLINE_ASSIGN = re.compile(r"(?:^|[\s;&|(`])(?:export\s+)?([A-Z][A-Z0-9_]*)=([^\s;&|)`]*)")


# Every value the probe judged a key by its context (a key name's value, a refresh token in JSON), whatever its shape:
# the shapes below cannot redact those, so each is replaced wherever it shows up in the report. Held in memory only.
# A value shorter than SECRET_MIN is no key, and replacing it everywhere would garble every path.
FOUND = set()
SECRET_MIN = 6


def found(value):
    """Records a value the probe judged a key, for redaction."""
    v = value.strip().strip("'\"")
    if len(v) >= SECRET_MIN:
        FOUND.add(v)


# The shapes for redaction: the same, without the word boundaries detection uses to keep prose out, so a key glued to
# other characters (`prefix_<key>` in a file name) is still replaced.
REDACT_SHAPES = [(kind, re.compile(pattern.pattern.replace(r"\b", ""))) for kind, pattern in SHAPES]


def redact(text):
    """`text` (a path, a process name: anything the machine controls) with every value found as a key and every
    key-shaped part replaced, so no finding's place can carry a key out."""
    for value in sorted(FOUND, key=len, reverse=True):
        text = text.replace(value, "[a secret]")
    for kind, pattern in REDACT_SHAPES:
        text = pattern.sub(f"[{kind}]", text)
    return text


def redacted(value):
    """Every string in the report, redacted."""
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, list):
        return [redacted(v) for v in value]
    if isinstance(value, dict):
        return {redact(k): redacted(v) for k, v in value.items()}
    return value


REFRESH = dict(SHAPES)["an OAuth refresh token"]


def shape_kinds(text):
    """The kinds of key `text` holds by shape, skipping public stand-ins. Never the values. Every text the probe
    checks (an environment value, an argument, a file's line or chunk) goes through here, so a refresh token is
    recorded for redaction wherever it was found. So is every other value a shape matched: redaction then replaces it
    as plain text wherever it shows up, whatever surrounds it."""
    kinds = set()
    for kind, pattern in SHAPES:
        for m in pattern.finditer(text):
            if PUBLIC_VALUE.search(m.group(0)):
                continue
            kinds.add(kind)
            found(m.group(1) if pattern.groups else m.group(0))
    return kinds


def value_finding(value):
    """The kind of key `value` holds, or None. Never the value."""
    kinds = shape_kinds(value)
    return next((kind for kind, _ in SHAPES if kind in kinds), None)


def scan_env(entries):
    """Findings in one environment: (NAME, kind) pairs. A key name with a real value counts; so does any
    variable whose value has a key's shape."""
    out = []
    for entry in entries:
        name, sep, value = entry.partition("=")
        if not sep:
            continue
        if name in KEY_NAMES and value.strip() not in PLACEHOLDERS:
            found(value)
            out.append((name, value_finding(value) or "a value"))
        else:
            kind = value_finding(value)
            if kind:
                out.append((name, kind))
    return out


def key_name(word):
    """The key name a command-line word spells (`--openai-api-key` is OPENAI_API_KEY), or None."""
    name = word.upper().replace("-", "_")
    return name if name in KEY_NAMES else None


def real_value(value):
    """A value after a key's name in an environment or argument: anything but empty, the placeholder or a reference."""
    v = value.strip().strip("'\"")
    return v not in PLACEHOLDERS and not v.startswith("$")


def scan_args(args):
    """Findings in one command line: kinds, or key names given a value."""
    out = set()
    for i, arg in enumerate(args):
        kind = value_finding(arg)
        if kind:
            out.add(kind)
        m = ARG_ASSIGN.match(arg)
        if m and key_name(m.group(1)) and real_value(m.group(2)):
            found(m.group(2))
            out.add(key_name(m.group(1)))
        m = ARG_NAME.match(arg)
        if m and key_name(m.group(1)) and i + 1 < len(args) and real_value(args[i + 1]):
            found(args[i + 1])
            out.add(key_name(m.group(1)))
        for m in INLINE_ASSIGN.finditer(arg):
            if m.group(1) in KEY_NAMES and real_value(m.group(2)):
                found(m.group(2))
                out.add(m.group(1))
    return sorted(out)


def literal_secret(value):
    """Whether a value written after a key's name in a file looks like the key itself."""
    return bool(SECRET_LITERAL.match(value)) and not STAND_IN.search(value)


def scan_text(text):
    """Findings in a file's text: (line number, what) pairs."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        seen = shape_kinds(line)
        for m in ASSIGN.finditer(line):
            if m.group(1) in KEY_NAMES and literal_secret(m.group(2)):
                found(m.group(2))
                seen.add(m.group(1))
        out.extend((n, what) for what in sorted(seen))
    return out


def read(path, limit=1 << 20):
    with open(path, "rb") as f:
        return f.read(limit)


def scan_file(path):
    """Findings in one whole file: (line number or None, what). A binary file is read in overlapping chunks (shapes
    only; a binary has no lines). In a text file only the lines the prefilter hits are checked: most hold none of the
    prefixes, and a Python loop over every line of every file was the walk's cost."""
    out = []
    with open(path, "rb") as f:
        head = f.read(4096)
        f.seek(0)
        if b"\0" in head:
            seen = set()
            tail = b""
            while True:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                window = tail + chunk
                # Every shape starts at a prefilter prefix (a quote before refresh_token, a word boundary before the
                # rest), so only a short stretch from each hit is checked, not the whole chunk with every shape.
                for hit in PREFILTER.finditer(window):
                    at = hit.start()
                    seen.update(shape_kinds(window[max(0, at - 2):at + HIT_SPAN].decode("latin-1")))
                tail = window[-OVERLAP:]
            return [(None, what) for what in sorted(seen)]
        # Whole lines a chunk at a time (a partial last line waits for the next chunk); only the lines the prefilter
        # hits are decoded and checked, and their numbers are counted from the newlines before them.
        line, rest = 1, b""
        while True:
            chunk = f.read(CHUNK)
            block = rest + chunk
            cut = len(block) if not chunk else block.rfind(b"\n") + 1
            whole, rest = block[:cut], block[cut:]
            seen_to, last = 0, -1
            for hit in PREFILTER.finditer(whole):
                start = whole.rfind(b"\n", 0, hit.start()) + 1
                if start == last:
                    continue
                line += whole.count(b"\n", seen_to, start)
                seen_to = last = start
                end = whole.find(b"\n", hit.start())
                out.extend((line, what) for _, what in scan_text(whole[start:len(whole) if end < 0 else end].decode("utf-8", "replace")))
            line += whole.count(b"\n", seen_to)
            if not chunk:
                return out
    return out


def scan_processes(root, me, report):
    proc = os.path.join(root, "proc")
    try:
        pids = [p for p in os.listdir(proc) if p.isdigit()]
    except OSError:
        report["unreadable"].append("proc")
        return
    grouped = {}
    for pid in pids:
        base = os.path.join(proc, pid)
        try:
            comm = read(os.path.join(base, "comm"), 64).decode("utf-8", "replace").strip() or "?"
            env = read(os.path.join(base, "environ"), 1 << 24).decode("utf-8", "replace").split("\0")
            args = read(os.path.join(base, "cmdline"), 1 << 24).decode("utf-8", "replace").split("\0")
        except OSError:
            # A process that ended while the probe read it holds nothing now; one still there is a gap.
            if os.path.isdir(base):
                report["scanned"]["procs_unreadable"] += 1
            continue
        report["scanned"]["processes"] += 1
        for name, kind in scan_env(env):
            grouped.setdefault(("env", comm, f"{name} ({kind})"), set()).add(pid)
        # This probe's own command line (and its sudo's and shell's) is its source and arguments, never a key;
        # their environments are still read above.
        if int(pid) in me:
            continue
        for what in scan_args(args):
            grouped.setdefault(("cmdline", comm, what), set()).add(pid)
    for (place, comm, what), ids in sorted(grouped.items()):
        report["findings"].append({"place": place, "where": f"process {comm} ({len(ids)} pid{'s' if len(ids) > 1 else ''})", "what": what})


def pseudo_devices():
    """The device ids of the pseudo file systems mounted here (their contents are the kernel's, not stored files). A
    folder or file on one, however it was reached (a link into /proc, say), is skipped by its device."""
    found = {"/proc", "/sys", "/dev"}
    try:
        with open("/proc/self/mounts", encoding="utf-8", errors="replace") as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 3 and fields[2] in PSEUDO_FS:
                    found.add(fields[1].replace("\\040", " "))
    except OSError:
        pass
    devices = set()
    for mount in found:
        try:
            devices.add(os.stat(mount).st_dev)
        except OSError:
            pass
    return devices


def scan_files(root, deadline, report):
    pseudo = pseudo_devices()
    real_root = os.path.realpath(root)
    # A file or folder can have several names: a symbolic link, a hard link, a bind mount. Its contents are read once
    # (by device and inode), but every name it is reached under is classed and reported on its own, so a name in a
    # place whose matches are shipped (a plugin cache) never hides the same key under a workspace name. A folder is
    # walked once per class (shipped or not), which still ends on a loop.
    walked_dirs, reported = set(), set()
    contents = {}

    for top in FILE_ROOTS:
        start = os.path.join(root, top)
        if not os.path.isdir(start):
            continue
        for dirpath, dirnames, filenames in os.walk(start, followlinks=True, onerror=lambda e: report["unreadable"].append(shown(root, e.filename))):
            try:
                st = os.stat(dirpath)
                key = (st.st_dev, st.st_ino, bool(SHIPPED.search(shown(real_root, os.path.realpath(dirpath)) + "/")))
                if st.st_dev in pseudo or key in walked_dirs:
                    dirnames[:] = []
                    continue
                walked_dirs.add(key)
            except OSError:
                report["unreadable"].append(shown(root, dirpath))
                dirnames[:] = []
                continue
            for name in filenames:
                if time.monotonic() > deadline:
                    report["truncated"] = True
                    return
                path = os.path.join(dirpath, name)
                if path == os.path.abspath(__file__):
                    continue
                walked = shown(root, path)
                try:
                    try:
                        st = os.stat(path)
                    except FileNotFoundError:
                        continue  # a link to nothing, or a file gone since the listing, holds nothing
                    if not stat.S_ISREG(st.st_mode) or st.st_dev in pseudo:
                        continue  # a socket, fifo or device, or a kernel file, holds no stored key
                    # A login file is one by the name it is reached under (a link named .codex/auth.json counts).
                    for suffix, what in LOGIN_FILES.items():
                        if walked.endswith("/" + suffix) and st.st_size > 0:
                            report["findings"].append({"place": "file", "where": walked, "what": what})
                    # Named and classed by where it is once symbolic links are resolved; each such name once.
                    where = shown(real_root, os.path.realpath(path))
                    if where in reported:
                        continue
                    reported.add(where)
                    inode = (st.st_dev, st.st_ino)
                    if inode not in contents:
                        contents[inode] = scan_file(path)
                        report["scanned"]["files"] += 1
                    hits = contents[inode]
                except OSError:
                    if os.path.lexists(path):
                        report["scanned"]["files_unreadable"] += 1
                    continue
                listed = report["shipped"] if is_shipped(where, path) else report["findings"]
                for line, what in hits:
                    listed.append({"place": "file", "where": where if line is None else f"{where}:{line}", "what": what})


def own_chain():
    """This probe's pid and its ancestors' (sudo, the exec shell): their command lines carry this source."""
    chain = set()
    pid = os.getpid()
    while pid > 1 and pid not in chain and len(chain) < 8:
        chain.add(pid)
        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                pid = int(f.read().rsplit(b")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return chain


def shown(root, path):
    """A path as it is on the machine (without the tests' --root)."""
    rel = os.path.relpath(path, root)
    return "/" + rel if rel != "." else "/"


def main(argv):
    root = "/"
    budget = 90.0
    as_root = os.geteuid() == 0
    i = 0
    while i < len(argv):
        if argv[i] == "--as-root":
            as_root = True
            i += 1
            continue
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
        "as_root": as_root,
        "findings": [],
        "shipped": [],
        "scanned": {"processes": 0, "procs_unreadable": 0, "files": 0, "files_unreadable": 0},
        "unreadable": [],
        "truncated": False,
    }
    me = own_chain()
    scan_processes(root, me, report)
    scan_files(root, t0 + budget, report)
    unreadable = sorted(set(report["unreadable"]))
    gaps = []
    if not as_root:
        gaps.append("not run as root")
    if report["scanned"]["procs_unreadable"]:
        gaps.append(f"{report['scanned']['procs_unreadable']} processes unreadable")
    if report["scanned"]["files_unreadable"]:
        gaps.append(f"{report['scanned']['files_unreadable']} files unreadable")
    if unreadable:
        gaps.append(f"{len(unreadable)} folders or /proc unreadable")
    if report["truncated"]:
        gaps.append(f"the file walk ran past its {budget:g} s budget")
    report["unreadable"] = unreadable[:20]
    report["gaps"] = gaps
    report["complete"] = not gaps
    report["ms"] = int((time.monotonic() - t0) * 1000)
    print("@@keyprobe " + json.dumps(redacted(report), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
