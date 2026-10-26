#!/usr/bin/env python3
"""Checks the cmux-next order file against the profdata the Release build uses (p08-startup.md, section F).

    python3 scripts/cmux-next/pgo/check.py --order Resources/build/cmux-next.order \\
        [--profdata-sha256 Resources/build/cmux-next.profdata.sha256]

The order (run-scenarios.py --stage order, task 109) is made from the `-profile-use` binary of one profdata and
names its sha256 in a `# profdata sha256 <sha>` header line. The check refuses an order whose header names another
profdata than the build's sha256 file (052), one without that header, one with no symbol and one that lists a
symbol twice. Task 053 adds the link map coverage and the launch-profile placement. A manual check: not in CI.

Exit codes: 0 the order passes, 1 it fails (each problem printed), 2 an input is missing or unreadable.
"""
import argparse, importlib.util, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
DEFAULT_SHA256 = os.path.join(REPO, "Resources", "build", "cmux-next.profdata.sha256")


def load_order_lib():
    name = "page_fault_order"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "page-fault-order.py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--order", required=True, help="the order file (Resources/build/cmux-next.order)")
    parser.add_argument("--profdata-sha256", default=DEFAULT_SHA256,
                        help="the sha256 file of the profdata the build uses (default %(default)s)")
    args = parser.parse_args(argv)
    lib = load_order_lib()
    try:
        with open(args.order) as source:
            text = source.read()
        profdata_sha = lib.read_sha256_file(args.profdata_sha256)
    except (OSError, lib.OrderError) as error:
        print(f"pgo-check: error: {error}", file=sys.stderr)
        return 2
    problems = lib.check_order(text, profdata_sha)
    for problem in problems:
        print(f"pgo-check: FAIL {problem}")
    if problems:
        return 1
    print(f"pgo-check: ok {len(lib.order_symbols(text))} symbols, profdata {profdata_sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
