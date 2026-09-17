#!/usr/bin/env python3
"""Audit locked dependencies; reject RSA if an optional SQLx feature enables it."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
# Cargo locks disabled optional dependencies too. SQLx's MySQL driver pulls RSA,
# but v3 only enables Postgres. This exception is invalid if any target selects it.
tree = subprocess.check_output(
    ['cargo', 'tree', '--workspace', '--locked', '--target', 'all',
     '--edges', 'normal,build,dev', '--prefix', 'none', '--format', '{p}'],
    cwd=root, text=True)
if any(line.startswith('rsa ') for line in tree.splitlines()):
    sys.exit('RSA entered the selected graph; RUSTSEC-2023-0071 exception is invalid')
print('Verified: optional MySQL RSA dependency is absent from all selected targets.', flush=True)
sys.exit(subprocess.run(['cargo', 'audit', '--ignore', 'RUSTSEC-2023-0071'], cwd=root).returncode)
