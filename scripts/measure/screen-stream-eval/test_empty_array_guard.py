"""An array that can stay empty is expanded with the ${a[@]+"${a[@]}"} guard in the eval's scripts.

The fleet Macs run these scripts with macOS's bash 3.2 under `set -u`, where "${a[@]}" of an empty
array aborts with "a[@]: unbound variable" (bash 4.4 and later expand it to nothing, so Linux CI
never sees it). targets/rd.sh's bench call expanded an empty `eval_flags` on every two-Mac run (a
viewer that is not 127.0.0.1 adds no flag), and every two-Mac rd view failed at once (2026-11-19).
"""
import re
import shutil
import subprocess
import unittest
from pathlib import Path

HERE = Path(__file__).parent
SCRIPTS = [HERE.parent / 'screen-stream-eval.sh', *sorted(HERE.glob('**/*.sh'))]
EMPTY_INIT = re.compile(r'(?:local\s+|declare\s+-a\s+)?([A-Za-z_][A-Za-z0-9_]*)=\(\)')
UNGUARDED = '"${%s[@]}"'
GUARDED = '${%s[@]+"${%s[@]}"}'


def unguarded_expansions(text):
    """(line number, array name) for each "${a[@]}" of an array the script starts out empty."""
    empty = set(EMPTY_INIT.findall(text))
    found = []
    for number, line in enumerate(text.splitlines(), 1):
        for name in empty:
            if UNGUARDED % name in line.replace(GUARDED % (name, name), ''):
                found.append((number, name))
    return found


class EmptyArrayGuardTests(unittest.TestCase):
    def test_no_script_expands_a_maybe_empty_array_unguarded(self):
        bad = [f'{path.relative_to(HERE.parent)}:{n}: "${{{name}[@]}}"'
               for path in SCRIPTS for n, name in unguarded_expansions(path.read_text())]
        self.assertEqual(bad, [], 'use ${a[@]+"${a[@]}"} (bash 3.2 + set -u aborts on an empty array)')

    def test_the_check_finds_the_old_rd_bench_line(self):
        old = 'f() {\n  local eval_flags=()\n  "$rd" bench "${eval_flags[@]}" --addr x\n}\n'
        self.assertEqual(unguarded_expansions(old), [(3, 'eval_flags')])
        self.assertEqual(unguarded_expansions(old.replace('"${eval_flags[@]}"', GUARDED % ('eval_flags', 'eval_flags'))), [])

    def test_the_guard_expands_to_nothing_and_to_each_word(self):
        bash = shutil.which('bash')
        if bash is None:
            self.skipTest('no bash')
        script = 'set -u; a=(); printf "<%s>" ${a[@]+"${a[@]}"}; echo; a=("x y" z); printf "<%s>" ${a[@]+"${a[@]}"}'
        out = subprocess.run([bash, '-c', script], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.splitlines(), ['<>', '<x y><z>'])


if __name__ == '__main__':
    unittest.main()
