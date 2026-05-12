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


def socket_path_for_file_name(
    file_name: str,
    directory: pathlib.Path = SOCKET_DIRECTORY,
) -> pathlib.Path:
    candidate = directory / file_name
    max_path_length = unix_socket_path_max_length()
    if len(str(candidate).encode("utf-8")) <= max_path_length:
        return candidate

    budget = max_path_length - len(str(directory).encode("utf-8")) - 1
    suffix = ".sock"
    stem = file_name[: -len(suffix)] if file_name.endswith(suffix) else file_name
    hash_suffix = f"-{fnv1a32_hex(file_name)}"
    stem_budget = budget - len(hash_suffix.encode("utf-8")) - len(suffix.encode("utf-8"))
    if stem_budget < 1:
        return candidate

    shortened_stem = stem[:stem_budget].strip(".-") or "cmux"
    return directory / f"{shortened_stem}{hash_suffix}{suffix}"


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] in {"-h", "--help"}:
        print("usage: cmux_socket_paths.py <socket-file-name>", file=sys.stderr)
        return 2
    print(socket_path_for_file_name(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
