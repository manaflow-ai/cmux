"""A measure script that copies a harness copies every local module the harness imports.

scripts/measure/*.sh copy their Python harnesses out of the checkout before they check out the commits they compare,
so the harness that runs is this commit's. update-click-ab.sh copied scripts/cmux-next/update-harness but not
scripts/cmux-next/tag_teardown.py, which run.py imports from its parent folder, and every round died with
`ModuleNotFoundError: No module named 'tag_teardown'` after the builds (cmux#44627). This reads each script's
`cp` commands, and for each copied Python file reads its imports with ast; a local module (one beside the file or in
its parent folder in the checkout) must be in the copied set too, and so must the modules that one imports.
"""
import ast
import re
import shlex
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MEASURE = ROOT / "scripts" / "measure"


def copy_commands(text):
    """Each `cp` command in a shell script as (sources, destination), joined across `\\` line ends and split at
    `&&`, `||`, `;` and `|`."""
    text = re.sub(r"\\\n", " ", text)
    commands = []
    for line in text.splitlines():
        line = line.split(" #", 1)[0]
        for part in re.split(r"&&|\|\||;|\|", line):
            try:
                words = shlex.split(part, posix=True)
            except ValueError:
                continue
            if not words or words[0] != "cp":
                continue
            paths = [w for w in words[1:] if not w.startswith("-")]
            if len(paths) >= 2:
                commands.append((paths[:-1], paths[-1]))
    return commands


def copied_sources(text, root):
    """The checkout paths a script copies: files, and every file under a copied folder."""
    copied = set()
    for sources, _ in copy_commands(text):
        for source in sources:
            if "$" in source or source.startswith("/"):
                continue
            path = (root / source).resolve()
            if path.is_dir():
                copied.update(p for p in path.rglob("*") if p.is_file())
            elif path.is_file():
                copied.add(path)
    return copied


def imported_names(path):
    """Top-level names a Python file imports (absolute imports only; a relative import is inside its package)."""
    try:
        tree = ast.parse(path.read_text(), filename=str(path))
    except (SyntaxError, UnicodeDecodeError):
        return set()
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and not node.level and node.module:
            names.add(node.module.split(".")[0])
    return names


def local_module(name, importer):
    """The checkout file `import name` reaches from `importer`'s folder or its parent folder (run.py puts both on
    sys.path), or None for a module outside the checkout."""
    for folder in (importer.parent, importer.parent.parent):
        for candidate in (folder / f"{name}.py", folder / name / "__init__.py"):
            if candidate.is_file():
                return candidate.resolve()
    return None


def missing_imports(text, root):
    """(importer, module) for each local module a copied Python file imports that the script does not copy,
    following the modules it does copy."""
    copied = copied_sources(text, root)
    missing = []
    queue = sorted(p for p in copied if p.suffix == ".py")
    seen = set(queue)
    while queue:
        importer = queue.pop(0)
        for name in sorted(imported_names(importer)):
            module = local_module(name, importer)
            if module is None or module == importer:
                continue
            if module not in copied:
                missing.append((importer.relative_to(root), module.relative_to(root)))
            elif module not in seen:
                seen.add(module)
                queue.append(module)
    return missing


class HarnessCopyImportsTests(unittest.TestCase):
    def test_every_measure_script_copies_what_its_copied_harness_imports(self):
        scripts = sorted(MEASURE.glob("*.sh"))
        self.assertTrue(scripts)
        problems = []
        for script in scripts:
            for importer, module in missing_imports(script.read_text(), ROOT):
                problems.append(f"{script.relative_to(ROOT)}: copies {importer}, which imports {module}; copy it too")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_old_update_click_ab_copy_is_refused(self):
        # update-click-ab.sh before cmux#44627: the harness folder and the summary, not tag_teardown.py.
        old = ('tools="$out/tools" && mkdir -p "$tools" && cp -R scripts/cmux-next/update-harness "$tools/" '
               '&& cp scripts/measure/update-click-ab.py "$tools/"\n')
        missing = missing_imports(old, ROOT)
        self.assertIn((Path("scripts/cmux-next/update-harness/run.py"), Path("scripts/cmux-next/tag_teardown.py")),
                      missing)
        fixed = old.rstrip("\n") + ' \\\n    && cp scripts/cmux-next/tag_teardown.py "$tools/"  # run.py imports it\n'
        self.assertEqual(missing_imports(fixed, ROOT), [])

    def test_follows_a_copied_module_into_its_own_imports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "h").mkdir()
            (root / "h" / "run.py").write_text("import json\nfrom helper import x\n")
            (root / "helper.py").write_text("import deeper\n")
            (root / "deeper.py").write_text("")
            missing = missing_imports('cp -R h "$t/" && cp helper.py "$t/"\n', root)
            self.assertEqual(missing, [(Path("helper.py"), Path("deeper.py"))])
            self.assertEqual(missing_imports('cp -R h "$t/" && cp helper.py deeper.py "$t/"\n', root), [])


if __name__ == "__main__":
    unittest.main()
