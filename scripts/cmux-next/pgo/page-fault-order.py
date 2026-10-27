#!/usr/bin/env python3
"""The order file of the cmux-next Release binary (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 109).

A library: `run-scenarios.py --stage order` records the cold launches and calls it; `pgo/check.py` reads the order
header with it. It makes the order from two sources, both against the final `-profile-use` binary and its link map
(`LD_GENERATE_MAP_FILE=YES`; Release is stripped, so symbols come from the map, not `nm`):

  launch symbols       the launch function list of stage 1 (launch-functions.txt: profile names of the functions
                       that ran before `startup_complete`), each mapped to its linker symbol in the map's
                       `__TEXT,__text`, in the map's address order. Only instrumented code (the CmuxNext Swift
                       targets) is in a profile.
  page-fault symbols   the symbol at each `__TEXT,__text` page fault of the cold launches (System Trace's
                       virtual-memory table, cut at the app's `startup_complete` launch mark in its os-signpost
                       table), in first-fault order: this also covers the Rust, Zig and C code
                       linked into the binary, which has no Swift profile.

The order lists the launch symbols first, then the page-fault symbols not already listed, each line once. Its
header binds it to the profdata (`# profdata sha256 <sha>`, the line launch-functions.txt carries too), so check.py
refuses an order made from another profile than the one the Release build uses.

Chrome makes its Android orderfile the same way: from a build that uses the PGO profile of the same commit, then
checks it (docs/orderfile.md, tools/cygprofile/orderfile_generator_backend.py, check_orderfile.py).
"""
import bisect, dataclasses, os, re, struct

TEXT_SEGMENT, TEXT_SECTION = "__TEXT", "__text"
SHA_HEADER = re.compile(r"^# profdata sha256 ([0-9a-f]{64})\s*$")
SHA_LINE = re.compile(r"^([0-9a-f]{64})\b")


class OrderError(RuntimeError):
    """Inputs that do not make an order (a link map of another binary, a missing header); the reason."""


# The profdata binding.

def header_shas(text):
    """Every profdata sha256 of the `# profdata sha256 <sha>` lines of an order or launch function list."""
    return [match.group(1) for match in map(SHA_HEADER.match, text.splitlines()) if match]


def read_sha256_file(path):
    """The sha256 of a `sha256sum`-format file (`<sha>  cmux-next.profdata`), its first line that is no comment."""
    with open(path) as source:
        for line in source:
            if line.strip() and not line.startswith("#"):
                match = SHA_LINE.match(line.strip().lower())
                if not match:
                    raise OrderError(f"{path}: {line.strip()[:80]!r} is no sha256 line")
                return match.group(1)
    raise OrderError(f"{path} has no sha256 line")


