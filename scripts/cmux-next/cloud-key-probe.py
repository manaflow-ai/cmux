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
import math
import os
import re
import stat
import sys
import time
import urllib.parse

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

ALL_SHAPES = frozenset(kind for kind, _ in SHAPES)

# Each shape's literal anchors: a shape can match only text that holds one, and a substring test is far cheaper than
# the shape's own search (the walk's largest cost). An assertion keeps the two lists together.
ANCHORS = {
    "an Anthropic API key": ("sk-ant-api",),
    "an Anthropic OAuth token": ("sk-ant-oat",),
    "an Anthropic refresh token": ("sk-ant-ort",),
    "an OpenAI project key": ("sk-proj-",),
    "an OpenAI service account key": ("sk-svcacct-",),
    "an OpenAI admin key": ("sk-admin-",),
    "an OpenAI user key": ("T3BlbkFJ",),
    "an OpenRouter key": ("sk-or-v1-",),
    "a Google AI key": ("AIza",),
    "an xAI key": ("xai-",),
    "a Groq key": ("gsk_",),
    "a Hugging Face token": ("hf_",),
    "an AWS access key id": ("AKIA", "ASIA"),
    "an OAuth refresh token": ('"refresh_token"',),
}
assert set(ANCHORS) == {kind for kind, _ in SHAPES}, "every shape has its anchors"
# A key's name ends in one of these, in any case (KEY_NAMES and the prefilter's assertion): no ending, no name.
NAME_ENDING = re.compile(r"_[Kk][Ee][Yy]|_[Tt][Oo][Kk][Ee][Nn]|_[Jj][Ss][Oo][Nn]")

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

# What is found by its context, not its shape alone: a key's name given a value, and a refresh token's JSON field. These
# are a credential wherever they are; installed software's public text (shipped) is only ever a bare shape.
CONTEXTUAL = KEY_NAMES | {"an OAuth refresh token"}

# Values that are not keys: the public placeholder every Cloud machine's agents send to the edge
# (web/services/coderouter/vmGuestEnv.ts), which swaps in the real credential outside the machine.
PLACEHOLDERS = {"", "cmux-vm-edge-placeholder"}

# `NAME=value`, `export NAME=value`, `"NAME": "value"` and `NAME: value` lines in a file, the name in any case
# (an AWS credentials file writes `aws_secret_access_key = ...`).
# What may stand between a name's `:` or `=` and its value, in any order and across lines: spaces and line breaks,
# a YAML block scalar's header (`|`, `|-`, `>+2`), a comment after a space, a YAML tag (`!!str`, `!vault`) or anchor
# (`&key`). Its alternatives start on different characters, so a failed match does not backtrack through them.
GAP = r'(?:\s+|(?<=\s)#[^\r\n]*|[|>][-+1-9]{0,2}(?=\s)|![^\s]*|&[^\s]+)*'
# A value: up to a quote, a space, a separator or a control byte (a NUL or a record's bytes end it in a binary file).
# One its quote opened runs to that quote instead, so a separator inside it (`"ab,c;d)e}f"`) is part of the key; every
# pattern below takes the quote just before it.
VALUE = r'(?:(?<=")[^"\s\x00-\x1f\x7f]*|(?<=\')[^\'\s\x00-\x1f\x7f]*|[^"\'\s,;)}\x00-\x1f\x7f]*)'
# A name, then its value in a lookahead: a match takes only the name, so a name that is not a key's
# (`env={MISTRAL_API_KEY:...}`) never takes the key's name with it, and every name is tried. Between them `:` or `=`,
# also behind an index's closing quote and bracket (`os.environ["NAME"] = `) or as make's `?=` and `+=`.
ASSIGN = re.compile(
    r'["\']?\b(?P<name>[A-Za-z][A-Za-z0-9_]*)\b(?=["\']?\]?\s*[?+]?[:=]' + GAP + r'["\']?(?P<value>' + VALUE + r'))'
)
# The forms with no `:` or `=`: a quoted name, then `,` (a call's first argument, `setdefault("NAME", value)`, its `(`
# on this line or an earlier one), and spaces after a Dockerfile `ENV` or fish's `set -x`. Each pattern starts on its own
# literal, so neither is tried at every character.
CALL_ASSIGN = re.compile(r'["\'](?P<name>[A-Za-z][A-Za-z0-9_]*)["\']\s*,' + GAP + r'["\']?(?P<value>' + VALUE + r')')
WORD_ASSIGN = re.compile(
    r'\b(?:ENV|set(?:\s+-[A-Za-z]+)+)[ \t]+(?P<name>[A-Za-z][A-Za-z0-9_]*)[ \t]' + GAP + r'["\']?(?P<value>' + VALUE + r')'
)
ASSIGNS = (ASSIGN, CALL_ASSIGN, WORD_ASSIGN)
# In a file a key's name alone is common (code that reads it, docs that name it): only a literal that looks
# like a secret counts there, at least 16 printable characters with a letter and a digit, and no reference or stand-in.
# Any printable character may be in a credential (base64's `+/=`, a password's `~!@#%^&*`), so the alphabet is all of
# printable ASCII but quotes, backquote and backslash (a value's own ends); what makes a value not a literal is how it
# reads: a reference (`$X`, `%X%`, `{{x}}`, `<x>`, `@x`, a YAML alias `*x`), code that starts as a call or an index
# (`os.environ.get(`, `env[`), or a stand-in. A bracket elsewhere is a character like any other (`ab+Zq8[Kd9]`).
# A value in the token alphabet (base64, base64url, hex) needs a letter and a digit; one with any other printable
# character also needs a random key's variety (4 bits a character), as minified code (`useFoo:!0`) has those too.
SECRET_LITERAL = re.compile(r"^(?=[^/]*[0-9])(?=.*[A-Za-z])[A-Za-z0-9_\-.+/=:]{16,}$")
SECRET_TOKEN = re.compile(r"^[A-Za-z0-9_\-.+/=:]{16,}$")
SECRET_PRINTABLE = re.compile(r"^(?=.*[0-9])(?=.*[A-Za-z])[!#-&(-\[\]-_a-~]{16,}$")
NOT_LITERAL = re.compile(r"^[$%{<@*]|^[A-Za-z_][A-Za-z0-9_.]*[(\[]")
# A stand-in is a value that starts as one: a stand-in word at its start, after at most a short prefix (`your-key`,
# `sk-test-1`, `placeholder_x`), or a reference (`process.env.X`, `os.environ`). Nothing inside a value counts but an
# ellipsis: a random key can hold any word by chance (`...myenvironment7...`, `Ab3-test-9...`), and is still a key.
STAND_IN = re.compile(
    r"^(?:[A-Za-z]{1,8}[-_])?(?:placeholder|example|dummy|fake|test|stub|changeme|your|xxxx)"
    r"|^(?:process\.env|os\.environ|environ|getenv)\b|\.\.\.",
    re.I,
)

