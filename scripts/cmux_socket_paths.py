#!/usr/bin/env python3
from __future__ import annotations

import ctypes
import pathlib
import platform
import sys


SOCKET_DIRECTORY = pathlib.Path("~/Library/Application Support/cmux").expanduser()


def unix_socket_path_max_length() -> int:
    system = platform.system()
    if system == "Darwin":
        class SockaddrUn(ctypes.Structure):
            _fields_ = [
                ("sun_len", ctypes.c_ubyte),
                ("sun_family", ctypes.c_ubyte),
                ("sun_path", ctypes.c_char * 104),
            ]

        return SockaddrUn.sun_path.size - 1
    if system == "Linux":
        class SockaddrUn(ctypes.Structure):
            _fields_ = [
                ("sun_family", ctypes.c_ushort),
                ("sun_path", ctypes.c_char * 108),
            ]

        return SockaddrUn.sun_path.size - 1
    return 103


def fnv1a32_hex(value: str) -> str:
    hash_value = 2_166_136_261
    for byte in value.encode("utf-8"):
        hash_value ^= byte
        hash_value = (hash_value * 16_777_619) & 0xFFFFFFFF
    return f"{hash_value:08x}"


def utf8_prefix(value: str, max_bytes: int) -> str:
    if max_bytes <= 0:
        return ""
    result: list[str] = []
    used_bytes = 0
    for char in value:
        width = len(char.encode("utf-8"))
        if used_bytes + width > max_bytes:
            break
        result.append(char)
        used_bytes += width
    return "".join(result)


def shortened_socket_file_name(file_name: str, directory: pathlib.Path) -> str:
    max_path_length = unix_socket_path_max_length()
    budget = max_path_length - len(str(directory).encode("utf-8")) - 1
    suffix = ".sock"
    if len(file_name.encode("utf-8")) <= budget:
        return file_name

    stem = file_name[: -len(suffix)] if file_name.endswith(suffix) else file_name
    hash_value = fnv1a32_hex(file_name)
    hash_suffix = f"-{hash_value}"
    if budget < len(suffix.encode("utf-8")) + 1:
        return f"{hash_value}{suffix}"

    stem_budget = budget - len(hash_suffix.encode("utf-8")) - len(suffix.encode("utf-8"))
    if stem_budget < 1:
        hash_budget = max(1, budget - len(suffix.encode("utf-8")))
        return f"{hash_value[:hash_budget]}{suffix}"

    shortened_stem = utf8_prefix(stem, stem_budget).strip(".-") or "cmux"
    shortened = f"{shortened_stem}{hash_suffix}{suffix}"
    if len(shortened.encode("utf-8")) <= budget:
        return shortened

    hash_budget = max(1, budget - len(suffix.encode("utf-8")))
    return f"{hash_value[:hash_budget]}{suffix}"


def socket_path_for_file_name(
    file_name: str,
    directory: pathlib.Path = SOCKET_DIRECTORY,
) -> pathlib.Path:
    candidate = directory / file_name
    max_path_length = unix_socket_path_max_length()
    if len(str(candidate).encode("utf-8")) <= max_path_length:
        return candidate

    shortened = directory / shortened_socket_file_name(file_name, directory)
    if len(str(shortened).encode("utf-8")) <= max_path_length:
        return shortened

    tmp_directory = pathlib.Path("/tmp")
    tmp_shortened = tmp_directory / shortened_socket_file_name(file_name, tmp_directory)
    if len(str(tmp_shortened).encode("utf-8")) <= max_path_length:
        return tmp_shortened

    return tmp_directory / f"{fnv1a32_hex(file_name)}.sock"


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] in {"-h", "--help"}:
        print("usage: cmux_socket_paths.py <socket-file-name>", file=sys.stderr)
        return 2
    print(socket_path_for_file_name(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
