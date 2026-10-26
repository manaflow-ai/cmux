#!/usr/bin/env python3
"""The cmux-next order file and PGO profile check (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 053;
done check 9 and query Q10).

    python3 scripts/cmux-next/pgo/check.py --app "$NX_APP" --order Resources/build/cmux-next.order --link-map MAP
    python3 scripts/cmux-next/pgo/check.py ... --launch-profile fresh-launch.profraw --profdata cmux-next.profdata
    python3 scripts/cmux-next/pgo/check.py --order Resources/build/cmux-next.order [--profdata-sha256 SHA256_FILE]

Run it by hand on a Release build that linked the order file (task 051 writes the link map), or from the refresh
script (054). It is not a CI step. Chrome's equivalent is tools/cygprofile/check_orderfile.py, which checks an
Android order file against the symbols of the binary it was linked into (docs/orderfile.md); the mismatch rate is
the count that clang's -Wprofile-instr-out-of-date gives (warn_profile_data_out_of_date in
clang/include/clang/Basic/DiagnosticFrontendKinds.td).

With no --link-map (no Release link yet) it checks only the order file (task 109): exactly one
`# profdata sha256` header, equal to the sha256 file of the profdata the build uses (--profdata-sha256, the same file
as --pinned), at least one symbol and no symbol twice. It prints each problem as `pgo-check: FAIL <problem>`, or
`pgo-check: ok <n> symbols, profdata <sha>`.

Checks with --link-map, each a line of the report:

    coverage       the order file's symbols that the link map lists as live. Release is stripped, so the link map,
                   not nm. Fails under --min-coverage (90 %), and when the order file has no symbols.
    binding        the order file's header line `# profdata sha256 <hex>` (run-scenarios.py --stage order, 109)
                   equals the sha256 of --profdata and the profile pinned in --pinned (default
                   Resources/build/cmux-next.profdata.sha256, task 052; skipped when that default file is absent).
                   Fails when the header has no sha, a sha differs, or there is nothing to compare it with.
    link-map       with --app: the map's __TEXT sections have the binary's addresses and sizes, so the map is of
                   that link. Fails when they differ.
    launch-window  with --launch-profile: the functions with an entry count above 0 in a launch profile of a
                   profile build at the same source (launch.profraw of run-scenarios.py), mapped to link map
                   symbols, that start in the first --pages (64) pages of __TEXT. The window starts at the page
                   of the start of __TEXT,__text; the page is 16 KiB for arm64, 4 KiB for x86_64. Functions the map
                   does not have (inlined into callers) are left out of the share. Fails under
                   --min-launch-window (90 %), and when no launch function is in the map.
    mismatch       with --launch-profile and --profdata: of the functions of the launch profile whose name the
                   profdata also has, the share whose structural hash differs (the compiler ignores their
                   profile). Names the profdata does not have are new code, counted apart. Fails over
                   --max-mismatch (20 %), and when no name is in both.

The last line is `PGO-CHECK <json>` with every check; --json writes the same report with the missing symbols.
Exit codes: 0 every check passed, 1 a check failed, 2 usage or an input that cannot be read (the error names it).

Seams (tests only): `--llvm-profdata` or CMUX_PGO_LLVM_PROFDATA replace `xcrun llvm-profdata`, as in
run-scenarios.py.
"""
import argparse, dataclasses, importlib.util, json, os, plistlib, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DEFAULT_PINNED = os.path.join(REPO, "Resources", "build", "cmux-next.profdata.sha256")
DEFAULT_PAGES, MIN_COVERAGE, MIN_LAUNCH_WINDOW, MAX_MISMATCH = 64, 90.0, 90.0, 20.0
SHOWN_MISSING = 10


def load_module(name, file):
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def load_order_lib():
    """page-fault-order.py (task 109), for its order file check."""
    return load_module("page_fault_order", "page-fault-order.py")


def load_runner():
    """run-scenarios.py, for its llvm-profdata seam, tool runner and sha256."""
    return load_module("run_scenarios", "run-scenarios.py")


runner = load_runner()


class InputError(RuntimeError):
    """An input that cannot be read or is not what its flag names; main() prints it and exits 2."""


def read_text(path, what):
    try:
        with open(path, errors="replace") as source:
            return source.read()
    except OSError as error:
        raise InputError(f"{what} {path}: {error.strerror}")


# The link map (ld64 and ld-prime write the same sections).

