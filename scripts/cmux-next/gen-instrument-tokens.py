#!/usr/bin/env python3
"""Instrument's one token file: write its CSS, check it against the app, and hold the gap shut.

schemas/instrument/instrument.json names every Instrument token (cmuxterm-hq RFD 0034's token table) with
the value Instrument wants and the value the app draws today, read from the file that sets it now. This
script:

  writes   webviews/src/ui/instrument.generated.css: `--instrument-*` at TODAY's values, so the sheet moves
           no pixel wherever it is imported; a pending Instrument value rides beside it as a comment. It is
           a build output (scripts/ci/generated-files.json, status build; gitignored): run this script to
           make it. `--print-css` writes it to stdout instead.
  checks   every token's recorded `today` against its live source. A PR that moves a default (design-scale,
           surface-roles, a setting's default) fails here until the token file says the new value, the
           version is bumped and CHANGELOG.md has that version.
  ratchets the pending list (tokens whose Instrument value is not drawn yet) against
           schemas/instrument/pending-baseline.json. It may only shrink: a token cannot fall back out of
           Instrument, and a new token cannot arrive already behind. `--update-baseline` writes the shrunk
           list and refuses to grow it.

`--rfd PATH` also checks that every name in the RFD's token table is here (the RFD lives in cmuxterm-hq,
which this repo's CI does not check out, so it is opt-in).

Usage: gen-instrument-tokens.py [--check] [--update-baseline] [--rfd PATH]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = 'schemas/instrument/instrument.json'
BASELINE = 'schemas/instrument/pending-baseline.json'
CHANGELOG = 'schemas/instrument/CHANGELOG.md'
CSS_FILE = 'webviews/src/ui/instrument.generated.css'
# What this check reads beside each token's own `today.file`.
INPUTS = (SOURCE, BASELINE, CHANGELOG)
NAME = re.compile(r'[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)*')
VERSION = re.compile(r'\d+\.\d+\.\d+')
STEP = re.compile(r'(\*\*)?([A-Za-z_][\w-]*)?(?:\[(\*|\d+|[\w-]+=[^\]]+)\])?$')
CSS_STRING = re.compile(r'(?:var|color-mix|light-dark)\(')
RFD_ROW = re.compile(r'^\|\s*`([^`]+)`\s*\|', re.M)
RFD_BLOCK = re.compile(r'<!-- instrument-tokens:begin[^>]*-->(.*?)<!-- instrument-tokens:end -->', re.S)


class TokenError(ValueError):
    pass


def _deep(node, key, want):
    """The first dict under node (depth first) whose `key` is `want`."""
    if isinstance(node, dict):
        if str(node.get(key)) == want:
            return node
        children = node.values()
    elif isinstance(node, list):
        children = node
    else:
        return None
    for child in children:
        found = _deep(child, key, want)
        if found is not None:
            return found
    return None


def resolve(data, path):
    """Read `a.b[name=x].c`, `list[*].field` or `**[key=x].field` out of parsed JSON."""
    nodes, many = [data], False
    for part in re.findall(r'(?:[^.\[]|\[[^\]]*\])+', path):
        m = STEP.match(part)
        if not m:
            raise TokenError(f'unreadable path step {part!r} in {path!r}')
        deep, field, index = m.groups()
        out = []
        for node in nodes:
            if deep:
                k, _, v = (index or '').partition('=')
                if not v:
                    raise TokenError(f'`**` needs [key=value] in {path!r}')
                hit = _deep(node, k, v)
                if hit is None:
                    raise TokenError(f'no object with {k}={v} under {path!r}')
                out.append(hit)
                continue
            if field:
                if not isinstance(node, dict) or field not in node:
                    raise TokenError(f'{path!r}: no field {field!r}')
                node = node[field]
            if index is None:
                out.append(node)
            elif index == '*':
                if not isinstance(node, list):
                    raise TokenError(f'{path!r}: [*] on a non-list')
                out.extend(node)
                many = True
            elif index.isdigit():
                out.append(node[int(index)])
            else:
                k, _, v = index.partition('=')
                hit = [item for item in node if isinstance(item, dict) and str(item.get(k)) == v]
                if len(hit) != 1:
                    raise TokenError(f'{path!r}: {len(hit)} items with {k}={v}, expected 1')
                out.append(hit[0])
        nodes = out
    return nodes if many else nodes[0]


def _px(value):
    """8, '8px' and 'var(--x, 8px)' compare as 8."""
    if isinstance(value, str):
        m = re.fullmatch(r'(?:var\(--[\w-]+,\s*)?(-?\d+(?:\.\d+)?)px\)?', value.strip())
        if m:
            return float(m.group(1))
    return value


def same(today, instrument):
    if isinstance(instrument, dict) and {'min', 'max'} <= instrument.keys():
        return isinstance(today, (int, float)) and instrument['min'] <= today <= instrument['max']
    a, b = _px(today), _px(instrument)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) < 1e-9
    return a == b


def is_rule(token):
    return 'rule' in token


def pending(token):
    """True when Instrument's value is not what the app draws today."""
    if is_rule(token):
        return 'waits' in token
    today = token.get('today')
    return today is None or not same(today['value'], token['instrument'])


