#!/usr/bin/env python3
"""Reject attachment cap names and literal size ceilings in upload code.

This is a source guard, not data-flow analysis. Named protocol/chunk boundaries remain
valid; inline numeric ceilings on file/batch sizes must not hide admission limits.
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
        "MAX_POSTER_BYTES": "Derived video-poster representation budget, not original admission.",
        "MAX_PREVIEW_IMAGE_BYTES": "Derived image-preview representation budget, not original admission.",
        "max_bytes": "DerivedVariant representation budget only; original upload is uncapped.",
    },
    "cmux-tui/crates/cmux-tui/src/link/access_cli/uploads.rs": {
        "MAX_FILE_BYTES": "Cloud CLI upload quota; deferred with the cloud transport integration.",
    },
    "webviews/src/agent-session/acpmux/attachments.ts": {
        "MAX_IMAGE_BYTES": "Model image representation budget; larger previews are downsampled.",
        "MAX_DOCUMENT_BYTES": "Inline protocol-frame budget; larger originals use file links.",
        "MAX_TEXT_BYTES": "Inline prompt-text budget; larger originals use file links.",
        "MAX_AUDIO_BYTES": "Inline audio protocol-frame budget; not staged file admission.",
    },
    "webviews/src/pages/home-channels/attachmentService.ts": {
        "maxBytes": "Preview encoding budget; original upload is uncapped.",
        "MAX_UNSIZED_DECODE_BYTES": "Shared optional image-preview decode budget; original upload is uncapped.",
    },
    "Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Attachments/AttachmentPolicy.swift": {
        "streamMaxBytes": "Worker transport threshold; larger originals use presigned upload.",
        "posterMaxBytes": "Derived video-poster representation budget.",
        "previewMaxBytes": "Derived image-preview representation budget.",
    },
    "Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Attachments/AttachmentMedia.swift": {
        "previewMaxBytes": "Derived image-preview representation budget.",
        "maximumSize": "Derived video-poster pixel dimensions, not original bytes.",
    },
    "backend/packages/home-core/src/conversation/attachments.ts": {
        "maxBytes": "Derived image representation budget; original upload is uncapped.",
    },
}
FORBIDDEN = re.compile(r"\b(?:MAX_[A-Z0-9_]*(?:BYTES|SIZE)|maximum\w*(?:File|Bytes|Stage)\w*)\b")
HOME_FORBIDDEN = re.compile(r"\b(?:MAX_[A-Z0-9_]*(?:BYTES|SIZE)|maximum\w*(?:File|Bytes|Stage)\w*|max\w*(?:File|Bytes|Size))\b")
EXCLUDED = {".git", ".build", "node_modules", "dist", "fixtures", "generated", "tests", "test", "__tests__", "vendor", "target", "build", "third_party"}
SOURCE_SUFFIXES = {".swift", ".rs", ".ts", ".tsx", ".js", ".mjs"}
# chat.upload is decoded here despite the filename lacking upload/attachment.
EXTRA_SOURCES = {"AgentPaneRequest+Decoding.swift"}
# Home admission also lives in files without attachment/upload in their names.
ADMISSION_PATHS = {
    "Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Attachments/AttachmentMedia.swift",
    "Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Attachments/AttachmentPolicy.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneRequest+Decoding.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentChatUploads.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextHome/NativeTranscript/HomeComposerCheck.swift",
    "backend/apps/api/src/home-attachment-gc.ts",
    "backend/apps/api/src/home-attachment-quota.ts",
    "backend/apps/api/src/home-attachments.ts",
    "backend/packages/home-core/src/conversation/attachments.ts",
    "cmux-tui/crates/cmux-conversation/src/attachments.rs",
    "webviews/src/agent-session/acpmux/attachments.ts",
    "webviews/src/pages/home-channels/attachmentService.ts",
}
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


def file_size(tokens: list[str]) -> bool:
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", " ".join(tokens)).lower()
    words = set(re.findall(r"[a-z]+", words))
    # These sizes bound one transfer unit, not the original or batch. In particular,
    # a named MAX_CHUNK_BYTES comparison can choose streaming for a large file.
    return bool(words & {"size", "bytes", "count", "length", "len"}) and not words & {"chunk", "chunks", "frame", "range"}


def files(root: Path) -> list[Path]:
    found: list[Path] = []
    for folder, directories, names in os.walk(root):
        directories[:] = [name for name in directories if name.lower() not in EXCLUDED and not name.endswith("Tests") and not name.startswith(".")]
        for name in names:
            path = Path(folder) / name
            relative = path.relative_to(root)
            if path.suffix not in SOURCE_SUFFIXES or ".test." in name or ".spec." in name:
                continue
            if relative.as_posix() in ADMISSION_PATHS or name in EXTRA_SOURCES or any("attachment" in part.lower() or "upload" in part.lower() for part in relative.parts):
                found.append(path)
    return sorted(found)


def violations(root: Path) -> list[str]:
    result: list[str] = []
    for path in files(root):
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        tokens = code_tokens(source)
        forbidden = HOME_FORBIDDEN if path.relative_to(root).as_posix() in ADMISSION_PATHS else FORBIDDEN
        for index, token in enumerate(tokens):
            finding = None
            if forbidden.fullmatch(token[0]) and token[0] not in TRANSPORT_BOUNDS:
                if token[0] not in RETAINED_BOUNDS.get(path.relative_to(root).as_posix(), {}):
                    finding = token[0]
            elif token[0] in COMPARISONS:
                left = operand(tokens, index - 1, -1)
                right = operand(tokens, index + 1, 1)
                for size, limit in ((left, right), (right, left)):
                    numeric = literal_value(limit)
                    if numeric is not None and numeric >= 1024 * 1024 and file_size(size):
                        finding = "literal size cap: " + " ".join(left + [token[0]] + right)
                        break
            if finding:
                line_number = source.count("\n", 0, token.start()) + 1
                result.append(f"{path.relative_to(root)}:{line_number}: {finding}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    found = violations(args.root.resolve())
    if found:
        print("attachment caps are forbidden in attachment/upload paths:")
        print("\n".join(found))
        return 1
    print("attachment cap guard: clean")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
