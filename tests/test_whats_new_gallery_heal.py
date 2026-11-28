#!/usr/bin/env python3
"""A before whose parent commit sits inside a base red still renders: the parent's build takes each source file it
failed to parse from the base's fix-forward (whats-new-gallery.py heal). 2026-11-27, run 46069736799: parent
b2f1339a had VirtualTranscript.tsx declaring layoutGeometry twice (#51044, fixed by #61071 106 commits later), so
setup-card-classic-import shipped with no before."""
import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "cmux-next", "media", "whats-new-gallery.py")
WORKFLOW = os.path.join(HERE, "..", ".github", "workflows", "whats-new-gallery.yml")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout.strip()


def commit(repo, files, msg):
    for path, text in files.items():
        full = os.path.join(repo, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(text)
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)
    return git(repo, "rev-parse", "HEAD")


class HealTests(unittest.TestCase):
    def test_a_base_red_parent_takes_the_broken_file_from_its_fix_forward(self):
        with tempfile.TemporaryDirectory() as repo:
            git(repo, "init", "-q")
            src = "webviews/src/agent-session/acpmux/VirtualTranscript.tsx"
            gal = "webviews/src/Row.gallery.tsx"
            commit(repo, {src: "import { layoutGeometry } from './g';\n", gal: "a\n"}, "good")
            commit(repo, {src: "import { layoutGeometry } from './g';\nimport { layoutGeometry } from './g';\n"}, "break")
            parent = commit(repo, {"README": "x\n"}, "parent")
            commit(repo, {gal: "b\n"}, "highlight")
            fix = commit(repo, {src: "import { layoutGeometry } from './g';\n"}, "fix forward")
            commit(repo, {src: "import { layoutGeometry, other } from './g';\n"}, "later")
            head = git(repo, "rev-parse", "HEAD")
            log = (f"\x1b[31mRolldownError: [BabelError] {repo}/{src}: Identifier 'layoutGeometry' has already been "
                   f"declared. (2:9)\n  SyntaxError: {repo}/{src}: Identifier 'layoutGeometry' has already been declared.\n"
                   f"[BabelError] {repo}/{gal}: overlaid gallery file\n[BabelError] /elsewhere/x.tsx: not in the tree\n")
            with tempfile.TemporaryDirectory() as tmp:
                log_path = os.path.join(tmp, "build.log")
                plan_path = os.path.join(tmp, "plan.json")
                open(log_path, "w").write(log)
                json.dump([{"parent": parent, "overlay": gal, "commit": head}], open(plan_path, "w"))
                out = subprocess.run([sys.executable, SCRIPT, "heal", "--at", repo, "--parent", parent, "--head", head,
                                      "--log", log_path, "--plan", plan_path], capture_output=True, text=True)
                self.assertEqual(out.returncode, 0, out.stderr)
                self.assertEqual(out.stdout, f"{fix} {src}\n")
                clean = os.path.join(tmp, "clean.log")
                open(clean, "w").write("built in 3s\n")
                out = subprocess.run([sys.executable, SCRIPT, "heal", "--at", repo, "--parent", parent, "--head", head,
                                      "--log", clean], capture_output=True, text=True)
                self.assertEqual((out.returncode, out.stdout), (0, ""), out.stderr)

    def test_the_parent_loop_heals_its_build_at_most_twice(self):
        text = open(WORKFLOW).read()
        loop = text.split("for parent in", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('build_parent "$parent" "$at" "$entries_at"', loop)
        fn = text.split("build_parent() {", 1)[1].split("\n          }\n", 1)[0]
        self.assertIn("for round in 0 1 2", fn)
        self.assertIn('tee "$RUNNER_TEMP/build-$parent.log"', fn)
        self.assertIn("whats-new-gallery.py\" heal", fn)
        self.assertIn('--plan "$out/plan.json"', fn)


if __name__ == "__main__":
    unittest.main()