def order_symbols(text):
    """The symbol lines of an order file: no comments, no blank lines."""
    return [line.strip() for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def check_order(text, profdata_sha):
    """The problems of an order file against the profdata the build uses (`profdata_sha`), empty when it passes:
    exactly one profdata header, equal to `profdata_sha`, at least one symbol, no symbol twice."""
    problems = []
    shas = header_shas(text)
    if not shas:
        problems.append("the order has no '# profdata sha256' header line")
    elif len(shas) > 1:
        problems.append(f"the order has {len(shas)} '# profdata sha256' header lines")
    elif shas[0] != profdata_sha:
        problems.append(f"the order was made from profdata {shas[0]}, the build uses {profdata_sha}")
    symbols = order_symbols(text)
    if not symbols:
        problems.append("the order lists no symbol")
    seen, twice = set(), []
    for symbol in symbols:
        if symbol in seen and symbol not in twice:
            twice.append(symbol)
        seen.add(symbol)
    if twice:
        problems.append(f"{len(twice)} symbols are listed twice, first {twice[0]}")
    return problems


# The link map.

@dataclasses.dataclass(frozen=True)
class Symbol:
    address: int
    size: int
    file: int
    name: str


@dataclasses.dataclass
class LinkMap:
    path: str
    arch: str
    objects: dict
    sections: list  # (address, size, segment, section)
    symbols: list  # the live symbols, every section, in map order

    def section(self, segment, name):
        found = [(address, size) for address, size, seg, sect in self.sections if (seg, sect) == (segment, name)]
        if not found:
            raise OrderError(f"the link map has no {segment},{name} section")
        return found[0]


OBJECT_LINE = re.compile(r"^\[\s*(\d+)\]\s(.*)$")
SECTION_LINE = re.compile(r"^0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+(\S+)\s+(\S+)\s*$")
SYMBOL_LINE = re.compile(r"^0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]\s(.*)$")


def parse_link_map(text):
    """A ld64 or ld-prime link map: `# Path:`, `# Arch:`, then the `# Object files:`, `# Sections:` and `# Symbols:`
    blocks. `# Dead Stripped Symbols:` (`<<dead>>` lines) are not in the binary and are left out."""
    path = arch = ""
    objects, sections, symbols, block = {}, [], [], None
    for line in text.splitlines():
        if line.startswith("# Path:"):
            path = line.split(":", 1)[1].strip()
        elif line.startswith("# Arch:"):
            arch = line.split(":", 1)[1].strip()
        elif line.startswith("# Object files:"):
            block = "objects"
        elif line.startswith("# Sections:"):
            block = "sections"
        elif line.startswith("# Symbols:"):
            block = "symbols"
        elif line.startswith("# Dead Stripped Symbols:"):
            block = None
        elif line.startswith("#") or not line.strip():
            continue
        elif block == "objects" and (match := OBJECT_LINE.match(line)):
            objects[int(match.group(1))] = match.group(2)
        elif block == "sections" and (match := SECTION_LINE.match(line)):
            sections.append((int(match.group(1), 16), int(match.group(2), 16), match.group(3), match.group(4)))
        elif block == "symbols" and (match := SYMBOL_LINE.match(line)):
            symbols.append(Symbol(int(match.group(1), 16), int(match.group(2), 16), int(match.group(3)),
                                  match.group(4)))
    if not sections or not symbols:
        raise OrderError("the link map has no sections or no symbols (is it an ld -map file?)")
    return LinkMap(path, arch, objects, sections, symbols)


def object_name(path):
    """How an order file names an object: `bar.o` for `/x/libfoo.a(bar.o)` and for `/x/bar.o`."""
    member = re.search(r"\(([^()]+)\)$", path)
    return member.group(1) if member else os.path.basename(path)


LOCAL_LABEL = re.compile(r"^(?:ltmp\d|l_|L)")  # assembler and linker-private labels: ltmpN, l_..., L...


def is_local_label(name):
    """A label the compiler made, not a function: LLVM's zero-size section label `ltmpN` (arm64 Mach-O), a linker-
    private `l_` or an assembler-local `L` name. ld cannot place one, and it can share a function's address."""
    return bool(LOCAL_LABEL.match(name))


class TextIndex:
    """The code symbols of `__TEXT,__text` by address and by name, local labels left out. Where several symbols
    start at one address, a fault there is the sized one's (then the first by name); a symbol of size 0 runs to the
    next address."""

    def __init__(self, link_map):
        self.link_map = link_map
        start, size = link_map.section(TEXT_SEGMENT, TEXT_SECTION)
        self.start, self.end = start, start + size
        at, self.by_name = {}, {}
        for symbol in sorted({s for s in link_map.symbols if self.start <= s.address < self.end
                              and not is_local_label(s.name)}, key=lambda s: (s.address, s.name)):
            at.setdefault(symbol.address, []).append(symbol)
            self.by_name.setdefault(symbol.name, []).append(symbol)
        self.starts = sorted(at)
        self.symbols = [min(at[address], key=lambda s: (s.size == 0, s.name)) for address in self.starts]
        self.ends = [symbol.address + symbol.size if symbol.size else following
                     for symbol, following in zip(self.symbols, [*self.starts[1:], self.end])]

    def symbol_at(self, address):
        index = bisect.bisect_right(self.starts, address) - 1
        if index >= 0 and address < self.ends[index]:
            return self.symbols[index]
        return None

    def order_line(self, symbol):
        """The order file line of `symbol`: its name, or `object:name` when another `__text` symbol has that name
        (ld's syntax for a static symbol, `man ld`, -order_file)."""
        if len(self.by_name[symbol.name]) == 1:
            return symbol.name
        return f"{object_name(self.link_map.objects.get(symbol.file, ''))}:{symbol.name}"


# The binary.

CPU_TYPES = {"arm64": 0x0100000C, "arm64e": 0x0100000C, "x86_64": 0x01000007}
LC_SEGMENT_64, MH_MAGIC_64 = 0x19, 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF


def macho_text(path, arch):
    """{"vmaddr", "text_address", "text_size"} of the `arch` image of Mach-O `path` (thin or universal): the
    `__TEXT` segment's address and its `__text` section, from the load commands."""
    with open(path, "rb") as source:
        data = source.read()
    offset = 0
    magic = struct.unpack_from(">I", data)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        wanted, count = CPU_TYPES.get(arch), struct.unpack_from(">I", data, 4)[0]
        layout, step = (">iiQQII", 32) if magic == FAT_MAGIC_64 else (">iiIII", 20)
        slices = [struct.unpack_from(layout, data, 8 + i * step) for i in range(count)]
        found = [entry[2] for entry in slices if entry[0] == wanted]
        if not found:
            raise OrderError(f"{path} has no {arch} image")
        offset = found[0]
    if struct.unpack_from("<I", data, offset)[0] != MH_MAGIC_64:
        raise OrderError(f"{path} is no 64-bit Mach-O image")
    ncmds = struct.unpack_from("<I", data, offset + 16)[0]
    command = offset + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, command)
        if cmd == LC_SEGMENT_64:
            segment, vmaddr, _vmsize, _fileoff, _filesize, _max, _init, nsects, _flags = \
                struct.unpack_from("<16sQQQQiiII", data, command + 8)
            if segment.rstrip(b"\0") == TEXT_SEGMENT.encode():
                for index in range(nsects):
                    name, _segment, address, length = struct.unpack_from("<16s16sQQ", data, command + 72 + index * 80)
                    if name.rstrip(b"\0") == TEXT_SECTION.encode():
                        return {"vmaddr": vmaddr, "text_address": address, "text_size": length}
                raise OrderError(f"{path}: the __TEXT segment has no __text section")
        command += size
    raise OrderError(f"{path} has no __TEXT segment")