# Files that are a provider login by where they are, whatever is in them.
LOGIN_FILES = {
    ".claude/.credentials.json": "a Claude login file",
    ".codex/auth.json": "a Codex login file",
    ".aws/credentials": "an AWS credentials file",
    ".config/gcloud/application_default_credentials.json": "a Google Cloud login file",
}

# Installed software, by place: what the image build put in /opt, and the harnesses' plugin caches.
# Only the harnesses' own caches in a home count: a project's `.claude/plugins` (in a workspace) is the person's.
SHIPPED = re.compile(r"^/opt/|^/(?:root|home/[^/]+)/(?:\.codex/\.tmp/plugins|\.claude/plugins)/")
# Programs the machine's installers put in its home, matched only when the file is a program (ELF), each with the only
# kinds of match it ships: acpmux and cmux carry a secret scanner's list of known public Google keys, and Codex (copied
# to arg0/apply_patch) its own key prefixes. Any other kind in such a file, or a match in any other program there, is a
# finding: the place alone never clears a file.
SHIPPED_PROGRAMS = (
    (re.compile(r"^/home/[^/]+/(?:\.local/bin/(?:acpmux|cmux|cmux-tui)|\.local/share/cmux-tui/builds/[^/]+/bin/[^/]+)$"),
     frozenset({"a Google AI key"})),
    (re.compile(r"^/home/[^/]+/\.codex/tmp/arg0/[^/]+/apply_patch$"),
     frozenset({"an OpenAI project key", "an OpenAI admin key", "an OpenAI service account key"})),
)


def shipped_kinds(where, path):
    """The kinds of match in a file that are installed software's public text, by where it is: every shape under /opt
    and in the harnesses' plugin caches, and for a program in a home (an ELF) only the kinds it ships. None: none."""
    if SHIPPED.search(where):
        return ALL_SHAPES
    for place, kinds in SHIPPED_PROGRAMS:
        if place.search(where):
            try:
                with open(path, "rb") as f:
                    return kinds if f.read(4) == b"\x7fELF" else None
            except OSError:
                return None
    return None
# The stand-ins AWS documents its examples with: only these exact values, so a real key that spells EXAMPLE by chance
# is still a key.
PUBLIC_VALUES = frozenset({"AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"})

FILE_ROOTS = ["home", "root", "etc", "opt", "srv", "tmp", "var/tmp", "run/user", "workspace"]
# The walk skips only pseudo file systems, by their mount points (a folder named `dev` in a project is walked), and
# follows symbolic links, each real folder and file once: a key behind a link is still a key on the machine.
PSEUDO_FS = {"proc", "sysfs", "devtmpfs", "devpts", "cgroup", "cgroup2", "securityfs", "debugfs", "tracefs", "configfs",
             "fusectl", "mqueue", "pstore", "bpf", "binfmt_misc", "hugetlbfs", "autofs", "efivarfs", "rpc_pipefs", "nsfs"}
CHUNK = 4 << 20
OVERLAP = 256
# How far past a prefilter hit a binary file's shapes are checked: longer than any key the shapes need to see.
HIT_SPAN = 512
# How far before a prefilter hit (a name's `_KEY` ending) a key's name may start, for a binary file's name check.
NAME_SPAN = 128
assert NAME_SPAN + 8 <= OVERLAP, "a key's name across chunks must fit in the overlap"

