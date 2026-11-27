#!/usr/bin/env python3
"""Retired classic-local acpmux probe; NEXT has its own keyed-start harness."""
import sys


if __name__ == "__main__":
    sys.exit(
        "The classic-local acpmux person-key probe is retired.\n"
        "From the repository root, use the NEXT development Cloud harness:\n"
        "  python3 -I scripts/cmux-next/acpmux-app-keyed-start-e2e.py --out <dir> < secrets\n"
        "Run that command with --help for options; its module docstring describes credentials.\n"
        "No credentials were read and no machine was created."
    )
