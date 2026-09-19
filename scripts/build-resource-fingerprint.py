#!/usr/bin/env python3
"""Hash a physical resource tree or Git inventory without per-file processes."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys


def fingerprint(mode, root):
    root = Path(root)
    result = hashlib.sha256()

    def field(value):
        value = os.fsencode(value)
        result.update(len(value).to_bytes(8, 'big'))
        result.update(value)

    def visit(path, recursive):
        field(str(path))
        try:
            info = path.lstat()
        except FileNotFoundError:
            field('missing')
            return
        field(str(stat.S_IMODE(info.st_mode)))
        if stat.S_ISLNK(info.st_mode):
            field('link'); field(os.readlink(path))
        elif stat.S_ISDIR(info.st_mode):
            field('directory')
            if recursive:
                for child in sorted(path.iterdir()):
                    visit(child, True)
        elif stat.S_ISREG(info.st_mode):
            field('file')
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            field(digest.hexdigest())
        else:
            raise ValueError('unsupported resource type: ' + str(path))

    if mode == 'tree':
        visit(root, True)
    elif mode == 'git':
        if not root.is_dir():
            field('missing-git'); field(str(root))
        else:
            env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
            names = subprocess.check_output(
                ['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], env=env)
            for name in sorted(set(names.split(b'\0')) - {b''}):
                path = Path(os.fsdecode(name))
                if path.is_absolute() or '..' in path.parts:
                    raise ValueError('unsafe inventory path')
                visit(root / path, False)
    else:
        raise ValueError('unknown fingerprint mode')
    return result.hexdigest()


if __name__ == '__main__':
    print(fingerprint(sys.argv[1], sys.argv[2]))