HEX = r"0x[0-9A-Fa-f]+"
SECTION_LINE = re.compile(rf"^({HEX})\s+({HEX})\s+(\S+)\s+(\S+)\s*$")
SYMBOL_LINE = re.compile(rf"^({HEX})\s+({HEX})\s+\[\s*\d+\]\s(.+?)\s*$")
DEAD_LINE = re.compile(rf"^<<dead>>\s+({HEX})\s+\[\s*\d+\]\s(.+?)\s*$")


@dataclasses.dataclass
class LinkMap:
    arch: str
    sections: dict  # (segment, section) -> (address, size)
    symbols: dict  # live name -> lowest address
    dead: set

    def text_sections(self):
        return {key: value for key, value in self.sections.items() if key[0] == "__TEXT"}

    def address_of_function(self, profile_name):
        for candidate in symbol_candidates(profile_name):
            if candidate in self.symbols:
                return self.symbols[candidate]
        return None


def parse_link_map(text):
    arch, part = "", None
    sections, symbols, dead = {}, {}, set()
    for line in text.splitlines():
        if line.startswith("# Arch:"):
            arch = line.split(":", 1)[1].strip()
        elif line.startswith("# Sections:"):
            part = "sections"
        elif line.startswith("# Symbols:"):
            part = "symbols"
        elif line.startswith("# Dead Stripped Symbols:"):
            part = "dead"
        elif part == "sections" and (match := SECTION_LINE.match(line)):
            sections[(match.group(3), match.group(4))] = (int(match.group(1), 16), int(match.group(2), 16))
        elif part == "symbols" and (match := SYMBOL_LINE.match(line)):
            address, name = int(match.group(1), 16), match.group(3)
            symbols[name] = min(address, symbols.get(name, address))
        elif part == "dead" and (match := DEAD_LINE.match(line)):
            dead.add(match.group(2))
    if not sections or not symbols:
        raise InputError("not a link map: no `# Sections:` or `# Symbols:` entries")
    return LinkMap(arch, sections, symbols, dead)


# The order file.

SHA_HEADER = re.compile(r"^#\s*profdata sha256\s+([0-9a-f]{64})\s*$")
ORDER_PREFIX = re.compile(r"^(?:(?:arm64e?|arm64_32|x86_64h?|i386):)?(?:[^\s:]+\.o:)?")


@dataclasses.dataclass
class OrderFile:
    symbols: list
    sha256: str
    duplicates: int


def parse_order(text):
    """The symbols of an ld order file in order (an `arch:` or `file.o:` prefix dropped, as ld reads it, the
    first of a repeated symbol kept), and the profdata sha256 of its header."""
    symbols, seen, sha, duplicates = [], set(), None, 0
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            match = SHA_HEADER.match(line)
            if match and sha is None:
                sha = match.group(1)
            continue
        symbol = line[ORDER_PREFIX.match(line).end():]
        if symbol in seen:
            duplicates += 1
            continue
        seen.add(symbol)
        symbols.append(symbol)
    return OrderFile(symbols, sha, duplicates)


# Profile names and their link map symbols.

SOURCE_PREFIX = re.compile(r"^[^:\[]*\.\w+:(?=.)")


def symbol_candidates(profile_name):
    """The Mach-O symbol names of a PGO function name. A local function's name starts with its source file
    (`File.swift:` for Swift, `file.c;` for clang); C and Swift symbols take a leading underscore, Objective-C
    methods do not."""
    name = profile_name.rsplit(";", 1)[-1]
    name = name[match.end():] if (match := SOURCE_PREFIX.match(name)) else name
    if name.startswith(("-[", "+[")):
        return [name]
    return ["_" + name, name]


FUNCTION_LINE = re.compile(r"^  (\S.*):$")
HASH_LINE = re.compile(r"^    Hash: (0x[0-9A-Fa-f]+)$")
COUNT_LINE = re.compile(r"^    Function count: (\d+)$")


def profile_records(show_output):
    """[(name, hash, entry count)] from `llvm-profdata show --all-functions`."""
    records, name, func_hash = [], None, None
    for line in show_output.splitlines():
        if match := FUNCTION_LINE.match(line):
            name, func_hash = match.group(1), None
        elif name is not None and (match := HASH_LINE.match(line)):
            func_hash = int(match.group(1), 16)
        elif name is not None and (match := COUNT_LINE.match(line)):
            records.append((name, func_hash, int(match.group(1))))
            name = None
    return records


