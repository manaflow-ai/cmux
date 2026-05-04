from __future__ import annotations

import os
import socket
import threading
from pathlib import Path


PRIVATE_SOCKET_MODE = 0o600
PRIVATE_SOCKET_DIR_MODE = 0o700
PRIVATE_SOCKET_UMASK = 0o177
UMASK_LOCK = threading.Lock()


def ensure_private_socket_directory(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=PRIVATE_SOCKET_DIR_MODE)


def bind_private_unix_socket(server: socket.socket, path: Path) -> None:
    with UMASK_LOCK:
        previous_umask = os.umask(PRIVATE_SOCKET_UMASK)
        try:
            server.bind(str(path))
        finally:
            os.umask(previous_umask)
    path.chmod(PRIVATE_SOCKET_MODE)
