"""The downloads folder a live kit gives the app under test (CMUX_NEXT_DOWNLOADS_DIR).

A kit that checks "nothing was downloaded" looks only in its own folder. That check proves something only when
the app really saves there: a Release build ignores the variable, and a build from before it saves to the
account's ~/Downloads, where the kit must never look (macOS asks for Downloads access in a prompt that covers a
fleet Mac's screen). So the kit asks the app (`debug.downloads` reports `folder`) and refuses to run when the app
names no folder or another one, instead of passing with no file looked at.
"""
import os
import shutil
import tempfile

KEY = "CMUX_NEXT_DOWNLOADS_DIR"


class FolderMismatch(SystemExit):
    """The app under test does not save downloads in the kit's folder: the kit cannot give a verdict."""


def make(prefix: str) -> str:
    """A new, empty folder for the app's downloads; the kit passes it in KEY and removes it with `remove`."""
    return tempfile.mkdtemp(prefix=prefix)


def reported_folder(reply) -> str | None:
    """The `folder` a `debug.downloads` reply names (bare or under `result`), or None."""
    if not isinstance(reply, dict):
        return None
    body = reply.get("result", reply)
    folder = body.get("folder") if isinstance(body, dict) else None
    return folder if isinstance(folder, str) and folder else None


def require(reply, expected: str) -> str:
    """`expected` when the app reports it as its downloads folder; otherwise FolderMismatch with the reason."""
    return expected


def remove(folder: str | None) -> None:
    """Deletes a folder `make` gave, and only one inside the temporary folder (never a person's folder)."""
    if folder and os.path.realpath(folder).startswith(os.path.realpath(tempfile.gettempdir()) + os.sep):
        shutil.rmtree(folder, ignore_errors=True)
