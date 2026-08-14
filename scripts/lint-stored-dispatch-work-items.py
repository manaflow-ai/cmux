#!/usr/bin/env python3
"""Reject deferred-action handles that can build recursive release chains.

The parent-repository gate covers DispatchWorkItem declarations in Sources,
CLI, ios, package Sources, and the pinned Bonsplit sources. It also rejects
closure-bearing deferred handles stored inline in macOS SwiftUI State, where a
successor closure can capture a value snapshot that still owns its predecessor.
Other gitlink dependencies such as Ghostty remain dependency-owned and must be
audited when their pinned revisions change.
"""

from __future__ import annotations

import collections
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCES_ROOT = REPO_ROOT / "Sources"
CLI_ROOT = REPO_ROOT / "CLI"
IOS_ROOT = REPO_ROOT / "ios"
PACKAGES_ROOT = REPO_ROOT / "Packages"
BONSPLIT_SOURCES_ROOT = REPO_ROOT / "vendor" / "bonsplit" / "Sources"
TYPE_DECLARATIONS = {"actor", "class", "enum", "extension", "protocol", "struct"}
CALLABLE_DECLARATIONS = {"deinit", "func", "init", "subscript"}
STATEMENT_STARTERS = {
    "actor",
    "class",
    "enum",
    "extension",
    "func",
    "let",
    "protocol",
    "struct",
    "var",
}
KEYWORDS = TYPE_DECLARATIONS | CALLABLE_DECLARATIONS | STATEMENT_STARTERS | {
    "didSet",
    "get",
    "set",
    "willSet",
}
IDENTIFIER_KINDS = {"escaped_identifier", "identifier"}
SWIFTUI_STATE_AUDITED_HANDLE_TYPES = ("Task", "DispatchSourceTimer", "Timer")
MACOS_SWIFTUI_SOURCE_PREFIXES = (
    "Sources/",
    "Packages/Shared/",
    "Packages/macOS/",
    "vendor/bonsplit/Sources/",
)


@dataclass(frozen=True)
class Token:
    value: str
    line: int
    column: int
    kind: str = "symbol"


@dataclass(frozen=True)
class Scope:
    kind: str
    name: str


@dataclass(frozen=True)
class Declaration:
    path: str
    name: str
    type_text: str
    context: str
    line: int

    @property
    def key(self) -> tuple[str, str, str, str]:
        return (self.path, self.name, self.type_text, self.context)


@dataclass(frozen=True)
class Allowance:
    path: str
    name: str
    type_text: str
    context: str
    count: int
    reason: str


class RequiredSourceRootMissingError(RuntimeError):
    """Raised when an audited dependency source tree is unavailable."""


# These declarations cannot link replaced queued work through their owner's
# stored state. Context is part of each key so moving a function-local timeout
# into stored owner state cannot inherit an allowance merely by preserving its
# spelling.
ALLOWANCES = (
    Allowance(
        "Sources/AppDelegate.swift",
        "timeoutWorkItem",
        "DispatchWorkItem?",
        "local:AppDelegate.waitForDebugStressCondition",
        1,
        "function-local, single-shot debug stress deadline",
    ),
    Allowance(
        "Sources/AppDelegate.swift",
        "timeoutWorkItem",
        "DispatchWorkItem?",
        "local:AppDelegate.publishMultiWindowNotificationSocketStateIfNeeded",
        1,
        "function-local, single-shot UI-test deadline",
    ),
    Allowance(
        "Sources/Panels/MarkdownRemoteImageLoader.swift",
        "timeoutWorkItem",
        "DispatchWorkItem?",
        "member:MarkdownPinnedRemoteImageLoader",
        1,
        "single-shot network timeout protected by finish()",
    ),
    Allowance(
        "Sources/TabManager.swift",
        "timeoutWork",
        "DispatchWorkItem?",
        "local:TabManager.setupChildExitKeyboardUITestIfNeeded",
        1,
        "function-local, single-shot UI-test deadline",
    ),
    Allowance(
        "Sources/Update/UpdateTitlebarAccessory.swift",
        "startupScanWorkItems",
        "[DispatchWorkItem]",
        "member:UpdateTitlebarAccessoryController",
        1,
        "fixed-size append-only startup scan fanout",
    ),
    Allowance(
        "Packages/macOS/CmuxRemoteDaemon/Sources/CmuxRemoteDaemon/Client/RemoteDaemonRPCClient.swift",
        "webSocketKeepaliveTimeoutWorkItem",
        "DispatchWorkItem?",
        "member:RemoteDaemonRPCClient",
        1,
        "state-queue-owned watchdog whose queued closure weakly captures the client",
    ),
    Allowance(
        "Packages/macOS/CmuxRemoteDaemon/Sources/CmuxRemoteDaemon/Client/RemoteDaemonRPCClient.swift",
        "transportKeepaliveTimeoutWorkItem",
        "DispatchWorkItem?",
        "member:RemoteDaemonRPCClient",
        1,
        "state-queue-owned watchdog whose queued closure weakly captures the client",
    ),
    Allowance(
        "CLI/cmux.swift",
        "keepaliveTimeoutWorkItem",
        "DispatchWorkItem?",
        "member:CMUXCLI.VMPtyWebSocketBridge",
        1,
        "send-queue-owned watchdog whose queued closure weakly captures the bridge",
    ),
)


