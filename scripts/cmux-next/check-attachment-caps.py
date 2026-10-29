#!/usr/bin/env python3
"""Reject attachment cap names and literal size or count ceilings in upload code.

Leo, 2026-10-26: "why the FUCK SHOULD THERE BE A FUCKING SIZE CAP ANYWAYS ... I ALREADY SAID WE
NEED ARBITARRILY LARGE FILES OF ANY TYPE". Attachments take arbitrarily large files of any type,
any number of them.

This is a source guard, not data-flow analysis. Named protocol/chunk boundaries remain
valid; inline numeric ceilings on file/batch sizes must not hide admission limits, and
neither may a ceiling on how many files a send or a batch takes (`files.length > 10`,
`list.count <= 64`, `MAX_ATTACHMENTS`). A comparison that only picks a route (one message
or several, inline or staged) carries `cap-allow: route` in a comment on its line or the
line above.

`bun run check` runs it as `check:attachment-caps` with `--warn`: each finding is a
`::warning` annotation and the exit is 0 (style and size checks warn, never fail).
Without `--warn` a finding exits 1 (tests/test_attachment_caps_guard.py).
"""

from __future__ import annotations

import argparse
import ast
import os
import re
from pathlib import Path

# Protocol frames/ranges, filename validation and terminal ACK buffers do not reject an
# original: transfer loops split files at these boundaries. Never exempt a file/total cap.
TRANSPORT_BOUNDS = {"MAX_CHUNK_BYTES", "MAX_RANGE_BYTES", "MAX_FRAME_BYTES", "MAX_MESSAGE_BYTES", "MAX_NAME_BYTES", "MAX_PENDING_INPUT_ACK_BYTES", "maximumUploadStageChunk", "maximumChunkBytes", "maximumFrameBytes", "maximumRangeBytes"}
# Scope exceptions name an exact path AND symbol, never a directory or a wildcard.
# Derived/protocol budgets stay. Legacy original-file limits are explicitly deferred
# to the streaming follow-up split from #26409; they are not permission for new caps.
RETAINED_BOUNDS = {
    "Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/MobileImageAttachmentPreparer.swift": {
        "maximumRawInputBytes": "Unused legacy declaration; outside native staged admission.",
        "maximumEncodedBytes": "Downsampled PNG/JPEG representation budget, not the input file.",
    },
    "Packages/iOS/CmuxMobileShellModel/Sources/CmuxMobileShellModel/TaskComposerAttachment.swift": {
        "maximumFileBytes": "Legacy mobile task admission; removal belongs to the streaming follow-up.",
        "maximumTotalBytes": "Legacy mobile task batch quota; deferred with its upload transport.",
    },
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneDraftAttachments.swift": {
        "maximumBytes": "Inline draft persistence memory budget; file-reference persistence is separate.",
    },
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneRequest+Decoding.swift": {
        "maximumWarmBytes": "New Tab warm-cache budget, unrelated to chat.upload decoding.",
    },
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneUpload.swift": {
        "maximumFileBytes": "Legacy whole-message inline upload; staged upload has separate admission.",
        "maximumTotalBytes": "Legacy whole-message batch budget; staged batches do not use it.",
        "maximumPeerFileBytes": "Legacy peer inline protocol budget; removal needs streaming integration.",
    },
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentPeerUploads.swift": {
        "maximumPeerFileBytes": "Legacy peer upload admission, deferred to the streaming follow-up.",
        "maximumTotalBytes": "Legacy peer batch quota, deferred with its transport replacement.",
    },
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/CloudUploads.swift": {
        "maximumFileBytes": "Cloud upload quota; removal waits for the streaming/multipart prerequisites.",
        "maximumTotalBytes": "Cloud batch quota; deferred with the cloud streaming integration.",
    },
    "Packages/macOS/CmuxNext/Sources/CmuxNextFloating/ChiefPet/ChiefAvatarUploads.swift": {
        "maximumBytes": "Custom pet-avatar image format budget; not a chat attachment.",
        "maximumGIFBytes": "Custom pet-avatar GIF budget; not a chat attachment.",
    },
    "cmux-tui/crates/cmux-conversation/src/attachments.rs": {
        "MAX_ATTACHMENT_BYTES": "Conversation admission; removal requires disk-backed cloud uploads.",
        "MAX_POSTER_BYTES": "Derived video-poster representation budget.",
        "MAX_PREVIEW_IMAGE_BYTES": "Derived image-preview representation budget.",
    },
    "cmux-tui/crates/cmux-tui/src/link/access_cli/uploads.rs": {
        "MAX_FILE_BYTES": "Cloud CLI upload quota; deferred with the cloud transport integration.",
        "MAX_FILES": "Open: the Cloud upload CLI takes 64 files a call; removed with its size cap (#27016).",
    },
    "webviews/src/agent-session/acpmux/attachments.ts": {
        "MAX_IMAGE_BYTES": "Model image representation budget; larger previews are downsampled.",
        "MAX_DOCUMENT_BYTES": "Inline PDF protocol-frame budget; larger originals use file links.",
        "MAX_TEXT_BYTES": "Inline prompt-text budget; larger originals use file links.",
        "MAX_AUDIO_BYTES": "Inline audio protocol-frame budget; not native staged file admission.",
    },
    "webviews/src/pages/home-channels/attachmentService.ts": {
        "MAX_ATTACHMENT_BYTES": "Home original admission; removal requires streaming and multipart upload.",
    },
    # Count bounds that are not a send's admission: concurrency and other surfaces' items.
    "cmux-tui/crates/cmux-tui-core/src/conversation_attachments.rs": {
        "MAX_UPLOADS": "Uploads open at once (concurrency); more wait their turn, none is refused for count.",
    },
    "cmux-tui/crates/cmux-tui-core/src/conversation_attachment_cloud.rs": {
        "MAX_UPLOADS": "The same concurrency bound, imported.",
    },
    "cmux-tui/crates/cmux-tui-core/src/state/workspace_checklist_store.rs": {
        "MAX_ITEM_ATTACHMENTS": "A workspace checklist item's links, not chat or Home attachments.",
    },
    # Open count caps on a send, found by this guard's count rules (HQ#4946 item 4 follow-up).
    # Each is a real cap to remove; listed so new ones still warn, never as permission.
    "Native/OptChat/chief-kernel/src/tools.rs": {
        "MAX_SEND_ATTACHMENTS": "Open: the Chief's send tool takes 10 attachments; Chief-area follow-up.",
    },
    "Native/OptChat/optchat-chief/src/tools.rs": {
        "MAX_SEND_ATTACHMENTS": "Open: re-export of the Chief kernel's cap above.",
    },
    "backend/apps/api/src/chief-brain-cc/attachments.ts": {
        "MAX_FILES": "Open: the hosted Chief brain reads the 12 newest files of a turn; Chief-area follow-up.",
    },
}
FORBIDDEN = re.compile(r"\b(?:MAX_[A-Z0-9_]*(?:BYTES|SIZE)|maximum\w*(?:File|Bytes|Stage)\w*)\b")
# Count caps by name: how many files a send or a batch takes. In attachment/upload paths any
# of these; elsewhere only a name that says attachments or uploads (a diff's or a git
# listing's file limit is not an attachment cap).
FORBIDDEN_COUNT = re.compile(r"\b(?:MAX_[A-Z0-9_]*(?:ATTACHMENTS|FILES|UPLOADS)|max(?:imum)?(?:[A-Z]\w*)?(?:Attachments|Files|Uploads)(?:Count)?)\b")
FORBIDDEN_COUNT_ANYWHERE = re.compile(r"\b(?:MAX_[A-Z0-9_]*(?:ATTACHMENTS|UPLOADS)|max(?:imum)?(?:[A-Z]\w*)?(?:Attachments|Uploads)(?:Count)?)\b")
# Collections a literal count comparison caps, in attachment/upload paths (elsewhere a count
# of attachments is a cache or a layout bound far more often than an admission cap).
COUNTED = {"files", "attachments", "attachment", "uploads", "upload", "batch", "manifest", "list", "items", "entries"}
ROUTE_MARK = "cap-allow: route"
EXCLUDED = {".git", ".build", "node_modules", "dist", "fixtures", "generated", "tests", "test", "__tests__", "vendor", "target", "build", "third_party"}
SOURCE_SUFFIXES = {".swift", ".rs", ".ts", ".tsx", ".js", ".mjs"}
# chat.upload is decoded here despite the filename lacking upload/attachment.
EXTRA_SOURCES = {"AgentPaneRequest+Decoding.swift"}
TOKEN = re.compile(r"//[^\n]*|/\*[\s\S]*?\*/|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[\w$]+|<=|>=|==|!=|=>|<<|>>|&&|\|\||[^\s]")
COMPARISONS = {"<", "<=", ">", ">="}
STOPS = COMPARISONS | {"==", "!=", "&&", "||", "=", ";", ",", ":", "?", "if", "guard", "else", "return", "let", "const", "var"}