def validate(data):
    if data.get('system') != 'Instrument' or not VERSION.fullmatch(str(data.get('version', ''))):
        raise TokenError('the file names system "Instrument" and a semver version')
    questions = data.get('questions') or {}
    names = [t.get('name') for t in data['tokens']]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        raise TokenError(f'tokens named twice: {", ".join(dupes)}')
    for t in data['tokens']:
        name = t.get('name') or '?'
        if not NAME.fullmatch(name):
            raise TokenError(f'{name}: a token name is dotted lowercase words')
        if not t.get('drawnOn'):
            raise TokenError(f'{name}: say what it is drawn on (drawnOn)')
        if is_rule(t) == ('instrument' in t):
            raise TokenError(f'{name}: a token is either a rule or has an instrument value, not both or neither')
        waits = t.get('waits')
        if waits is not None and waits not in questions:
            raise TokenError(f'{name}: waits {waits!r} is not one of the questions')
        if 'today' in t and (is_rule(t) or not {'file', 'path', 'value'} <= t['today'].keys()):
            raise TokenError(f'{name}: today is {{file, path, value}} on a value token')
        if not is_rule(t):
            if pending(t) and waits is None:
                raise TokenError(f'{name}: Instrument says {t["instrument"]!r}, the app draws '
                                 f'{t.get("today", {}).get("value")!r}; record what it waits on (waits)')
            if not pending(t) and waits is not None:
                raise TokenError(f'{name}: the app already draws Instrument\'s value; drop waits {waits!r}')
        if 'note' in t and not (isinstance(t['note'], str) and t['note']):
            raise TokenError(f'{name}: note is a sentence')
        for off in t.get('offToken', []):
            if not (isinstance(off, dict) and {'file', 'line', 'value', 'on'} <= off.keys()
                    and isinstance(off['line'], int)):
                raise TokenError(f'{name}: an offToken entry is {{file, line, value, on}}')


def drift(data, root=ROOT):
    """Each token whose recorded `today` is no longer what its source says."""
    found, cache = [], {}
    for t in data['tokens']:
        today = t.get('today')
        if not today:
            continue
        if today['file'] not in cache:
            path = root / today['file']
            if not path.is_file():
                found.append(f'{t["name"]}: {today["file"]} does not exist')
                continue
            cache[today['file']] = json.loads(path.read_text(encoding='utf-8'))
        try:
            live = resolve(cache[today['file']], today['path'])
        except TokenError as error:
            found.append(f'{t["name"]}: {error}')
            continue
        if live != today['value']:
            found.append(f'{t["name"]}: {today["file"]} {today["path"]} is {live!r}, the token file says '
                         f'{today["value"]!r}. A default moved: set today.value, bump the version and add it '
                         f'to {CHANGELOG}.')
    return found


def _literal(value):
    """The CSS text an offToken entry quotes, without the explanation after ' = ' or ' ('."""
    return re.split(r' = | \(', value, maxsplit=1)[0].strip()


def stale_off_token(data, root=ROOT):
    """offToken entries whose file:line no longer holds the raw value. Warnings: other PRs move these
    lines, so a stale entry asks for a refresh and never fails a check."""
    found = []
    for t in data['tokens']:
        for off in t.get('offToken', []):
            path = root / off['file']
            lines = path.read_text(encoding='utf-8').split('\n') if path.is_file() else []
            if off['line'] > len(lines) or _literal(off['value']) not in lines[off['line'] - 1]:
                found.append(f'{t["name"]}: offToken {off["file"]}:{off["line"]} no longer reads '
                             f'{_literal(off["value"])!r}; refresh the entry')
    return found


def pending_names(data):
    return sorted(t['name'] for t in data['tokens'] if pending(t))


def ratchet(data, baseline):
    """Growth is a failure; a shrink not yet written to the baseline is a failure too, so it stays won."""
    now, then = set(pending_names(data)), set(baseline.get('pending', []))
    problems = [f'{n}: newly behind Instrument (not in {BASELINE}); the gap may only shrink'
                for n in sorted(now - then)]
    problems += [f'{n}: now draws Instrument\'s value; lock it in with --update-baseline'
                 for n in sorted(then - now)]
    return problems