def _newline(tokens: list[Token], line: int, column: int) -> None:
    if not tokens or tokens[-1].kind != "newline":
        tokens.append(Token("\n", line, column, "newline"))


def tokenize_swift(source: str) -> list[Token]:
    """Return structural Swift tokens while discarding comments and strings."""
    tokens: list[Token] = []
    index = 0
    line = 1
    column = 1

    def advance(count: int = 1) -> None:
        nonlocal index, line, column
        for _ in range(count):
            if source[index] == "\n":
                line += 1
                column = 1
            else:
                column += 1
            index += 1

    def string_opening() -> tuple[int, int] | None:
        hash_count = 0
        while index + hash_count < len(source) and source[index + hash_count] == "#":
            hash_count += 1
        quote_index = index + hash_count
        if quote_index < len(source) and source[quote_index] == '"':
            return (hash_count, quote_index)
        return None

    def advance_ignored() -> None:
        if source[index] == "\n":
            _newline(tokens, line, column)
        advance()

    def skip_block_comment() -> None:
        depth = 1
        advance(2)
        while index < len(source) and depth:
            if source.startswith("/*", index):
                depth += 1
                advance(2)
            elif source.startswith("*/", index):
                depth -= 1
                advance(2)
            else:
                advance_ignored()

    def skip_interpolation() -> None:
        depth = 1
        while index < len(source) and depth:
            if source.startswith("//", index):
                while index < len(source) and source[index] != "\n":
                    advance()
                continue
            if source.startswith("/*", index):
                skip_block_comment()
                continue
            if opening := string_opening():
                skip_string_literal(*opening)
                continue
            if source[index] == "(":
                depth += 1
                advance()
                continue
            if source[index] == ")":
                depth -= 1
                advance()
                continue
            advance_ignored()

    def skip_string_literal(hash_count: int, quote_index: int) -> None:
        opening_length = hash_count + (3 if source.startswith('"""', quote_index) else 1)
        closing_quote = '"""' if opening_length - hash_count == 3 else '"'
        closing = closing_quote + ("#" * hash_count)
        interpolation_opening = "\\" + ("#" * hash_count) + "("
        advance(opening_length)
        while index < len(source):
            if source.startswith(closing, index):
                advance(len(closing))
                return
            if source.startswith(interpolation_opening, index):
                advance(len(interpolation_opening))
                skip_interpolation()
                continue
            if hash_count == 0 and source[index] == "\\":
                advance()
                if index < len(source):
                    advance_ignored()
                continue
            advance_ignored()

    while index < len(source):
        character = source[index]
        if character == "\n":
            _newline(tokens, line, column)
            advance()
            continue
        if character.isspace():
            advance()
            continue
        if source.startswith("//", index):
            while index < len(source) and source[index] != "\n":
                advance()
            continue
        if source.startswith("/*", index):
            skip_block_comment()
            continue

        if opening := string_opening():
            skip_string_literal(*opening)
            continue

        token_line = line
        token_column = column
        if character == "`":
            advance()
            start = index
            while index < len(source) and source[index] not in {"`", "\n"}:
                advance()
            value = source[start:index]
            if index < len(source) and source[index] == "`":
                advance()
            tokens.append(Token(value, token_line, token_column, "escaped_identifier"))
            continue
        if character == "_" or character.isalpha():
            start = index
            while index < len(source) and (source[index] == "_" or source[index].isalnum()):
                advance()
            value = source[start:index]
            kind = "keyword" if value in KEYWORDS else "identifier"
            tokens.append(Token(value, token_line, token_column, kind))
            continue
        if source.startswith("->", index):
            tokens.append(Token("->", token_line, token_column))
            advance(2)
            continue
        tokens.append(Token(character, token_line, token_column))
        advance()

    return tokens