def code_tokens(source: str) -> list[re.Match[str]]:
    # Keep positions for diagnostics while ignoring comments and strings.
    return [m for m in TOKEN.finditer(source) if not m[0].startswith(('//', '/*', '"', "'", '`'))]


def operand(tokens: list[re.Match[str]], index: int, direction: int) -> list[str]:
    """Read one operand, retaining balanced calls and Swift reduce closures."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    if direction < 0:
        pairs = {closing: opening for opening, closing in pairs.items()}
    stack: list[str] = []
    result: list[str] = []
    while 0 <= index < len(tokens):
        token = tokens[index][0]
        if not stack and (token in STOPS or token in pairs.values()):
            break
        # A forward brace begins the conditional body, not a numeric operand.
        if not stack and direction > 0 and token == "{":
            break
        if token in pairs:
            stack.append(pairs[token])
        elif stack and token == stack[-1]:
            stack.pop()
        result.append(token)
        index += direction
    return result if direction > 0 else result[::-1]


def literal_value(tokens: list[str]) -> int | None:
    """Evaluate only bounded integer arithmetic, never source calls or identifiers."""
    expression = " ".join(tokens)
    if not expression or len(expression) > 200 or not re.fullmatch(r"[0-9_\s()+*<>-]+", expression):
        return None

    def value(node: ast.AST) -> int:
        if isinstance(node, ast.Constant) and type(node.value) is int:
            result = node.value
        elif isinstance(node, ast.BinOp):
            left, right = value(node.left), value(node.right)
            if isinstance(node.op, ast.Mult):
                result = left * right
            elif isinstance(node.op, ast.Add):
                result = left + right
            elif isinstance(node.op, ast.Sub):
                result = left - right
            elif isinstance(node.op, ast.LShift) and 0 <= right <= 63:
                result = left << right
            else:
                raise ValueError("unsupported arithmetic")
        else:
            raise ValueError("not an integer expression")
        if abs(result) > 2**64:
            raise ValueError("oversized arithmetic")
        return result

    try:
        return value(ast.parse(expression, mode="eval").body)
    except (SyntaxError, ValueError, RecursionError):
        return None


def words_of(tokens: list[str]) -> set[str]:
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", " ".join(tokens)).lower()
    return set(re.findall(r"[a-z]+", words))


def file_count(tokens: list[str], nouns: set[str]) -> bool:
    """A count of files, attachments or batch entries (`files.length`, `list.count`)."""
    words = words_of(tokens)
    return bool(words & {"count", "length", "len"}) and bool(words & nouns) and not words & {"chunk", "chunks", "frame", "range", "text", "name", "bytes", "size", "key", "keys"}


def file_size(tokens: list[str]) -> bool:
    words = words_of(tokens)
    # These sizes bound one transfer unit, not the original or batch. In particular,
    # a named MAX_CHUNK_BYTES comparison can choose streaming for a large file.
    return bool(words & {"size", "bytes", "count", "length", "len"}) and not words & {"chunk", "chunks", "frame", "range"}


def attachment_path(relative: Path) -> bool:
    return relative.name in EXTRA_SOURCES or any("attachment" in part.lower() or "upload" in part.lower() for part in relative.parts)


def files(root: Path, everywhere: bool = False) -> list[Path]:
    """Sources in attachment/upload paths, or every source when `everywhere`."""
    found: list[Path] = []
    for folder, directories, names in os.walk(root):
        directories[:] = [name for name in directories if name.lower() not in EXCLUDED and not name.endswith("Tests") and not name.startswith(".")]
        for name in names:
            path = Path(folder) / name
            relative = path.relative_to(root)
            if path.suffix not in SOURCE_SUFFIXES or ".test." in name or ".spec." in name:
                continue
            if everywhere or attachment_path(relative):
                found.append(path)
    return sorted(found)


def routed(lines: list[str], line_number: int) -> bool:
    """The finding's line, or the line above it, says the comparison only picks a route."""
    return any(ROUTE_MARK in lines[at] for at in (line_number - 1, line_number - 2) if 0 <= at < len(lines))