def read_profile(tool, path):
    if not os.path.isfile(path):
        raise InputError(f"profile {path}: no such file")
    try:
        records = profile_records(runner.run_tool(tool, "show", "--all-functions", path))
    except runner.StageError as error:
        raise InputError(str(error))
    if not records:
        raise InputError(f"llvm-profdata show listed no functions for {path}")
    return records


# The binary.

LC_SEGMENT_64, MH_MAGIC_64, FAT_MAGIC, FAT_MAGIC_64 = 0x19, 0xFEEDFACF, 0xCAFEBABE, 0xCAFEBABF
CPU_TYPES = {0x0100000C: "arm64", 0x01000007: "x86_64"}


def cpu_family(arch):
    return "arm64" if arch.startswith("arm64") else arch


def app_executable(app):
    if os.path.isfile(app):
        return app
    plist = os.path.join(app, "Contents", "Info.plist")
    try:
        with open(plist, "rb") as source:
            name = plistlib.load(source)["CFBundleExecutable"]
    except (OSError, KeyError, plistlib.InvalidFileException) as error:
        raise InputError(f"--app {app}: no CFBundleExecutable in {plist} ({error})")
    return os.path.join(app, "Contents", "MacOS", name)


def read_at(source, offset, size, path):
    source.seek(offset)
    data = source.read(size)
    if len(data) != size:
        raise InputError(f"{path}: truncated Mach-O")
    return data


def slices(source, path):
    """[(cpu type, offset)] of a thin or universal Mach-O file."""
    (magic,) = struct.unpack(">I", read_at(source, 0, 4, path))
    if magic not in (FAT_MAGIC, FAT_MAGIC_64):
        return [(None, 0)]
    (count,) = struct.unpack(">I", read_at(source, 4, 4, path))
    entry, size = (">iiIII", 20) if magic == FAT_MAGIC else (">iiQQII", 32)
    return [(fields[0], fields[2]) for fields in
            (struct.unpack(entry, read_at(source, 8 + index * size, size, path)) for index in range(count))]


def binary_text_sections(path, arch):
    """{("__TEXT", section): (address, size)} of the `arch` slice (the only slice when the map names none)."""
    try:
        source = open(path, "rb")
    except OSError as error:
        raise InputError(f"binary {path}: {error.strerror}")
    with source:
        found = slices(source, path)
        if len(found) > 1:
            found = [s for s in found if CPU_TYPES.get(s[0]) == cpu_family(arch)]
            if len(found) != 1:
                raise InputError(f"{path}: no single {arch or 'unnamed'} slice")
        offset = found[0][1]
        header = struct.unpack("<IiiIIIII", read_at(source, offset, 32, path))
        if header[0] != MH_MAGIC_64:
            raise InputError(f"{path}: not a 64-bit Mach-O file")
        commands = read_at(source, offset + 32, header[5], path)
    try:
        return segment_sections(commands, header[4], b"__TEXT")
    except struct.error:
        raise InputError(f"{path}: truncated load commands")


def segment_sections(commands, count, name):
    sections, at = {}, 0
    for _ in range(count):
        command, size = struct.unpack_from("<II", commands, at)
        if command == LC_SEGMENT_64:
            segment = struct.unpack_from("<16sQQQQiiII", commands, at + 8)
            if segment[0].rstrip(b"\0") == name:
                for index in range(segment[7]):
                    fields = struct.unpack_from("<16s16sQQ", commands, at + 72 + index * 80)
                    sections[(name.decode(), fields[0].rstrip(b"\0").decode())] = (fields[2], fields[3])
        at += size
    return sections


# The checks.

def percent(part, whole):
    """The exact share in percent (thresholds compare it; reports round it to 2 places), None for no whole."""
    return 100.0 * part / whole if whole else None


def check(name, ok, detail, **values):
    return {"check": name, "ok": ok, "detail": detail, **values}


def check_coverage(order, link_map, minimum):
    live = [s for s in order.symbols if s in link_map.symbols]
    dead = [s for s in order.symbols if s not in link_map.symbols and s in link_map.dead]
    missing = [s for s in order.symbols if s not in link_map.symbols and s not in link_map.dead]
    share = percent(len(live), len(order.symbols))
    if share is None:
        return check("coverage", False, "the order file has no symbols", percent=None, symbols=0)
    detail = (f"{share:.2f} % of {len(order.symbols)} order symbols are live in the link map (>= {minimum} %); "
              f"{len(dead)} dead-stripped, {len(missing)} absent")
    return check("coverage", share >= minimum, detail, percent=round(share, 2), symbols=len(order.symbols),
                 live=len(live), dead_stripped=dead, absent=missing, duplicates=order.duplicates)


