#!/usr/bin/env python3
"""Generate the Chromium Host wire from cmux_cef_shim.h and chromium-host-ops.json, and check it.

The Chromium Host (plans/cmux-next/chrome-parity/p01-process.md, sections 3.1 and 3.2) runs
Chromium's browser process outside cmux. cmux keeps calling the same `cmux_shim_*` C ABI; in host
mode it loads a remote shim whose every export is machine-generated from the header, the way
Chromium generates its IPC stubs and proxies from .mojom files
(mojo/public/tools/bindings/mojom_bindings_generator.py) instead of writing them by hand. Like a
mojom method without `[Sync]`, no op here waits for the other process: there is no `sync` class.

Inputs (paths relative to --root, the repository by default):

  SHIMH  Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h
         Parsed after removing comments and preprocessor lines (`#define` included). Every
         `CMUX_SHIM_EXPORT` declaration is an export; cmux_shim_event_kind_t lists the event kinds.
  OPS    plans/cmux-next/chromium-host-ops.json (task p01-process-010), one entry per export and
         per event kind; `classes` and `fields` in the file document it:
           {"version": 1, "pseudo_events": {"attach": "..."},
            "exports": [{"name": "cmux_shim_x", "class": CLASS,
                         "args": [{"name": "browser_id", "type": "int"},
                                  {"name": "fn", "type": "void (*)(void* context)", "function_pointer": true}],
                         "returns": "int", "result_used_by": [], "mirror_key": null,
                         "refresh_events": [], "pending_keys": [], "reply_event": null,
                         "reason": "", "channel": "control"}, ...],
            "events": [{"kind": "CMUX_SHIM_ADDRESS", "value": 4,
                        "refreshes": ["tab.navigation_state[browser_id]"]}, ...]}
            "optional_exports": [...], "optional_events": [...],
            "host_mode_rewrites": [{"site": "CmuxNextBrowser/CEF/File.swift: Type.function(_:)",
                                    "exports": ["cmux_shim_x"], "needs": "reply", "change": "...",
                                    "task": "p01-process-021"}, ...]}
         `args`, `returns` and an event's `value` repeat the header (`--dump-header` prints them),
         so a signature change shows as drift. CLASS is one of
           post     one-way: the remote returns at once (1 for an int); a Swift caller that reads
                    the result is refused (--check-return-use)
           mirror   served from cmux's main-thread cache; `mirror_key` is scope.field[args], its
                    params the export's arguments (out-parameters excluded: an int buffer's capacity
                    is the reader's, and the host pushes MIRROR_OUT_CAPACITY ints); `refresh_events` are
                    event kinds, KIND:<request> (a CMUX_SHIM_TAB_EVENT sub-kind) or a pseudo event
           async    sent with a token and awaited by it: the REPLY frame carries the result and the
                    out-parameters (the start result, when `reply_event` is an event that answers it
                    later). The remote returns 1 once sent (a string result: NULL) and zeroes the
                    out-parameters; Swift sites move to the token API (task 018)
           mint     the client mints the id and sends it first; `mint_returns` names the C return:
                    `id` (the minted id) or `sent` (1 once sent; `reply_event` carries the id with
                    the export's `request`)
           policy   a callback setter: the client keeps the callback, the host installs its own
                    handler (hand-written InstallPolicy<Name> in HOST/src) and pushes events
           view     like post; NSView* arguments travel as ChromiumHostPageView tokens
           local    hand-written client code (HOST/client, outside generated/)
           preinit  queued in the client and applied in order before CefInitialize. A non-void one
                    returns the client's own check and names `reply_event` wire:REPLY: the host's
                    verdict, sent by token when it applies the op
         `pending_keys` are mirror keys a post (or an async op) changes, `*` for a param the op
         does not name: the client marks them pending under the op's token until the host's ack
         (an async op's: its REPLY), and the host pushes them again after it runs the op and
         before that ack or REPLY (RefreshMirror), so the value cmux reads once the mark clears is
         the host's after the op. `local` and
         `policy` need a `reason`. `channel` "input" sends the op on the input ring.
         `optional_exports` are fork API symbols CEFShimLibrary binds with r.optional that the
         header does not declare yet (with a `fork_api`); they take op ids after the header's, and
         the host calls them through ctx.OptionalExport. `optional_events` are event kinds
         CEFShimEvent.swift decodes that cmux_shim_event_kind_t does not list yet.
         `host_mode_rewrites` are Swift sites the remote shim cannot keep as they are, and the
         sites that stay as written (needs `kept`, `change` says why: in-process-only code, a
         local the remote answers the same way); --check-return-use and --check-pre-attach accept
         a listed site's calls of its exports. --swift-sites drops a site that is done: one listed
         with needs after_attach, host_exit or kept (a finished pending_tab site becomes kept), an
         async call (or a preinit whose verdict is a wire:REPLY) in the token form, inside a closure
         handed to CEFRuntime's sendAsync, siteCall
         or profileWrite (CEFRuntime+HostReplies.swift), which await the answer the same way in
         both backends, and a mint_returns id call in the mint form (its id keys a `.reply(for:`
         wait for its reply_event). A site listed with needs
         `client` is a local export the client defines by hand (HOST/client, outside generated/)
         with the in-process contract, so the same call serves both backends: `change` names the
         client's wire entry point (cmux_remote::PostPasswordReveal), and the site stays listed
         until HOST/client both defines the export and calls that entry point outside its own
         declarations and definitions (the transport sends it).

Outputs (written by a run without a check flag; --check fails when one is stale):

  HOST/src/generated/host_dispatch.inc       cmux_host::DispatchOp, ProduceMirror, kOptionalExports,
                                             kMirrorRefreshes, ForEachMirrorRefreshedBy, EncodeEvent
  HOST/client/generated/remote_shim.inc      every cmux_shim_* export of a generated class, and
                                             cmux_shim_abi_id (the header's SHA-256)
  CEFS/ChromiumHost/Generated/ChromiumHostOps.swift
                                             ChromiumHostOp (ids, classes, wire types, Call,
                                             reply decoder, refresh table) and ChromiumHostEventKind
                                             (record decoder, mirrors each event refreshes)

  HOST = Packages/macOS/CmuxNext/ChromiumHost, CEFS = .../Sources/CmuxNextBrowser/CEF. Op ids are
  1..N in header order, then optional_exports. kShimAbiID is the header's identity, as the shim
  ABI's; kWireID (in both HELLOs) hashes the op table, so either side refuses another generation.

The .inc files are included after the code that defines their interface (tasks 013 and 014). Every
C argument is `arg_<name>` in generated code and no generator local starts with `arg_`, so a header
argument named `reply` or `token` never collides with a generated local:

  namespace cmux_remote (client):
    TlvWriter: I32(int32_t) U32(uint32_t) I64(int64_t) F64(double) Str(const char*) (NULL kept
      apart from "") Bytes(const void*, size_t) View(void* ns_view) StrList(const char* const*, int)
    TlvReader (a cached mirror value): present() I32() U32() I64() Str() -> std::optional<std::string>
      Bytes() -> std::string  I32Array(int* out, int capacity)
    Never blocking; each returns whether the op was accepted for sending (false: no channel):
      bool Post(uint16_t op, uint32_t token, const TlvWriter&)               control channel
      bool PostInput(uint16_t op, uint32_t token, const TlvWriter&)          input ring
      bool PostForReply(uint16_t op, uint32_t token, const TlvWriter&)  registers the token
        for the reply handler (task 018) before it sends, and drops it when the op is not sent
    int32_t PostPreinit(uint16_t op, uint32_t token, const TlvWriter&)  queued until attach, a post
      after initialize; returns the client's check of the arguments (1 queued, 0 refused). A token
      other than 0 is registered as PostForReply registers it, for the host's verdict
    uint32_t NextToken()   int32_t MintID(uint16_t op) (the op picks the id range)
    char* Dup(const std::string&)  (malloc)
    void MarkPending(uint16_t mirror_op, uint32_t token, const TlvWriter& key, uint32_t wildcards)
      (bit i of wildcards: param i is `*` and absent from key)
    TlvReader MirrorLookup(uint16_t mirror_op, const TlvWriter& key)
    void SetPolicy(uint16_t op, void* fn)
  namespace cmux_host (host):
    TlvReader: I32() U32() I64() F64() Str() -> std::optional<std::string>  Bytes() -> std::string
      View() -> uint64_t  StrList() -> std::vector<std::string>  ok()  AtEnd()
    TlvWriter: as the client's, plus I32Array(const int*, size_t)
    HostContext: int Browser(int32_t client_id)  void* PageView(uint64_t token)  Ack(uint32_t)
      void* OptionalExport(uint16_t op) (the host shim's symbol, or NULL)
      Reply(uint32_t token, const TlvWriter&)
      BindMinted(uint16_t op, int32_t minted, int64_t result, int32_t client_browser)
        (client_browser: the export's first *browser_id argument as cmux sent it, 0 without one;
        devtools_call's result is keyed by its browser, host_client_ids.h)
      BindMintedOnEvent(uint16_t op, int32_t minted, int event_kind, int32_t request, int64_t started)
        (the event of that kind and request reports Chromium's id; started 0: it never comes)
      PushMirror(uint16_t op, const TlvWriter& key, const TlvWriter& value)
      RefreshMirror(uint16_t op, const TlvWriter& key, uint32_t wildcards): pushes mirror `op` again
        now, before the op's ACK: the key itself when `key` names every parameter, else each key it
        has pushed that matches (bit i of wildcards: param i is `*` and absent from key)
    void Wipe(std::vector<std::string>&)
  scripts/cmux-next/tests/gen-chromium-host-wire.test.sh declares this interface and compiles both
  .inc files against it (c++ -fsyntax-only -Wshadow -Werror).

Commands:

  gen-chromium-host-wire.py                 write the generated files
  ... --check                               ops complete and valid, generated files current, every
                                            export implemented on both sides (exit 1 otherwise)
  ... --check-ops                           only the ops JSON, against the header and CEFShimLibrary
  ... --list-missing                        the live queue: export, class, missing side
  ... --swift-sites [--by-file]             Swift call sites that change in host mode: async,
                                            mint, view, local, and post-like results read; an
                                            async site that reads its wire:REPLY answer in the
                                            call's turn, outside host_mode_rewrites, adds sync-reply
  ... --check-return-use                    exit 1 when a Swift caller binds, guards, compares or
                                            returns the result of a post, view, preinit or policy,
                                            outside host_mode_rewrites
  ... --check-pre-attach                    exit 1 for a mirror read on the startup path
                                            (STARTUP_ROOTS and the functions they pass the shim to)
                                            that no host_mode_rewrites entry (after_attach) lists
  ... --check-view-parity [--list-unmapped] every method of the vendored remote_cocoa mojoms
      [--list-pending]                      (plans/cmux-next/remote_cocoa_mojom/) maps to one of:
                                            op (a header or optional export), event (a header or
                                            optional event kind), wire (a Kind of chromium_host_wire.h)
                                            or not_needed (the reason) in
                                            plans/cmux-next/chromium-host-view-parity.json. A pending
                                            row (the design task that builds its carrier, with a note
                                            naming it) is not a mapping: it stays unmapped, so the
                                            check fails and --list-unmapped lists it until the row
                                            names the carrier; --list-pending prints those rows and
                                            their tasks. Each mojom is listed with its Chromium path,
                                            version and commit (the version
                                            scripts/cmux-next/cef-manifest.json pins) and sha256;
                                            prints the method and [Sync] counts it parsed from the
                                            files, by interface and target
  ... --dump-header                         the parsed header as JSON (counts, exports, events)

No CI job runs this (p01-process section 4, rule 4); scripts/cmux-next/tests/
gen-chromium-host-wire.test.sh tests it without a build.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

SCRIPT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SCRIPT_ROOT / "scripts"))
from swift_source_mask import mask_swift_source  # noqa: E402

GENERATOR = "scripts/cmux-next/gen-chromium-host-wire.py"
APP = "Packages/macOS/CmuxNext/Sources"
CEFS = APP + "/CmuxNextBrowser/CEF"
HOST = "Packages/macOS/CmuxNext/ChromiumHost"
SHIMH = CEFS + "/Shim/cmux_cef_shim.h"
SHIM_LIBRARY = CEFS + "/CEFShimLibrary.swift"
# CEFShimLibrary's initializer, which binds every export (p10-stability-067 moved it out of SHIM_LIBRARY).
SHIM_LIBRARY_BIND = CEFS + "/CEFShimLibrary+Bind.swift"
OPS = "plans/cmux-next/chromium-host-ops.json"
PARITY = "plans/cmux-next/chromium-host-view-parity.json"
MOJOM_DIR = "plans/cmux-next/remote_cocoa_mojom"
DESIGN_RESULT = "plans/cmux-next/chrome-parity/design-result.json"
CEF_MANIFEST = "scripts/cmux-next/cef-manifest.json"  # "chromium": the fork's Chromium version
HOST_INC = HOST + "/src/generated/host_dispatch.inc"
CLIENT_INC = HOST + "/client/generated/remote_shim.inc"
SWIFT_OUT = CEFS + "/ChromiumHost/Generated/ChromiumHostOps.swift"
HOST_SRC = HOST + "/src"
CLIENT_SRC = HOST + "/client"
HOST_WIRE = HOST_SRC + "/chromium_host_wire.h"  # the page view's input and push frames (enum Kind)

CLASSES = ("post", "mirror", "async", "mint", "policy", "view", "local", "preinit")
GENERATED_CLIENT = {"post", "mirror", "async", "mint", "policy", "view", "preinit"}
POST_LIKE = {"post", "view", "preinit", "policy"}  # the remote returns a stand-in result
SITE_CLASSES = {"async", "mint", "view", "local"}
SCHEMA_VERSION = 1
TOP_LISTS = ("optional_exports", "optional_events", "host_mode_rewrites")
TOP_FIELDS = {"version", "header", "sources_root", "design", "classes", "fields", "pseudo_events", "exports",
              "events", *TOP_LISTS}
REQUIRED_EXPORT_FIELDS = {"name", "class", "args", "returns", "result_used_by", "mirror_key", "refresh_events",
                          "pending_keys", "reply_event", "reason"}
EXPORT_FIELDS = REQUIRED_EXPORT_FIELDS | {"channel", "mint_returns"}
OPTIONAL_EXPORT_FIELDS = EXPORT_FIELDS | {"fork_api"}  # fork_api: the fork API that adds the symbol
DOCUMENTED_FIELDS = EXPORT_FIELDS | set(TOP_LISTS)  # what `fields` in the ops JSON explains
EVENT_FIELDS = {"kind", "value", "refreshes", "reason"}
REWRITE_FIELDS = {"site", "exports", "needs", "change", "task"}
REWRITE_NEEDS = ("after_attach", "reply", "pending_tab", "host_exit", "kept", "client")
# A listed site with one of these needs is done as the entry says; a `reply` site is done only in the
# token form (TOKEN_FORM_CALLS). A `pending_tab` site still needs its work: once done, its entry
# becomes `kept`, with a change that names the task that did it. A `client` site is done once the
# hand-written client defines its export and calls the wire entry point its change names (CLIENT_WIRE).
SETTLED_NEEDS = ("after_attach", "host_exit", "kept")
CLIENT_WIRE = re.compile(r"\bcmux_remote::(Post\w+)\b")  # a `client` entry's wire entry point
# CEFRuntime functions that send an async op and await its answer the same way in both backends
# (CEFRuntime+HostReplies.swift, task p01-process-021): an async call in a closure handed to one is in
# the token form, and --swift-sites no longer lists it. So is a preinit call whose verdict is a
# wire:REPLY (task p01-process-070: the remote shim returns its own check and the host's verdict comes
# as that REPLY). A mint call there is no reply's call (sendAsync returns nothing sent for it), so it
# stays listed.
TOKEN_FORM_CALLS = ("sendAsync", "siteCall", "profileWrite")
TOKEN_FORM_CLASSES = ("async",)
TOKEN_FORM_VERDICT_CLASSES = ("preinit",)  # with reply_event wire:REPLY
MINT_RETURNS = ("id", "sent")  # the minted id at once, or 1 when sent (the id arrives in reply_event)
REPLY_WIRE = "wire:REPLY"  # the control channel's REPLY frame answers the call
ARG_PREFIX = "arg_"  # every C argument in generated code; generator locals never start with it
# Functions that run before CefInitialize returns; --check-pre-attach follows the CEFShimLibrary they pass on.
STARTUP_ROOTS = (("CmuxNextBrowser/CEF/CEFLibraryLoader.swift", "CEFLibraryLoader", "load"),
                 ("CmuxNextBrowser/CEF/CEFRuntime.swift", "CEFRuntime", "initialize"))
CHANNELS = ("control", "input")
MAX_RECORDS = 1 << 16
MAX_OUT_CAPACITY = 1 << 16
# A mirror's int buffer (an int* with its capacity) as the host pushes it: the capacity is the reader's,
# not part of the key, so the host fills this many and each read copies what fits its own buffer
# (TlvReader::I32Array). Far under the frame bound (control::kMaxBody).
MIRROR_OUT_CAPACITY = 64
EVENT_OP, REPLY_OP, MIRROR_OP, ACK_OP = 0x8001, 0x8002, 0x8003, 0x8004

# Wire kinds of one C argument. Sent: i u l d s b v L R; out-params (in the reply): I A B;
# never marshalled: F (function pointer), C (its context), ? (unknown).
OUT_KINDS = {"I", "A", "B"}
SWIFT_TYPE = {"i": ".int32", "u": ".uint32", "l": ".int64", "d": ".double", "s": ".string", "b": ".bytes",
              "v": ".view", "L": ".strings", "R": ".records", "S": ".string"}
REPLY_SWIFT = {"I": ".int32", "A": ".int32Array", "B": ".bytes"}
ACRONYMS = {"url": "URL", "id": "ID", "ids": "IDs", "abi": "ABI", "ssl": "SSL", "api": "API", "json": "JSON",
            "devtools": "DevTools", "ext": "Ext", "otr": "OTR"}
SWIFT_KEYWORDS = {"default", "import", "init", "self", "protocol", "func", "return", "in", "is", "as", "case",
                  "class", "struct", "enum", "extension", "let", "var", "if", "else", "for", "while", "do",
                  "switch", "break", "continue", "where", "throw", "throws", "try", "catch", "guard", "defer",
                  "repeat", "static", "subscript", "super", "nil", "true", "false", "operator", "inout",
                  "internal", "private", "public", "fileprivate", "open", "deinit", "typealias", "any", "some"}


class Failure(Exception):
    """A problem the run reports and exits 1 on."""


# ---------------------------------------------------------------------------------------------
# Header


@dataclass
class Arg:
    ctype: str  # normalized C type ("const char*"), or the whole declarator for a function pointer
    name: str
    kind: str = "?"
    pair: Arg | None = None  # the length or capacity argument this one consumed
    pointer_type: str = ""  # an inline function pointer's type without its name: "void (*)(void* context)"

    @property
    def decl(self) -> str:
        return self.ctype if self.kind == "F" and "(*" in self.ctype else f"{self.ctype} {self.name}"

    @property
    def var(self) -> str:
        """The argument's name in generated code: never one of the generator's own locals."""
        return ARG_PREFIX + self.name

    @property
    def generated_decl(self) -> str:
        """The parameter as a generated function declares it (named `var`)."""
        if self.kind == "F" and self.pointer_type:
            return self.pointer_type.replace("(*)", f"(*{self.var})", 1)
        return f"{self.ctype} {self.var}"

    @property
    def c_type(self) -> str:
        """The parameter's type without its name, for a function pointer type."""
        return self.pointer_type or self.ctype

    def as_json(self) -> dict:
        """The argument as the ops JSON lists it."""
        entry: dict = {"name": self.name, "type": self.pointer_type or self.ctype}
        if self.kind == "F":
            entry["function_pointer"] = True
        return entry