# Cheap byte prefilter: a line or chunk without one of these holds no finding, so only those get the full checks.
PREFILTER = re.compile(
    # Every key name ends in one of these, in any case (`aws_secret_access_key`, `Mistral_Api_Key`), as character
    # classes: as fast as plain words, where a case-blind group costs the walk 2 to 1000 times over.
    # `\u00` too: JSON may write any ASCII character of a name or prefix that way (readings() takes it off).
    rb"sk-|AIza|xai-|gsk_|hf_|AKIA|ASIA|refresh_token|_[Kk][Ee][Yy]|_[Tt][Oo][Kk][Ee][Nn]|_[Jj][Ss][Oo][Nn]|\\u00"
)
# The same prefixes and name endings in decoded text: a `\u00` hit counts only when its stretch, escapes taken off,
# holds one (minified code is full of `\u00XX`, and checking each one cost the walk about a tenth of its files).
TOKENS = re.compile(PREFILTER.pattern.decode().removesuffix(r"|\\u00"))


def escape_hit(hit, text):
    """Whether an escape's prefilter hit (backslash, u00) leads nowhere: `text`, its stretch, holds no prefix or name
    ending once decoded."""
    return hit.group(0) == b"\\u00" and not any(TOKENS.search(r) for r in readings(text)[1:])
# A key's name as a command-line word: `NAME=value`, `--name=value`, or `--name` then the value as the next word,
# in any case, with `-` for `_`. A longer word (a `sh -c` script) is split into its shell words and read the same way.
ARG_ASSIGN = re.compile(r"^-{0,2}([A-Za-z][A-Za-z0-9_-]*)=(.*)$", re.S)
ARG_NAME = re.compile(r"^-{1,2}([A-Za-z][A-Za-z0-9_-]*)$")
INLINE_ASSIGN = re.compile(r"(?:^|[\s;&|(`])(?:export\s+)?([A-Za-z][A-Za-z0-9_]*)=([^\s;&|)`]*)")
# A key name's ending in a script, `_` or `-` separated, in any case: where its words are split.
SCRIPT_NAME_HINT = re.compile(r"[-_](?:key|token|json)\b", re.I)
# How deep a script inside an argument is split again (`sh -c "bash -c '...'"`).
SCRIPT_DEPTH = 3


# Every value the probe judged a key by its context (a key name's value, a refresh token in JSON), whatever its shape:
# the shapes below cannot redact those, so each is replaced wherever it shows up in the report. Held in memory only.
# A value shorter than SECRET_MIN is no key, and replacing it everywhere would garble every path.
FOUND = set()
SECRET_MIN = 6


def found(value):
    """Records a value the probe judged a key, for redaction, as found and as decoded: a value read from JSON or a
    URL may be escaped there (`\\u006f`, `%6F`) and spelled plainly in a path or a process name."""
    v = value.strip().strip("'\"")
    variants = {v, urllib.parse.unquote(v)}
    try:
        variants.add(json.loads(f'"{v}"'))
    except ValueError:
        pass
    for variant in variants:
        if isinstance(variant, str) and len(variant) >= SECRET_MIN:
            FOUND.add(variant)


# A word of a report string (a path's part, a process name) that shares this many characters in a row with a found
# key is replaced whole: Linux cuts a process name to 15 bytes, and any other cut copy of a key is a piece of it.
PIECE = 8
# A part of a report string: a path's part or a word, cut only at `/` and spaces, so no punctuation inside a
# credential (`=`, `+`, `@`, `:`) splits it into short, harmless-looking pieces.
PART = re.compile(r"[^/\s]+")