def pinned_sha(path):
    """The sha256 of the first line of a `sha256sum`-format file that is not a comment; None for no such line."""
    for line in read_text(path, "--pinned").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            token = line.split()[0].lower()
            if not re.fullmatch(r"[0-9a-f]{64}", token):
                raise InputError(f"--pinned {path}: `{token}` is not a sha256")
            return token
    return None


def check_binding(order, profdata, pinned):
    if order.sha256 is None:
        return check("binding", False, "the order file has no `# profdata sha256 <hex>` header line")
    sources = {}
    if profdata:
        if not os.path.isfile(profdata):
            raise InputError(f"--profdata {profdata}: no such file")
        sources["profdata"] = runner.sha256_of(profdata)
    if pinned:
        sources["pinned"] = pinned_sha(pinned)
    if not sources:
        return check("binding", False, "nothing to compare the order header's sha256 with: pass --profdata or "
                     "--pinned", sha256=order.sha256)
    differ = {k: v for k, v in sources.items() if v != order.sha256}
    detail = (f"order header sha256 {order.sha256} matches {' and '.join(sources)}" if not differ else
              "; ".join(f"{k} is {v or 'not pinned'}, the order header {order.sha256}" for k, v in differ.items()))
    return check("binding", not differ, detail, sha256=order.sha256, compared=sources)


def check_link_map(link_map, app):
    binary = app_executable(app)
    mapped, built = link_map.text_sections(), binary_text_sections(binary, link_map.arch)
    differ = sorted(f"{seg},{sect}" for (seg, sect) in set(mapped) & set(built)
                    if mapped[(seg, sect)] != built[(seg, sect)])
    if ("__TEXT", "__text") not in mapped or ("__TEXT", "__text") not in built:
        differ.append("__TEXT,__text missing")
    detail = ("the link map's __TEXT sections match the binary" if not differ else
              f"the link map is not of this binary: {', '.join(differ)} differ")
    return check("link-map", not differ, detail, binary=binary)


def page_size_for(arch, explicit):
    return explicit or (16384 if cpu_family(arch) == "arm64" else 4096)


def check_launch_window(records, link_map, pages, page_size, minimum):
    text = link_map.sections.get(("__TEXT", "__text"))
    if text is None:
        raise InputError("the link map has no __TEXT,__text section")
    start = text[0] - text[0] % page_size
    end = start + pages * page_size
    inside, outside, unmapped = [], [], []
    for name in sorted({name for name, _, count in records if count > 0}):
        address = link_map.address_of_function(name)
        (unmapped if address is None else inside if start <= address < end else outside).append(name)
    share = percent(len(inside), len(inside) + len(outside))
    if share is None:
        return check("launch-window", False, "no launch function of the profile is in the link map",
                     unmapped=len(unmapped))
    detail = (f"{share:.2f} % of {len(inside) + len(outside)} launch functions start in the first {pages} pages "
              f"of __TEXT ({page_size} B pages, >= {minimum} %); {len(unmapped)} not in the link map")
    return check("launch-window", share >= minimum, detail, percent=round(share, 2), pages=pages, page_size=page_size,
                 inside=len(inside), outside=outside, unmapped=len(unmapped))


def check_mismatch(fresh, pinned, maximum):
    hashes = {}
    for name, func_hash, _ in pinned:
        hashes.setdefault(name, set()).add(func_hash)
    compared = mismatched = new = 0
    differing = []
    for name, func_hash in sorted({(name, func_hash) for name, func_hash, _ in fresh}):
        if name not in hashes:
            new += 1
        else:
            compared += 1
            if func_hash not in hashes[name]:
                mismatched += 1
                differing.append(name)
    rate = percent(mismatched, compared)
    if rate is None:
        return check("mismatch", False, "no function of the launch profile is in the profdata", new=new)
    detail = (f"{rate:.2f} % of {compared} functions have another hash in the profdata (<= {maximum} %); "
              f"{new} new functions")
    return check("mismatch", rate <= maximum, detail, percent=round(rate, 2), compared=compared, mismatched=differing,
                 new=new)