@dataclass
class Export:
    name: str
    returns: str
    args: list[Arg]
    owned_free: bool  # its char* result is freed with cmux_shim_free_owned
    index: int = 0
    wire: list[Arg] = field(default_factory=list)  # args in wire order, pairs folded
    optional: bool = False  # an optional_exports entry: not in the header; the host resolves it at run time

    @property
    def c_signature(self) -> str:
        """The export's function pointer type: `int (*)(int, const char*)`."""
        return f"{self.returns} (*)({', '.join(a.c_type for a in self.args) or 'void'})"

    @property
    def short(self) -> str:
        return self.name[len("cmux_shim_"):]

    @property
    def ret_kind(self) -> str:
        return {"void": "", "int": "i", "unsigned int": "u", "int64_t": "l", "char*": "s",
                "const char*": "S"}.get(self.returns, "?")


@dataclass
class Header:
    exports: list[Export]
    events: list[tuple[str, int]]
    structs: dict[str, list[Arg]]
    identity: str
    fn_types: set[str] = field(default_factory=set)  # typedef'd function pointer types


def blank_out(text: str) -> str:
    """Comments and preprocessor lines become spaces; offsets and newlines stay."""
    out = list(text)

    def hide(start: int, end: int) -> None:
        for i in range(start, end):
            if out[i] != "\n":
                out[i] = " "

    i = 0
    line_start = True
    while i < len(text):
        if line_start and text[i:].lstrip(" \t").startswith("#"):
            end = i
            while True:  # a preprocessor line, with its backslash continuations
                nl = text.find("\n", end)
                nl = len(text) if nl < 0 else nl
                if nl > 0 and text[nl - 1] == "\\" and nl < len(text):
                    end = nl + 1
                    continue
                break
            hide(i, nl)
            i = nl
            continue
        if text.startswith("//", i):
            nl = text.find("\n", i)
            nl = len(text) if nl < 0 else nl
            hide(i, nl)
            i = nl
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = len(text) if end < 0 else end + 2
            hide(i, end)
            i = end
            continue
        line_start = text[i] == "\n"
        i += 1
    return "".join(out)


def normalize_type(text: str) -> str:
    text = re.sub(r"\s*\*\s*", "* ", text.strip())
    text = re.sub(r"\s+", " ", text).strip()
    return text.replace("* *", "**")


def split_top(text: str, sep: str = ",") -> list[str]:
    parts, depth, cur = [], 0, []
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if "".join(cur).strip():
        parts.append("".join(cur))
    return [p.strip() for p in parts]


def match_paren(text: str, open_index: int) -> int:
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    raise Failure(f"unbalanced parentheses at offset {open_index}")


def parse_decl(text: str) -> Arg:
    text = re.sub(r"\s+", " ", text.strip())
    fn = re.fullmatch(r"(.+?)\(\s*\*\s*(\w+)\s*\)\s*\((.*)\)", text)
    if fn:
        params = ", ".join(normalize_type(p) for p in split_top(fn.group(3)))
        ret = normalize_type(fn.group(1))
        return Arg(f"{ret} (*{fn.group(2)})({params})", fn.group(2), "F", pointer_type=f"{ret} (*)({params})")
    m = re.fullmatch(r"(.*?[\s*])(\w+)", text)
    if not m:
        raise Failure(f"cannot parse the declaration '{text}'")
    return Arg(normalize_type(m.group(1)), m.group(2))


def classify_args(args: list[Arg], fn_types: set[str], structs: dict[str, list[Arg]]) -> list[Arg]:
    """Sets each argument's wire kind; returns the wire list (a length or capacity folds into its buffer)."""
    wire: list[Arg] = []
    i = 0
    while i < len(args):
        a = args[i]
        nxt = args[i + 1] if i + 1 < len(args) else None
        t = a.ctype
        is_len = nxt is not None and nxt.ctype in ("size_t", "int") and re.search(r"(length|len)$", nxt.name)
        is_cap = nxt is not None and nxt.ctype in ("size_t", "int") and re.search(r"(capacity|len)$", nxt.name)
        is_count = nxt is not None and nxt.ctype == "int" and re.search(r"count$", nxt.name)
        if a.kind == "F" or t in fn_types:
            a.kind = "F"
        elif t == "void*" and re.fullmatch(r"ctx|context", a.name):
            a.kind = "C"
        elif t == "void*" and a.name.endswith("view"):
            a.kind = "v"
        elif t == "const char* const*" and is_count:
            a.kind, a.pair = "L", nxt
        elif t in ("const void*", "const uint8_t*") and is_len:
            a.kind, a.pair = "b", nxt
        elif t.startswith("const ") and t.endswith("*") and t[6:-1] in structs and is_count:
            a.kind, a.pair = "R", nxt
        elif t == "int*" and is_cap and nxt.name.endswith("capacity"):
            a.kind, a.pair = "A", nxt
        elif t in ("uint8_t*", "char*") and is_cap:
            a.kind, a.pair = "B", nxt
        elif t == "int*":
            a.kind = "I"
        elif t == "const char*":
            a.kind = "s"
        else:
            a.kind = {"int": "i", "unsigned int": "u", "int64_t": "l", "double": "d"}.get(t, "?")
        wire.append(a)
        i += 2 if a.pair is not None else 1
    return wire


def parse_header(path: Path) -> Header:
    raw = path.read_bytes()
    text = raw.decode("utf-8")
    code = blank_out(text)
    fn_types = set(re.findall(r"typedef[^;()]*\(\s*\*\s*(\w+)\s*\)\s*\(", code))
    structs: dict[str, list[Arg]] = {}
    for m in re.finditer(r"typedef\s+struct\s*\{([^}]*)\}\s*(\w+)\s*;", code):
        fields = [parse_decl(f) for f in m.group(1).split(";") if f.strip()]
        structs[m.group(2)] = fields
    exports: list[Export] = []
    for m in re.finditer(r"\bCMUX_SHIM_EXPORT\s+([^;(){}]*?)\b(cmux_shim_\w+)\s*\(", code):
        close = match_paren(code, m.end() - 1)
        if not code[close + 1:].lstrip().startswith(";"):
            raise Failure(f"{m.group(2)}: expected ';' after the declaration")
        body = code[m.end():close].strip()
        args = [] if body in ("", "void") else [parse_decl(p) for p in split_top(body)]
        doc_start = max(code.rfind(";", 0, m.start()), code.rfind("}", 0, m.start()))
        exports.append(Export(m.group(2), normalize_type(m.group(1)), args,
                              "cmux_shim_free_owned" in text[doc_start + 1:m.start()]))
    for index, export in enumerate(exports, 1):
        export.index = index
        export.wire = classify_args(export.args, fn_types, structs)
    names = [e.name for e in exports]
    if len(set(names)) != len(names):
        raise Failure("the header declares an export twice")
    em = re.search(r"typedef\s+enum\s*\{([^}]*)\}\s*cmux_shim_event_kind_t\s*;", code)
    if not em:
        raise Failure("the header has no cmux_shim_event_kind_t")
    events: list[tuple[str, int]] = []
    value = -1  # a C enum's first enumerator without an initializer is 0
    for item in em.group(1).split(","):
        item = item.strip()
        if not item:
            continue
        km = re.fullmatch(r"(CMUX_SHIM_\w+)(?:\s*=\s*(\d+))?", item)
        if not km:
            raise Failure(f"cannot parse the event kind '{item}'")
        value = int(km.group(2)) if km.group(2) else value + 1
        events.append((km.group(1), value))
    return Header(exports, events, structs, hashlib.sha256(raw).hexdigest(), fn_types)


# ---------------------------------------------------------------------------------------------
# Ops JSON


@dataclass
class MirrorKey:
    """`scope.field[param,...]`: a mirror's cache key, or (in pending_keys) a pattern with `*`."""

    base: str  # "tab.navigation_state"
    params: list[str]  # ["browser_id"]
    text: str

    @property
    def ident(self) -> str:
        return re.sub(r"[^0-9A-Za-z]", "_", self.base)


MIRROR_KEY = re.compile(r"([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)(?:\[([a-z0-9_*,]*)\])?")
REFRESH = re.compile(r"(CMUX_SHIM_\w+?)(?::(\d+))?")


def parse_mirror_key(text: object) -> MirrorKey | None:
    m = MIRROR_KEY.fullmatch(text) if isinstance(text, str) else None
    if not m:
        return None
    params = [p for p in (m.group(3) or "").split(",")] if m.group(3) else []
    if any(not p for p in params):
        return None
    return MirrorKey(f"{m.group(1)}.{m.group(2)}", params, text)


@dataclass
class Refresh:
    """One refresh event of a mirror: an event kind, a sub-kind (`CMUX_SHIM_TAB_EVENT:<request>`)
    or a pseudo event (`attach`, the host's hello)."""

    kind: str
    request: int | None
    pseudo: bool


@dataclass
class Op:
    export: Export
    cls: str
    mirror_key: MirrorKey | None
    refresh_events: list[Refresh]
    pending_keys: list[MirrorKey]
    reply_event: str | None
    reason: str
    channel: str
    mint_returns: str | None = None


@dataclass
class Rewrite:
    """A host_mode_rewrites entry: the calls of `exports` in `functions` of `path` (under sources_root)
    that the remote shim cannot keep as they are; --check-return-use and --check-pre-attach accept them."""

    path: str  # relative to sources_root
    functions: list[tuple[str, str]]  # (type, or "" when the entry names none; function name)
    exports: list[str]
    needs: str
    site: str
    wire: str = ""  # needs client: the client's wire entry point (CLIENT_WIRE)


@dataclass
class Model:
    header: Header
    exports: list[Export]  # op id order: the header's exports, then optional_exports
    ops: dict[str, Op]  # by export name, op id order
    refreshes: dict[str, list[str]]  # event kind -> mirror bases, as the events list them
    mirror_ops: dict[str, Op]  # mirror base ("tab.navigation_state") -> op
    pseudo_events: list[str]
    events: list[tuple[str, int]]  # the header's event kinds, then optional_events
    rewrites: list[Rewrite]
    wire_identity: str  # SHA-256 of the header and the ops JSON: one value per generated wire


def key_args(export: Export) -> list[Arg]:
    """The arguments that name a mirror's entry (every argument but the out-parameters)."""
    return [a for a in export.wire if a.kind not in OUT_KINDS]


def optional_export(entry: dict, header: Header, index: int) -> Export:
    """An optional_exports entry as an Export: its args and returns stand in for the header's."""
    args = []
    for listed in entry.get("args") or []:
        if not isinstance(listed, dict) or not isinstance(listed.get("name"), str) \
                or not isinstance(listed.get("type"), str):
            raise Failure("args must be objects with a name and a type")
        ctype, name = listed["type"], listed["name"]
        args.append(parse_decl(ctype.replace("(*)", f"(*{name})", 1) if "(*)" in ctype else f"{ctype} {name}"))
    returns = entry.get("returns")
    if not isinstance(returns, str):
        raise Failure("returns must be a C type")
    export = Export(entry["name"], normalize_type(returns), args, False, index, optional=True)
    export.wire = classify_args(export.args, header.fn_types, header.structs)
    if [a.as_json() for a in export.args] != entry.get("args"):
        raise Failure(f"args are not written as the generator normalizes them: "
                      f"{json.dumps([a.as_json() for a in export.args])}")
    return export


def rewrite_functions(site: str) -> tuple[str, list[tuple[str, str]]] | None:
    """`File.swift: Type.function(_:), more text` -> (path, [(type, function)]); None when malformed."""
    m = re.fullmatch(r"([\w+./-]+\.swift): (.+)", site, re.S)
    if not m:
        return None
    head = m.group(2).split(", ")[0]
    functions = re.findall(r"(?:\b([A-Z]\w*)\.)?\b([a-z_]\w*)\(", head)
    return (m.group(1), functions) if functions else None