def violations(root: Path) -> list[str]:
    result: list[str] = []
    for path in files(root, everywhere=True):
        relative = path.relative_to(root)
        upload_code = attachment_path(relative)
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if not upload_code and not FORBIDDEN_COUNT_ANYWHERE.search(source):
            continue
        count_names = FORBIDDEN_COUNT if upload_code else FORBIDDEN_COUNT_ANYWHERE
        lines = source.split("\n")
        tokens = code_tokens(source)
        for index, token in enumerate(tokens):
            finding = None
            if upload_code and FORBIDDEN.fullmatch(token[0]) and token[0] not in TRANSPORT_BOUNDS:
                if token[0] not in RETAINED_BOUNDS.get(relative.as_posix(), {}):
                    finding = token[0]
            elif count_names.fullmatch(token[0]):
                if token[0] not in RETAINED_BOUNDS.get(relative.as_posix(), {}):
                    finding = "count cap: " + token[0]
            elif upload_code and token[0] in COMPARISONS:
                left = operand(tokens, index - 1, -1)
                right = operand(tokens, index + 1, 1)
                for counted, limit in ((left, right), (right, left)):
                    numeric = literal_value(limit)
                    if numeric is None:
                        continue
                    if numeric >= 1024 * 1024 and file_size(counted):
                        finding = "literal size cap: " + " ".join(left + [token[0]] + right)
                        break
                    if numeric >= 2 and file_count(counted, COUNTED):
                        finding = "literal count cap: " + " ".join(left + [token[0]] + right)
                        break
            if finding:
                line_number = source.count("\n", 0, token.start()) + 1
                if not routed(lines, line_number):
                    result.append(f"{relative}:{line_number}: {finding}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--warn", action="store_true",
                        help="report each finding as a ::warning annotation and exit 0 (bun run check)")
    args = parser.parse_args()
    found = violations(args.root.resolve())
    if found and args.warn:
        for finding in found:
            path, line, message = finding.split(":", 2)
            print(f"::warning file={path},line={line},title=attachment cap::{message.strip()} "
                  "(attachments take any number of files of any size; see scripts/cmux-next/check-attachment-caps.py)")
        print(f"attachment cap guard: {len(found)} warning(s)")
        return 0
    if found:
        print("attachment caps are forbidden in attachment/upload paths:")
        print("\n".join(found))
        return 1
    print("attachment cap guard: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
