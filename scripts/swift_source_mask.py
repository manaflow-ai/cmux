"""Hide Swift comments and string contents while preserving source offsets."""

import re

_STRING_START = re.compile(r'(\#*)("""|")')


def _comment_end(source, index):
    if source.startswith("//", index):
        end = source.find("\n", index)
        return len(source) if end < 0 else end
    depth = 1
    index += 2
    while index < len(source) and depth:
        if source.startswith("/*", index):
            depth += 1
            index += 2
        elif source.startswith("*/", index):
            depth -= 1
            index += 2
        else:
            index += 1
    return index


def _interpolation_end(source, index):
    depth = 1
    while index < len(source) and depth:
        if source.startswith(("//", "/*"), index):
            index = _comment_end(source, index)
        elif literal := _STRING_START.match(source, index):
            index = _string_end(source, literal)
        else:
            depth += (source[index] == "(") - (source[index] == ")")
            index += 1
    return index


def _string_end(source, literal):
    hashes, quotes = literal.groups()
    index = literal.end()
    closing = quotes + hashes
    escape = "\\" + hashes
    while index < len(source):
        if source.startswith(escape, index):
            index += len(escape)
            if source.startswith("(", index):
                index = _interpolation_end(source, index + 1)
            else:
                index += 1
        elif source.startswith(closing, index):
            return index + len(closing)
        else:
            index += 1
    return min(index, len(source))


def mask_swift_source(source):
    masked = list(source)

    def hide(start, end):
        for index in range(start, end):
            if masked[index] != "\n":
                masked[index] = " "

    index = 0
    while index < len(source):
        start = index
        if source.startswith(("//", "/*"), index):
            index = _comment_end(source, index)
        else:
            literal = _STRING_START.match(source, index)
            if not literal:
                index += 1
                continue
            index = _string_end(source, literal)
        hide(start, index)
    return "".join(masked)