# Names the machine controls (a path's parts, a process's name, an environment variable's name) print only when they
# are on the fixed lists below, whatever detection found or missed: no rule about a name's letters, digits, case or
# punctuation can show that it holds no credential, a list can. Any other part prints as `[a name]` (`[a process]`,
# `[a variable]`), keeping a file extension from EXTENSIONS. Detection decides what counts as a finding; only these
# lists decide what may be printed.
KNOWN_NAMES = {
    # The walked roots and the usual system folders.
    "", "home", "root", "etc", "opt", "srv", "tmp", "var", "run", "user", "workspace", "usr", "lib", "lib64", "bin",
    "sbin", "share", "local", "include", "src", "proc", "sys", "dev", "mnt", "media", "boot", "snap", "cmux", "ubuntu",
    # What tools keep in a home or a project.
    ".cache", ".config", ".local", ".ssh", ".aws", ".codex", ".claude", ".gemini", ".npm", ".bun", ".cargo", ".rustup",
    ".docker", ".kube", ".git", ".vscode", ".gnupg", ".pki", ".tmp", "gcloud", "plugins", "sessions", "projects", "arg0",
    "builds", "cmux-tui", "node_modules", "dist", "build", "target", "out", "vendor", "packages", "site-packages",
    "dist-packages", "project", "app", "apps", "lib", "libs", "test", "tests", "docs", "scripts", "config", "data",
    "logs", "log", "state", "cache", "skills", "agents", "commands", "hooks", "keyprobe",
    # Files that hold credentials, settings or shell setup.
    ".env", ".env.local", ".env.production", ".env.development", ".npmrc", ".netrc", ".pypirc", ".bashrc", ".profile",
    ".bash_profile", ".zshrc", ".gitconfig", ".git-credentials", ".claude.json", ".credentials.json", "auth.json",
    "credentials", "config", "config.json", "config.toml", "settings.json", "settings.local.json", "secrets.json",
    "application_default_credentials.json", "credentials.db", "access_tokens.db", "hosts.yml", "token.json",
    "session.json", "environment", "apply_patch", "acpmux", "cmux", "codex", "claude", "notes.txt", "README.md",
}
KNOWN_PROCESSES = {
    "bash", "sh", "dash", "zsh", "node", "bun", "python3", "python", "claude", "codex", "acpmux", "cmux", "cmux-tui",
    "sshd", "systemd", "systemd-journal", "systemd-logind", "systemd-udevd", "systemd-resolve", "sudo", "tmux", "cron",
    "dbus-daemon", "agetty", "containerd", "dockerd", "tail", "sleep", "env", "tool", "init", "rsyslogd", "git",
}
EXTENSIONS = {".json", ".env", ".toml", ".yaml", ".yml", ".ini", ".txt", ".md", ".ts", ".js", ".mjs", ".py", ".rs",
              ".sh", ".bin", ".conf", ".cfg", ".pem", ".key", ".db", ".log", ".bak", ".old"}
# What the probe itself writes in place of a value, kept only when it is the whole part (with a line number): any
# other character beside a mark is the machine's and goes through the same rule as any name.
OWN_MARKS = {"[a secret]", "[a piece of a secret]", "[a name]"} | {f"[{kind}]" for kind, _ in SHAPES}


def shown_part(name):
    """One part of a path, as it may be printed. A `:N` in it is the machine's, never taken for a line number: the
    probe adds its own line numbers after this (redacted)."""
    if name in KNOWN_NAMES or name in OWN_MARKS:
        return name
    ext = next((e for e in EXTENSIONS if name.endswith(e) and len(name) > len(e)), "")
    return "[a name]" + ext


def safe_place(text):
    """A finding's place (`/a/path:N` or `process NAME (N pids)`) with every part the machine named made safe."""
    m = re.match(r"^process (.*) \((\d+ pids?)\)$", text, re.S)
    if m:
        comm = m.group(1)
        return f"process {comm if comm in KNOWN_PROCESSES else '[a process]'} ({m.group(2)})"
    return "/".join(shown_part(part) for part in text.split("/"))

_PIECES = (0, set())


def pieces():
    """Every PIECE-long run of every found key (the whole key, if shorter), kept until another key is found."""
    global _PIECES
    if _PIECES[0] != len(FOUND):
        out = set()
        for value in FOUND:
            n = min(PIECE, len(value))
            out.update(value[i:i + n] for i in range(len(value) - n + 1))
        _PIECES = (len(FOUND), out)
    return _PIECES[1]


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
    keys = pieces()
    lengths = {len(k) for k in keys}

    def piece_of_key(m):
        word = m.group(0)
        if any(word[i:i + n] in keys for n in lengths for i in range(len(word) - n + 1)):
            return "[a piece of a secret]"
        return word

    return PART.sub(piece_of_key, text)


def redacted(value, place=False):
    """Every string in the report, redacted; places (`where`, `unreadable`) also cut down to safe names."""
    if isinstance(value, str):
        return safe_place(redact(value)) if place else redact(value)
    if isinstance(value, list):
        return [redacted(v, place) for v in value]
    if isinstance(value, dict):
        # Field names are the probe's own words, never the machine's: a key that spells one (`...findings...`) must
        # not rename the answer's fields, or the answer stops parsing and its finding is lost.
        out = {k: redacted(v, place or k in ("where", "unreadable")) for k, v in value.items() if k != "line"}
        # A file finding's line number is the probe's own count, added after the place is made safe.
        if isinstance(value.get("line"), int) and "where" in out:
            out["where"] += f":{value['line']}"
        return out
    return value


REFRESH = dict(SHAPES)["an OAuth refresh token"]
assert all(re.search(r"_(KEY|TOKEN|JSON)\b|_TOKEN_", n) for n in KEY_NAMES), "a key name the prefilter misses"


# A quote, backslash or slash escaped for a shell string or JSON (`\"`), and any ASCII character JSON writes as
# `\u00XX` (`sk\u002dproj-`, `OPENAI\u005fAPI\u005fKEY`, `\u0022`).
ESCAPED = re.compile(r'\\(["\'\\/])|\\u00([0-7][0-9A-Fa-f])')