def _significant(tokens: list[Token], start: int, step: int = 1) -> int | None:
    index = start
    while 0 <= index < len(tokens):
        if tokens[index].kind != "newline":
            return index
        index += step
    return None


def _has_attribute(
    tokens: list[Token], declaration_start: int, attribute: str
) -> bool:
    index = declaration_start - 1
    while index >= 0:
        token = tokens[index]
        if token.value in {"{", "}", ";"}:
            return False
        if token.kind == "keyword" and token.value in STATEMENT_STARTERS | CALLABLE_DECLARATIONS:
            return False
        if token.value == attribute:
            at_index = _significant(tokens, index - 1, step=-1)
            if at_index is not None and tokens[at_index].value == "@":
                return True
        index -= 1
    return False


def _scope_for_open_brace(tokens: list[Token], brace_index: int) -> Scope:
    start = brace_index - 1
    while start >= 0 and tokens[start].value not in {"{", "}", ";"}:
        start -= 1
    header = [token for token in tokens[start + 1 : brace_index] if token.kind != "newline"]
    candidate: tuple[int, str] | None = None
    for index, token in enumerate(header):
        if token.kind == "keyword" and token.value in TYPE_DECLARATIONS | CALLABLE_DECLARATIONS:
            candidate = (index, token.value)
    if candidate is None:
        return Scope("block", "")

    index, kind = candidate
    if kind in {"init", "deinit", "subscript"}:
        return Scope("callable", kind)
    name_index = index + 1
    while name_index < len(header) and header[name_index].kind not in IDENTIFIER_KINDS:
        name_index += 1
    if name_index == len(header):
        return Scope("block", "")
    name = header[name_index].value
    return Scope("callable" if kind == "func" else "type", name)


def _declaration_context(scopes: list[Scope]) -> str:
    type_names = [scope.name for scope in scopes if scope.kind == "type"]
    for scope in reversed(scopes):
        if scope.kind == "callable":
            owner = ".".join([*type_names, scope.name])
            return f"local:{owner}"
    if type_names:
        return f"member:{'.'.join(type_names)}"
    return "global"


def _declaration_end(tokens: list[Token], start: int) -> int:
    paren_depth = 0
    bracket_depth = 0
    angle_depth = 0
    saw_annotation_or_initializer = False
    is_type_annotation = False
    previous_value = ""
    previous_was_newline = False
    index = start
    while index < len(tokens):
        token = tokens[index]
        value = token.value
        if token.kind == "newline":
            next_index = _significant(tokens, index + 1)
            next_value = tokens[next_index].value if next_index is not None else ""
            needs_continuation = (
                paren_depth > 0
                or bracket_depth > 0
                or angle_depth > 0
                or previous_value in {":", "=", ",", ".", "->", "&", "(", "[", "<"}
                or next_value in {"=", ".", "?", "!", "&"}
            )
            if saw_annotation_or_initializer and not needs_continuation:
                return index
            if not saw_annotation_or_initializer:
                return index
            previous_was_newline = True
            index += 1
            continue
        if (
            previous_was_newline
            and token.kind == "keyword"
            and value in STATEMENT_STARTERS
            and paren_depth == bracket_depth == 0
        ):
            return index
        if value == ";" and paren_depth == bracket_depth == angle_depth == 0:
            return index
        if value == "{" and paren_depth == bracket_depth == angle_depth == 0:
            return index
        if value == "}" and paren_depth == bracket_depth == 0:
            return index
        if value == ":" and paren_depth == bracket_depth == angle_depth == 0:
            saw_annotation_or_initializer = True
            is_type_annotation = True
        elif value == "=" and paren_depth == bracket_depth == angle_depth == 0:
            saw_annotation_or_initializer = True
            is_type_annotation = False
        if value == "(":
            paren_depth += 1
        elif value == ")":
            paren_depth = max(0, paren_depth - 1)
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif value == "<" and is_type_annotation:
            angle_depth += 1
        elif value == ">" and angle_depth:
            angle_depth -= 1
        previous_value = value
        previous_was_newline = False
        index += 1
    return index


def _annotated_type_text(
    declaration_tokens: list[Token],
    audited_type: str,
) -> str | None:
    values = [token.value for token in declaration_tokens if token.kind != "newline"]
    if audited_type not in values:
        return None
    paren_depth = 0
    bracket_depth = 0
    angle_depth = 0
    annotation_colon: int | None = None
    equals: int | None = None
    for index, value in enumerate(values):
        if value == ":" and paren_depth == bracket_depth == angle_depth == 0:
            annotation_colon = index
            continue
        if value == "=" and paren_depth == bracket_depth == angle_depth == 0:
            equals = index
            break
        if value == "(":
            paren_depth += 1
        elif value == ")":
            paren_depth = max(0, paren_depth - 1)
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif value == "<":
            angle_depth += 1
        elif value == ">" and angle_depth:
            angle_depth -= 1

    if annotation_colon is not None:
        end = equals if equals is not None else len(values)
        annotation = values[annotation_colon + 1 : end]
        if audited_type in annotation:
            return "".join(annotation)
    return None