def check_link_map_matches(link_map, text):
    """Refuses a link map that is not the binary's: its `__TEXT,__text` must have the binary's address and size."""
    address, size = link_map.section(TEXT_SEGMENT, TEXT_SECTION)
    if (address, size) != (text["text_address"], text["text_size"]):
        raise OrderError(f"the link map's __text is {address:#x}+{size:#x}, the binary's "
                         f"{text['text_address']:#x}+{text['text_size']:#x}: the map is of another build")


VMMAP_TEXT = re.compile(r"^__TEXT\s+([0-9A-Fa-f]+)-([0-9A-Fa-f]+)\s")


def text_load_address(vmmap_text, binary):
    """Where the running process mapped the `__TEXT` segment of `binary` (`vmmap -w <pid>`): its lowest `__TEXT`
    region whose path is the binary's."""
    paths = {binary, os.path.realpath(binary)}
    starts = [int(match.group(1), 16) for line in vmmap_text.splitlines()
              if (match := VMMAP_TEXT.match(line)) and any(line.rstrip().endswith(p) for p in paths)]
    if not starts:
        raise OrderError(f"vmmap shows no __TEXT region of {binary}")
    return min(starts)


# The page faults.

ADDRESS_COLUMNS = ("address", "virtual-address", "vm-address", "fault-address")
VM_SCHEMA = re.compile(r"virtual-memory|vm-fault|page-fault|^vm-")