def readings(text):
    """`text` as written, and as a shell or a JSON parser reads it once each layer of escaping is taken off (up to
    three): a login's JSON inside a shell string, its quotes written as backslash-quote, holds a refresh token's
    field only once they are unescaped. Every detector checks each reading, so an escaped credential is found as a plain one."""
    out = [text]
    while "\\" in out[-1] and len(out) < 4:
        nxt = ESCAPED.sub(lambda m: m.group(1) or chr(int(m.group(2), 16)), out[-1])
        if nxt == out[-1]:
            break
        out.append(nxt)
    return out


def shape_kinds(text):
    """The kinds of key `text` holds by shape, skipping public stand-ins. Never the values. Every text the probe
    checks (an environment value, an argument, a file's line or chunk) goes through here, so a refresh token is
    recorded for redaction wherever it was found. So is every other value a shape matched: redaction then replaces it
    as plain text wherever it shows up, whatever surrounds it."""
    kinds = set()
    for reading in readings(text):
        for kind, pattern in SHAPES:
            if not any(a in reading for a in ANCHORS[kind]):
                continue
            for m in pattern.finditer(reading):
                if m.group(0) in PUBLIC_VALUES:
                    continue
                kinds.add(kind)
                found(m.group(1) if pattern.groups else m.group(0))
    return kinds


def value_finding(value):
    """The kind of key `value` holds, or None. Never the value."""
    kinds = shape_kinds(value)
    return next((kind for kind, _ in SHAPES if kind in kinds), None)


# An environment variable's name prints as itself only when it is a known key's name or on KNOWN_VARS; any other name
# may carry a credential (`CACHE_<token>`, whatever its case).
KNOWN_VARS = {"PATH", "HOME", "USER", "SHELL", "PWD", "LANG", "TERM", "EDITOR", "TMPDIR", "XDG_CONFIG_HOME",
              "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "NODE_OPTIONS", "PYTHONPATH", "EXTRA_PATH"}


def shown_var(name):
    """An environment variable's name as it may be printed."""
    return name if name in KEY_NAMES or name in KNOWN_VARS else "[a variable]"


def scan_env(entries):
    """Findings in one environment: (NAME, kind) pairs. A key name with a real value counts; so does any
    variable whose value has a key's shape."""
    out = []
    for entry in entries:
        name, sep, value = entry.partition("=")
        if not sep:
            continue
        # A name in any case: a key's name in lower case is set the same way, and read by tools that fold case.
        if name.upper() in KEY_NAMES and value.strip() not in PLACEHOLDERS:
            found(value)
            out.append((name.upper(), value_finding(value) or "a value"))
        else:
            kind = value_finding(value)
            if kind:
                out.append((shown_var(name), kind))
    return out


def key_name(word):
    """The key name a command-line word spells (`--openai-api-key` is OPENAI_API_KEY), or None."""
    name = word.upper().replace("-", "_")
    return name if name in KEY_NAMES else None


def real_value(value):
    """A value after a key's name in an environment or argument: anything but empty, the placeholder or a reference."""
    v = value.strip().strip("'\"")
    return v not in PLACEHOLDERS and not v.startswith("$")


# A shell word: quoted and bare pieces run together (`--key="a b"`), or a run of separators (`;`, `&&`, `|`). An
# unbalanced quote ends at the text's end. One regex pass: a long script costs its length once.
SHELL_WORD = re.compile(r"""(?:'[^']*'?|"(?:\\.|[^"\\])*"?|[^\s'";&|()])+|[;&|()]+""")
SHELL_QUOTED = re.compile(r"""'([^']*)'?|"((?:\\.|[^"\\])*)"?""")


def shell_words(script):
    """A script's words as a POSIX shell splits them, quotes taken off, its separators as their own words."""
    return [SHELL_QUOTED.sub(lambda m: m.group(1) if m.group(1) is not None else m.group(2), w)
            for w in SHELL_WORD.findall(script)]


def scan_args(args, depth=0):
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
            if key_name(m.group(1)) and real_value(m.group(2)):
                found(m.group(2))
                out.add(key_name(m.group(1)))
        if depth < SCRIPT_DEPTH and any(c.isspace() for c in arg):
            # Only the stretches around key names' endings are split, overlapping ones merged: each byte at most once.
            spans = []
            for m in SCRIPT_NAME_HINT.finditer(arg):
                a, b = max(0, m.start() - NAME_SPAN), m.end() + HIT_SPAN
                if spans and a <= spans[-1][1]:
                    spans[-1][1] = b
                else:
                    spans.append([a, b])
            for a, b in spans:
                out.update(scan_args(shell_words(arg[a:b]), depth + 1))
    return sorted(out)


def entropy(value):
    """Bits per character: a random key is near log2 of its alphabet, a word or identifier far below."""
    counts = {}
    for c in value:
        counts[c] = counts.get(c, 0) + 1
    return -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values())


def literal_secret(value):
    """Whether a value written after a key's name in a file looks like the key itself: a token with a letter and a
    digit, or one without digits whose characters are as varied as a random key's (an identifier such as
    `requiredStringValueHere` is not, at under 4 bits a character)."""
    if value in PUBLIC_VALUES or STAND_IN.search(value) or NOT_LITERAL.search(value):
        return False
    if SECRET_LITERAL.match(value):
        return True
    if SECRET_PRINTABLE.match(value) and entropy(value) >= 4.0:
        return True
    return bool(SECRET_TOKEN.match(value)) and len(value) >= 20 and entropy(value) >= 4.2