def _is_direct_collection_initializer(
    initializer: list[str],
    audited_type: str,
) -> bool:
    if initializer[0] == "[":
        return audited_type in initializer
    if len(initializer) < 4 or initializer[0] not in {"Array", "Dictionary"}:
        return False
    if initializer[1] != "<":
        return False

    angle_depth = 0
    generic_end: int | None = None
    for index, value in enumerate(initializer[1:], start=1):
        if value == "<":
            angle_depth += 1
        elif value == ">":
            angle_depth -= 1
            if angle_depth == 0:
                generic_end = index
                break
    if generic_end is None or generic_end + 1 >= len(initializer):
        return False
    return (
        initializer[generic_end + 1] == "("
        and audited_type in initializer[2:generic_end]
    )


def _dispatch_type_text(declaration_tokens: list[Token]) -> str | None:
    values = [token.value for token in declaration_tokens if token.kind != "newline"]
    if "DispatchWorkItem" not in values:
        return None
    if annotated_type := _annotated_type_text(declaration_tokens, "DispatchWorkItem"):
        return annotated_type

    paren_depth = 0
    bracket_depth = 0
    angle_depth = 0
    equals: int | None = None
    for index, value in enumerate(values):
        if value == "=" and paren_depth == bracket_depth == angle_depth == 0:
            equals = index
            break
        if value == "(":
            paren_depth += 1
        elif value == ")":
            paren_depth = max(0, paren_depth - 1)
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif value == "<":
            angle_depth += 1
        elif value == ">" and angle_depth:
            angle_depth -= 1

    if equals is None:
        return None
    initializer = values[equals + 1 :]
    if not initializer:
        return None
    if initializer[0] == "DispatchWorkItem":
        return "<inferred:DispatchWorkItem>"
    if _is_direct_collection_initializer(initializer, "DispatchWorkItem"):
        return "<inferred:[DispatchWorkItem]>"
    return None


def _swiftui_state_handle_type_text(
    declaration_tokens: list[Token],
) -> str | None:
    for audited_type in SWIFTUI_STATE_AUDITED_HANDLE_TYPES:
        if type_text := _annotated_type_text(declaration_tokens, audited_type):
            return type_text

    values = [token.value for token in declaration_tokens if token.kind != "newline"]
    paren_depth = 0
    bracket_depth = 0
    angle_depth = 0
    equals: int | None = None
    for index, value in enumerate(values):
        if value == "=" and paren_depth == bracket_depth == angle_depth == 0:
            equals = index
            break
        if value == "(":
            paren_depth += 1
        elif value == ")":
            paren_depth = max(0, paren_depth - 1)
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif value == "<":
            angle_depth += 1
        elif value == ">" and angle_depth:
            angle_depth -= 1

    if equals is None:
        return None
    initializer = values[equals + 1 :]
    if not initializer:
        return None
    if initializer[0] == "Task":
        return "<inferred:Task>"
    if _is_direct_collection_initializer(initializer, "Task"):
        return "<inferred:[Task]>"
    if initializer[:3] == ["DispatchSource", ".", "makeTimerSource"]:
        return "<inferred:DispatchSourceTimer>"
    if _is_direct_collection_initializer(initializer, "DispatchSourceTimer"):
        return "<inferred:[DispatchSourceTimer]>"
    if initializer[:3] == ["Timer", ".", "scheduledTimer"]:
        return "<inferred:Timer>"
    if _is_direct_collection_initializer(initializer, "Timer"):
        return "<inferred:[Timer]>"
    return None


def _is_computed_property(
    tokens: list[Token],
    declaration_start: int,
    declaration_end: int,
    scopes: list[Scope],
) -> bool:
    if _declaration_context(scopes).startswith("local:"):
        return False
    if declaration_end >= len(tokens) or tokens[declaration_end].value != "{":
        return False

    paren_depth = 0
    bracket_depth = 0
    angle_depth = 0
    for token in tokens[declaration_start:declaration_end]:
        value = token.value
        if value == "=" and paren_depth == bracket_depth == angle_depth == 0:
            return False
        if value == "(":
            paren_depth += 1
        elif value == ")":
            paren_depth = max(0, paren_depth - 1)
        elif value == "[":
            bracket_depth += 1
        elif value == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif value == "<":
            angle_depth += 1
        elif value == ">" and angle_depth:
            angle_depth -= 1

    accessor_index = _significant(tokens, declaration_end + 1)
    if accessor_index is None:
        return True
    return tokens[accessor_index].value not in {"didSet", "willSet"}