def load_ops(header: Header, root: Path) -> tuple[Model | None, list[str], dict[str, str]]:
    """The model (None when the file is missing or unreadable), the problems, and per-export problems."""
    path = root / OPS
    problems: list[str] = []
    per_export: dict[str, str] = {}
    if not path.exists():
        return None, [f"{OPS} is missing: classify every export (task p01-process-010)"], {}
    raw = path.read_bytes()
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return None, [f"{OPS}: {error}"], {}
    if not isinstance(data, dict) or data.get("version") != SCHEMA_VERSION:
        return None, [f'{OPS}: expected an object with "version": {SCHEMA_VERSION}'], {}
    extra = set(data) - TOP_FIELDS
    if extra:
        problems.append(f"{OPS}: unknown top-level keys {sorted(extra)}")
    for key in ("exports", "events", *TOP_LISTS):
        if not isinstance(data.get(key, []), list):
            problems.append(f"{OPS}: {key} must be a list")
            data[key] = []
    if data.get("header", SHIMH) != SHIMH:
        problems.append(f"{OPS}: header {data.get('header')!r} is not {SHIMH}")
    if data.get("sources_root", APP) != APP:
        problems.append(f"{OPS}: sources_root {data.get('sources_root')!r} is not {APP}")
    classes = data.get("classes")
    if classes is not None and (not isinstance(classes, dict) or set(classes) != set(CLASSES)):
        listed = sorted(classes) if isinstance(classes, dict) else classes
        problems.append(f"{OPS}: classes must document exactly {', '.join(CLASSES)} (no sync), not {listed}")
    fields = data.get("fields")
    if fields is not None and (not isinstance(fields, dict) or set(fields) != DOCUMENTED_FIELDS):
        problems.append(f"{OPS}: fields must document exactly {sorted(DOCUMENTED_FIELDS)}")
    pseudo = data.get("pseudo_events") or {}
    if not isinstance(pseudo, dict) or not all(re.fullmatch(r"[a-z_]+", k) for k in pseudo):
        problems.append(f"{OPS}: pseudo_events must map lowercase names to their meaning")
        pseudo = {}
    pseudo_events = sorted(pseudo)
    by_name = {e.name: e for e in header.exports}

    # Event kinds: the header's, then optional_events (decoded by CEFShimEvent.swift, not yet in the header).
    events = list(header.events)
    if any(value < 0 for _, value in events):
        problems.append(f"{SHIMH}: an event kind below 0 (pseudo events take the negative values)")
    for entry in data.get("optional_events") or []:
        kind = entry.get("kind") if isinstance(entry, dict) else None
        if not isinstance(kind, str) or not re.fullmatch(r"CMUX_SHIM_\w+", kind):
            problems.append(f"{OPS}: optional event {entry!r} has no CMUX_SHIM_* kind")
            continue
        value = entry.get("value")
        if kind in dict(header.events):
            problems.append(f"{kind}: the header lists it now: move the entry from optional_events into events")
        elif kind in dict(events):
            problems.append(f"{kind}: listed twice")
        elif not isinstance(value, int) or isinstance(value, bool) or value < 0:
            problems.append(f"{kind}: an optional event needs its value, an int >= 0")
        elif value in {v for _, v in events}:
            problems.append(f"{kind}: value {value} is also {dict((v, k) for k, v in events)[value]}'s")
        else:
            events.append((kind, value))
    event_values = dict(events)

    entries: dict[str, dict] = {}
    optional_entries: list[dict] = []
    for key, listed in (("exports", data.get("exports") or []), ("optional_exports", data.get("optional_exports") or [])):
        for entry in listed:
            name = entry.get("name") if isinstance(entry, dict) else None
            if not isinstance(name, str) or not re.fullmatch(r"cmux_shim_\w+", name):
                problems.append(f"{OPS}: an {key} entry without a cmux_shim_* name: {entry!r}")
                continue
            if name in entries:
                problems.append(f"{name}: classified twice")
                continue
            if key == "exports" and name not in by_name:
                problems.append(f"{name}: classified but not exported by the header (stale entry)")
            elif key == "optional_exports" and name in by_name:
                problems.append(f"{name}: the header declares it now: move the entry from optional_exports "
                                f"into exports")
                continue
            elif key == "optional_exports":
                optional_entries.append(entry)
            entries[name] = entry

    def bad(name: str, message: str) -> None:
        problems.append(f"{name}: {message}")
        per_export.setdefault(name, message)

    exports = list(header.exports)
    for entry in optional_entries:
        try:
            exports.append(optional_export(entry, header, len(exports) + 1))
        except Failure as error:
            bad(entry["name"], str(error))

    def refresh(name: str, text: object) -> Refresh | None:
        if isinstance(text, str) and text in pseudo:
            return Refresh(text, None, True)
        m = REFRESH.fullmatch(text) if isinstance(text, str) else None
        if not m or m.group(1) not in event_values:
            bad(name, f"refresh event {text!r} is not an event kind, KIND:<request> or a pseudo event")
            return None
        return Refresh(m.group(1), int(m.group(2)) if m.group(2) else None, False)

    ops: dict[str, Op] = {}
    for export in exports:
        entry = entries.get(export.name)
        if entry is None:
            bad(export.name, "unclassified (no entry in the ops JSON)")
            continue
        unknown = set(entry) - (OPTIONAL_EXPORT_FIELDS if export.optional else EXPORT_FIELDS)
        if unknown:
            bad(export.name, f"unknown fields {sorted(unknown)}")
        missing = REQUIRED_EXPORT_FIELDS - set(entry)
        if missing:
            bad(export.name, f"missing fields {sorted(missing)}")
        cls = entry.get("class")
        if cls == "sync":
            bad(export.name, "class sync is refused: no op waits for the host (use mirror, async or post)")
            continue
        if cls not in CLASSES:
            bad(export.name, f"unknown class {cls!r} (one of {', '.join(CLASSES)})")
            continue
        header_args = [a.as_json() for a in export.args]
        listed_args = entry.get("args")
        if isinstance(listed_args, list) and len(listed_args) == len(header_args):
            for listed, arg in zip(listed_args, export.args):
                if isinstance(listed, dict) and listed.get("function_pointer") and arg.kind != "F":
                    # Checked here, not by class: the header must agree that this is a callback.
                    bad(export.name, f"'{arg.name}' is marked function_pointer but the header's type is "
                                     f"{arg.ctype!r}")
        if listed_args != header_args:
            bad(export.name, f"args drifted from the header: {json.dumps(header_args)}")
        if entry.get("returns") != export.returns:
            bad(export.name, f"returns drifted from the header: {export.returns!r}")
        lists = {}
        for key in ("result_used_by", "refresh_events", "pending_keys"):
            value = entry.get(key) or []
            if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
                bad(export.name, f"{key} must be a list of strings")
                value = []
            lists[key] = value
        reason = entry.get("reason") or ""
        if not isinstance(reason, str):
            bad(export.name, "reason must be a string")
            reason = ""
        reply_event = entry.get("reply_event")
        if reply_event is not None and reply_event != REPLY_WIRE and reply_event not in event_values:
            bad(export.name, f"reply_event {reply_event!r} is not an event kind or {REPLY_WIRE}")
        channel = entry.get("channel", "control")
        if channel not in CHANNELS:
            bad(export.name, f"channel {channel!r} is not one of {', '.join(CHANNELS)}")
            channel = "control"
        fork_api = entry.get("fork_api")
        if export.optional and (not isinstance(fork_api, int) or isinstance(fork_api, bool) or fork_api < 1):
            bad(export.name, "an optional export names the fork API that adds it (fork_api, an int)")
        mirror_key = None
        if entry.get("mirror_key") is not None:
            mirror_key = parse_mirror_key(entry["mirror_key"])
            if mirror_key is None or "*" in mirror_key.params:
                bad(export.name, f"mirror_key {entry['mirror_key']!r} is not scope.field[param,...]")
        pending = []
        for text in lists["pending_keys"]:
            parsed = parse_mirror_key(text)
            if parsed is None:
                bad(export.name, f"pending key {text!r} is not scope.field[param or *,...]")
            else:
                pending.append(parsed)
        refreshes = [r for r in (refresh(export.name, t) for t in lists["refresh_events"]) if r is not None]
        op = Op(export, cls, mirror_key, refreshes, pending, reply_event, reason, channel, entry.get("mint_returns"))
        for message in class_problems(op):
            bad(export.name, message)
        ops[export.name] = op

    mirror_ops: dict[str, Op] = {}
    for op in ops.values():
        if op.cls == "mirror" and op.mirror_key:
            key = op.mirror_key
            if key.base in mirror_ops:
                bad(op.export.name, f"mirror_key {key.base!r} is also {mirror_ops[key.base].export.name}'s")
            mirror_ops[key.base] = op
            want = [a.name for a in key_args(op.export)]
            if key.params != want:
                bad(op.export.name, f"mirror_key {key.text!r} must name the export's key arguments {want}")
    for op in ops.values():
        for pattern in op.pending_keys:
            target = mirror_ops.get(pattern.base)
            if target is None:
                bad(op.export.name, f"pending key {pattern.text!r} is no mirror's key")
                continue
            target_args = key_args(target.export)
            if len(pattern.params) != len(target_args):
                bad(op.export.name, f"pending key {pattern.text!r} needs {len(target_args)} params "
                                    f"({target.mirror_key.text})")
                continue
            own = {a.name: a for a in key_args(op.export)}
            for param, wanted in zip(pattern.params, target_args):
                if param == "*":
                    continue
                arg = own.get(param)
                if arg is None:
                    bad(op.export.name, f"pending key {pattern.text!r}: {param!r} is not an argument (use *)")
                elif arg.kind != wanted.kind:
                    bad(op.export.name, f"pending key {pattern.text!r}: {param!r} is not a {wanted.ctype} "
                                        f"like {target.mirror_key.text}'s {wanted.name!r}")

    refreshes: dict[str, list[str]] = {}
    seen_events: set[str] = set()
    optional_kinds = set(event_values) - set(dict(header.events))
    for key, listed in (("events", data.get("events") or []), ("optional_events", data.get("optional_events") or [])):
        for entry in listed:
            kind = entry.get("kind") if isinstance(entry, dict) else None
            if kind not in event_values or (key == "events") == (kind in optional_kinds):
                if key == "events":
                    problems.append(f"{OPS}: event entry {entry!r} names no event kind of the header")
                continue  # a bad optional event is reported above
            if kind in seen_events:
                problems.append(f"{kind}: listed twice")
            seen_events.add(kind)
            if set(entry) - EVENT_FIELDS:
                problems.append(f"{kind}: unknown fields {sorted(set(entry) - EVENT_FIELDS)}")
            if "value" in entry and entry["value"] != event_values[kind]:
                problems.append(f"{kind}: value {entry['value']!r} drifted from the header ({event_values[kind]})")
            bases = []
            for text in entry.get("refreshes") or []:
                parsed = parse_mirror_key(text)
                target = mirror_ops.get(parsed.base) if parsed else None
                if target is None or parsed.text != target.mirror_key.text:
                    problems.append(f"{kind}: refreshes {text!r}, which is no mirror's key")
                    continue
                bases.append(parsed.base)
            refreshes[kind] = bases
    for kind, _ in header.events:
        if kind not in seen_events:
            problems.append(f"{kind}: event kind missing from the ops JSON")
    for base, op in mirror_ops.items():
        listed = {kind for kind, bases in refreshes.items() if base in bases}
        own = {r.kind for r in op.refresh_events if not r.pseudo}
        if listed != own:
            bad(op.export.name, f"refresh_events name {sorted(own)}, but the events that refresh "
                                f"{op.mirror_key.text!r} are {sorted(listed)}")

    rewrites: list[Rewrite] = []
    for entry in data.get("host_mode_rewrites") or []:
        site = entry.get("site") if isinstance(entry, dict) else None
        if not isinstance(site, str):
            problems.append(f"{OPS}: a host_mode_rewrites entry without a site: {entry!r}")
            continue
        label = f"host_mode_rewrites {site!r}"
        if set(entry) != REWRITE_FIELDS:
            problems.append(f"{label}: fields must be exactly {sorted(REWRITE_FIELDS)}")
        parsed_site = rewrite_functions(site)
        if parsed_site is None:
            problems.append(f"{label}: site is 'File.swift: Type.function(...)' under {APP}")
            continue
        rel, functions = parsed_site
        if (root / SHIM_LIBRARY).is_file() and not (root / APP / rel).is_file():  # a tree with the sources
            problems.append(f"{label}: {APP}/{rel} does not exist")
        names = entry.get("exports")
        if not isinstance(names, list) or not names or not all(isinstance(n, str) for n in names):
            problems.append(f"{label}: exports must be a non-empty list of export names")
            names = []
        for name in names:
            if name not in entries:
                problems.append(f"{label}: {name!r} is no classified export")
            elif entry.get("needs") == "after_attach" and name in ops and ops[name].cls != "mirror":
                problems.append(f"{label}: needs after_attach is for mirror reads; {name} is {ops[name].cls}")
            elif entry.get("needs") == "client" and name in ops and ops[name].cls != "local":
                problems.append(f"{label}: needs client is for local exports the client defines; {name} is {ops[name].cls}")
        client_wire = CLIENT_WIRE.search(str(entry.get("change") or "")) if entry.get("needs") == "client" else None
        if entry.get("needs") == "client" and client_wire is None:
            problems.append(f"{label}: needs client names the client's wire entry point in change "
                            f"(cmux_remote::PostPasswordReveal)")
        if entry.get("needs") not in REWRITE_NEEDS:
            problems.append(f"{label}: needs {entry.get('needs')!r} is not one of {', '.join(REWRITE_NEEDS)}")
        if not isinstance(entry.get("change"), str) or not entry["change"].strip():
            problems.append(f"{label}: change says what the site becomes")
        if not isinstance(entry.get("task"), str) or not re.fullmatch(r"p\d{2}-[a-z0-9]+-\d{3}[a-z]?", entry["task"]):
            problems.append(f"{label}: task {entry.get('task')!r} is not a task id (p01-process-015)")
        rewrites.append(Rewrite(rel, functions, names, str(entry.get("needs")), site,
                                client_wire.group(1) if client_wire else ""))

    # What the generated code depends on (op ids, classes, wire kinds, events), not reasons or prose.
    def op_wire(e: Export) -> list:
        op = ops.get(e.name)
        shape = [e.name, e.returns, [[a.name, a.kind] for a in e.wire]]
        if op is None:
            return shape
        return shape + [op.cls, op.reply_event, op.channel, op.mint_returns,
                         op.mirror_key.text if op.mirror_key else None, [k.text for k in op.pending_keys],
                         [[r.kind, r.request] for r in op.refresh_events]]

    wire = {"abi": header.identity, "events": events, "ops": [op_wire(e) for e in exports]}
    wire_identity = hashlib.sha256(json.dumps(wire, sort_keys=True).encode()).hexdigest()
    return (Model(header, exports, ops, refreshes, mirror_ops, pseudo_events, events, rewrites, wire_identity),
            problems, per_export)


def request_arg(e: Export) -> Arg | None:
    """The `request` token a mint_returns sent export passes on to its reply_event."""
    return next((a for a in e.wire if a.name == "request" and a.kind == "i"), None)


DERIVED_SUFFIXES = ("_n", "_s", "_p", "_capacity", "_value")  # locals the generator derives from an argument


def class_problems(op: Op) -> list[str]:
    e, cls = op.export, op.cls
    kinds = [a.kind for a in e.wire]
    out: list[str] = []
    names = {a.name for a in e.args}
    for a in e.args:
        clash = next((a.name + s for s in DERIVED_SUFFIXES if a.name + s in names), None)
        if clash:
            out.append(f"argument '{clash}' has the name of a local generated for '{a.name}': rename one")
    if cls not in ("local", "policy") and "F" in kinds:
        fn = next(a for a in e.wire if a.kind == "F")
        out.append(f"function-pointer argument '{fn.name}' in a {cls} export (only local or policy)")
        return out
    if cls in ("local", "policy") and not op.reason.strip():
        out.append(f"class {cls} needs a reason")
    if e.name == "cmux_shim_abi_id":
        if cls != "local":
            out.append("the generator emits cmux_shim_abi_id from the header's identity: class local")
        return out
    if cls == "local":
        if op.channel != "control":
            out.append("a local export is never sent: no channel")
        return out
    if "v" in kinds and cls not in ("view", "mint"):
        out.append(f"an NSView* argument goes to ChromiumHostPageView: class view or mint, not {cls}")
    if e.returns in ("char*", "const char*") and cls not in ("mirror", "async"):
        out.append(f"a {e.returns} result must be mirror or async, not {cls}")
    if cls in POST_LIKE and any(k in OUT_KINDS for k in kinds):
        out.append(f"out-parameters need a reply: a {cls} export cannot have them")
    if e.ret_kind == "?":
        out.append(f"cannot marshal the result type {e.returns!r}")
    for a in e.wire:
        if a.kind == "C" and cls != "policy":
            out.append(f"callback context '{a.name}' outside a policy")
        elif a.kind == "?":
            out.append(f"cannot marshal argument '{a.decl}'")
    if cls == "policy" and "F" not in kinds:
        out.append("a policy export sets a callback: it has no function-pointer argument")
    if cls == "mint" and e.returns != "int":
        out.append("a mint export returns the minted int id")
    if cls == "mirror":
        if not e.ret_kind:
            out.append("a mirror export returns the cached value")
        if not op.mirror_key:
            out.append("a mirror export needs mirror_key")
        if not op.refresh_events:
            out.append("a mirror export needs refresh_events")
        if any(k in ("v", "b", "L", "R", "C", "B") for k in kinds):
            out.append("a mirror key is ints and strings only; its only out-parameters are int* and int buffers")
    elif op.mirror_key or op.refresh_events:
        out.append("mirror_key and refresh_events are for mirror exports")
    if op.pending_keys and cls not in ("post", "view", "preinit", "mint", "async"):
        out.append("pending_keys are for ops the host acks or answers")
    if cls == "async":
        if op.reply_event is None:
            out.append(f"an async export names its answer: reply_event is an event kind or {REPLY_WIRE}")
        elif op.reply_event != REPLY_WIRE and any(k in OUT_KINDS for k in kinds):
            out.append(f"out-parameters come back in {REPLY_WIRE}, not in an event")
    elif cls == "mint":
        if op.reply_event is None or op.reply_event == REPLY_WIRE:
            out.append("a mint export names the event that reports the minted id (reply_event)")
    elif cls == "preinit":
        if e.ret_kind and op.reply_event != REPLY_WIRE:
            out.append(f"a non-void preinit returns the client's own check; the host's verdict is "
                       f"reply_event {REPLY_WIRE}")
        elif not e.ret_kind and op.reply_event is not None:
            out.append("a void preinit has no verdict to send back: no reply_event")
    elif op.reply_event == REPLY_WIRE:
        out.append(f"a {cls} export returns at once: {REPLY_WIRE} is for async and non-void preinit exports")
    elif op.reply_event is not None and cls not in ("post", "view"):
        out.append(f"reply_event is for async, mint and post exports, not {cls}")
    if op.channel == "input" and cls not in ("post", "view"):
        out.append("the input channel carries one-way ops (post or view) only")
    if cls == "mint" and op.mint_returns not in MINT_RETURNS:
        out.append(f"a mint export names its C return: mint_returns is {' or '.join(MINT_RETURNS)}")
    elif cls == "mint" and op.mint_returns == "sent" and not request_arg(e):
        out.append("mint_returns sent needs an int `request` argument: reply_event carries it with the id")
    elif cls != "mint" and op.mint_returns is not None:
        out.append("mint_returns is for mint exports")
    return out