def named_kinds(text):
    """The key names `text` gives a literal secret (an assignment, or a JSON field named after a key), each value
    recorded for redaction."""
    seen = set()
    for reading in readings(text):
        if not NAME_ENDING.search(reading):
            continue
        for m in (m for p in ASSIGNS for m in p.finditer(reading)):
            if m["name"].upper() in KEY_NAMES and literal_secret(m["value"]):
                found(m["value"])
                seen.add(m["name"].upper())
    return seen


def scan_text(text):
    """Findings in a file's text: (line number, what) pairs."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        seen = shape_kinds(line) | named_kinds(line)
        out.extend((n, what) for what in sorted(seen))
    return out


# A key's name or a refresh token's field, then `:` or `=`: its value follows, on this line or a later one.
OPENER = re.compile(r'(?:(?:"refresh_token"|\b[A-Za-z][A-Za-z0-9_]*(?:_KEY|_TOKEN|_JSON|_key|_token|_json)\b["\']?\]?)\s*[?+]?[:=]'
                    r'|["\'][A-Za-z][A-Za-z0-9_]*(?:_KEY|_TOKEN|_JSON|_key|_token|_json)["\']\s*,)' + GAP + r'["\']?')
VALUE_TO_END = re.compile(VALUE)
# How far past its line a value is followed before it counts as ended: past any real key.
MAX_VALUE = 1 << 20


def open_value(text):
    """Whether `text`, in any of its readings (escapes taken off), ends inside a value (or before it starts) after a
    key's name or a refresh token's field."""
    for reading in readings(text):
        last = None
        for last in OPENER.finditer(reading):
            pass
        if last is not None and VALUE_TO_END.fullmatch(reading, last.end()) is not None:
            return True
    return False


def context_kinds(text, line_end):
    """What a key's name or a refresh token's field opening a line names when its value is on a later line (JSON
    and YAML put it there freely): matches that start before `line_end` in `text`, the line and what follows it.
    Each value is recorded for redaction."""
    seen = set()
    # Each reading's own line end: taking escapes off shortens the line. The line can run out of escapes before what
    # follows it does (a value escaped on the next line): every later reading keeps the line's last length.
    ends = [len(r) for r in readings(text[:line_end])]
    for i, reading in enumerate(readings(text)):
        end = ends[min(i, len(ends) - 1)]
        if '"refresh_token"' in reading:
            for m in REFRESH.finditer(reading):
                if m.start() < end and m.group(0) not in PUBLIC_VALUES:
                    found(m.group(1))
                    seen.add("an OAuth refresh token")
        if not NAME_ENDING.search(reading):
            continue
        for m in (m for p in ASSIGNS for m in p.finditer(reading)):
            if m.start() < end and m["name"].upper() in KEY_NAMES and literal_secret(m["value"]):
                found(m["value"])
                seen.add(m["name"].upper())
    return seen


# A login file's own fields: every string under one of these names is recorded for redaction, whatever its shape,
# so a path that spells one (a folder named after the token) cannot carry it out.
LOGIN_FIELD = re.compile(r"token|key|secret|password|credential", re.I)


# Spaces within the line only: `\s` crosses line breaks, and `^\s*` rescanned every blank line after each line start.
LOGIN_LINE = re.compile(r"^[ \t]*([A-Za-z0-9_.-]+)[ \t]*[=:][ \t]*(\S+)[ \t]*\r?$", re.M)


# How much of a login file is read for its fields (a real one is a few KiB), so a huge or sparse one cannot take the
# probe's memory or its budget.
LOGIN_READ = 16 << 20
LOGIN_QUOTED = re.compile(r'"([^"\\]{1,128})"\s*:\s*"((?:[^"\\]|\\.)*)"')


def login_values(path):
    """Records the secret fields of a login file for redaction, from the whole file: JSON fields, quoted
    `"name": "value"` pairs (JSON the parser refuses) and `name = value` lines (an AWS credentials file is INI). Never
    reports them. Places print only safe names (safe_place), so this is the second guard, not the only one."""
    try:
        with open(path, "rb") as f:
            raw = f.read(LOGIN_READ + 1)
    except OSError:
        return
    # A login file past LOGIN_READ is not a real one: its first LOGIN_READ bytes are read for fields, never parsed whole.
    whole = len(raw) <= LOGIN_READ
    raw = raw[:LOGIN_READ]
    text = raw.decode("utf-8", "replace")
    for pattern in (LOGIN_LINE, LOGIN_QUOTED):
        for m in pattern.finditer(text):
            if LOGIN_FIELD.search(m.group(1)):
                found(m.group(2))
    if not whole:
        return
    try:
        data = json.loads(raw)
    except ValueError:
        return
    stack = [(None, data)]
    while stack:
        name, value = stack.pop()
        if isinstance(value, dict):
            stack.extend(value.items())
        elif isinstance(value, list):
            stack.extend((name, v) for v in value)
        elif isinstance(value, str) and name and LOGIN_FIELD.search(name):
            found(value)


def read(path, limit=1 << 20):
    with open(path, "rb") as f:
        return f.read(limit)


class OutOfTime(Exception):
    """The walk's deadline passed inside a file: `hits` holds what was found in the part read."""

    def __init__(self, hits):
        super().__init__("past the deadline")
        self.hits = hits