def compare_allowances(
    found: list[Declaration],
    allowances: tuple[Allowance, ...] = ALLOWANCES,
) -> tuple[
    collections.Counter[tuple[str, str, str, str]],
    collections.Counter[tuple[str, str, str, str]],
]:
    actual = collections.Counter(item.key for item in found)
    allowed = collections.Counter(
        (item.path, item.name, item.type_text, item.context)
        for item in allowances
        for _ in range(item.count)
    )
    return (actual - allowed, allowed - actual)


def scan_declarations(source: str, path: str) -> list[Declaration]:
    tokens = tokenize_swift(source)
    scopes: list[Scope] = []
    declarations: list[Declaration] = []
    for index, token in enumerate(tokens):
        if token.value == "{":
            scopes.append(_scope_for_open_brace(tokens, index))
            continue
        if token.value == "}":
            if scopes:
                scopes.pop()
            continue
        if token.kind != "keyword" or token.value != "var":
            continue

        name_index = _significant(tokens, index + 1)
        if name_index is None or tokens[name_index].kind not in IDENTIFIER_KINDS:
            continue
        end = _declaration_end(tokens, name_index + 1)
        if _is_computed_property(tokens, index, end, scopes):
            continue
        declaration_tokens = tokens[index:end]
        context = _declaration_context(scopes)
        type_text = _dispatch_type_text(declaration_tokens)
        if (
            type_text is None
            and path.startswith(MACOS_SWIFTUI_SOURCE_PREFIXES)
            and context.startswith("member:")
            and _has_attribute(tokens, index, "State")
        ):
            type_text = _swiftui_state_handle_type_text(declaration_tokens)
        if type_text is None:
            continue
        declarations.append(
            Declaration(
                path=path,
                name=tokens[name_index].value,
                type_text=type_text,
                context=context,
                line=token.line,
            )
        )
    return declarations


def declarations() -> list[Declaration]:
    if not BONSPLIT_SOURCES_ROOT.is_dir():
        raise RequiredSourceRootMissingError(
            f"required audited source root is missing: {BONSPLIT_SOURCES_ROOT}"
        )

    found: list[Declaration] = []
    # CI initializes Bonsplit before this audit so a parent-repository change
    # cannot silently reintroduce the SwiftUI State ownership pattern that
    # produced the recursive release chain.
    source_roots = [SOURCES_ROOT, CLI_ROOT, IOS_ROOT, BONSPLIT_SOURCES_ROOT]
    source_roots.extend(sorted(PACKAGES_ROOT.glob("*/*/Sources")))
    paths = {
        path
        for source_root in source_roots
        for path in source_root.rglob("*.swift")
    }
    for path in sorted(paths):
        relative = path.relative_to(REPO_ROOT).as_posix()
        found.extend(scan_declarations(path.read_text(encoding="utf-8"), relative))
    return found


def main() -> int:
    try:
        found = declarations()
    except RequiredSourceRootMissingError as error:
        print(f"lint-stored-dispatch-work-items: {error}", file=sys.stderr)
        return 1
    unexpected, stale = compare_allowances(found)
    if not unexpected and not stale:
        print(
            "lint-stored-dispatch-work-items: ok "
            f"({len(found)} audited deferred-action declarations)"
        )
        return 0

    print(
        "Stored DispatchWorkItem declarations and closure-bearing handles in macOS SwiftUI "
        "State can rebuild recursive release chains. Use a scheduler that cannot retain "
        "prior queued work, or prove that replacement drops the predecessor before capturing "
        "owner state.",
        file=sys.stderr,
    )
    lines_by_key: dict[tuple[str, str, str, str], list[int]] = collections.defaultdict(list)
    for item in found:
        lines_by_key[item.key].append(item.line)
    for key, count in sorted(unexpected.items()):
        path, name, type_text, context = key
        lines = ",".join(str(line) for line in lines_by_key[key])
        print(
            f"unexpected: {path}:{lines}: {name}: {type_text} "
            f"({context}, count={count})",
            file=sys.stderr,
        )
    for (path, name, type_text, context), count in sorted(stale.items()):
        print(
            f"stale allowance: {path}: {name}: {type_text} "
            f"({context}, count={count})",
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