# ---------------------------------------------------------------------------------------------
# Names


def tokens(snake: str) -> list[str]:
    return [t for t in snake.lower().split("_") if t]


def swift_name(snake: str) -> str:
    parts = tokens(snake)
    head = parts[0] if parts[0] not in ACRONYMS or parts[0] == "ext" else ACRONYMS[parts[0]].lower()
    if parts[0] == "devtools":
        head = "devTools"
    name = head + "".join(ACRONYMS.get(t, t.capitalize()) for t in parts[1:])
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def pascal(snake: str) -> str:
    return "".join(t.capitalize() for t in tokens(snake))


def op_const(export: Export) -> str:
    return "kOp" + pascal(export.short)


# ---------------------------------------------------------------------------------------------
# C++ generation

BANNER = ("// GENERATED by {gen} from\n// {shimh} and {ops}.\n"
          "// Do not edit: run python3 {gen}.\n")


def is_browser_arg(a: Arg) -> bool:
    return a.kind == "i" and a.name.endswith("browser_id")


def stand_in(export: Export) -> str:
    """What a post-like export's remote returns: the call is sent, so it reports success."""
    k = export.ret_kind
    return {"": "", "s": "nullptr", "S": "nullptr", "u": "1u"}.get(k, "1")


def zero(export: Export) -> str:
    """The C zero value of the export's result: a mirror read before attach, a call not sent."""
    k = export.ret_kind
    return {"": "", "s": "nullptr", "S": "nullptr", "u": "0u"}.get(k, "0")


def sent_result(export: Export, sent: str) -> str:
    """An async export's immediate return: 1 when `sent`, else 0; a string result arrives in the reply."""
    k = export.ret_kind
    if k in ("s", "S"):
        return "nullptr"
    one, nil = ("1u", "0u") if k == "u" else ("1", "0")
    return f"{sent} ? {one} : {nil}"


WIRE_NUMBER = {"i": "I32", "u": "U32", "l": "I64", "d": "F64"}
# Number fields of a record struct (an R argument): C type -> wire kind.
RECORD_NUMBER = {"int": "i", "unsigned int": "u", "int64_t": "l"}


def client_encode(a: Arg, w: str, structs: dict[str, list[Arg]], lines: list[str], ind: str) -> None:
    k, n = a.kind, a.var
    if k in WIRE_NUMBER:
        lines.append(f"{ind}{w}.{WIRE_NUMBER[k]}({n});")
    elif k == "s":
        lines.append(f"{ind}{w}.Str({n});")
    elif k == "b":
        lines.append(f"{ind}{w}.Bytes({n}, static_cast<size_t>({a.pair.var}));")
    elif k == "v":
        lines.append(f"{ind}{w}.View({n});")
    elif k == "L":
        lines.append(f"{ind}{w}.StrList({n}, {a.pair.var});")
    elif k == "R":
        fields = structs[a.ctype[6:-1]]
        lines.append(f"{ind}const int {n}_n = {n} != nullptr && {a.pair.var} > 0 ? {a.pair.var} : 0;")
        lines.append(f"{ind}{w}.I32({n}_n);")
        lines.append(f"{ind}for (int i = 0; i < {n}_n; ++i) {{")
        for f in record_fields(fields):
            if f[0] == "b":
                lines.append(f"{ind}  {w}.Bytes({n}[i].{f[1]}, {n}[i].{f[2]});")
            else:
                lines.append(f"{ind}  {w}.{WIRE_NUMBER[f[0]]}({n}[i].{f[1]});")
        lines.append(f"{ind}}}")
    elif k in ("A", "B"):
        lines.append(f"{ind}{w}.I32(static_cast<int32_t>({a.pair.var}));")


def record_has_bytes(a: Arg, structs: dict[str, list[Arg]]) -> bool:
    """Whether a record argument carries strings (the host keeps them in `<arg>_s` and wipes them)."""
    return any(f[0] == "b" for f in record_fields(structs[a.ctype[6:-1]]))


def record_fields(fields: list[Arg]) -> list[tuple[str, str, str]]:
    """(b, pointer, length), or (i|u|l, name, '') for an int, unsigned int or int64_t, per wire field of a struct."""
    out, i = [], 0
    while i < len(fields):
        f = fields[i]
        nxt = fields[i + 1] if i + 1 < len(fields) else None
        if f.ctype == "const char*" and nxt is not None and nxt.name == f.name + "_length":
            out.append(("b", f.name, nxt.name))
            i += 2
        elif f.ctype in RECORD_NUMBER:
            out.append((RECORD_NUMBER[f.ctype], f.name, ""))
            i += 1
        else:
            raise Failure(f"cannot marshal the struct field '{f.decl}'")
    return out


def clear_outputs(e: Export, body: list[str]) -> None:
    """Out-parameters of a call answered later hold zero, never stale memory, until the reply comes."""
    for a in e.wire:
        if a.kind == "I":
            body.append(f"  if ({a.var} != nullptr) *{a.var} = 0;")
        elif a.kind in ("A", "B"):
            body.append(f"  if ({a.var} != nullptr && {a.pair.var} > 0) {a.var}[0] = 0;")


def client_function(op: Op, model: Model) -> list[str]:
    e, cls = op.export, op.cls
    sig = f"CMUX_SHIM_EXPORT {e.returns} {e.name}({', '.join(a.generated_decl for a in e.args) or 'void'})"
    const = op_const(e)
    body: list[str] = []
    if cls == "mirror":
        body.append("  TlvWriter key_w;")
        for a in e.wire:
            if a.kind not in OUT_KINDS:
                client_encode(a, "key_w", model.header.structs, body, "  ")
        body.append(f"  TlvReader value_r = MirrorLookup({const}, key_w);")
        body.append(f"  if (!value_r.present()) return {zero(e)};")
        k = e.ret_kind
        if k in ("s", "S"):
            body.append("  const std::optional<std::string> mirror_result = value_r.Str();")
        else:
            body.append(f"  const auto mirror_result = value_r.{WIRE_NUMBER[k]}();")
        for a in e.wire:
            if a.kind == "I":
                body.append(f"  const int32_t {a.var}_value = value_r.I32();")
                body.append(f"  if ({a.var} != nullptr) *{a.var} = {a.var}_value;")
            elif a.kind == "A":
                body.append(f"  value_r.I32Array({a.var}, {a.pair.var});")
            elif a.kind == "B":
                body.append(f"  const std::string {a.var}_value = value_r.Bytes();")
                body.append(f"  if ({a.var} != nullptr) std::memcpy({a.var}, {a.var}_value.data(), "
                            f"std::min({a.var}_value.size(), static_cast<size_t>({a.pair.var})));")
        body.append("  return mirror_result ? Dup(*mirror_result) : nullptr;" if k in ("s", "S")
                    else "  return mirror_result;")
        return [sig + " {", *body, "}"]
    body.append("  TlvWriter op_w;")
    if cls == "mint":
        body.append(f"  const int32_t minted_id = MintID({const});")
        body.append("  op_w.I32(minted_id);")
    if cls == "policy":
        fn = next(a for a in e.wire if a.kind == "F")
        body.append(f"  SetPolicy({const}, reinterpret_cast<void*>({fn.var}));")
        body.append(f"  op_w.I32({fn.var} != nullptr ? 1 : 0);")
    for a in e.wire:
        if a.kind == "C":
            body.append(f"  (void){a.var};")
        elif a.kind != "F":
            client_encode(a, "op_w", model.header.structs, body, "  ")
    replies = cls == "async" or op.reply_event == REPLY_WIRE  # a REPLY frame answers the token
    token = "op_token" if op.pending_keys or replies else "0"
    if token != "0":
        body.append("  const uint32_t op_token = NextToken();")
    own = {a.name: a for a in key_args(e)}
    for pattern in op.pending_keys:
        target = model.mirror_ops[pattern.base]
        var = f"pending_{pattern.ident}"
        body.append(f"  TlvWriter {var};")
        wildcards = 0
        for index, param in enumerate(pattern.params):
            if param == "*":
                wildcards |= 1 << index
            else:
                client_encode(own[param], var, model.header.structs, body, "  ")
        body.append(f"  MarkPending({op_const(target.export)}, op_token, {var}, {wildcards:#x}u);  "
                    f"// {pattern.text}")
    if cls == "preinit":
        # The client's own check (1 queued, 0 refused); with a token the host's verdict comes as REPLY.
        call = f"PostPreinit({const}, {token}, op_w)"
        body.append(f"  return {call};" if e.ret_kind else f"  (void){call};")
        return [sig + " {", *body, "}"]
    if cls == "async":
        clear_outputs(e, body)
        send = f"PostForReply({const}, op_token, op_w)"
        if e.ret_kind:
            body.append(f"  const bool op_sent = {send};")
            if e.ret_kind in ("s", "S"):
                body.append("  (void)op_sent;")
            body.append(f"  return {sent_result(e, 'op_sent')};")
        else:
            body.append(f"  (void){send};")
        return [sig + " {", *body, "}"]
    send = f"{'PostInput' if op.channel == 'input' else 'Post'}({const}, {token}, op_w)"
    if cls == "mint":
        body.append(f"  const bool op_sent = {send};")
        body.append("  return op_sent ? 1 : 0;" if op.mint_returns == "sent" else "  return op_sent ? minted_id : 0;")
    else:
        body.append(f"  (void){send};")
        if e.ret_kind:
            body.append(f"  return {stand_in(e)};")
    return [sig + " {", *body, "}"]


def op_enum(model: Model) -> list[str]:
    lines = ["enum Op : uint16_t {"]
    lines += [f"  {op_const(e)} = {e.index},{'  // optional' if e.optional else ''}" for e in model.exports]
    lines += ["};", f"inline constexpr uint16_t kOpCount = {len(model.exports)};",
              f"inline constexpr uint16_t kOpEvent = {EVENT_OP:#x};  // host -> cmux: one shim event",
              f"inline constexpr uint16_t kOpReply = {REPLY_OP:#x};  // host -> cmux: an async op's result",
              f"inline constexpr uint16_t kOpMirror = {MIRROR_OP:#x};  // host -> cmux: a mirror value",
              f"inline constexpr uint16_t kOpAck = {ACK_OP:#x};  // host -> cmux: a token's op ran",
              f"inline constexpr int kEventKindCount = {len(model.events)};",
              f'inline constexpr char kShimAbiID[] = "{model.header.identity}";',
              "// Both sides' HELLO carries it: the op ids, classes and wire types of this generation.",
              f'inline constexpr char kWireID[] = "{model.wire_identity}";']
    return lines


def optional_exports_table(model: Model) -> list[str]:
    """kOptionalExports: each optional op and its symbol, which a host lists in its HELLO when its
    shim has it (the host's table in render_host has the same entries)."""
    optional = [e for e in model.exports if e.optional]
    out = ["// Exports the header does not declare yet (fork API symbols): the client sends one only to",
           "// a host whose HELLO lists its symbol.",
           "struct OptionalExport {", "  uint16_t op;", "  const char* name;", "};",
           "inline constexpr OptionalExport kOptionalExports[] = {"]
    out += [f'    {{{op_const(e)}, "{e.name}"}},' for e in optional] or ['    {0, ""},  // none']
    return out + ["};"]


def render_client(model: Model) -> str:
    out = [BANNER.format(gen=GENERATOR, shimh=SHIMH, ops=OPS),
           "// The remote shim (libcmux_cef_shim_remote.dylib): the same C ABI as the in-process shim,",
           "// each export a non-blocking op to the Chromium Host. Included by HOST/client/remote_shim.mm",
           "// after cmux_cef_shim.h and the cmux_remote wire interface; local exports are hand-written",
           "// in HOST/client outside generated/. Optional exports (fork API symbols the header does not",
           "// declare yet) are defined here too, so CEFShimLibrary's r.optional finds them.",
           "",
           "namespace cmux_remote {", *op_enum(model), *optional_exports_table(model),
           "}  // namespace cmux_remote", "",
           'extern "C" {', "using namespace cmux_remote;", "",
           "CMUX_SHIM_EXPORT const char* cmux_shim_abi_id(void) {", "  return kShimAbiID;", "}"]
    for op in model.ops.values():
        if op.cls in GENERATED_CLIENT:
            out += ["", *client_function(op, model)]
    out += ["", '}  // extern "C"', ""]
    return "\n".join(out)


def host_decode(a: Arg, structs: dict[str, list[Arg]], lines: list[str]) -> str:
    """Appends the decoding of one wire argument; returns the C argument text for the call."""
    k, n = a.kind, a.var
    if k in WIRE_NUMBER:
        lines.append(f"      const auto {n} = r.{WIRE_NUMBER[k]}();")
        return f"ctx.Browser({n})" if is_browser_arg(a) else n
    if k == "s":
        lines.append(f"      const std::optional<std::string> {n} = r.Str();")
        return f"{n} ? {n}->c_str() : nullptr"
    if k == "b":
        lines.append(f"      const std::string {n} = r.Bytes();")
        return (f"reinterpret_cast<{a.ctype}>({n}.data()), "
                f"static_cast<{a.pair.ctype}>({n}.size())")
    if k == "v":
        lines.append(f"      void* const {n} = ctx.PageView(r.View());")
        return n
    if k == "L":
        lines.append(f"      const std::vector<std::string> {n} = r.StrList();")
        lines.append(f"      std::vector<const char*> {n}_p;")
        lines.append(f"      for (const std::string& s : {n}) {n}_p.push_back(s.c_str());")
        return f"{n}_p.data(), static_cast<int>({n}_p.size())"
    if k == "R":
        struct = a.ctype[6:-1]
        fields = record_fields(structs[struct])
        nb = sum(1 for f in fields if f[0] == "b")
        lines.append(f"      const int32_t {n}_n = r.I32();")
        lines.append(f"      if (!r.ok() || {n}_n < 0 || {n}_n > kMaxRecords) return false;")
        if nb:
            lines.append(f"      std::vector<std::string> {n}_s(static_cast<size_t>({n}_n) * {nb});")
        lines.append(f"      std::vector<{struct}> {n}(static_cast<size_t>({n}_n));")
        lines.append(f"      for (size_t i = 0; i < {n}.size(); ++i) {{")
        slot = 0
        for f in fields:
            if f[0] == "b":
                s = f"{n}_s[i * {nb} + {slot}]"
                lines.append(f"        {s} = r.Bytes();")
                lines.append(f"        {n}[i].{f[1]} = {s}.data();")
                lines.append(f"        {n}[i].{f[2]} = {s}.size();")
                slot += 1
            elif f[1].endswith("browser_id"):
                # A browser id in a record is cmux's, as a browser argument is: mapped to Chromium's.
                lines.append(f"        {n}[i].{f[1]} = ctx.Browser(static_cast<int32_t>(r.I64()));")
            else:
                lines.append(f"        {n}[i].{f[1]} = r.{WIRE_NUMBER[f[0]]}();")
        lines.append("      }")
        return f"{n}.data(), {n}_n"
    if k in ("A", "B"):
        lines.append(f"      const int32_t {n}_capacity = r.I32();")
        lines.append(f"      if (!r.ok() || {n}_capacity < 0 || {n}_capacity > kMaxOutCapacity) return false;")
        elem = "int" if k == "A" else "uint8_t"
        lines.append(f"      std::vector<{elem}> {n}(static_cast<size_t>({n}_capacity));")
        cast = f"reinterpret_cast<{a.ctype}>({n}.data())" if a.ctype == "char*" else f"{n}.data()"
        return f"{cast}, static_cast<{a.pair.ctype}>({n}_capacity)"
    if k == "I":
        lines.append(f"      int {n} = 0;")
        return f"&{n}"
    raise Failure(f"cannot decode '{a.decl}'")