def scan_file(path, deadline=math.inf):
    """Findings in one whole file: (line number or None, what). Past `deadline` (checked at each read and each hit) it raises
    OutOfTime with the findings so far. A binary file (a database, say) is read in overlapping
    chunks, by shape and by key name; a binary has no lines. In a text file only the lines the prefilter hits are checked: most hold none of the
    prefixes, and a Python loop over every line of every file was the walk's cost."""
    out = []
    with open(path, "rb") as f:
        head = f.read(4096)
        f.seek(0)
        if b"\0" in head:
            seen = set()
            tail = b""
            while True:
                if time.monotonic() > deadline:
                    raise OutOfTime([(None, what) for what in sorted(seen)])
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                window = tail + chunk
                # Every shape starts at a prefilter prefix (a quote before refresh_token, a word boundary before the
                # rest), so only a short stretch from each hit is checked, not the whole chunk with every shape.
                tail = window[-OVERLAP:]
                for hit in PREFILTER.finditer(window):
                    if time.monotonic() > deadline:
                        raise OutOfTime([(None, what) for what in sorted(seen)])
                    at = hit.start()
                    stop = at + HIT_SPAN
                    if escape_hit(hit, window[max(0, at - NAME_SPAN):stop].decode("latin-1")):
                        continue
                    # A value left open at the span's end (a long refresh token) is followed to its end, up to
                    # MAX_VALUE; one still open at the window's end is checked again with the next chunk.
                    # Each stretch starts a name's length before the hit: a key's name, or an escaped opening quote
                    # (`\u0022refresh_token`), precedes it.
                    begin = max(0, at - NAME_SPAN)
                    while open_value(window[begin:stop].decode("latin-1")) and stop < len(window) and stop - at < MAX_VALUE:
                        stop += stop - at
                    if stop >= len(window) and open_value(window[begin:].decode("latin-1")) and len(window) - at < MAX_VALUE:
                        # Held back with its key's name: the name starts up to NAME_SPAN before the hit.
                        tail = window[max(0, at - NAME_SPAN):]
                        break
                    stretch = window[begin:stop].decode("latin-1")
                    seen.update(shape_kinds(stretch))
                    seen.update(named_kinds(stretch))
            # Hits held back for the next chunk (a value still open) are checked to the file's end.
            for hit in PREFILTER.finditer(tail):
                if time.monotonic() > deadline:
                    raise OutOfTime([(None, what) for what in sorted(seen)])
                stretch = tail[max(0, hit.start() - NAME_SPAN):hit.start() + MAX_VALUE].decode("latin-1")
                seen.update(shape_kinds(stretch))
                seen.update(named_kinds(stretch))
            return [(None, what) for what in sorted(seen)]
        # Whole lines a chunk at a time (a partial last line waits for the next chunk); only the lines the prefilter
        # hits are decoded and checked, and their numbers are counted from the newlines before them.
        # A line longer than one read is checked in pieces, each carrying the last OVERLAP bytes of the one before, so a
        # key's name across the cut is whole in the next piece. Hits in the carried bytes are checked again (a name the cut
        # split matched in neither piece alone); a finding counts once per line. One huge line holds a read or two.
        line, rest, carried, got = 1, b"", 0, set()
        while True:
            if time.monotonic() > deadline:
                raise OutOfTime(out)
            chunk = f.read(CHUNK)
            block = rest + chunk
            cut = len(block) if not chunk else block.rfind(b"\n") + 1
            carried = 0
            if chunk and len(block) - cut > CHUNK:
                cut, carried = len(block) - OVERLAP, OVERLAP
            whole, rest = block[:cut], block[cut - carried:]
            # `dead`: a line whose escapes lead nowhere. escape_hit reads the whole line, so each of its other `\u00`
            # hits would read it again: a line of many escapes cost its length times their number.
            # `start` and `end` bound the line of the last hit (`end` at its newline): a hit before `end` is on that line,
            # and the next line's bounds are searched from there, so each byte is searched once however many hits a line has.
            seen_to, last, dead, start, end = 0, -1, -1, 0, -1
            for hit in PREFILTER.finditer(whole):
                if time.monotonic() > deadline:
                    raise OutOfTime(out)
                if hit.start() > end:
                    start = whole.rfind(b"\n", max(end, 0), hit.start()) + 1
                    end = whole.find(b"\n", hit.start())
                    end = len(whole) if end < 0 else end
                if start == last or (start == dead and hit.group(0) == b"\\u00"):
                    continue
                if escape_hit(hit, whole[start:end].decode("utf-8", "replace")):
                    dead = start
                    continue
                line += whole.count(b"\n", seen_to, start)
                seen_to = last = start
                seen = {what for _, what in scan_text(whole[start:end].decode("utf-8", "replace"))}
                # A value on a later line: the stretch after the hit, read ahead past this chunk's end if need be
                # (what is read ahead is kept for the next chunk).
                # From the line's start to past its end, so every hit on the line has its stretch checked, not the first,
                # and on until a value left open there (`"refresh_token":` then a long token) has ended.
                stop, ended = end + HIT_SPAN, not chunk
                while True:
                    if time.monotonic() > deadline:
                        raise OutOfTime(out)
                    if stop > len(block) and not ended:
                        need = stop - len(block)
                        more = f.read(need)
                        block += more
                        rest += more
                        ended = len(more) < need
                    after = block[start:stop].decode("utf-8", "replace")
                    if (ended and stop >= len(block)) or stop - end >= MAX_VALUE or not open_value(after):
                        break
                    stop += max(HIT_SPAN, stop - end)
                seen |= context_kinds(after, len(whole[start:end].decode("utf-8", "replace")))
                for what in sorted(seen):
                    if (line, what) not in got:
                        got.add((line, what))
                        out.append((line, what))
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
        # This probe's source reaches it as a shell's heredoc: the argument that carries it (the shell's script) is
        # skipped in this probe's own chain, every other argument of every ancestor (a supervisor started with a key)
        # is read.
        if int(pid) in me:
            args = [a for a in args if SOURCE_MARK not in a]
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


