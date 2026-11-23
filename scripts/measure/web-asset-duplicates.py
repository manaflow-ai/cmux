#!/usr/bin/env python3
"""Read-only exact-file and inline-font accounting for an extracted web artifact.

Companion wrapper: web-asset-duplicates.sh (fleet command and artifact identity).
Archive experiment omits paths and is NOT a usable package or a runtime estimate.
"""
import argparse
import base64
from collections import defaultdict
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import platform
import tarfile
import zlib

FONT = re.compile(rb'data:(?:font/[^;,]+|application/(?:font-woff|x-font-ttf|octet-stream));base64,([A-Za-z0-9+/=]+)')
MAGIC = (b'wOF2', b'wOFF', b'OTTO', b'\x00\x01\x00\x00')


def groups(rows):
    buckets = defaultdict(list)
    for name, data in rows:
        buckets[hashlib.sha256(data).hexdigest()].append((name, len(data)))
    return [dict(sha256=h, bytesPerCopy=v[0][1], copies=len(v),
                 redundantBytes=(len(v)-1)*v[0][1], paths=[n for n, _ in v])
            for h, v in sorted(buckets.items())]


def archive_size(rows, unique=False):
    out = io.BytesIO()
    seen = set()
    with gzip.GzipFile(fileobj=out, mode='wb', compresslevel=6, mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w|', format=tarfile.USTAR_FORMAT) as tar:
            for name, data in rows:
                digest = hashlib.sha256(data).digest()
                if unique and digest in seen:
                    continue
                seen.add(digest)
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode = len(data), 0o644
                tar.addfile(entry, io.BytesIO(data))
    return len(out.getvalue())


def measure(root):
    rows = []
    # Downloaded artifact roots are bounded by fetch-web-bundles.sh. This also
    # rejects symlinks so a local fixture cannot silently read outside its tree.
    for f in sorted(root.rglob('*')):
        if f.is_symlink():
            raise ValueError(f'symlink in input: {f}')
        if f.is_file() and f != root / '.manifest.json':
            rows.append((f.relative_to(root).as_posix(), f.read_bytes()))
    if not rows:
        raise ValueError('no asset files')
    whole = groups(rows)
    external = [(n, b) for n, b in rows if Path(n).suffix in ('.woff', '.woff2', '.ttf', '.otf')]
    inline = []
    for name, data in rows:
        if not name.endswith(('.css', '.js', '.mjs', '.html', '.deflate')):
            continue
        if name.endswith('.deflate'):
            data = zlib.decompress(data, -15)
        for index, match in enumerate(FONT.finditer(data)):
            font = base64.b64decode(match[1], validate=True)
            if font[:4] in MAGIC:
                inline.append((f'{name}#font-{index}', font))
    fonts = groups(inline)
    all_fonts = groups(external + inline)
    baseline, unique = archive_size(rows), archive_size(rows, True)
    manifest = root / '.manifest.json'
    return dict(schema=1, runtime=dict(python=platform.python_version(), zlib=zlib.ZLIB_RUNTIME_VERSION), manifest=json.loads(manifest.read_text()) if manifest.exists() else None,
                files=len(rows), storedBytes=sum(len(b) for _, b in rows),
                uniquePayloads=len(whole), duplicateGroups=[g for g in whole if g['copies'] > 1],
                redundantBytes=sum(g['redundantBytes'] for g in whole),
                externalFontFiles=len(external), externalFontBytes=sum(len(b) for _, b in external),
                externalFontRedundantBytes=sum(g['redundantBytes'] for g in groups(external)),
                inlineFontOccurrences=len(inline), uniqueInlineFonts=len(fonts),
                inlineFontBytes=sum(len(b) for _, b in inline),
                inlineFontRedundantBytes=sum(g['redundantBytes'] for g in fonts),
                inlineFontGroups=fonts, allFontGroups=all_fonts, allFontRedundantBytes=sum(g['redundantBytes'] for g in all_fonts),
                archiveExperiment=dict(baselineBytes=baseline, uniquePayloadBytes=unique,
                                       deltaBytes=baseline-unique, gzipLevel=6,
                                       semantics='sorted USTAR, normalized metadata; omitted duplicate paths; not installable'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = measure(args.root.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('inlineFontGroups', 'allFontGroups', 'duplicateGroups')}))


if __name__ == '__main__':
    main()