def host_value(e: Export, w: str, lines: list[str], result: str, free: bool = True) -> None:
    """Writes the result (the local `result`) and the out-parameters into writer `w`."""
    k = e.ret_kind
    if k in ("i", "u", "l"):
        lines.append(f"      {w}.{WIRE_NUMBER[k]}({result});")
    elif k in ("s", "S"):
        lines.append(f"      {w}.Str({result});")
        if k == "s" and free:
            lines.append(f"      if ({result} != nullptr) "
                         f"{'cmux_shim_free_owned' if e.owned_free else 'cmux_shim_free'}({result});")
    for a in e.wire:
        if a.kind == "I":
            lines.append(f"      {w}.I32({a.var});")
        elif a.kind == "A":
            lines.append(f"      {w}.I32Array({a.var}.data(), {a.var}.size());")
        elif a.kind == "B":
            lines.append(f"      {w}.Bytes({a.var}.data(), {a.var}.size());")


def host_call(e: Export, call_args: list[str], lines: list[str], result: str | None) -> None:
    """Calls the export (an optional one through the host shim's symbol, when it defines it)."""
    args = ", ".join(call_args)
    if not e.optional:
        call = f"{e.name}({args})"
        lines.append(f"      const auto {result} = {call};" if result else f"      {call};")
        return
    lines.append(f"      const auto optional_fn = reinterpret_cast<{e.c_signature}>(ctx.OptionalExport({op_const(e)}));")
    if result:
        lines.append(f"      const {e.returns} {result} = optional_fn != nullptr ? optional_fn({args}) : {zero(e)};")
    else:
        lines.append(f"      if (optional_fn != nullptr) optional_fn({args});")


def host_refresh(op: Op, model: Model, lines: list[str]) -> None:
    """Pushes the op's pending keys again, read after the op ran, before its ACK or REPLY. cmux's mark
    clears at that ACK, so what it reads next is the host's value after the op, never the one from
    before it; a navigation's commit pushes again later (LOAD_START, ADDRESS)."""
    own = {a.name: a for a in key_args(op.export)}
    for pattern in op.pending_keys:
        target = model.mirror_ops[pattern.base]
        var = f"refresh_{pattern.ident}"
        lines.append(f"      TlvWriter {var};")
        wildcards = 0
        for index, param in enumerate(pattern.params):
            if param == "*":
                wildcards |= 1 << index
                continue
            a = own[param]
            if a.kind in WIRE_NUMBER:
                lines.append(f"      {var}.{WIRE_NUMBER[a.kind]}({a.var});")
            elif a.kind == "s":
                lines.append(f"      {var}.Str({a.var} ? {a.var}->c_str() : nullptr);")
            else:
                raise Failure(f"{op.export.name}: pending key {pattern.text!r}: a {a.ctype} parameter "
                              "cannot name a mirror key")
        lines.append(f"      ctx.RefreshMirror({op_const(target.export)}, {var}, {wildcards:#x}u);  "
                     f"// {pattern.text}")


def host_case(op: Op, model: Model) -> list[str]:
    e, cls = op.export, op.cls
    lines = [f"    case {op_const(e)}: {{"]
    if cls == "mint":
        lines.append("      const int32_t minted_id = r.I32();")
    if cls == "policy":
        lines.append("      const bool policy_installed = r.I32() != 0;")
    call_args = []
    for a in e.wire:
        if a.kind in ("F", "C"):
            continue
        call_args.append(host_decode(a, model.header.structs, lines))
    lines.append("      if (!r.ok() || !r.AtEnd()) return false;")
    answer = "      ctx.Ack(wire_token);"
    if cls == "policy":
        lines.append(f"      InstallPolicy{pascal(e.short)}(ctx, policy_installed"
                     f"{''.join(', ' + p for p in call_args)});")
    elif cls == "async" or (cls == "preinit" and op.reply_event == REPLY_WIRE):
        host_call(e, call_args, lines, "call_result" if e.ret_kind else None)
        lines.append("      TlvWriter reply_w;")
        host_value(e, "reply_w", lines, "call_result")
        answer = "      ctx.Reply(wire_token, reply_w);"
    elif cls == "mint":
        host_call(e, call_args, lines, "call_result")
        if op.mint_returns == "sent":
            kind = dict(model.events)[op.reply_event]
            lines.append(f"      ctx.BindMintedOnEvent({op_const(e)}, minted_id, {kind} /* {op.reply_event} */, "
                         f"{request_arg(e).var}, call_result);")
        else:
            browser = next((a.var for a in e.wire if is_browser_arg(a)), "0")
            lines.append(f"      ctx.BindMinted({op_const(e)}, minted_id, call_result, {browser});")
    else:
        host_call(e, call_args, lines, "call_result" if e.ret_kind else None)
        if e.ret_kind:
            lines.append("      (void)call_result;")
    host_refresh(op, model, lines)
    lines.append(answer)
    lines += [f"      Wipe({a.var}_s);" for a in e.wire if a.kind == "R" and record_has_bytes(a, model.header.structs)]
    lines += ["      return true;", "    }"]
    return lines


def mirror_out_buffer(a: Arg, lines: list[str]) -> str:
    """A mirror's int buffer: kMirrorOutCapacity ints, never read from the key (key_args leaves the
    capacity out, as the client's MirrorLookup key does)."""
    lines.append(f"      std::vector<int> {a.var}(static_cast<size_t>(kMirrorOutCapacity));")
    return f"{a.var}.data(), static_cast<{a.pair.ctype}>(kMirrorOutCapacity)"


def mirror_case(op: Op, model: Model) -> list[str]:
    e = op.export
    lines = [f"    case {op_const(e)}: {{"]
    call_args = [mirror_out_buffer(a, lines) if a.kind == "A" else host_decode(a, model.header.structs, lines)
                 for a in e.wire]
    lines.append("      if (!r.ok() || !r.AtEnd()) return false;")
    host_call(e, call_args, lines, "call_result")
    lines.append("      TlvWriter key_w;")
    for a in e.wire:
        if a.kind in WIRE_NUMBER:
            lines.append(f"      key_w.{WIRE_NUMBER[a.kind]}({a.var});")
        elif a.kind == "s":
            lines.append(f"      key_w.Str({a.var} ? {a.var}->c_str() : nullptr);")
    lines.append("      TlvWriter value_w;")
    host_value(e, "value_w", lines, "call_result")
    lines += [f"      ctx.PushMirror({op_const(e)}, key_w, value_w);", "      return true;", "    }"]
    return lines


def render_host(model: Model) -> str:
    out = [BANNER.format(gen=GENERATOR, shimh=SHIMH, ops=OPS),
           "// The Chromium Host's side of every generated op. Included by HOST/src/host_dispatch.mm after",
           "// cmux_cef_shim.h and the cmux_host wire interface. A malformed op returns false: the caller",
           "// ends the connection (p01-process section 4, rule 2).",
           "",
           "namespace cmux_host {", *op_enum(model),
           f"inline constexpr int32_t kMaxRecords = {MAX_RECORDS};",
           f"inline constexpr int32_t kMaxOutCapacity = {MAX_OUT_CAPACITY};",
           f"inline constexpr int32_t kMirrorOutCapacity = {MIRROR_OUT_CAPACITY};", ""]
    optional = [e for e in model.exports if e.optional]
    out += ["// Exports the header does not declare yet (fork API symbols): the host resolves each in its shim,",
            "// lists the ones it found in the HELLO, and answers an op whose symbol is missing with zero.",
            "struct OptionalExport {", "  uint16_t op;", "  const char* name;", "};",
            "inline constexpr OptionalExport kOptionalExports[] = {"]
    out += [f'    {{{op_const(e)}, "{e.name}"}},' for e in optional] or ['    {0, ""},  // none']
    out += ["};", ""]
    policies = [op for op in model.ops.values() if op.cls == "policy"]
    if policies:
        out.append("// Hand-written in HOST/src: install the host's own handler and push its policy.")
        for op in policies:
            extra = "".join(f", {host_param(a)}" for a in op.export.wire if a.kind not in ("F", "C"))
            out.append(f"void InstallPolicy{pascal(op.export.short)}(HostContext& ctx, bool installed{extra});")
        out.append("")
    out += ["// Runs one op from cmux on the UI thread; wire_token is the frame's token.",
            "inline bool DispatchOp(HostContext& ctx, uint16_t op, uint32_t wire_token, TlvReader& r) {",
            "  switch (op) {"]
    for op in model.ops.values():
        if op.cls in GENERATED_CLIENT and op.cls != "mirror":
            out += host_case(op, model)
    out += ["    default:", "      return false;  // a mirror, local or unknown op never arrives", "  }", "}", "",
            "// Reads one mirror for `key` (the export's arguments) and pushes it to cmux.",
            "inline bool ProduceMirror(HostContext& ctx, uint16_t op, TlvReader& r) {", "  switch (op) {"]
    for op in model.ops.values():
        if op.cls == "mirror":
            out += mirror_case(op, model)
    out += ["    default:", "      return false;", "  }", "}", "",
            "// The mirrors an event kind refreshes; the host pushes them before the event.",
            "// kind is an event kind (>= 0) or a pseudo event (kEvent<Name>, < 0); request -1 matches any",
            "// request, otherwise only an event with that request (CMUX_SHIM_TAB_EVENT's sub-kind).",
            "struct MirrorRefresh {", "  int kind;", "  int request;", "  uint16_t op;", "};"]
    out += [f"inline constexpr int kEvent{pascal(name)} = {value};  // pseudo event"
            for name, value in pseudo_event_values(model)]
    out.append("inline constexpr MirrorRefresh kMirrorRefreshes[] = {")
    refresh_rows = mirror_refresh_rows(model)
    out += [f"    {{{kind}, {request}, {op_const(op.export)}}},  // {label}" for kind, request, op, label in refresh_rows]
    if not refresh_rows:
        out.append("    {0, -1, 0},  // none")
    out += ["};", "",
            "// Calls f(op) for each mirror the event refreshes, in table order.",
            "template <typename F>",
            "inline void ForEachMirrorRefreshedBy(int kind, int request, F&& f) {",
            "  for (const MirrorRefresh& row : kMirrorRefreshes) {",
            "    if (row.op != 0 && row.kind == kind && (row.request < 0 || row.request == request)) f(row.op);",
            "  }", "}", "",
            "// One shim event as the kOpEvent payload (cmux_shim_event_fn's arguments).",
            "inline void EncodeEvent(TlvWriter& w, int kind, int browser_id, int request, int64_t a, int64_t b,",
            "                        const char* s1, const char* s2) {",
            "  w.I32(kind);", "  w.I32(browser_id);", "  w.I32(request);", "  w.I64(a);", "  w.I64(b);",
            "  w.Str(s1);", "  w.Str(s2);", "}", "}  // namespace cmux_host", ""]
    return "\n".join(out)


def pseudo_event_values(model: Model) -> list[tuple[str, int]]:
    """Pseudo events (attach) as kind values -1, -2, ... in name order: event kinds are >= 0."""
    return [(name, -1 - index) for index, name in enumerate(model.pseudo_events)]


def mirror_refresh_rows(model: Model) -> list[tuple[int, int, Op, str]]:
    """(kind value, request or -1, mirror op, label) for every refresh event of every mirror, in op order."""
    kinds = dict(model.events)
    pseudo = dict(pseudo_event_values(model))
    rows = []
    for op in model.ops.values():
        if op.cls != "mirror":
            continue
        for r in op.refresh_events:
            value = pseudo[r.kind] if r.pseudo else kinds[r.kind]
            label = r.kind if r.request is None else f"{r.kind}:{r.request}"
            rows.append((value, -1 if r.request is None else r.request, op, label))
    return rows


def host_param(a: Arg) -> str:
    kind = "int" if is_browser_arg(a) else {"i": "int32_t", "u": "uint32_t", "l": "int64_t", "d": "double",
                                            "s": "const char*", "v": "void*"}.get(a.kind)
    if kind is None:
        raise Failure(f"a policy argument '{a.decl}' must be a number, a string or a view")
    return f"{kind} {a.name}"


# ---------------------------------------------------------------------------------------------
# Swift generation


def swift_types(export: Export, cls: str) -> tuple[list[str], list[str]]:
    if cls == "local":
        return [], []
    args: list[str] = [".int32"] if cls in ("mint", "policy") else []
    for a in export.wire:
        if a.kind in ("A", "B"):
            args.append(".int32")
        elif a.kind in SWIFT_TYPE:
            args.append(SWIFT_TYPE[a.kind])
    reply = [SWIFT_TYPE[export.ret_kind]] if export.ret_kind in SWIFT_TYPE else []
    reply += [REPLY_SWIFT[a.kind] for a in export.wire if a.kind in REPLY_SWIFT]
    return args, reply


# Frame fields each wire kind takes in client_encode; a list (L, R) takes a variable number.
FRAME_FIELDS = {"i": 1, "u": 1, "l": 1, "d": 1, "s": 1, "b": 1, "v": 1, "A": 1, "B": 1, "C": 0, "F": 0, "I": 0}


def swift_pending_keys(op: Op, model: Model) -> list[str]:
    """`PendingKey(.mirror, [field index or nil])` per pending key: the frame field client_encode puts
    each named parameter in (a mint or policy op's first field is the minted id or the flag)."""
    position: dict[str, int] = {}
    index: int | None = 1 if op.cls in ("mint", "policy") else 0
    for a in op.export.wire:
        if index is None:
            break
        position[a.name] = index
        count = FRAME_FIELDS.get(a.kind)
        index = None if count is None else index + count
    keys = []
    for pattern in op.pending_keys:
        fields = []
        for param in pattern.params:
            if param == "*":
                fields.append("nil")
            elif param in position:
                fields.append(str(position[param]))
            else:
                raise Failure(f"{op.export.name}: pending key {pattern.text!r}: {param!r} follows a list "
                              "argument, so no fixed frame field holds it")
        mirror = swift_name(model.mirror_ops[pattern.base].export.short).strip("`")
        keys.append(f"PendingKey(.{mirror}, [{', '.join(fields)}])")
    return keys


