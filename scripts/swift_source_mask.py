"""Hide Swift comments and string contents while preserving source offsets."""

import re

_STRING_START = re.compile(r'(\#*)("""|")')


def mask_swift_source(source):
    masked = list(source)

    def hide(start, end):
        for index in range(start, end):
            if masked[index] != "\n":
                masked[index] = " "

    index = 0
    while index < len(source):
        start = index
        if source.startswith("//", index):
            index = source.find("\n", index)
            if index < 0:
                index = len(source)
        elif source.startswith("/*", index):
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
        else:
            literal = _STRING_START.match(source, index)
            if not literal:
                index += 1
                continue
            hashes, quotes = literal.groups()
            index += len(literal.group())
            closing = quotes + hashes
            escape = "\\" + hashes
            while index < len(source):
                if source.startswith(escape, index):
                    index += len(escape) + 1
                elif source.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
            index = min(index, len(source))
        hide(start, index)
    return "".join(masked)