def is_vm_schema(schema):
    """A table of xctrace's Virtual Memory Trace instrument (System Trace template)."""
    return bool(VM_SCHEMA.search(schema))


def cell_int(value):
    """An integer cell of trace.xctrace_rows: an int, or a (value, fmt) pair whose value or fmt is a number."""
    candidates = value if isinstance(value, tuple) else (value,)
    for candidate in candidates:
        if isinstance(candidate, int):
            return candidate
        if isinstance(candidate, str):
            try:
                return int(candidate.replace(",", ""), 0)
            except ValueError:
                continue
    return None


def row_pid(row):
    for column in ("process", "thread"):
        cell = row.get(column)
        if isinstance(cell, dict) and cell.get("pid") is not None:
            return cell["pid"]
    return None


def cell_text(value):
    """A string cell of trace.xctrace_rows: its text, else its `fmt` (an os-log-metadata message has only a fmt)."""
    if isinstance(value, tuple):
        return value[0] if isinstance(value[0], str) and value[0] else value[1]
    return value


SIGNPOST_SCHEMA, SUBSYSTEM, LAUNCH_MARK = "os-signpost", "com.cmuxterm.app.next", "launch.mark"
STARTUP_COMPLETE = "startup_complete"
MARK_MS = re.compile(r"(?:^|\s)ms=([0-9]+(?:\.[0-9]+)?)\b")


def startup_cutoff(rows, pid, mark=STARTUP_COMPLETE):
    """The trace time (ns since the recording began) of process `pid`'s launch mark `mark`, from an os-signpost table:
    the app's `launch.mark` events (LaunchSignposts: `<mark> ms=<ms since process start>`) give its process start
    (the earliest `time - ms`: a mark is emitted at or after the time it names, trace.py's launch_process_start),
    plus the mark's ms. Raises when the app emitted no such mark."""
    starts, marked = [], None
    for row in rows:
        if cell_text(row.get("name")) != LAUNCH_MARK or row_pid(row) != pid:
            continue
        subsystem = cell_text(row.get("subsystem"))
        if subsystem is not None and subsystem != SUBSYSTEM:
            continue
        time = cell_int(row.get("time"))
        message = cell_text(row.get("message")) or cell_text(row.get("format-string")) or ""
        name, _, rest = message.partition(" ")
        ms = MARK_MS.search(rest)
        if time is None or not ms:
            continue
        ms_ns = round(float(ms.group(1)) * 1_000_000)
        starts.append(time - ms_ns)
        if name == mark and marked is None:
            marked = ms_ns
    if marked is None:
        raise OrderError(f"the {SIGNPOST_SCHEMA} table has no {LAUNCH_MARK} {mark} of pid {pid}")
    return min(starts) + marked


def fault_addresses(rows, pid, cutoff_ns=None):
    """The fault addresses of process `pid` in a virtual-memory table (rows of trace.xctrace_rows), in time order
    (the `start` column, else the table's order). With `cutoff_ns` (startup_cutoff), only the faults that started
    by then: a row of `pid` with no start is refused. Raises when no row has an address column."""
    faults, saw_address, columns = [], False, set()
    for position, row in enumerate(rows):
        columns.update(row)
        column = next((c for c in ADDRESS_COLUMNS if row.get(c) is not None), None)
        if column is None:
            continue
        saw_address = True
        address = cell_int(row[column])
        if address is None or row_pid(row) != pid:
            continue
        start = cell_int(row.get("start"))
        if cutoff_ns is not None:
            if start is None:
                raise OrderError(f"a fault of pid {pid} has no start time to cut at {STARTUP_COMPLETE} "
                                 f"(columns: {sorted(row)})")
            if start > cutoff_ns:
                continue
        faults.append((start if start is not None else position, position, address))
    if not saw_address:
        raise OrderError(f"the virtual-memory table has no address column (columns: {sorted(columns)})")
    return [address for _, _, address in sorted(faults)]