def render_swift(model: Model) -> str:
    h = model.header
    names = [swift_name(e.short) for e in model.exports]
    if len(set(names)) != len(names):
        raise Failure("two exports map to one Swift case name")
    ev_names = [swift_name(k[len("CMUX_SHIM_"):]) for k, _ in model.events]
    optional_rows = pack(["." + swift_name(e.short).strip("`") for e in model.exports if e.optional], "        ")
    optional_ops = (["    static let optionalOps: Set<ChromiumHostOp> = ["]
                    + [row + "," for row in optional_rows] + ["    ]"]) if optional_rows else \
        ["    static let optionalOps: Set<ChromiumHostOp> = []"]
    out = [BANNER.format(gen=GENERATOR, shimh=SHIMH, ops=OPS),
           "/// Every `cmux_shim_*` export as a Chromium Host control op; `rawValue` is the wire id",
           "/// (plans/cmux-next/chrome-parity/p01-process.md, section 3.2).",
           "nonisolated enum ChromiumHostOp: UInt16, CaseIterable, Sendable {"]
    out += pack([f"{n} = {e.index}" for n, e in zip(names, model.exports)], "    case ")
    out += ["",
            "    /// The SHA-256 of the cmux_cef_shim.h this table was generated from (`CEFShimABI`).",
            f'    static let abiIdentity = "{h.identity}"',
            "    /// This generation's op ids, classes and wire types; both HELLOs carry it.",
            f'    static let wireIdentity = "{model.wire_identity}"',
            "    /// Ops of fork API symbols the header does not declare yet (`r.optional` in CEFShimLibrary).",
            *optional_ops,
            "    /// Host -> cmux control ops: a shim event, an async result, a mirror value, an ack.",
            f"    static let eventOp: UInt16 = {EVENT_OP:#x}, replyOp: UInt16 = {REPLY_OP:#x}",
            f"    static let mirrorOp: UInt16 = {MIRROR_OP:#x}, ackOp: UInt16 = {ACK_OP:#x}",
            "",
            "    /// How an export crosses to the host (plans/cmux-next/chromium-host-ops.json).",
            "    nonisolated enum Class: Sendable {",
            "        case post, mirror, `async`, mint, policy, view, local, preinit",
            "    }",
            "",
            "    nonisolated enum WireType: Sendable {",
            "        case int32, uint32, int64, double, string, bytes, view, strings, records, int32Array",
            "    }",
            "",
            "    nonisolated enum Value: Equatable, Sendable {",
            "        case int32(Int32), uint32(UInt32), int64(Int64), double(Double), string(String?), bytes([UInt8])",
            "        case view(UInt64), strings([String]), records([[Value]]), int32Array([Int32])",
            "",
            "        var wireType: WireType {",
            "            switch self {",
            "            case .int32: .int32",
            "            case .uint32: .uint32",
            "            case .int64: .int64",
            "            case .double: .double",
            "            case .string: .string",
            "            case .bytes: .bytes",
            "            case .view: .view",
            "            case .strings: .strings",
            "            case .records: .records",
            "            case .int32Array: .int32Array",
            "            }",
            "        }",
            "    }",
            "",
            "    nonisolated enum WireError: Error, Equatable, Sendable {",
            "        /// A local or mirror op never goes on the wire.",
            "        case notOnWire(ChromiumHostOp)",
            "        case valueCount(expected: Int, got: Int)",
            "        case valueType(index: Int, expected: WireType, got: WireType)",
            "        /// The reader ran out of bytes or found a malformed value.",
            "        case malformed",
            "    }",
            "",
            "    /// One op as cmux sends it: values in wire order (a mint or policy op's first value is the",
            "    /// minted id or the installed flag).",
            "    nonisolated struct Call: Equatable, Sendable {",
            "        let op: ChromiumHostOp",
            "        let token: UInt32",
            "        let values: [Value]",
            "",
            "        init(_ op: ChromiumHostOp, token: UInt32, values: [Value]) throws(WireError) {",
            "            guard op.wireClass != .local, op.wireClass != .mirror else { throw .notOnWire(op) }",
            "            let types = op.argumentTypes",
            "            guard types.count == values.count else {",
            "                throw .valueCount(expected: types.count, got: values.count)",
            "            }",
            "            for (index, (type, value)) in zip(types, values).enumerated() where value.wireType != type {",
            "                throw .valueType(index: index, expected: type, got: value.wireType)",
            "            }",
            "            self.op = op",
            "            self.token = token",
            "            self.values = values",
            "        }",
            "    }",
            "",
            "    /// A mirror key the op changes (`pending_keys`): cmux marks it pending under the op's token",
            "    /// until the host's ACK. `fields` holds, per key parameter, the index of the op frame's field",
            "    /// that names it, or nil for `*` (any value).",
            "    nonisolated struct PendingKey: Equatable, Sendable {",
            "        let mirror: ChromiumHostOp",
            "        let fields: [Int?]",
            "",
            "        init(_ mirror: ChromiumHostOp, _ fields: [Int?]) {",
            "            self.mirror = mirror",
            "            self.fields = fields",
            "        }",
            "    }",
            "",
            "    private nonisolated struct Row: Sendable {",
            "        let wireClass: Class",
            "        let arguments: [WireType]",
            "        let reply: [WireType]",
            "        let pending: [PendingKey]",
            "",
            "        init(_ wireClass: Class, _ arguments: [WireType], _ reply: [WireType],",
            "             _ pending: [PendingKey] = []) {",
            "            self.wireClass = wireClass",
            "            self.arguments = arguments",
            "            self.reply = reply",
            "            self.pending = pending",
            "        }",
            "    }",
            "",
            "    private static let rows: [Row] = ["]
    for e in model.exports:
        op = model.ops[e.name]
        args, reply = swift_types(e, op.cls)
        row = f"        Row(.{op.cls}, [{', '.join(args)}], [{', '.join(reply)}]"
        pending = swift_pending_keys(op, model)
        if pending:
            out.append(f"{row},")
            out += [f"            [{', '.join(pending)}]),"] if len(", ".join(pending)) < 90 else \
                ["            ["] + [f"                {key}," for key in pending] + ["            ]),"]
        else:
            out.append(f"{row}),")
    out += ["    ]",
            "",
            "    private var row: Row { Self.rows[Int(rawValue) - 1] }",
            "    var wireClass: Class { row.wireClass }",
            "    /// The values cmux sends, in order.",
            "    var argumentTypes: [WireType] { row.arguments }",
            "    /// An async op's REPLY or a mirror's value: the result, then the out-parameters.",
            "    var replyTypes: [WireType] { row.reply }",
            "    /// The mirror keys the op changes (`pending_keys`); empty for most ops.",
            "    var pendingKeys: [PendingKey] { row.pending }",
            "",
            "    /// Decodes a REPLY or MIRROR value; `next` reads one value of a type from the frame.",
            "    func decodeReply(reading next: (WireType) throws(WireError) -> Value) throws(WireError) -> [Value] {",
            "        var values: [Value] = []",
            "        for (index, type) in replyTypes.enumerated() {",
            "            let value = try next(type)",
            "            guard value.wireType == type else {",
            "                throw .valueType(index: index, expected: type, got: value.wireType)",
            "            }",
            "            values.append(value)",
            "        }",
            "        return values",
            "    }",
            "",
            "    /// An event (or pseudo event) that refreshes a mirror; `request` -1 matches any request.",
            "    nonisolated struct Refresh: Equatable, Sendable {",
            "        let kind: Int32",
            "        let request: Int32",
            "        let mirror: ChromiumHostOp",
            "",
            "        init(_ kind: Int32, _ request: Int32, _ mirror: ChromiumHostOp) {",
            "            self.kind = kind",
            "            self.request = request",
            "            self.mirror = mirror",
            "        }",
            "    }",
            ""]
    for name, value in pseudo_event_values(model):
        out += [f"    /// The pseudo event `{name}` as a refresh kind (event kinds are >= 0).",
                f"    static let {swift_name(name + '_event')}: Int32 = {value}"]
    out.append("    static let refreshes: [Refresh] = [")
    for kind, request, op, label in mirror_refresh_rows(model):
        out.append(f"        Refresh({kind}, {request}, .{swift_name(op.export.short).strip('`')}),  // {label}")
    out += ["    ]",
            "",
            "    /// The mirrors an event of `kind` with `request` refreshes, in table order.",
            "    static func mirrors(refreshedByKind kind: Int32, request: Int32) -> [ChromiumHostOp] {",
            "        refreshes.compactMap { $0.kind == kind && ($0.request < 0 || $0.request == request) ? $0.mirror : nil }",
            "    }",
            "}",
            "",
            "/// `cmux_shim_event_kind_t`, as the host forwards it in an `eventOp` frame.",
            "nonisolated enum ChromiumHostEventKind: Int32, CaseIterable, Sendable {"]
    out += pack([f"{n} = {v}" for n, (_, v) in zip(ev_names, model.events)], "    case ")
    out += ["",
            "    /// The mirrors this event refreshes; the host pushes them before the event. `request` is the",
            "    /// event's request (CMUX_SHIM_TAB_EVENT's sub-kind).",
            "    func refreshedMirrors(request: Int32) -> [ChromiumHostOp] {",
            "        ChromiumHostOp.mirrors(refreshedByKind: rawValue, request: request)",
            "    }",
            "",
            "    /// One event: `cmux_shim_event_fn`'s arguments. A kind this build does not know still decodes.",
            "    nonisolated struct Record: Equatable, Sendable {",
            "        let rawKind: Int32",
            "        let browser: Int32",
            "        let request: Int32",
            "        let a: Int64",
            "        let b: Int64",
            "        let s1: String",
            "        let s2: String",
            "",
            "        var kind: ChromiumHostEventKind? { ChromiumHostEventKind(rawValue: rawKind) }",
            "",
            "        typealias Reader = (ChromiumHostOp.WireType) throws(ChromiumHostOp.WireError) -> ChromiumHostOp.Value",
            "",
            "        init(reading next: Reader) throws(ChromiumHostOp.WireError) {",
            "            rawKind = try Self.int32(next(.int32))",
            "            browser = try Self.int32(next(.int32))",
            "            request = try Self.int32(next(.int32))",
            "            a = try Self.int64(next(.int64))",
            "            b = try Self.int64(next(.int64))",
            "            s1 = try Self.string(next(.string))",
            "            s2 = try Self.string(next(.string))",
            "        }",
            "",
            "        private static func int32(_ value: ChromiumHostOp.Value) throws(ChromiumHostOp.WireError) -> Int32 {",
            "            guard case .int32(let number) = value else { throw .malformed }",
            "            return number",
            "        }",
            "",
            "        private static func int64(_ value: ChromiumHostOp.Value) throws(ChromiumHostOp.WireError) -> Int64 {",
            "            guard case .int64(let number) = value else { throw .malformed }",
            "            return number",
            "        }",
            "",
            "        private static func string(_ value: ChromiumHostOp.Value) throws(ChromiumHostOp.WireError) -> String {",
            "            guard case .string(let text) = value else { throw .malformed }",
            "            return text ?? \"\"",
            "        }",
            "    }",
            "}",
            ""]
    return "\n".join(out)


def pack(items: list[str], prefix: str, width: int = 116) -> list[str]:
    lines, cur = [], ""
    for item in items:
        candidate = f"{cur}, {item}" if cur else item
        if cur and len(prefix) + len(candidate) > width:
            lines.append(prefix + cur)
            cur = item
        else:
            cur = candidate
    if cur:
        lines.append(prefix + cur)
    return lines


# ---------------------------------------------------------------------------------------------
# Hand-written sides


def strip_c_comments(text: str) -> str:
    return blank_out(text)


def hand_written(root: Path, folder: str) -> str:
    base = root / folder
    if not base.is_dir():
        return ""
    parts = []
    for path in sorted(base.rglob("*")):
        if path.is_file() and path.suffix in (".mm", ".cc", ".cpp", ".h") and "generated" not in path.parts:
            parts.append(strip_c_comments(path.read_text(encoding="utf-8", errors="replace")))
    return "\n".join(parts)


def calls(code: str, name: str) -> bool:
    """Whether `code` calls the free function `name` (qualified or not), apart from its declarations and
    definitions (a type word before the name) and member calls of the same name (R().Name)."""
    for m in re.finditer(rf"(?:\b\w+\s*::\s*)*\b{re.escape(name)}\s*\(", code):
        before = code[:m.start()].rstrip()
        if before.endswith((".", "->")):
            continue
        word = re.search(r"\b(\w+)\s*[*&]*$", before)
        if word is not None and word.group(1) != "return":
            continue
        return True
    return False


def defines(code: str, name: str) -> bool:
    for m in re.finditer(rf"\b{re.escape(name)}\s*\(", code):
        try:
            close = match_paren(code, m.end() - 1)
        except Failure:
            continue
        if code[close + 1:].lstrip().startswith("{"):
            return True
    return False


def missing_sides(model: Model | None, header: Header, per_export: dict[str, str], root: Path
                  ) -> list[tuple[str, str, str]]:
    rows = []
    client = hand_written(root, CLIENT_SRC)
    host = hand_written(root, HOST_SRC)
    for e in model.exports if model else header.exports:
        op = model.ops.get(e.name) if model else None
        if op is None or e.name in per_export:
            rows.append((e.name, op.cls if op else "-", "classification"))
            continue
        if op.cls == "local" and e.name != "cmux_shim_abi_id" and not defines(client, e.name):
            rows.append((e.name, op.cls, f"client (hand-written in {CLIENT_SRC})"))
        if op.cls == "policy" and not defines(host, "InstallPolicy" + pascal(e.short)):
            rows.append((e.name, op.cls, f"host (InstallPolicy{pascal(e.short)} in {HOST_SRC})"))
    return rows


def shim_library_text(root: Path) -> str:
    """CEFShimLibrary's declaration and, when it has one, its binding initializer's file."""
    return "\n".join(path.read_text(encoding="utf-8") for path in (root / SHIM_LIBRARY, root / SHIM_LIBRARY_BIND)
                     if path.exists())


def shim_library_problems(model: Model, root: Path) -> list[str]:
    """CEFShimLibrary binds header exports with r(...) and optional exports with r.optional(...)."""
    path = root / SHIM_LIBRARY
    if not path.exists():
        return []
    code = re.sub(r"//[^\n]*", "", shim_library_text(root))
    bound = re.findall(r'\br(\.optional)?\(\s*"(cmux_shim_\w+)"\s*\)', code)
    in_header = {e.name for e in model.header.exports}
    optional = {e.name for e in model.exports if e.optional}
    problems = []
    seen = set()
    for how, name in bound:
        seen.add(name)
        if name in optional and not how:
            problems.append(f"{SHIM_LIBRARY}: {name} is an optional export: bind it with r.optional")
        elif name not in in_header and name not in optional:
            problems.append(f"{SHIM_LIBRARY}: {name} is neither a header export nor in optional_exports")
    for name in sorted(optional - seen):
        problems.append(f"{OPS}: optional export {name} is not bound in {SHIM_LIBRARY} (stale entry)")
    return problems


# ---------------------------------------------------------------------------------------------
# Swift call sites


@dataclass
class Site:
    path: str
    line: int
    export: str
    prop: str
    used: bool
    owner: str = ""  # the innermost type declaration around the call ("" at file scope)
    function: str = ""  # the innermost func, init or computed var around the call
    offset: int = 0  # in the file's text
    token_form: bool = False  # in a closure handed to one of TOKEN_FORM_CALLS
    mint_form: bool = False  # a mint_returns id call whose id keys the wait for its reply_event (in_mint_form)


def shim_properties(root: Path) -> dict[str, str]:
    path = root / SHIM_LIBRARY
    if not path.exists():
        raise Failure(f"{SHIM_LIBRARY} is missing: it maps Swift names to exports")
    text = shim_library_text(root)
    # An export bound to its C type as `let cName: <type> = try unsafe r("export")`, which the property `name`
    # wraps in Swift types (CEFShimLibrary+Bind.swift).
    c_binding = re.compile(r'\blet\s+c([A-Z]\w*)\s*:[^\n]*?=\s*(?:try\s+)?(?:unsafe\s+)?r(?:\.optional)?\(\s*"(cmux_shim_\w+)"\s*\)')
    names = {local[0].lower() + local[1:]: export for local, export in c_binding.findall(text)}
    names.update(re.findall(r'\b(\w+)\s*=\s*(?:[^\n"=]*==[^\n"]*\?\s+)?(?:try\s+)?(?:unsafe\s+)?r(?:\.optional)?\(\s*"(cmux_shim_\w+)"\s*\)',
                            c_binding.sub("", text)))
    return names


# The head of a brace block that is a statement, not a closure (the text before `{` on its line).
CONTROL_HEAD = re.compile(r"^\s*(?:}\s*)?(if|guard|while|for|switch|else|defer|do|repeat|catch|init|deinit|set|"
                          r"willSet|didSet)\b|\b(else|do|defer|repeat)\s*$")
MODIFIERS = r"(?:(?:@\w+(?:\([^)]*\))?|private|fileprivate|internal|public|package|open|static|class|final|override|" \
            r"nonisolated|mutating|nonmutating|dynamic|lazy)(?:\([^)]*\))?\s+)*"
FUNC_HEAD = re.compile(rf"^\s*{MODIFIERS}(func|subscript)\b")
GETTER_HEAD = re.compile(rf"^\s*{MODIFIERS}(get\b|var\s+\w+\s*:[^=]*$)")
BINARY_RIGHT = re.compile(r"^(==|!=|>=|<=|\?\?|&&|\|\||[<>+\-*/%](?!>)|\.(?!\.)|\?\.|!\.|as\b|is\b|\[)")
STATEMENT_LABEL = re.compile(r"(^|\n)\s*(case\b[^\n]*|default)\s*:$")
WORD_USES = ("return", "guard", "if", "while", "case", "switch", "where", "throw", "yield")