def login_file(path, walked, st, report):
    """A login file is one by the name it is reached under (a link named .codex/auth.json counts); each name once."""
    for suffix, what in LOGIN_FILES.items():
        if walked.endswith("/" + suffix) and st.st_size > 0 and (walked, what) not in report["_login"]:
            report["_login"].add((walked, what))
            login_values(path)
            report["findings"].append({"place": "file", "where": walked, "what": what})


def skipped_login_files(root, dirpath, report):
    """The login files named across a folder the walk skips because it already read it under another name. A login
    name wholly inside the folder was seen under the first name, since the names inside it are the same; one that
    starts outside is not (`/workspace/p/.codex` linked to a cache folder: its auth.json). So for each login name
    whose leading folders end the skipped folder's name, the rest of it under the folder is checked."""
    walked_dir = shown(root, dirpath)
    for suffix in LOGIN_FILES:
        parts = suffix.split("/")
        for k in range(1, len(parts)):
            if not walked_dir.endswith("/" + "/".join(parts[:k])):
                continue
            path = os.path.join(dirpath, *parts[k:])
            try:
                st = os.stat(path)
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                login_file(path, shown(root, path), st, report)


def scan_login_files(root, report):
    """Every home's login files by their own names, whatever the walk skipped: a home's `.codex` linked to a folder
    the walk already read under another name is never walked again, but its auth.json is still a login file."""
    homes = [os.path.join(root, "root")]
    try:
        homes += [os.path.join(root, "home", h) for h in sorted(os.listdir(os.path.join(root, "home")))]
    except OSError:
        pass
    for home in homes:
        for suffix in LOGIN_FILES:
            path = os.path.join(home, suffix)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if stat.S_ISREG(st.st_mode):
                login_file(path, shown(root, path), st, report)


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
                    if st.st_dev not in pseudo:
                        skipped_login_files(root, dirpath, report)
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
                    login_file(path, walked, st, report)
                    # Named and classed by where it is once symbolic links are resolved; each such name once.
                    where = shown(real_root, os.path.realpath(path))
                    if where in reported:
                        continue
                    reported.add(where)
                    inode = (st.st_dev, st.st_ino)
                    out_of_time = False
                    if inode not in contents:
                        try:
                            contents[inode] = scan_file(path, deadline)
                        except OutOfTime as cut:
                            contents[inode], out_of_time = cut.hits, True
                        report["scanned"]["files"] += 1
                    hits = contents[inode]
                except OSError:
                    if os.path.lexists(path):
                        report["scanned"]["files_unreadable"] += 1
                    continue
                # Installed software's public text is a key's shape alone (a scanner's list of public keys). A key
                # found by its context (a key's name given a secret, or a `"refresh_token":` field, as in an
                # assignment in /opt/tool/.env) is configuration, a finding anywhere.
                shipped = shipped_kinds(where, path) or frozenset()
                for line, what in hits:
                    listed = report["shipped"] if what in shipped and what not in CONTEXTUAL else report["findings"]
                    listed.append({"place": "file", "where": where, "line": line, "what": what})
                if out_of_time:
                    # A file read in part: what it showed is reported, and the walk is cut there.
                    report["truncated"] = True
                    return


# The heredoc delimiter keyProbeCommand (cloud-journey.ts) wraps this source in: the shell argument holding it.
SOURCE_MARK = "CMUX_KEY_" + "PROBE"


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
    report["_login"] = set()
    scan_login_files(root, report)
    scan_files(root, t0 + budget, report)
    del report["_login"]
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