def unslid(addresses, load_address, vmaddr):
    """Runtime addresses moved into the link map's address space (ASLR slide = load address - __TEXT vmaddr)."""
    slide = load_address - vmaddr
    return [address - slide for address in addresses]


def first_fault_symbols(addresses, index):
    """The `__text` symbols hit by `addresses` (link map space), each once, in the order of its first fault."""
    seen, ordered = set(), []
    for address in addresses:
        symbol = index.symbol_at(address)
        if symbol is not None and symbol not in seen:
            seen.add(symbol)
            ordered.append(symbol)
    return ordered


def majority(count):
    return count // 2 + 1


def fault_symbols(runs, index, min_runs=None):
    """The symbols that faulted in at least `min_runs` (default a majority) of `runs` (each a list of link map
    addresses in time order), by their median first-fault rank, then address: a symbol one launch happened to
    fault on does not move in and out of the order between refreshes."""
    needed = majority(len(runs)) if min_runs is None else min_runs
    if not runs or not 1 <= needed <= len(runs):
        raise OrderError(f"--min-runs {needed}: there are {len(runs)} recorded cold launches")
    ranks = {}
    for addresses in runs:
        for rank, symbol in enumerate(first_fault_symbols(addresses, index)):
            ranks.setdefault(symbol, []).append(rank)
    kept = [(sorted(r)[(len(r) - 1) // 2], symbol.address, symbol) for symbol, r in ranks.items() if len(r) >= needed]
    return [symbol for _, _, symbol in sorted(kept, key=lambda item: item[:2])], needed


# The launch functions.

LOCAL_PREFIX = re.compile(r"^[^;]*;(.+)$")  # IR PGO name of a local function: `<file>;<name>`
OLD_LOCAL_PREFIX = re.compile(r"^[^:]*\.(?:swift|c|cc|cpp|m|mm|zig|rs|s|S):(.+)$")  # `<file>:<name>`


def linker_names(profile_name):
    """The link map names a profile name can have: a local function loses its `<file>;` or `<file>:` prefix, an
    Objective-C method its `\\1`; C and Swift symbols get the leading underscore, `-[Class method]` has none."""
    name = profile_name.lstrip("\x01")
    match = LOCAL_PREFIX.match(name) or OLD_LOCAL_PREFIX.match(name)
    if match:
        name = match.group(1)
    return ("_" + name, name)


def read_launch_functions(path):
    """(profile names, profdata sha of the header) of stage 1's launch-functions.txt."""
    with open(path) as source:
        text = source.read()
    shas = header_shas(text)
    if len(shas) != 1:
        raise OrderError(f"{path} has {len(shas)} '# profdata sha256' header lines, not one")
    return [line.strip() for line in text.splitlines() if line.strip() and not line.startswith("#")], shas[0]


def launch_symbols(names, index):
    """(the `__text` symbols of the launch functions in address order, the names the map has no symbol for)."""
    found, missing = set(), []
    for name in names:
        symbols = next((index.by_name[c] for c in linker_names(name) if c in index.by_name), None)
        if symbols is None:
            missing.append(name)  # inlined everywhere by -profile-use, or dead-stripped
        else:
            found.update(symbols)
    return sorted(found, key=lambda s: (s.address, s.name)), missing


def order_lines(launch, faults, index):
    """The order: the launch symbols, then the page-fault symbols not already listed; each line once."""
    lines, seen = [], set()
    for symbol in [*launch, *faults]:
        line = index.order_line(symbol)
        if line not in seen:
            seen.add(line)
            lines.append(line)
    return lines


def render_order(profdata_sha, comments, lines):
    header = ["# cmux-next order file (scripts/cmux-next/pgo/run-scenarios.py --stage order)",
              f"# profdata sha256 {profdata_sha}", *(f"# {comment}" for comment in comments)]
    return "\n".join(header + lines) + "\n"