def matching_open(text: str, close: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    for i in range(close, -1, -1):
        if text[i] == close_ch:
            depth += 1
        elif text[i] == open_ch:
            depth -= 1
            if depth == 0:
                return i
    return -1


def matching_close(text: str, open_index: int, open_ch: str, close_ch: str) -> int:
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i
    return len(text) - 1


def expression_start(text: str, index: int) -> int:
    """Extends an expression left over a receiver chain (`tab.runtime.shim?.`, `url.withCString`)."""
    i = index
    while i > 0:
        ch = text[i - 1]
        if ch.isalnum() or ch in "_.?!$":
            i -= 1
        elif ch == ")":
            i = matching_open(text, i - 1, "(", ")")
            if i < 0:
                return index
        else:
            break
    return i


def result_used(text: str, start: int, end: int) -> bool:
    """Whether the expression text[start:end] is bound, guarded, compared, passed or returned."""
    for _ in range(32):
        line_end = text.find("\n", end)
        right = text[end:len(text) if line_end < 0 else line_end].lstrip()
        if BINARY_RIGHT.match(right):
            return True
        left = text[:start].rstrip()
        while True:
            word = re.search(r"\b(try\??|try!|await)$", left)
            if not word:
                break
            left = left[:word.start()].rstrip()
        if not left:
            return False
        if "\n" in text[len(left):start] and (re.search(r"[!)}\]]$", left) or STATEMENT_LABEL.search(left)):
            return False  # the previous line ended a statement or is a `case ...:` label
        if left.endswith(";"):
            return False
        if re.search(r"(^|[^=!<>])=$", left):
            return not re.search(r"(^|[\s(;{])_\s*=$", left)
        if re.search(r"(==|!=|>=|<=|&&|\|\||\?\?|[(\[,:?!<>+\-*/%])$", left):
            return True
        word = re.search(r"\b(\w+)$", left)
        if word and word.group(1) in WORD_USES:
            return True
        if word and word.group(1) == "in" and re.search(r"\bfor\b[^{}\n]*\bin$", left):
            return True  # iterated
        brace = None
        if left.endswith("{"):
            brace = len(left) - 1
        elif word and word.group(1) == "in":
            brace = enclosing_brace(text, start)
        if brace is None or brace < 0:
            return False  # a statement of its own: the result is dropped
        close = matching_close(text, brace, "{", "}")
        if text[end:close].strip():
            return False  # one statement among several
        head_start = text.rfind("\n", 0, brace) + 1
        # The head of this brace only: `if v >= 5 { return call {` heads the closure with `return call`.
        head = re.split(r"[{};]", text[head_start:brace])[-1]
        before = text[:brace].rstrip()
        # A closure stored or passed returns the result, also inside a statement's head
        # (`switch text.withCString({ shim.x($0) })`); only the block after a head drops it.
        if not before or re.search(r"[=(\[,:]$", before):
            return True
        if CONTROL_HEAD.search(head):
            return False
        if FUNC_HEAD.match(head):
            return "->" in head  # a single-expression body returns its value
        if GETTER_HEAD.match(head):
            return True
        start, end = expression_start(text, len(before)), close + 1
    return True


def enclosing_brace(text: str, index: int) -> int:
    depth = 0
    for i in range(index - 1, -1, -1):
        if text[i] == "}":
            depth += 1
        elif text[i] == "{":
            if depth == 0:
                return i
            depth -= 1
    return -1


@dataclass
class Scope:
    kind: str  # "type" or "func"
    name: str  # the type's name, or the func's ("init" for an initializer, a computed var's name)
    head: str  # the declaration text before `{`
    open: int
    close: int


DECL_MODIFIERS = r"(?:(?:@\w+(?:\([^)]*\))?|private|fileprivate|internal|public|package|open|static|class|final|" \
                 r"override|nonisolated|mutating|nonmutating|dynamic|lazy|convenience|required|indirect)" \
                 r"(?:\([^)]*\))?\s+)*"
DECL_FUNC = re.compile(rf"^\s*{DECL_MODIFIERS}(?:func\s+([A-Za-z_]\w*)|(init)[?!]?\s*[(<]|"
                       rf"var\s+([A-Za-z_]\w*)\s*:[^=]*$)", re.S)
DECL_TYPE = re.compile(rf"^\s*{DECL_MODIFIERS}(?:class|struct|enum|extension|actor|protocol)\s+([A-Z]\w*)")


def declaration_head(masked: str, brace: int) -> str:
    """The text before `{` from the start of its declaration: its line, or the line where its
    parameter list opens."""
    start = masked.rfind("\n", 0, brace) + 1
    while start > 0 and masked.count(")", start, brace) > masked.count("(", start, brace):
        start = masked.rfind("\n", 0, start - 1) + 1
    return masked[start:brace].lstrip(" \t}")


def swift_scopes(masked: str) -> list[Scope]:
    """Every type and function body of a masked Swift file, outermost first."""
    scopes: list[Scope] = []
    stack: list[Scope | None] = []
    for i, ch in enumerate(masked):
        if ch == "{":
            head = declaration_head(masked, i)
            func, typ = DECL_FUNC.match(head), DECL_TYPE.match(head)
            scope = None
            if func:
                scope = Scope("func", next(g for g in func.groups() if g), head, i, len(masked))
            elif typ:
                scope = Scope("type", typ.group(1), head, i, len(masked))
            if scope:
                scopes.append(scope)
            stack.append(scope)
        elif ch == "}" and stack:
            scope = stack.pop()
            if scope:
                scope.close = i
    return scopes


def context_at(scopes: list[Scope], index: int) -> tuple[str, str]:
    """(innermost type, innermost function) around `index`."""
    owner = function = ""
    for scope in scopes:
        if scope.open < index < scope.close:
            if scope.kind == "type":
                owner = scope.name
            else:
                function = scope.name
    return owner, function


# A parameter that is a closure taking the CEFShimLibrary first (`_ body: (CEFShimLibrary, Int32) -> Int32`).
SHIM_CLOSURE_PARAM = re.compile(r":\s*(?:@\w+\s+)*\(\s*(?:_\s+\w+\s*:\s*)?CEFShimLibrary\s*[,)]")
# A closure's first parameter when it names one (`{ library, browser in`, `{ (library: CEFShimLibrary) in`).
CLOSURE_PARAM_NAME = re.compile(r"\s*(?:\[[^\]]*\]\s*)?\(?\s*([A-Za-z_]\w*)\b[^{}]*?\bin\b")


def shim_closure_takers(files: list[tuple[str, str, list[Scope]]]) -> set[str]:
    """Functions that hand the CEFShimLibrary to a closure argument (`call { $0.extReload($1, id) }`)."""
    return {scope.name for _, _, scopes in files for scope in scopes
            if scope.kind == "func" and SHIM_CLOSURE_PARAM.search(scope.head)}


def shim_closure_receivers(masked: str, takers: set[str]) -> list[tuple[int, str]]:
    """(open brace, receiver name) of every closure passed to a shim closure taker: `$0`, or the
    closure's first parameter when it names one."""
    if not takers:
        return []
    found = []
    names = "|".join(re.escape(t) for t in sorted(takers))
    for m in re.finditer(rf"(?<![\w.])(?:{names})\s*([({{])", masked):
        if re.search(r"\bfunc\s+$", masked[:m.start()]):
            continue  # the declaration
        brace = m.end() - 1
        if m.group(1) == "(":
            inner = masked[m.end():].lstrip()
            if inner.startswith("{"):
                brace = len(masked) - len(inner)  # the closure is the first argument
            else:
                close = matching_close(masked, m.end() - 1, "(", ")")
                after = masked[close + 1:].lstrip()
                if not after.startswith("{"):
                    continue
                brace = len(masked) - len(after)  # a trailing closure
        named = CLOSURE_PARAM_NAME.match(masked, brace + 1)
        receiver = named.group(1) if named and named.group(1) != "_" else "$0"
        found.append((brace, receiver))
    return found


def swift_sites(root: Path) -> list[Site]:
    """Every call of a CEFShimLibrary function: through `shim`, or through the closure parameter of
    a function that passes the library to its closure argument."""
    props = shim_properties(root)
    sites: list[Site] = []
    files = swift_files(root)
    takers = shim_closure_takers(files)
    for rel, masked, scopes in files:
        calls = {(m.start(), m.end(), m.group(1))
                 for m in re.finditer(r"\bshim[?!]?\.([A-Za-z_]\w*)\s*\(", masked)}
        for brace, receiver in shim_closure_receivers(masked, takers):
            if receiver == "shim":
                continue  # the pattern above finds it
            close = matching_close(masked, brace, "{", "}")
            pattern = re.compile(rf"(?<![\w$]){re.escape(receiver)}[?!]?\.([A-Za-z_]\w*)\s*\(")
            calls |= {(m.start(), m.end(), m.group(1)) for m in pattern.finditer(masked, brace, close)}
        for begin, end, prop in sorted(calls):
            export = props.get(prop)
            if export is None:
                continue
            close = matching_close(masked, end - 1, "(", ")")
            start = expression_start(masked, begin)
            owner, function = context_at(scopes, begin)
            sites.append(Site(rel, masked.count("\n", 0, begin) + 1, export, prop,
                              result_used(masked, start, close + 1), owner, function, begin,
                              in_token_form(masked, scopes, begin), in_mint_form(masked, scopes, start)))
    return sites


def closure_callee(masked: str, brace: int) -> str:
    """The function a closure that opens at `brace` is handed to: `f(...) {`, `f {` or `f(x, label: {`;
    "" when the brace opens no argument closure."""
    left = masked[:brace].rstrip()
    if left.endswith(")"):  # a trailing closure after the call's parentheses
        left = masked[:matching_open(masked, len(left) - 1, "(", ")")].rstrip()
    elif left.endswith(("(", ",", ":")):  # an argument: the call is the unclosed `(` before it
        depth = 0
        for i in range(brace - 1, -1, -1):
            if masked[i] in ")]}":
                depth += 1
            elif masked[i] in "([{":
                if depth == 0:
                    if masked[i] != "(":
                        return ""
                    left = masked[:i].rstrip()
                    break
                depth -= 1
        else:
            return ""
    m = re.search(r"\b([A-Za-z_]\w*)$", left)
    return m.group(1) if m else ""


def in_token_form(masked: str, scopes: list[Scope], index: int) -> bool:
    """Whether the call at `index` is inside a closure handed to one of TOKEN_FORM_CALLS, within the
    innermost function around it."""
    floor = max((s.open for s in scopes if s.kind == "func" and s.open < index < s.close), default=-1)
    brace = enclosing_brace(masked, index)
    while brace > floor:
        if closure_callee(masked, brace) in TOKEN_FORM_CALLS:
            return True
        brace = enclosing_brace(masked, brace)
    return False


MINT_BINDING = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]+)?=\s*$")
REPLY_WAIT = re.compile(r"\.reply\(\s*for\s*:")


def in_mint_form(masked: str, scopes: list[Scope], start: int) -> bool:
    """Whether the call whose expression starts at `start` is in the mint form: its result is bound to a
    local (`let message = shim.devToolsCall(...)`) that keys, directly or through locals made from it, a
    `.reply(for:` wait later in the same function. The minted id is the key in both backends: the host
    answers it in the export's reply_event, a refusal included, so nothing reads an answer in the call."""
    line_start = masked.rfind("\n", 0, start) + 1
    bound = MINT_BINDING.search(masked, line_start, start)
    body = min((s for s in scopes if s.kind == "func" and s.open < start < s.close),
               key=lambda s: s.close - s.open, default=None)
    if bound is None or body is None:
        return False
    rest = masked[start:body.close]
    names = {bound.group(1)}
    for m in re.finditer(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^=\n]+)?=([^\n]*)", rest):
        if any(re.search(rf"\b{re.escape(n)}\b", m.group(2)) for n in names):
            names.add(m.group(1))
    for m in REPLY_WAIT.finditer(rest):
        key = first_argument(rest, m.end(), matching_close(rest, rest.index("(", m.start()), "(", ")"))
        if any(re.search(rf"\b{re.escape(n)}\b", key) for n in names):
            return True
    return False


def first_argument(text: str, begin: int, close: int) -> str:
    """text[begin:close] up to its first comma outside nested brackets."""
    depth = 0
    for i in range(begin, close):
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
        elif text[i] == "," and depth == 0:
            return text[begin:i]
    return text[begin:close]


def site_settled(model: Model, site: Site, op: Op, client: str) -> bool:
    """Whether a call site already meets host mode, so --swift-sites no longer lists it: an async call, or
    a preinit answered by a wire:REPLY verdict, in the token form, a mint_returns id call in the mint
    form, a site a host_mode_rewrites entry settles (SETTLED_NEEDS), or a `client` one whose export
    `client` (hand_written HOST/client) defines and whose wire entry point it calls."""
    if site.token_form and op.cls in TOKEN_FORM_CLASSES:
        return True
    if site.token_form and op.cls in TOKEN_FORM_VERDICT_CLASSES and op.reply_event == REPLY_WIRE:
        return True
    if site.mint_form and op.cls == "mint" and op.mint_returns == "id" and op.reply_event:
        return True
    rewrite = rewrite_for(model, site)
    if rewrite is not None and rewrite.needs == "client":
        return defines(client, site.export) and calls(client, rewrite.wire)
    return rewrite is not None and rewrite.needs in SETTLED_NEEDS


def swift_files(root: Path) -> list[tuple[str, str, list[Scope]]]:
    """(path, masked source, scopes) of every app Swift file that mentions the shim."""
    out = []
    for path in sorted((root / APP).rglob("*.swift")):
        rel = path.relative_to(root).as_posix()
        if rel in (SHIM_LIBRARY, SHIM_LIBRARY_BIND) or "/Generated/" in rel:
            continue
        source = path.read_text(encoding="utf-8", errors="replace")
        if "shim" not in source and "CEFShimLibrary" not in source:
            continue
        masked = mask_swift_source(source)
        out.append((rel, masked, swift_scopes(masked)))
    return out


def rewrite_site_problems(model: Model, root: Path) -> list[str]:
    """Every host_mode_rewrites function exists in its file and uses one of the entry's exports by
    its CEFShimLibrary name (a call, or an optional function read): an entry that names no site
    accepts nothing and only reads like a rule."""
    if not (root / SHIM_LIBRARY).is_file():
        return []  # a tree without the sources
    names: dict[str, set[str]] = {}
    for prop, export in shim_properties(root).items():
        names.setdefault(export, set()).add(prop)
    files = {rel: (masked, scopes) for rel, masked, scopes in swift_files(root)}
    problems = []
    for rewrite in model.rewrites:
        path = f"{APP}/{rewrite.path}"
        if not (root / path).is_file():
            continue  # load_ops reports it
        masked, scopes = files.get(path) or (mask_swift_source((root / path).read_text(encoding="utf-8")), [])
        if not scopes:
            scopes = swift_scopes(masked)
        props = sorted(p for export in rewrite.exports for p in names.get(export, ()))
        uses = re.compile(rf"\.(?:{'|'.join(map(re.escape, props))})\b") if props else None
        for owner, function in rewrite.functions:
            bodies = [s for s in scopes if s.kind == "func" and s.name == function
                      and owner in ("", context_at(scopes, s.open)[0])]
            label = f"host_mode_rewrites {rewrite.site!r}: {owner + '.' if owner else ''}{function}"
            if not bodies:
                problems.append(f"{label} is no function of {path}")
            elif uses is None or not any(uses.search(masked, s.open, s.close) for s in bodies):
                problems.append(f"{label} uses none of {', '.join(rewrite.exports)}: name the function that calls them")
    return problems


def rewrite_for(model: Model, site: Site, needs: tuple[str, ...] | None = None) -> Rewrite | None:
    """The host_mode_rewrites entry that accepts this call site, if any."""
    for rewrite in model.rewrites:
        if f"{APP}/{rewrite.path}" != site.path or site.export not in rewrite.exports:
            continue
        if needs is not None and rewrite.needs not in needs:
            continue
        if any(fn == site.function and owner in ("", site.owner) for owner, fn in rewrite.functions):
            return rewrite
    return None


def startup_bodies(root: Path) -> tuple[dict[str, list[tuple[int, int]]], list[str]]:
    """The bodies that run before CefInitialize returns: STARTUP_ROOTS and every function they hand the
    CEFShimLibrary to (`f(shim)`, `Type(shim)`), transitively. Returns {path: [(open, close)]}, problems."""
    files = swift_files(root)
    functions: dict[tuple[str, str], list[tuple[str, Scope]]] = {}  # (owner, name) -> scopes
    takes_shim: dict[str, list[tuple[str, str, Scope]]] = {}  # name -> (path, owner, scope) of shim takers
    for rel, _, scopes in files:
        for scope in scopes:
            if scope.kind != "func":
                continue
            owner, _ = context_at(scopes, scope.open)
            functions.setdefault((owner, scope.name), []).append((rel, scope))
            if "CEFShimLibrary" in scope.head:
                key = owner if scope.name == "init" else scope.name
                takes_shim.setdefault(key, []).append((rel, owner, scope))
    sources = {rel: masked for rel, masked, _ in files}
    problems: list[str] = []
    queue: list[tuple[str, Scope]] = []
    for path, owner, name in STARTUP_ROOTS:
        found = [(rel, s) for rel, s in functions.get((owner, name), []) if rel == f"{APP}/{path}"]
        if not found:
            problems.append(f"startup root {owner}.{name} is not in {APP}/{path}: update STARTUP_ROOTS")
        queue += found
    bodies: dict[str, list[tuple[int, int]]] = {}
    seen: set[tuple[str, int]] = set()
    while queue:
        rel, scope = queue.pop()
        if (rel, scope.open) in seen:
            continue
        seen.add((rel, scope.open))
        bodies.setdefault(rel, []).append((scope.open, scope.close))
        body = sources[rel][scope.open:scope.close]
        for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\(\s*(?:[a-z]\w*\.)*shim\s*[,)]", body):
            queue += [(path, s) for path, _, s in takes_shim.get(m.group(1), [])]
    return bodies, problems

# ---------------------------------------------------------------------------------------------
# View parity


@dataclass(frozen=True)
class MojomMethod:
    interface: str
    name: str
    sync: bool  # [Sync]: the caller waits for the reply