def baseline_text(names):
    return json.dumps({'$comment': f'Instrument tokens not yet drawn. Only shrinks: scripts/cmux-next/'
                                   f'gen-instrument-tokens.py --update-baseline refuses to add one.',
                       'pending': names}, indent=2) + '\n'


def changelog_problems(data, text):
    version = data['version']
    if not re.search(rf'^## {re.escape(version)}\b', text, re.M):
        return [f'{CHANGELOG} has no "## {version}" entry']
    return []


def _css_value(t):
    today = t.get('today')
    if not today:
        return None
    value = today['value']
    if isinstance(value, bool) or isinstance(value, list):
        return None
    if isinstance(value, (int, float)):
        unit = t.get('unit', '')
        return f'{value:g}{unit}' if unit in ('px', '%') else f'{value:g}'
    if isinstance(value, str) and CSS_STRING.match(value):
        return value
    return None


def _show(value):
    if isinstance(value, dict) and {'min', 'max'} <= value.keys():
        return f'{value["min"]} to {value["max"]}'
    if isinstance(value, list):
        return ', '.join(str(v) for v in value)
    return str(value)


def css(data):
    lines = [f'/* GENERATED by scripts/cmux-next/gen-instrument-tokens.py from {SOURCE}; do not edit. */',
             f'/* Instrument {data["version"]}. Every value is what the app draws today; a pending Instrument',
             '   value is the comment beside it and is applied only when its default moves. */',
             ':root {']
    unset = []
    for t in data['tokens']:
        value = _css_value(t)
        if value is None:
            if not is_rule(t):
                unset.append(t['name'])
            continue
        var = '--instrument-' + t['name'].replace('.', '-')
        note = ''
        if pending(t):
            note = f' /* Instrument {_show(t["instrument"])}{t.get("unit", "") if not isinstance(t["instrument"], str) else ""}; waits {t["waits"]} */'
        lines.append(f'  {var}: {value};{note}')
    lines.append('}')
    if unset:
        lines.append(f'/* No CSS value today: {", ".join(unset)}. */')
    return '\n'.join(lines) + '\n'


def rfd_problems(data, text):
    block = RFD_BLOCK.search(text)
    if not block:
        return ['the RFD has no instrument-tokens:begin/end block']
    want = set(RFD_ROW.findall(block.group(1))) - {'Token'}
    have = {t['name'] for t in data['tokens']} | {t['part'] for t in data['tokens'] if 'part' in t}
    return [f'{n}: in the RFD token table, not in {SOURCE}' for n in sorted(want - have)]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--check', action='store_true', help='fail on any drift instead of writing')
    ap.add_argument('--update-baseline', action='store_true', help='write the shrunk pending list')
    ap.add_argument('--print-css', action='store_true', help='print the sheet and exit')
    ap.add_argument('--rfd', type=Path, help="cmuxterm-hq's docs/rfd/0034-design-instrument.md")
    args = ap.parse_args(argv)
    data = json.loads((ROOT / SOURCE).read_text(encoding='utf-8'))
    try:
        validate(data)
    except TokenError as error:
        print(f'gen-instrument-tokens: {error}', file=sys.stderr)
        return 1
    if args.print_css:
        sys.stdout.write(css(data))
        return 0
    problems = drift(data)
    problems += changelog_problems(data, (ROOT / CHANGELOG).read_text(encoding='utf-8'))
    if args.rfd:
        problems += rfd_problems(data, args.rfd.read_text(encoding='utf-8'))
    baseline_path = ROOT / BASELINE
    baseline = json.loads(baseline_path.read_text(encoding='utf-8')) if baseline_path.is_file() else None
    if args.update_baseline:
        grown = sorted(set(pending_names(data)) - set((baseline or {}).get('pending', [])))
        if baseline is not None and grown:
            problems.append(f'--update-baseline refuses to add: {", ".join(grown)}')
        else:
            baseline_path.write_text(baseline_text(pending_names(data)), encoding='utf-8')
            baseline = json.loads(baseline_path.read_text(encoding='utf-8'))
    if baseline is None:
        problems.append(f'{BASELINE} is missing; write it once with --update-baseline')
    else:
        problems += ratchet(data, baseline)
    for warning in stale_off_token(data):
        print(f'gen-instrument-tokens: warning: {warning}', file=sys.stderr)
    if not args.check:
        (ROOT / CSS_FILE).write_text(css(data), encoding='utf-8')
    for problem in problems:
        print(f'gen-instrument-tokens: {problem}', file=sys.stderr)
    if not problems:
        n = len(pending_names(data))
        print(f'Instrument {data["version"]}: {len(data["tokens"])} tokens, {n} pending, no drift')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
