#!/usr/bin/env python3
"""Deterministically synchronize direct cmuxTests Swift files into project.pbxproj."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


ID_PATTERN = r"[A-Za-z0-9]+"
DIRECT_SOURCE_TREE = "<group>"
TARGET_NAME = "cmuxTests"
PROJECT_RELATIVE_PATH = Path("cmux.xcodeproj/project.pbxproj")
TESTS_RELATIVE_PATH = Path("cmuxTests")


class WiringError(RuntimeError):
    pass


@dataclass(frozen=True)
class FileReference:
    identifier: str
    comment: str
    path: str | None
    source_tree: str | None

    @property
    def is_direct_swift(self) -> bool:
        return (
            self.path is not None
            and self.path.endswith(".swift")
            and "/" not in self.path
            and self.source_tree == DIRECT_SOURCE_TREE
        )


@dataclass(frozen=True)
class BuildFile:
    identifier: str
    comment: str
    file_ref: str


@dataclass(frozen=True)
class ObjectBlock:
    identifier: str
    comment: str
    text: str


@dataclass(frozen=True)
class SyncResult:
    text: str
    actions: tuple[str, ...]


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        body = value[1:-1]
        return re.sub(r"\\(.)", r"\1", body)
    return value


def _quote_openstep(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _section(text: str, name: str) -> str:
    begin = f"/* Begin {name} section */"
    end = f"/* End {name} section */"
    start = text.find(begin)
    if start < 0:
        raise WiringError(f"project is missing {begin}")
    finish = text.find(end, start)
    if finish < 0:
        raise WiringError(f"project is missing {end}")
    finish += len(end)
    return text[start:finish]


def _replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise WiringError(f"expected exactly one {label}, found {count}")
    return text.replace(old, new, 1)


def _object_blocks(section_text: str, isa: str) -> list[ObjectBlock]:
    lines = section_text.splitlines(keepends=True)
    blocks: list[ObjectBlock] = []
    header_re = re.compile(
        rf"^\s*(?P<id>{ID_PATTERN}) /\* (?P<comment>.*?) \*/ = \{{\s*$"
    )
    for index, line in enumerate(lines):
        match = header_re.match(line.rstrip("\n"))
        if match is None:
            continue
        collected = [line]
        for end_index in range(index + 1, len(lines)):
            collected.append(lines[end_index])
            if re.match(r"^\s*\};\s*$", lines[end_index].rstrip("\n")):
                break
        block_text = "".join(collected)
        if f"isa = {isa};" in block_text:
            blocks.append(
                ObjectBlock(
                    identifier=match.group("id"),
                    comment=match.group("comment"),
                    text=block_text,
                )
            )
    return blocks


def _parse_file_references(text: str) -> dict[str, FileReference]:
    section_text = _section(text, "PBXFileReference")
    # Match object substrings instead of whole physical lines. Some historical
    # hand edits placed two pbxproj objects on one line; treating a line as one
    # object would hide the first entry and can make a repair destructive.
    object_re = re.compile(
        rf"(?P<id>{ID_PATTERN}) /\* (?P<comment>.*?) \*/ = "
        r"\{\s*isa = PBXFileReference;\s*(?P<body>.*?)\};",
        re.DOTALL,
    )
    result: dict[str, FileReference] = {}
    for match in object_re.finditer(section_text):
        body = match.group("body")
        quoted = r'"(?:\\.|[^"\\])*"'
        path_match = re.search(rf"path = (?P<value>{quoted}|[^;]+);", body)
        source_match = re.search(rf"sourceTree = (?P<value>{quoted}|[^;]+);", body)
        result[match.group("id")] = FileReference(
            identifier=match.group("id"),
            comment=match.group("comment"),
            path=_unquote(path_match.group("value")) if path_match else None,
            source_tree=_unquote(source_match.group("value")) if source_match else None,
        )
    return result


def _parse_build_files(text: str) -> dict[str, BuildFile]:
    section_text = _section(text, "PBXBuildFile")
    object_re = re.compile(
        rf"(?P<id>{ID_PATTERN}) /\* (?P<comment>.*?) \*/ = "
        r"\{isa = PBXBuildFile; (?P<body>[^\n]*?)\};"
    )
    result: dict[str, BuildFile] = {}
    for match in object_re.finditer(section_text):
        file_ref_match = re.search(rf"fileRef = (?P<id>{ID_PATTERN}) /\*", match.group("body"))
        if file_ref_match is None:
            continue
        result[match.group("id")] = BuildFile(
            identifier=match.group("id"),
            comment=match.group("comment"),
            file_ref=file_ref_match.group("id"),
        )
    return result


def _list_entries(block_text: str, key: str) -> list[tuple[str, str]]:
    key_match = re.search(rf"(?m)^[ \t]*{re.escape(key)} = \([ \t]*$", block_text)
    if key_match is None:
        raise WiringError(f"object block is missing {key} list")
    close_match = re.search(r"(?m)^[ \t]*\);[ \t]*$", block_text[key_match.end() :])
    if close_match is None:
        raise WiringError(f"object block has unterminated {key} list")
    body_start = key_match.end()
    body_end = body_start + close_match.start()
    body = block_text[body_start:body_end]
    entry_re = re.compile(rf"(?P<id>{ID_PATTERN}) /\* (?P<comment>[^*]+?) \*/,")
    return [(match.group("id"), match.group("comment")) for match in entry_re.finditer(body)]


def _find_cmux_tests_group(text: str) -> ObjectBlock:
    groups = [
        block
        for block in _object_blocks(_section(text, "PBXGroup"), "PBXGroup")
        if block.comment == TARGET_NAME and re.search(r"(?m)^\s*path = cmuxTests;\s*$", block.text)
    ]
    if len(groups) != 1:
        raise WiringError(f"expected one cmuxTests PBXGroup, found {len(groups)}")
    return groups[0]


def _find_cmux_tests_target(text: str) -> ObjectBlock:
    targets = [
        block
        for block in _object_blocks(_section(text, "PBXNativeTarget"), "PBXNativeTarget")
        if block.comment == TARGET_NAME
        and re.search(r'(?m)^\s*name = "?cmuxTests"?;\s*$', block.text)
    ]
    if len(targets) != 1:
        raise WiringError(f"expected one cmuxTests PBXNativeTarget, found {len(targets)}")
    return targets[0]


def _sources_blocks(text: str) -> dict[str, ObjectBlock]:
    return {
        block.identifier: block
        for block in _object_blocks(_section(text, "PBXSourcesBuildPhase"), "PBXSourcesBuildPhase")
    }


def _target_sources(text: str, source_blocks: dict[str, ObjectBlock]) -> dict[str, str]:
    result: dict[str, str] = {}
    for block in _object_blocks(_section(text, "PBXNativeTarget"), "PBXNativeTarget"):
        name_match = re.search(r'(?m)^\s*name = (?P<name>"[^"]+"|[^;]+);\s*$', block.text)
        target_name = _unquote(name_match.group("name")) if name_match else block.comment
        for source_id in source_blocks:
            if re.search(rf"\b{re.escape(source_id)} /\* Sources \*/", block.text):
                result[source_id] = target_name
    return result


def _cmux_tests_sources_id(target: ObjectBlock, source_blocks: dict[str, ObjectBlock]) -> str:
    candidates = [
        source_id
        for source_id in source_blocks
        if re.search(rf"\b{re.escape(source_id)} /\* Sources \*/", target.text)
    ]
    if len(candidates) != 1:
        raise WiringError(
            f"expected one Sources build phase for cmuxTests, found {len(candidates)}"
        )
    return candidates[0]


def _stable_id(kind: str, filename: str) -> str:
    payload = f"cmux-test-wiring-v1\0{kind}\0{filename}".encode("utf-8")
    return hashlib.sha256(payload).hexdigest().upper()[:24]


def _all_object_ids(text: str) -> set[str]:
    return set(
        re.findall(
            rf"({ID_PATTERN}) /\* .*? \*/ = \{{",
            text,
        )
    )


def _ensure_fresh_generated_id(text: str, identifier: str, filename: str, kind: str) -> None:
    if identifier in _all_object_ids(text):
        raise WiringError(
            f"deterministic {kind} identifier {identifier} for {filename} is already used by another object"
        )


def _entry_sort_key(line: str) -> tuple[str, str]:
    comment = re.search(r"/\*\s*(?P<label>.+?)\s*\*/", line)
    label = comment.group("label").lower() if comment else line.strip().lower()
    identifier = line.lstrip().split(" ", 1)[0]
    return (label, identifier)


def _flat_section_is_line_oriented(section_text: str) -> bool:
    lines = section_text.splitlines()
    if len(lines) < 2:
        return True
    entry_re = re.compile(
        rf"^\s*{ID_PATTERN} /\* .*? \*/ = \{{.*\}};\s*$"
    )
    return all(not line.strip() or entry_re.match(line) is not None for line in lines[1:-1])


def _append_section_lines(text: str, section_name: str, lines: Iterable[str]) -> str:
    additions = list(lines)
    if not additions:
        return text
    section_text = _section(text, section_name)
    section_lines = section_text.splitlines(keepends=True)
    body = section_lines[1:-1]

    if not _flat_section_is_line_oriented(section_text):
        # Preserve legacy/multiline OpenStep objects verbatim. Sorting their
        # physical lines would split one logical object into unrelated pieces.
        insert_at = len(body)
        while insert_at > 0 and not body[insert_at - 1].strip():
            insert_at -= 1
        body[insert_at:insert_at] = additions
    else:
        for addition in additions:
            addition_key = _entry_sort_key(addition)
            index = next(
                (
                    i
                    for i, existing in enumerate(body)
                    if existing.strip() and _entry_sort_key(existing) > addition_key
                ),
                next(
                    (i for i, existing in enumerate(body) if not existing.strip()),
                    len(body),
                ),
            )
            body.insert(index, addition)

    new_section = section_lines[0] + "".join(body) + section_lines[-1]
    return _replace_once(text, section_text, new_section, section_name)


def _remove_object_line(text: str, section_name: str, identifier: str) -> str:
    section_text = _section(text, section_name)
    pattern = re.compile(
        rf"{re.escape(identifier)} /\* .*? \*/ = \{{isa = [^;\n]+;[^\n]*?\}};"
    )
    match = pattern.search(section_text)
    if match is None:
        raise WiringError(f"could not remove {identifier} from {section_name}")

    line_start = section_text.rfind("\n", 0, match.start()) + 1
    line_end = section_text.find("\n", match.end())
    if line_end < 0:
        line_end = len(section_text)
    prefix = section_text[line_start:match.start()]
    suffix = section_text[match.end():line_end]
    if not prefix.strip() and not suffix.strip():
        remove_end = line_end + (1 if line_end < len(section_text) else 0)
        new_section = section_text[:line_start] + section_text[remove_end:]
    else:
        new_section = section_text[:match.start()] + section_text[match.end():]
    return _replace_once(text, section_text, new_section, section_name)


def _append_list_entry(block_text: str, key: str, identifier: str, comment: str) -> str:
    entries = _list_entries(block_text, key)
    if any(entry_id == identifier for entry_id, _ in entries):
        return block_text
    key_match = re.search(rf"(?m)^[ \t]*{re.escape(key)} = \([ \t]*$", block_text)
    assert key_match is not None
    close_match = re.search(r"(?m)^(?P<indent>[ \t]*)\);[ \t]*$", block_text[key_match.end() :])
    assert close_match is not None
    body_start = key_match.end()
    body_end = body_start + close_match.start()
    close_indent = close_match.group("indent")
    item_indent = close_indent + "\t"
    entry = f"{item_indent}{identifier} /* {comment} */,\n"

    body = block_text[body_start:body_end]
    if key == "files":
        lines = body.splitlines(keepends=True)
        entry_key = _entry_sort_key(entry)
        index = next(
            (
                i
                for i, existing in enumerate(lines)
                if existing.strip() and _entry_sort_key(existing) > entry_key
            ),
            len(lines),
        )
        lines.insert(index, entry)
        new_body = "".join(lines)
    else:
        new_body = body + entry
    return block_text[:body_start] + new_body + block_text[body_end:]


def _remove_list_entry(block_text: str, key: str, identifier: str, comment: str) -> str:
    token = f"{identifier} /* {comment} */,"
    key_match = re.search(rf"(?m)^[ \t]*{re.escape(key)} = \([ \t]*$", block_text)
    if key_match is None:
        raise WiringError(f"object block is missing {key} list")
    close_match = re.search(r"(?m)^[ \t]*\);[ \t]*$", block_text[key_match.end() :])
    if close_match is None:
        raise WiringError(f"object block has unterminated {key} list")
    body_start = key_match.end()
    body_end = body_start + close_match.start()
    body = block_text[body_start:body_end]
    if token not in body:
        raise WiringError(f"could not remove {comment} ({identifier}) from {key}")

    # Prefer removing a whole line. Fall back to removing only the token so
    # hand-edited pbxproj lines that contain multiple entries stay intact.
    full_line = re.compile(
        rf"(?m)^[ \t]*{re.escape(token)}[ \t]*\n?"
    )
    new_body, count = full_line.subn("", body, count=1)
    if count == 0:
        new_body = body.replace(token, "", 1)
    return block_text[:body_start] + new_body + block_text[body_end:]


def _replace_block(text: str, old: ObjectBlock, new_text: str, label: str) -> str:
    return _replace_once(text, old.text, new_text, label)


def _group_memberships(text: str) -> dict[str, set[str]]:
    memberships: dict[str, set[str]] = {}
    for group in _object_blocks(_section(text, "PBXGroup"), "PBXGroup"):
        try:
            entries = _list_entries(group.text, "children")
        except WiringError:
            continue
        for identifier, _ in entries:
            memberships.setdefault(identifier, set()).add(group.comment)
    return memberships


def _source_memberships(
    source_blocks: dict[str, ObjectBlock], target_sources: dict[str, str]
) -> dict[str, list[tuple[str, str]]]:
    memberships: dict[str, list[tuple[str, str]]] = {}
    for phase_id, block in source_blocks.items():
        for identifier, _ in _list_entries(block.text, "files"):
            memberships.setdefault(identifier, []).append(
                (phase_id, target_sources.get(phase_id, f"Sources phase {phase_id}"))
            )
    return memberships


def _direct_group_refs(
    group: ObjectBlock, file_refs: dict[str, FileReference]
) -> dict[str, list[FileReference]]:
    result: dict[str, list[FileReference]] = {}
    for identifier, comment in _list_entries(group.text, "children"):
        ref = file_refs.get(identifier)
        if ref is None or not ref.is_direct_swift or ref.path is None:
            continue
        result.setdefault(ref.path, []).append(ref)
    return result


def _direct_refs_by_name(
    file_refs: dict[str, FileReference],
) -> dict[str, list[FileReference]]:
    result: dict[str, list[FileReference]] = {}
    for ref in file_refs.values():
        if ref.is_direct_swift and ref.path is not None:
            result.setdefault(ref.path, []).append(ref)
    return result


def _rewrite_flat_object_comment(
    text: str,
    section_name: str,
    identifier: str,
    isa: str,
    comment: str,
    *,
    file_ref_id: str | None = None,
    file_ref_comment: str | None = None,
) -> str:
    section_text = _section(text, section_name)
    pattern = re.compile(
        rf"{re.escape(identifier)} /\* .*? \*/ = \{{isa = {re.escape(isa)};(?P<body>[^\n]*?)\}};"
    )
    matches = list(pattern.finditer(section_text))
    if len(matches) != 1:
        raise WiringError(
            f"expected one {isa} object {identifier}, found {len(matches)}"
        )
    match = matches[0]
    body = match.group("body")
    if file_ref_id is not None:
        if file_ref_comment is None:
            raise WiringError("file_ref_comment is required with file_ref_id")
        file_ref_pattern = re.compile(
            rf"(fileRef = {re.escape(file_ref_id)}) /\* .*? \*/"
        )
        body, count = file_ref_pattern.subn(
            rf"\1 /* {file_ref_comment} */", body, count=1
        )
        if count != 1:
            raise WiringError(
                f"PBXBuildFile {identifier} is missing fileRef {file_ref_id}"
            )
    replacement = f"{identifier} /* {comment} */ = {{isa = {isa};{body}}};"
    new_section = section_text[: match.start()] + replacement + section_text[match.end() :]
    return _replace_once(text, section_text, new_section, section_name)


def _rewrite_list_entry_comment(
    block_text: str, key: str, identifier: str, comment: str
) -> str:
    key_match = re.search(rf"(?m)^[ \t]*{re.escape(key)} = \([ \t]*$", block_text)
    if key_match is None:
        raise WiringError(f"object block is missing {key} list")
    close_match = re.search(r"(?m)^[ \t]*\);[ \t]*$", block_text[key_match.end() :])
    if close_match is None:
        raise WiringError(f"object block has unterminated {key} list")
    body_start = key_match.end()
    body_end = body_start + close_match.start()
    body = block_text[body_start:body_end]
    pattern = re.compile(
        rf"{re.escape(identifier)} /\* [^*]+? \*/,"
    )
    body, count = pattern.subn(f"{identifier} /* {comment} */,", body)
    if count != 1:
        raise WiringError(
            f"expected one {identifier} entry in {key}, found {count}"
        )
    return block_text[:body_start] + body + block_text[body_end:]


def _sort_flat_section(text: str, section_name: str) -> str:
    section_text = _section(text, section_name)
    if not _flat_section_is_line_oriented(section_text):
        return text

    lines = section_text.splitlines(keepends=True)
    if len(lines) < 2:
        return text
    body = lines[1:-1]
    entries = [line for line in body if line.strip()]
    blanks = [line for line in body if not line.strip()]
    entries.sort(key=_entry_sort_key)
    new_section = lines[0] + "".join(entries + blanks) + lines[-1]
    return _replace_once(text, section_text, new_section, section_name)


def _sort_list_entries(block_text: str, key: str) -> str:
    key_match = re.search(rf"(?m)^[ \t]*{re.escape(key)} = \([ \t]*$", block_text)
    if key_match is None:
        raise WiringError(f"object block is missing {key} list")
    close_match = re.search(r"(?m)^[ \t]*\);[ \t]*$", block_text[key_match.end() :])
    if close_match is None:
        raise WiringError(f"object block has unterminated {key} list")
    body_start = key_match.end()
    body_end = body_start + close_match.start()
    body = block_text[body_start:body_end]
    leading_newline = "\n" if body.startswith("\n") else ""
    if leading_newline:
        body = body[1:]
    lines = body.splitlines(keepends=True)
    entries = [line for line in lines if line.strip()]
    blanks = [line for line in lines if not line.strip()]
    entries.sort(key=_entry_sort_key)
    # normalize-pbxproj.py sorts every line of a build phase `files` list,
    # blank ones included, and a blank line sorts first. Flat sections are the
    # other way round (see _sort_flat_section), matching sort_flat_section
    # there. Emit the same order or the result fails check-pbxproj.sh.
    return (
        block_text[:body_start]
        + leading_newline
        + "".join(blanks + entries)
        + block_text[body_end:]
    )


def _dirty_disk_filenames(text: str, filenames: list[str]) -> list[str]:
    """Return disk files whose direct cmuxTests wiring needs inspection."""
    file_refs = _parse_file_references(text)
    build_files = _parse_build_files(text)
    group = _find_cmux_tests_group(text)
    target = _find_cmux_tests_target(text)
    source_blocks = _sources_blocks(text)
    target_sources = _target_sources(text, source_blocks)
    tests_sources_id = _cmux_tests_sources_id(target, source_blocks)
    group_memberships = _group_memberships(text)
    source_memberships = _source_memberships(source_blocks, target_sources)
    direct_refs_by_name = _direct_group_refs(group, file_refs)
    all_direct_refs_by_name = _direct_refs_by_name(file_refs)
    tests_source_entries = _list_entries(source_blocks[tests_sources_id].text, "files")
    builds_by_ref: dict[str, list[BuildFile]] = {}
    for build in build_files.values():
        builds_by_ref.setdefault(build.file_ref, []).append(build)
    source_ids_by_comment: dict[str, list[str]] = {}
    for entry_id, comment in tests_source_entries:
        source_ids_by_comment.setdefault(comment, []).append(entry_id)
    group_child_comments: dict[str, list[str]] | None = None

    dirty: list[str] = []
    for filename in filenames:
        refs = direct_refs_by_name.get(filename, [])
        all_refs = all_direct_refs_by_name.get(filename, [])
        if (
            len(refs) != 1
            or len(all_refs) != 1
            or refs[0].identifier != all_refs[0].identifier
        ):
            dirty.append(filename)
            continue
        ref = refs[0]
        if group_child_comments is None:
            group_child_comments = {}
            for entry_id, comment in _list_entries(group.text, "children"):
                group_child_comments.setdefault(entry_id, []).append(comment)
        group_comments = group_child_comments.get(ref.identifier, [])
        if (
            ref.comment != filename
            or group_comments != [filename]
            or group_memberships.get(ref.identifier, set()) != {TARGET_NAME}
        ):
            dirty.append(filename)
            continue

        linked = builds_by_ref.get(ref.identifier, [])
        expected_comment = f"{filename} in Sources"
        if len(linked) != 1 or linked[0].comment != expected_comment:
            dirty.append(filename)
            continue
        build = linked[0]
        memberships = source_memberships.get(build.identifier, [])
        if memberships != [(tests_sources_id, TARGET_NAME)]:
            dirty.append(filename)
            continue

        named_source_entries = [
            entry_id
            for entry_id in source_ids_by_comment.get(expected_comment, [])
            if entry_id not in build_files or build_files[entry_id].file_ref == ref.identifier
        ]
        if named_source_entries != [build.identifier]:
            dirty.append(filename)
            continue

    return dirty


def _safe_remove_duplicate_ref(
    text: str,
    filename: str,
    ref: FileReference,
    canonical_ref_id: str,
    group: ObjectBlock,
    source_blocks: dict[str, ObjectBlock],
    tests_sources_id: str,
    build_files: dict[str, BuildFile],
    group_memberships: dict[str, set[str]],
    source_memberships: dict[str, list[tuple[str, str]]],
    actions: list[str],
) -> str:
    other_groups = group_memberships.get(ref.identifier, set()) - {TARGET_NAME}
    if other_groups:
        raise WiringError(
            f"{filename} has duplicate file reference {ref.identifier} also used by group(s): "
            + ", ".join(sorted(other_groups))
        )

    linked_builds = [build for build in build_files.values() if build.file_ref == ref.identifier]
    for build in linked_builds:
        foreign = [
            target
            for phase_id, target in source_memberships.get(build.identifier, [])
            if phase_id != tests_sources_id
        ]
        if foreign:
            raise WiringError(
                f"{filename} is a member of unexpected target(s): {', '.join(sorted(set(foreign)))}"
            )

    if TARGET_NAME in group_memberships.get(ref.identifier, set()):
        current_group = _find_cmux_tests_group(text)
        matching_comments = [
            comment
            for entry_id, comment in _list_entries(current_group.text, "children")
            if entry_id == ref.identifier
        ]
        if len(matching_comments) != 1:
            raise WiringError(
                f"expected one cmuxTests group entry for duplicate ref {ref.identifier}"
            )
        current_group_text = _remove_list_entry(
            current_group.text, "children", ref.identifier, matching_comments[0]
        )
        text = _replace_block(
            text, current_group, current_group_text, "cmuxTests PBXGroup"
        )

    for build in linked_builds:
        current_sources = _sources_blocks(text)[tests_sources_id]
        source_entries = _list_entries(current_sources.text, "files")
        matching_source_comments = [
            comment
            for entry_id, comment in source_entries
            if entry_id == build.identifier
        ]
        for source_comment in matching_source_comments:
            current_sources = _sources_blocks(text)[tests_sources_id]
            current_sources_text = _remove_list_entry(
                current_sources.text,
                "files",
                build.identifier,
                source_comment,
            )
            text = _replace_block(
                text, current_sources, current_sources_text, "cmuxTests Sources phase"
            )
        text = _remove_object_line(text, "PBXBuildFile", build.identifier)

    text = _remove_object_line(text, "PBXFileReference", ref.identifier)
    actions.append(
        f"collapsed duplicate {filename} file reference {ref.identifier} into {canonical_ref_id}"
    )
    return text


def synchronize(project_text: str, test_filenames: Iterable[str]) -> SyncResult:
    filenames = sorted(set(test_filenames))
    for filename in filenames:
        if Path(filename).name != filename or not filename.endswith(".swift"):
            raise WiringError(f"unsupported test filename: {filename}")

    text = project_text
    actions: list[str] = []

    # Most runs are already clean. Parse once to identify only files whose wiring
    # needs work, then reparse after each mutation candidate. This keeps the
    # mutation path simple without scanning the full project once per test file.
    dirty_filenames = _dirty_disk_filenames(text, filenames)
    for filename in dirty_filenames:
        file_refs = _parse_file_references(text)
        build_files = _parse_build_files(text)
        group = _find_cmux_tests_group(text)
        target = _find_cmux_tests_target(text)
        source_blocks = _sources_blocks(text)
        target_sources = _target_sources(text, source_blocks)
        tests_sources_id = _cmux_tests_sources_id(target, source_blocks)
        group_memberships = _group_memberships(text)
        source_memberships = _source_memberships(source_blocks, target_sources)
        direct_refs_by_name = _direct_group_refs(group, file_refs)
        all_direct_refs_by_name = _direct_refs_by_name(file_refs)

        refs = direct_refs_by_name.get(filename, [])
        unique_refs = {ref.identifier: ref for ref in refs}
        all_candidates = all_direct_refs_by_name.get(filename, [])
        if unique_refs:
            canonical_ref = min(unique_refs.values(), key=lambda item: item.identifier)
        elif all_candidates:
            canonical_ref = min(all_candidates, key=lambda item: item.identifier)
            other_groups = group_memberships.get(canonical_ref.identifier, set()) - {TARGET_NAME}
            if other_groups:
                raise WiringError(
                    f"{filename} file reference is already used by group(s): "
                    + ", ".join(sorted(other_groups))
                )
        else:
            identifier = _stable_id("file-ref", filename)
            _ensure_fresh_generated_id(text, identifier, filename, "PBXFileReference")
            line = (
                f"\t\t{identifier} /* {filename} */ = "
                f'{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {_quote_openstep(filename)}; sourceTree = "<group>"; }};\n'
            )
            text = _append_section_lines(text, "PBXFileReference", [line])
            canonical_ref = FileReference(
                identifier=identifier,
                comment=filename,
                path=filename,
                source_tree=DIRECT_SOURCE_TREE,
            )
            actions.append(f"added PBXFileReference for {filename}")
            all_candidates = [canonical_ref]

        # Refuse foreign target membership before normalizing duplicates.
        build_files = _parse_build_files(text)
        source_blocks = _sources_blocks(text)
        target_sources = _target_sources(text, source_blocks)
        tests_sources_id = _cmux_tests_sources_id(_find_cmux_tests_target(text), source_blocks)
        source_memberships = _source_memberships(source_blocks, target_sources)
        candidate_ref_ids = {ref.identifier for ref in all_candidates} | {
            canonical_ref.identifier
        }
        for build in build_files.values():
            if build.file_ref not in candidate_ref_ids:
                continue
            foreign_targets = [
                target_name
                for phase_id, target_name in source_memberships.get(build.identifier, [])
                if phase_id != tests_sources_id
            ]
            if foreign_targets:
                raise WiringError(
                    f"{filename} is a member of unexpected target(s): "
                    + ", ".join(sorted(set(foreign_targets)))
                    + "; refusing to change target membership"
                )

        # Collapse duplicate direct file references for the same cmuxTests file.
        for duplicate_ref in sorted(all_candidates, key=lambda item: item.identifier):
            if duplicate_ref.identifier == canonical_ref.identifier:
                continue
            text = _safe_remove_duplicate_ref(
                text,
                filename,
                duplicate_ref,
                canonical_ref.identifier,
                _find_cmux_tests_group(text),
                _sources_blocks(text),
                tests_sources_id,
                _parse_build_files(text),
                _group_memberships(text),
                _source_memberships(_sources_blocks(text), _target_sources(text, _sources_blocks(text))),
                actions,
            )

        # Ensure the canonical file reference appears once in the cmuxTests group.
        group = _find_cmux_tests_group(text)
        group_entries = _list_entries(group.text, "children")
        matching_group_entries = [
            (entry_id, comment)
            for entry_id, comment in group_entries
            if entry_id == canonical_ref.identifier
        ]
        if not matching_group_entries:
            new_group = _append_list_entry(
                group.text, "children", canonical_ref.identifier, filename
            )
            text = _replace_block(text, group, new_group, "cmuxTests PBXGroup")
            actions.append(f"added {filename} to cmuxTests group")
        elif len(matching_group_entries) > 1:
            for _ in range(len(matching_group_entries) - 1):
                current_group = _find_cmux_tests_group(text)
                current_matches = [
                    comment
                    for entry_id, comment in _list_entries(current_group.text, "children")
                    if entry_id == canonical_ref.identifier
                ]
                new_group = _remove_list_entry(
                    current_group.text,
                    "children",
                    canonical_ref.identifier,
                    current_matches[0],
                )
                text = _replace_block(text, current_group, new_group, "cmuxTests PBXGroup")
            actions.append(f"removed duplicate cmuxTests group membership for {filename}")

        before_comments = text
        text = _rewrite_flat_object_comment(
            text,
            "PBXFileReference",
            canonical_ref.identifier,
            "PBXFileReference",
            filename,
        )
        current_group = _find_cmux_tests_group(text)
        canonical_group = _rewrite_list_entry_comment(
            current_group.text, "children", canonical_ref.identifier, filename
        )
        text = _replace_block(
            text, current_group, canonical_group, "cmuxTests PBXGroup"
        )
        if text != before_comments:
            actions.append(f"normalized file-reference comments for {filename}")

        file_refs = _parse_file_references(text)
        build_files = _parse_build_files(text)
        source_blocks = _sources_blocks(text)
        target = _find_cmux_tests_target(text)
        tests_sources_id = _cmux_tests_sources_id(target, source_blocks)
        sources = source_blocks[tests_sources_id]
        source_entries = _list_entries(sources.text, "files")
        expected_source_comment = f"{filename} in Sources"
        linked_builds = [
            build
            for build in build_files.values()
            if build.file_ref == canonical_ref.identifier
        ]
        linked_ids = {build.identifier for build in linked_builds}
        source_ids = [
            entry_id
            for entry_id, comment in source_entries
            if entry_id in linked_ids
            or (entry_id not in build_files and comment == expected_source_comment)
        ]

        preferred = sorted(linked_ids.intersection(source_ids))
        if preferred:
            canonical_build_id = preferred[0]
        elif linked_builds:
            canonical_build_id = min(linked_ids)
        elif source_ids:
            # A Sources entry with no PBXBuildFile object is a real silent-skip
            # failure. Preserve the existing Sources UUID and recreate the
            # missing object so the diff is minimal.
            canonical_build_id = min(source_ids)
        else:
            canonical_build_id = _stable_id("build-file", filename)
            _ensure_fresh_generated_id(text, canonical_build_id, filename, "PBXBuildFile")

        build_files = _parse_build_files(text)
        existing_build = build_files.get(canonical_build_id)
        if existing_build is None:
            line = (
                f"\t\t{canonical_build_id} /* {filename} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {canonical_ref.identifier} /* {filename} */; }};\n"
            )
            text = _append_section_lines(text, "PBXBuildFile", [line])
            actions.append(f"added PBXBuildFile for {filename}")
        elif existing_build.file_ref != canonical_ref.identifier:
            raise WiringError(
                f"{filename} canonical PBXBuildFile {canonical_build_id} points at "
                f"{existing_build.file_ref}, expected {canonical_ref.identifier}"
            )

        # Normalize every cmuxTests source membership tied to this file reference,
        # even when an old Xcode edit left stale display comments behind.
        sources = _sources_blocks(text)[tests_sources_id]
        current_entries = _list_entries(sources.text, "files")
        duplicate_entries = [
            (entry_id, comment)
            for entry_id, comment in current_entries
            if (
                entry_id in linked_ids
                or (entry_id not in build_files and comment == expected_source_comment)
            ) and entry_id != canonical_build_id
        ]
        for duplicate_build_id, duplicate_comment in sorted(duplicate_entries):
            current_sources = _sources_blocks(text)[tests_sources_id]
            new_sources = _remove_list_entry(
                current_sources.text,
                "files",
                duplicate_build_id,
                duplicate_comment,
            )
            text = _replace_block(
                text, current_sources, new_sources, "cmuxTests Sources phase"
            )
            build_files = _parse_build_files(text)
            duplicate_build = build_files.get(duplicate_build_id)
            if duplicate_build is not None:
                memberships = _source_memberships(
                    _sources_blocks(text), _target_sources(text, _sources_blocks(text))
                ).get(duplicate_build_id, [])
                if memberships:
                    raise WiringError(
                        f"cannot remove duplicate PBXBuildFile {duplicate_build_id} for {filename}; "
                        "it still belongs to a Sources phase"
                    )
                text = _remove_object_line(text, "PBXBuildFile", duplicate_build_id)
            actions.append(f"removed duplicate cmuxTests Sources membership for {filename}")

        sources = _sources_blocks(text)[tests_sources_id]
        canonical_entries = [
            comment
            for entry_id, comment in _list_entries(sources.text, "files")
            if entry_id == canonical_build_id
        ]
        if not canonical_entries:
            new_sources = _append_list_entry(
                sources.text,
                "files",
                canonical_build_id,
                expected_source_comment,
            )
            text = _replace_block(text, sources, new_sources, "cmuxTests Sources phase")
            actions.append(f"added {filename} to cmuxTests Sources phase")
        elif len(canonical_entries) > 1:
            for _ in range(len(canonical_entries) - 1):
                current_sources = _sources_blocks(text)[tests_sources_id]
                current_comments = [
                    comment
                    for entry_id, comment in _list_entries(current_sources.text, "files")
                    if entry_id == canonical_build_id
                ]
                new_sources = _remove_list_entry(
                    current_sources.text,
                    "files",
                    canonical_build_id,
                    current_comments[0],
                )
                text = _replace_block(
                    text, current_sources, new_sources, "cmuxTests Sources phase"
                )
            actions.append(f"removed duplicate cmuxTests Sources membership for {filename}")

        before_source_comments = text
        text = _rewrite_flat_object_comment(
            text,
            "PBXBuildFile",
            canonical_build_id,
            "PBXBuildFile",
            expected_source_comment,
            file_ref_id=canonical_ref.identifier,
            file_ref_comment=filename,
        )
        current_sources = _sources_blocks(text)[tests_sources_id]
        canonical_sources = _rewrite_list_entry_comment(
            current_sources.text,
            "files",
            canonical_build_id,
            expected_source_comment,
        )
        text = _replace_block(
            text, current_sources, canonical_sources, "cmuxTests Sources phase"
        )
        if text != before_source_comments:
            actions.append(f"normalized build/source comments for {filename}")

        # Remove any now-unused duplicate PBXBuildFile objects for the canonical
        # file reference. They are safe to drop only when no Sources phase uses them.
        build_files = _parse_build_files(text)
        memberships = _source_memberships(
            _sources_blocks(text), _target_sources(text, _sources_blocks(text))
        )
        for build in sorted(build_files.values(), key=lambda item: item.identifier):
            if (
                build.file_ref == canonical_ref.identifier
                and build.identifier != canonical_build_id
                and not memberships.get(build.identifier)
            ):
                text = _remove_object_line(text, "PBXBuildFile", build.identifier)
                actions.append(f"removed unused duplicate PBXBuildFile for {filename}")

    # Remove direct cmuxTests file references whose files were deleted. External
    # SOURCE_ROOT references and nested paths are deliberately outside this tool.
    disk = set(filenames)
    file_refs = _parse_file_references(text)
    group = _find_cmux_tests_group(text)
    direct_refs_by_name = _direct_group_refs(group, file_refs)
    # A partially deleted entry can lose its group child before its Sources
    # membership. That membership still identifies the direct test reference;
    # do not rely on display comments or unrelated direct references elsewhere.
    source_blocks = _sources_blocks(text)
    tests_sources_id = _cmux_tests_sources_id(_find_cmux_tests_target(text), source_blocks)
    test_build_ids = {entry_id for entry_id, _ in _list_entries(source_blocks[tests_sources_id].text, "files")}
    test_ref_ids = {
        build.file_ref for build in _parse_build_files(text).values()
        if build.identifier in test_build_ids
    }
    remaining_groups = _group_memberships(text)
    for filename, refs in _direct_refs_by_name(file_refs).items():
        known_ids = {ref.identifier for ref in direct_refs_by_name.get(filename, [])}
        for ref in refs:
            if (
                ref.identifier in test_ref_ids
                and ref.identifier not in known_ids
                and not remaining_groups.get(ref.identifier)
            ):
                direct_refs_by_name.setdefault(filename, []).append(ref)
    for filename in sorted(set(direct_refs_by_name) - disk):
        refs = sorted(direct_refs_by_name[filename], key=lambda item: item.identifier)
        for ref in refs:
            source_blocks = _sources_blocks(text)
            target_sources = _target_sources(text, source_blocks)
            tests_sources_id = _cmux_tests_sources_id(_find_cmux_tests_target(text), source_blocks)
            build_files = _parse_build_files(text)
            memberships = _source_memberships(source_blocks, target_sources)
            linked_builds = [build for build in build_files.values() if build.file_ref == ref.identifier]
            foreign_targets = sorted(
                {
                    target_name
                    for build in linked_builds
                    for phase_id, target_name in memberships.get(build.identifier, [])
                    if phase_id != tests_sources_id
                }
            )
            if foreign_targets:
                raise WiringError(
                    f"deleted {filename} is still a member of unexpected target(s): "
                    + ", ".join(foreign_targets)
                )

            group_memberships = _group_memberships(text).get(ref.identifier, set()) - {TARGET_NAME}
            if group_memberships:
                raise WiringError(
                    f"deleted {filename} is still referenced by group(s): "
                    + ", ".join(sorted(group_memberships))
                )

            current_group = _find_cmux_tests_group(text)
            current_group_comments = [
                comment
                for entry_id, comment in _list_entries(current_group.text, "children")
                if entry_id == ref.identifier
            ]
            if len(current_group_comments) > 1:
                raise WiringError(
                    f"expected one cmuxTests group entry for deleted {filename}"
                )
            if current_group_comments:
                new_group = _remove_list_entry(
                    current_group.text,
                    "children",
                    ref.identifier,
                    current_group_comments[0],
                )
                text = _replace_block(text, current_group, new_group, "cmuxTests PBXGroup")

            for build in linked_builds:
                current_sources = _sources_blocks(text)[tests_sources_id]
                matching_source_comments = [
                    comment
                    for entry_id, comment in _list_entries(current_sources.text, "files")
                    if entry_id == build.identifier
                ]
                for source_comment in matching_source_comments:
                    current_sources = _sources_blocks(text)[tests_sources_id]
                    new_sources = _remove_list_entry(
                        current_sources.text,
                        "files",
                        build.identifier,
                        source_comment,
                    )
                    text = _replace_block(
                        text, current_sources, new_sources, "cmuxTests Sources phase"
                    )
                text = _remove_object_line(text, "PBXBuildFile", build.identifier)

            # Also remove dangling Sources entries with this filename even if
            # the PBXBuildFile object had already disappeared.
            current_sources = _sources_blocks(text)[tests_sources_id]
            remaining_build_files = _parse_build_files(text)
            dangling_ids = [
                entry_id
                for entry_id, comment in _list_entries(current_sources.text, "files")
                if entry_id not in remaining_build_files and comment == f"{filename} in Sources"
            ]
            for dangling_id in dangling_ids:
                current_sources = _sources_blocks(text)[tests_sources_id]
                new_sources = _remove_list_entry(
                    current_sources.text,
                    "files",
                    dangling_id,
                    f"{filename} in Sources",
                )
                text = _replace_block(
                    text, current_sources, new_sources, "cmuxTests Sources phase"
                )

            text = _remove_object_line(text, "PBXFileReference", ref.identifier)
            actions.append(f"removed deleted {filename} from project wiring")

    text = _sort_flat_section(text, "PBXBuildFile")
    text = _sort_flat_section(text, "PBXFileReference")
    source_blocks = _sources_blocks(text)
    tests_sources_id = _cmux_tests_sources_id(
        _find_cmux_tests_target(text), source_blocks
    )
    current_sources = source_blocks[tests_sources_id]
    sorted_sources = _sort_list_entries(current_sources.text, "files")
    text = _replace_block(
        text, current_sources, sorted_sources, "cmuxTests Sources phase"
    )

    return SyncResult(text=text, actions=tuple(actions))


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="sync-test-wiring",
        description=(
            "Synchronize direct cmuxTests/*.swift files into the cmuxTests Xcode target. "
            "The command edits only PBXBuildFile, PBXFileReference, the cmuxTests group, "
            "and the cmuxTests Sources phase."
        ),
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="exit 1 when project.pbxproj would change; never write",
    )
    mode.add_argument(
        "--dry-run",
        action="store_true",
        help="print the deterministic diff; never write",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="cmux repository root (defaults to git top-level, then cwd)",
    )
    return parser.parse_args(argv)


def _repo_root(explicit: Path | None) -> Path:
    if explicit is not None:
        return explicit.resolve()
    import subprocess

    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        )
        return Path(result.stdout.strip()).resolve()
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd().resolve()


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    root = _repo_root(args.repo_root)
    project = root / PROJECT_RELATIVE_PATH
    tests_dir = root / TESTS_RELATIVE_PATH
    if not project.is_file():
        print(f"sync-test-wiring: missing {project}", file=sys.stderr)
        return 2
    if not tests_dir.is_dir():
        print(f"sync-test-wiring: missing {tests_dir}", file=sys.stderr)
        return 2

    filenames = sorted(path.name for path in tests_dir.iterdir() if path.is_file() and path.suffix == ".swift")
    original = project.read_text(encoding="utf-8")
    try:
        result = synchronize(original, filenames)
    except WiringError as error:
        print(f"sync-test-wiring: {error}", file=sys.stderr)
        return 2

    changed = result.text != original
    if args.dry_run:
        if changed:
            sys.stdout.writelines(
                difflib.unified_diff(
                    original.splitlines(keepends=True),
                    result.text.splitlines(keepends=True),
                    fromfile=str(PROJECT_RELATIVE_PATH),
                    tofile=str(PROJECT_RELATIVE_PATH),
                )
            )
        else:
            print("sync-test-wiring: clean")
        return 0

    if args.check:
        if changed:
            print("sync-test-wiring: project wiring is out of sync", file=sys.stderr)
            for action in result.actions:
                print(f"  - {action}", file=sys.stderr)
            if not result.actions:
                print("  - normalized pbxproj section and Sources ordering", file=sys.stderr)
            print("run ./scripts/sync-test-wiring and commit the pbxproj change", file=sys.stderr)
            return 1
        print(f"sync-test-wiring: ok (checked {len(filenames)} test files)")
        return 0

    if changed:
        project.write_text(result.text, encoding="utf-8")
        print(f"sync-test-wiring: updated {PROJECT_RELATIVE_PATH}")
        for action in result.actions:
            print(f"  - {action}")
    else:
        print(f"sync-test-wiring: clean (checked {len(filenames)} test files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