def mojom_methods(text: str) -> list[MojomMethod]:
    code = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))
    out = []
    for m in re.finditer(r"\binterface\s+(\w+)\s*\{", code):
        close = matching_close(code, m.end() - 1, "{", "}")
        body = code[m.end():close]
        depth, cur, statements = 0, [], []
        for ch in body:
            depth += ch == "{"
            depth -= ch == "}"
            if ch == ";" and depth == 0:
                statements.append("".join(cur))
                cur = []
            else:
                cur.append(ch)
        for statement in statements:
            attributes = re.match(r"\s*((?:\[[^\]]*\]\s*)*)", statement)
            s = statement[attributes.end():]
            if re.match(r"(enum|struct|const|union)\b", s):
                continue
            mm = re.match(r"(\w+)\s*@?\d*\s*\(", s)
            if mm:
                sync = re.search(r"[\[,]\s*Sync\s*[\],=]", attributes.group(1)) is not None
                out.append(MojomMethod(m.group(1), mm.group(1), sync))
    return out


PARITY_TARGETS = ("op", "event", "wire", "not_needed", "pending")
PARITY_ROW_FIELDS = {"mojom", "interface", "method", "note", *PARITY_TARGETS}
TASK_ID = re.compile(r"p\d{2}-[a-z][a-z0-9-]*-\d{3}[a-z]?")


class ParityCarriers:
    """What a parity row may name: exports and event kinds of the header and the ops JSON's
    optional lists, the Kinds of chromium_host_wire.h, and the design's task ids (for pending)."""

    def __init__(self, root: Path, header: Header) -> None:
        self.exports = {e.name for e in header.exports}
        self.events = {k for k, _ in header.events}
        ops = root / OPS
        if ops.exists():
            data = json.loads(ops.read_text(encoding="utf-8"))
            self.exports |= {e.get("name") for e in data.get("optional_exports", [])}
            self.events |= {e.get("kind") for e in data.get("optional_events", [])}
        self.wire: set[str] | None = None
        wire = root / HOST_WIRE
        if wire.exists():
            code = blank_out(wire.read_text(encoding="utf-8"))
            m = re.search(r"\benum\s+Kind\b[^{;]*\{", code)
            body = code[m.end():matching_close(code, m.end() - 1, "{", "}")] if m else ""
            self.wire = set(re.findall(r"\b(k\w+)\s*=", body))
        self.tasks: set[str] | None = None
        design = root / DESIGN_RESULT
        if design.exists():
            programs = json.loads(design.read_text(encoding="utf-8")).get("programs", {})
            self.tasks = {t["id"] for p in programs.values() for t in p.get("tasks", []) if "id" in t}

    def row_problem(self, row: dict, label: str) -> str | None:
        unknown = sorted(set(row) - PARITY_ROW_FIELDS)
        if unknown:
            return f"{label}: unknown field(s) {', '.join(unknown)}"
        targets = [t for t in PARITY_TARGETS if t in row]
        if len(targets) != 1:
            return f"{label}: needs exactly one of {', '.join(PARITY_TARGETS)}"
        target, value = targets[0], row[targets[0]]
        if not isinstance(value, str) or not value.strip():
            return f"{label}: {target} must be a non-empty string"
        if target == "op" and value not in self.exports:
            return f"{label}: op {value!r} is neither a header export nor an optional export"
        if target == "event" and value not in self.events:
            return f"{label}: event {value!r} is neither a header event kind nor an optional event"
        if target == "wire" and self.wire is None:
            return f"{label}: wire {value!r}, but {HOST_WIRE} is missing"
        if target == "wire" and value not in self.wire:
            return f"{label}: wire {value!r} is not a Kind of {HOST_WIRE}"
        if target == "pending":
            if not TASK_ID.fullmatch(value):
                return f"{label}: pending {value!r} is not a task id (pNN-program-NNN)"
            if self.tasks is not None and value not in self.tasks:
                return f"{label}: pending task {value} is not in {DESIGN_RESULT}"
            if not str(row.get("note", "")).strip():
                return f"{label}: a pending row needs a note naming the carrier its task builds"
        return None


MOJOM_FIELDS = {"file", "source", "chromium", "commit", "sha256", "role"}
HEX40, HEX64 = re.compile(r"[0-9a-f]{40}"), re.compile(r"[0-9a-f]{64}")


@dataclass
class ViewParity:
    problems: list[str] = field(default_factory=list)
    unmapped: list[str] = field(default_factory=list)
    pending: list[str] = field(default_factory=list)  # "label\ttask"
    counts: list[str] = field(default_factory=list)  # parsed from the vendored texts, never constants


def mojom_provenance(root: Path, mojoms: list) -> tuple[list[str], str | None]:
    """(problems, "version (commit)") for the parity JSON's mojoms list: every file names its Chromium
    path, version, commit and sha256, all at one revision, the one cef-manifest.json pins."""
    problems: list[str] = []
    revisions = set()
    for entry in mojoms:
        name = entry.get("file", "?")
        unknown = sorted(set(entry) - MOJOM_FIELDS)
        if unknown:
            problems.append(f"{name}: unknown mojoms field(s) {', '.join(unknown)}")
        source = str(entry.get("source", ""))
        if source.rsplit("/", 1)[-1] != name:
            problems.append(f"{name}: source {source!r} is not the Chromium path of this file")
        if not HEX40.fullmatch(str(entry.get("commit", ""))):
            problems.append(f"{name}: commit must be the 40-hex Chromium commit it was copied at")
        if not HEX64.fullmatch(str(entry.get("sha256", ""))):
            problems.append(f"{name}: sha256 must be the file's 64-hex sha256")
        if not str(entry.get("chromium", "")).strip():
            problems.append(f"{name}: chromium must be the Chromium version it was copied at")
        revisions.add((str(entry.get("chromium", "")), str(entry.get("commit", ""))))
    if len(revisions) > 1:
        problems.append("the mojoms come from more than one Chromium revision: "
                        + ", ".join(f"{v} ({c[:12]})" for v, c in sorted(revisions)))
    if len(revisions) != 1:
        return problems, None
    version, commit = next(iter(revisions))
    manifest = root / CEF_MANIFEST
    if manifest.exists():
        pinned = json.loads(manifest.read_text(encoding="utf-8")).get("chromium")
        if pinned != version:
            problems.append(f"the mojoms are Chromium {version} but {CEF_MANIFEST} pins {pinned}: vendor them "
                            f"again at the pinned revision and re-check their rows")
    return problems, f"{version} ({commit[:12]})"


def view_parity(root: Path, header: Header) -> ViewParity:
    out = ViewParity()
    parity_path, mojom_dir = root / PARITY, root / MOJOM_DIR
    if not parity_path.exists():
        out.problems.append(f"{PARITY} is missing (task p01-process-055)")
    if not mojom_dir.is_dir():
        out.problems.append(f"{MOJOM_DIR}/ is missing: vendor the remote_cocoa mojoms (task p01-process-059)")
    if out.problems:
        return out
    data = json.loads(parity_path.read_text(encoding="utf-8"))
    listed = {m.get("file"): m for m in data.get("mojoms", [])}
    provenance_problems, revision = mojom_provenance(root, data.get("mojoms", []))
    out.problems += provenance_problems
    on_disk = sorted(p.name for p in mojom_dir.glob("*.mojom"))
    for name in on_disk:
        if name not in listed:
            out.problems.append(f"{MOJOM_DIR}/{name} is not listed in {PARITY}")
    methods: dict[tuple[str, str, str], str | None] = {}  # -> the target that maps it
    sync: set[tuple[str, str, str]] = set()
    for name in sorted({str(n) for n in listed} | set(on_disk)):
        path = mojom_dir / name
        if not path.exists():
            out.problems.append(f"{PARITY} lists {name}, which is not in {MOJOM_DIR}/")
            continue
        raw = path.read_bytes()
        if name in listed and listed[name].get("sha256") != hashlib.sha256(raw).hexdigest():
            out.problems.append(f"{name} changed since it was mapped (sha256 differs): re-check its rows")
        for m in mojom_methods(raw.decode("utf-8")):
            methods[(name, m.interface, m.name)] = None
            if m.sync:
                sync.add((name, m.interface, m.name))
    carriers = ParityCarriers(root, header)
    seen: set[tuple[str, str, str]] = set()
    pending: dict[tuple[str, str, str], str] = {}
    for row in data.get("methods", []):
        key = (row.get("mojom"), row.get("interface"), row.get("method"))
        label = f"{key[0]} {key[1]}.{key[2]}"
        if key not in methods:
            out.problems.append(f"{label}: mapped, but the mojom has no such method (stale row)")
            continue
        if key in seen:
            out.problems.append(f"{label}: mapped twice")
        seen.add(key)
        problem = carriers.row_problem(row, label)
        if problem:
            out.problems.append(problem)
        elif "pending" in row:
            pending[key] = row["pending"]
            continue  # no carrier yet: the method stays unmapped
        methods[key] = next((t for t in PARITY_TARGETS if t in row), "?")
    unmapped = [key for key, target in sorted(methods.items()) if not target]
    out.unmapped = [f"{m} {i}.{n}" for m, i, n in unmapped]
    for key in unmapped:
        label = f"{key[0]} {key[1]}.{key[2]}"
        task = pending.get(key)
        out.problems.append(f"{label}: unmapped, pending on {task}" if task else f"{label}: unmapped")
    out.pending = [f"{m} {i}.{n}\t{task}" for (m, i, n), task in sorted(pending.items())]

    def tally(keys: list[tuple[str, str, str]]) -> str:
        targets = [methods[k] for k in keys]
        mapped = ", ".join(f"{t} {targets.count(t)}" for t in PARITY_TARGETS if t in targets)
        waiting = sum(k in pending for k in keys)
        return (f"{len(keys)} methods, {sum(k in sync for k in keys)} [Sync]; "
                f"{len(keys) - targets.count(None)} mapped" + (f" ({mapped})" if mapped else "")
                + (f", {waiting} pending" if waiting else ""))

    keys = sorted(methods)
    out.counts.append(f"view parity: {len(on_disk)} vendored mojoms at Chromium {revision or '?'}: {tally(keys)}")
    for mojom, interface in sorted({(k[0], k[1]) for k in keys}):
        out.counts.append(f"  {mojom} {interface}: "
                          + tally([k for k in keys if k[0] == mojom and k[1] == interface]))
    return out


# ---------------------------------------------------------------------------------------------
# Main


def outputs(model: Model) -> dict[str, str]:
    return {HOST_INC: render_host(model), CLIENT_INC: render_client(model), SWIFT_OUT: render_swift(model)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=SCRIPT_ROOT, help="repository root (default: this checkout)")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--check-ops", action="store_true")
    parser.add_argument("--list-missing", action="store_true")
    parser.add_argument("--swift-sites", action="store_true")
    parser.add_argument("--by-file", action="store_true")
    parser.add_argument("--check-return-use", action="store_true")
    parser.add_argument("--check-pre-attach", action="store_true")
    parser.add_argument("--check-view-parity", action="store_true")
    parser.add_argument("--list-unmapped", action="store_true")
    parser.add_argument("--list-pending", action="store_true")
    parser.add_argument("--dump-header", action="store_true")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        header = parse_header(root / SHIMH)
        if args.dump_header:
            json.dump({"identity": header.identity, "exports_count": len(header.exports),
                       "events_count": len(header.events),
                       "exports": [{"name": e.name, "returns": e.returns, "args": [a.as_json() for a in e.args],
                                    "wire": "".join(a.kind for a in e.wire)} for e in header.exports],
                       "events": [{"kind": k, "value": v} for k, v in header.events]}, sys.stdout, indent=1)
            print()
            return 0
        if args.check_view_parity or args.list_unmapped or args.list_pending:
            parity = view_parity(root, header)
            if args.list_unmapped:
                print("\n".join(parity.unmapped))
            if args.list_pending:
                print("\n".join(parity.pending))
            if args.check_view_parity and parity.counts:
                print("\n".join(parity.counts))
            for p in parity.problems:
                print(f"view parity: {p}", file=sys.stderr)
            return 1 if parity.problems and args.check_view_parity else 0
        model, problems, per_export = load_ops(header, root)
        if args.swift_sites or args.check_return_use or args.check_pre_attach:
            if model is None:
                raise Failure("; ".join(problems))
            if args.check_pre_attach:
                return report_pre_attach(model, root)
            return report_sites(model, root, args)
        if args.list_missing or args.check or args.check_ops:
            if model is not None:
                problems += shim_library_problems(model, root) + rewrite_site_problems(model, root)
            if args.list_missing:
                for row in missing_sides(model, header, per_export, root):
                    print("\t".join(row))
            failed = bool(problems)
            for p in problems:
                print(f"ops: {p}", file=sys.stderr)
            if args.check and model is not None and not problems:
                for rel, text in outputs(model).items():
                    path = root / rel
                    if not path.exists() or path.read_text(encoding="utf-8") != text:
                        print(f"stale: {rel} (run python3 {GENERATOR})", file=sys.stderr)
                        failed = True
            if args.check:
                for name, cls, side in missing_sides(model, header, per_export, root):
                    if side != "classification":
                        print(f"missing: {name} ({cls}): {side}", file=sys.stderr)
                        failed = True
            if not failed and (args.check or args.check_ops):
                n_opt = sum(1 for e in model.exports if e.optional)
                e_opt = len(model.events) - len(header.events)
                print(f"chromium host wire: {len(header.exports)}/{len(header.exports)} exports classified "
                      f"(+{n_opt} optional), {len(header.events)}/{len(header.events)} event kinds "
                      f"(+{e_opt} optional), {len(model.rewrites)} host-mode rewrites, 0 sync")
            return 1 if failed and (args.check or args.check_ops) else 0
        if model is None or problems:
            for p in problems:
                print(f"ops: {p}", file=sys.stderr)
            return 1
        for rel, text in outputs(model).items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                path.write_text(text, encoding="utf-8")
                print(f"wrote {rel}")
        return 0
    except Failure as error:
        print(f"gen-chromium-host-wire: {error}", file=sys.stderr)
        return 1


def site_reasons(model: Model, op: Op, site: Site) -> list[str]:
    """Why a call site changes in host mode: its class; result-read when it reads a stand-in result;
    sync-reply when it reads, in the call's turn, an answer that comes later in the op's wire:REPLY
    (the result or the out-parameters) and no host_mode_rewrites entry (needs reply) moves it to the
    token API (CEFHostReplies, task 018)."""
    reasons = [op.cls] if op.cls in SITE_CLASSES else []
    if site.used and op.cls in POST_LIKE:
        reasons.append("result-read")
    if site.used and op.cls == "async" and op.reply_event == REPLY_WIRE and rewrite_for(model, site, ("reply",)) is None:
        reasons.append("sync-reply")
    return reasons


def report_sites(model: Model, root: Path, args: argparse.Namespace) -> int:
    rows = []
    client = hand_written(root, CLIENT_SRC)
    for site in swift_sites(root):
        op = model.ops.get(site.export)
        if op is None or site_settled(model, site, op, client):
            continue
        reasons = site_reasons(model, op, site)
        if reasons:
            rows.append((site, op.cls, reasons))
    if args.check_return_use:
        bad = [(site, cls) for site, cls, reasons in rows if "result-read" in reasons and rewrite_for(model, site) is None]
        for site, cls in bad:
            print(f"{site.path}:{site.line}: {site.export} is {cls}; this caller reads its result "
                  f"(shim.{site.prop}): drop the read, reclassify, or list the site in host_mode_rewrites",
                  file=sys.stderr)
        if not bad:
            print("chromium host wire: 0 stand-in results read outside host_mode_rewrites")
        return 1 if bad else 0
    if args.by_file:
        files: dict[str, list[str]] = {}
        for site, _, _ in rows:
            files.setdefault(site.path, []).append(site.export)
        for path, names in sorted(files.items()):
            print(f"{path}\t{len(names)}\t{','.join(sorted(set(names)))}")
    else:
        for site, cls, reasons in rows:
            print(f"{site.path}:{site.line}\t{site.export}\t{cls}\t{','.join(reasons)}")
    return 0


def report_pre_attach(model: Model, root: Path) -> int:
    """Exit 1 for a mirror read on the startup path that no host_mode_rewrites entry (after_attach) moves
    after the attach await: in host mode it would read the empty cache."""
    bodies, problems = startup_bodies(root)
    for p in problems:
        print(f"pre-attach: {p}", file=sys.stderr)
    bad = []
    for site in swift_sites(root):
        op = model.ops.get(site.export)
        if op is None or op.cls != "mirror":
            continue
        if not any(open_ < site.offset < close for open_, close in bodies.get(site.path, [])):
            continue
        if rewrite_for(model, site, ("after_attach",)) is None:
            bad.append(site)
    for site in bad:
        owner = f"{site.owner}." if site.owner else ""
        print(f"{site.path}:{site.line}: {site.export} is a mirror read in {owner}{site.function}, which runs "
              f"before the host attaches: list it in host_mode_rewrites (needs after_attach) or read it later",
              file=sys.stderr)
    if not bad and not problems:
        print("chromium host wire: 0 mirror reads before attach outside host_mode_rewrites")
    return 1 if bad or problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