def run_checks(args):
    order = parse_order(read_text(args.order, "--order"))
    link_map = parse_link_map(read_text(args.link_map, "--link-map"))
    pinned = args.pinned if args.pinned is not None else (DEFAULT_PINNED if os.path.exists(DEFAULT_PINNED) else None)
    results = [check_coverage(order, link_map, args.min_coverage), check_binding(order, args.profdata, pinned)]
    if args.app:
        results.append(check_link_map(link_map, args.app))
    if args.launch_profile:
        tool = runner.profdata_tool(args.llvm_profdata)
        fresh = read_profile(tool, args.launch_profile)
        results.append(check_launch_window(fresh, link_map, args.pages, page_size_for(link_map.arch, args.page_size),
                                           args.min_launch_window))
        if args.profdata:
            results.append(check_mismatch(fresh, read_profile(tool, args.profdata), args.max_mismatch))
    return results


LISTS = ("dead_stripped", "absent", "outside", "mismatched")


def summary(result):
    """The result without its name lists, which only --json keeps."""
    return {key: (len(value) if key in LISTS else value) for key, value in result.items()}


def report(results, json_path):
    for result in results:
        print(f"{result['check']}: {'ok' if result['ok'] else 'FAILED'}: {result['detail']}")
        for key in LISTS:
            names = result.get(key) or []
            for name in names[:SHOWN_MISSING]:
                print(f"    {key}: {name}")
            if len(names) > SHOWN_MISSING:
                print(f"    {key}: ... {len(names) - SHOWN_MISSING} more (--json lists every one)")
    if json_path:
        with open(json_path, "w") as target:
            json.dump({"checks": results}, target, indent=1)
    ok = all(result["ok"] for result in results)
    print("PGO-CHECK " + json.dumps({"ok": ok, "checks": [summary(r) for r in results]}), flush=True)
    return ok


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--order", required=True, help="the order file (Resources/build/cmux-next.order)")
    parser.add_argument("--link-map", help="the link map of the Release link (LD_GENERATE_MAP_FILE); without it "
                        "only the order file is checked against --profdata-sha256")
    parser.add_argument("--app", help="the Release app bundle or its executable; checks the map is of its link")
    parser.add_argument("--launch-profile", help="a launch.profraw of a profile build at the same source")
    parser.add_argument("--profdata", help="the profdata the Release build used (its sha256 and its hashes)")
    parser.add_argument("--pinned", "--profdata-sha256", dest="pinned", help="the pinned profile's sha256 file "
                        "(default Resources/build/cmux-next.profdata.sha256 when it exists)")
    parser.add_argument("--pages", type=int, default=DEFAULT_PAGES, help="pages of the launch window (64)")
    parser.add_argument("--page-size", type=int, help="bytes per page (default 16384 for arm64, 4096 otherwise)")
    parser.add_argument("--min-coverage", type=float, default=MIN_COVERAGE, help="percent (90)")
    parser.add_argument("--min-launch-window", type=float, default=MIN_LAUNCH_WINDOW, help="percent (90)")
    parser.add_argument("--max-mismatch", type=float, default=MAX_MISMATCH, help="percent (20)")
    parser.add_argument("--json", help="write the full report, with every missing name, to this file")
    parser.add_argument("--llvm-profdata", help="llvm-profdata command (default: xcrun llvm-profdata)")
    args = parser.parse_args(argv)
    if args.pages < 1 or (args.page_size is not None and args.page_size < 1):
        parser.error("--pages and --page-size must be positive")
    if not args.link_map and (args.app or args.launch_profile or args.profdata):
        parser.error("--app, --launch-profile and --profdata need --link-map")
    return args


def check_order_only(order_path, sha256_path):
    """The order file against the sha256 file of the profdata the build uses, before a Release link exists."""
    lib = load_order_lib()
    try:
        text = read_text(order_path, "--order")
        profdata_sha = lib.read_sha256_file(sha256_path)
    except (OSError, lib.OrderError) as error:
        raise InputError(str(error))
    problems = lib.check_order(text, profdata_sha)
    for problem in problems:
        print(f"pgo-check: FAIL {problem}")
    if not problems:
        print(f"pgo-check: ok {len(lib.order_symbols(text))} symbols, profdata {profdata_sha}")
    return not problems


def main(argv=None):
    args = parse_args(argv)
    try:
        if not args.link_map:
            return 0 if check_order_only(args.order, args.pinned or DEFAULT_PINNED) else 1
        results = run_checks(args)
    except InputError as error:
        print(f"pgo-check: error: {error}", file=sys.stderr, flush=True)
        return 2
    return 0 if report(results, args.json) else 1


if __name__ == "__main__":
    sys.exit(main())
