#!/usr/bin/env python3
"""Tests for polling_scan.py: a polling loop checked into a script or a workflow fails CI."""

import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import polling_scan  # noqa: E402

REASON = "a CI job with no glaeda-gh; bounded by a 15 minute deadline on the job's own token"


class Repo:
    def __init__(self, files, allowlist=None):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        for rel, text in files.items():
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(text))
        self.allowlist = None
        if allowlist is not None:
            self.allowlist = self.root / "polling-allowlist.json"
            self.allowlist.write_text(json.dumps({"entries": allowlist}))
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)

    def scan(self):
        args = ["--root", str(self.root)]
        if self.allowlist:
            args += ["--allowlist", str(self.allowlist)]
        out = subprocess.run([sys.executable, str(HERE / "polling_scan.py"), *args], capture_output=True, text=True)
        self.dir.cleanup()
        return out.returncode, out.stdout


LOOP_SCRIPT = """\
#!/bin/bash
set -euo pipefail
echo start
until gh run view "$1" --exit-status; do
  sleep 30
done
"""

WORKFLOW = """\
name: x
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: Wait for the smoke
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          while :; do
            gh api "repos/$GITHUB_REPOSITORY/actions/runs/${{ github.run_id }}/jobs"
            sleep 30
          done
      - name: Python is not shell
        shell: python
        run: |
          while True:
              subprocess.run(["gh", "run", "view"]); time.sleep(5)
      - run: gh pr checks 5 --watch
"""


class PollingScanTests(unittest.TestCase):
    def test_a_new_loop_in_a_script_fails(self):
        rc, out = Repo({"scripts/wait.sh": LOOP_SCRIPT}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("scripts/wait.sh:4:", out)
        self.assertIn("1 violations", out)

    def test_a_shebang_script_without_an_extension_is_scanned(self):
        rc, out = Repo({"tools/waiter": LOOP_SCRIPT}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("tools/waiter:4:", out)

    def test_workflow_run_blocks_are_scanned_with_their_lines(self):
        rc, out = Repo({".github/workflows/x.yml": WORKFLOW}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn(".github/workflows/x.yml:12:", out)
        self.assertIn(".github/workflows/x.yml:21:", out)  # the one-line gh pr checks --watch
        self.assertIn("2 violations", out)  # not the python step

    def test_an_allowlisted_loop_passes_and_is_counted(self):
        allow = [{"path": "scripts/wait.sh", "match": 'until gh run view "$1" --exit-status; do', "reason": REASON}]
        rc, out = Repo({"scripts/wait.sh": LOOP_SCRIPT}, allow).scan()
        self.assertEqual(rc, 0, out)
        self.assertIn("0 violations, 1 allowlisted", out)

    def test_an_allowlist_entry_needs_a_reason(self):
        allow = [{"path": "scripts/wait.sh", "match": 'until gh run view "$1" --exit-status; do', "reason": ""}]
        rc, out = Repo({"scripts/wait.sh": LOOP_SCRIPT}, allow).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("needs a reason", out)

    def test_a_stale_allowlist_entry_fails(self):
        allow = [{"path": "scripts/gone.sh", "match": "while :; do", "reason": REASON}]
        rc, out = Repo({"scripts/ok.sh": "#!/bin/sh\necho ok\n"}, allow).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("matches no loop", out)

    def test_loops_through_a_local_github_function_fail(self):
        script = """\
        #!/usr/bin/env bash
        read_api() {
          gh api "$@"
        }
        while true; do
          read_api repos/o/r/issues/1/comments
          sleep 60
        done
        """
        rc, out = Repo({"scripts/reviews.sh": script}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("scripts/reviews.sh:5:", out)

    def test_text_that_only_mentions_a_loop_passes(self):
        script = """\
        #!/bin/bash
        # until gh run view 1; do sleep 5; done
        echo 'while true; do gh run view 1; sleep 5; done'
        cat <<'EOF'
        while :; do gh pr checks 1; sleep 5; done
        EOF
        for pr in 1 2 3; do gh pr view "$pr"; done
        glaeda-gh wait run o/r/1 --timeout 600
        """
        rc, out = Repo({"scripts/ok.sh": script, "README.md": "while :; do gh run view; sleep 1; done\n"}).scan()
        self.assertEqual(rc, 0, out)

    def test_a_one_line_github_function_counts(self):
        script = "#!/bin/bash\nread_api() { gh api \"$@\"; }\nuntil read_api repos/o/r/pulls/1; do sleep 30; done\n"
        rc, out = Repo({"scripts/inline.sh": script}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("scripts/inline.sh:3:", out)

    def test_a_bounded_file_wait_is_still_a_wait_in_a_file(self):
        script = "#!/bin/bash\nend=$((SECONDS + 60))\nwhile [ ! -s out.txt ] && [ $SECONDS -lt $end ]; do sleep 1; done\n"
        rc, out = Repo({"scripts/bounded.sh": script}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("scripts/bounded.sh:3:", out)

    def test_a_heredoc_script_inside_a_substitution_is_data(self):
        script = ("#!/bin/bash\ncode=$(cat <<'PERL'\nwhile ($b =~ s/\\A([^\\n]*)\\n//) { next unless -e $f; sleep 1; }\n"
                  "print \"it's (odd\";\nPERL\n)\nperl -e \"$code\"\n")
        rc, out = Repo({"scripts/perl.sh": script}).scan()
        self.assertEqual(rc, 0, out)

    def test_a_shell_script_with_another_suffix_is_scanned_by_its_shebang(self):
        rc, out = Repo({"tools/runner.py": LOOP_SCRIPT}).scan()
        self.assertEqual(rc, 1, out)

    def test_shell_paths_options_and_defaults_are_shell(self):
        loop = "          while true; do gh run view 1; sleep 1; done\n"
        wf = ("defaults:\n  run:\n    shell: bash -e {0}\njobs:\n  a:\n    steps:\n"
              "      - shell: /bin/bash\n        run: |\n" + loop +
              "      - shell: bash -euo pipefail {0}\n        run: |\n" + loop +
              "      - run: |\n" + loop)
        rc, out = Repo({".github/workflows/s.yml": wf}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("3 violations", out)

    def test_defaults_never_skip_a_block(self):
        loop = "          while true; do gh run view 1; sleep 1; done\n"
        wf = ("defaults:\n  run:\n    shell: python\njobs:\n  a:\n    steps:\n      - run: |\n" + loop +
              "    defaults: # use bash\n      run:\n        shell: bash\n")
        rc, out = Repo({".github/workflows/d.yml": wf}).scan()
        self.assertEqual(rc, 1, out)

    def test_env_with_options_is_scanned(self):
        wf = ("jobs:\n  a:\n    steps:\n      - shell: /usr/bin/env -u python bash {0}\n        run: |\n"
              "          while true; do gh run view 1; sleep 1; done\n")
        rc, out = Repo({".github/workflows/u.yml": wf}).scan()
        self.assertEqual(rc, 1, out)

    def test_a_steps_own_python_shell_is_not_scanned(self):
        wf = ("jobs:\n  a:\n    steps:\n      - shell: python\n        run: |\n"
              "          while true; do gh run view 1; sleep 1; done\n")
        rc, out = Repo({".github/workflows/p.yml": wf}).scan()
        self.assertEqual(rc, 0, out)

    def test_unusual_yaml_spellings_are_read(self):
        loop = "while true; do gh run view 1; sleep 1; done"
        wf = ("jobs:\n  a:\n    steps:\n"
              "      -   name: Python\n          shell: python\n          run: print(1)\n"
              "      -   run: |\n            " + loop + "\n          shell: bash\n"
              "      - {shell: bash, run: '" + loop + "'}\n"
              "      - 'run': '" + loop + "'\n")
        rc, out = Repo({".github/workflows/y.yml": wf}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("3 violations", out)

    def test_a_workflow_that_does_not_parse_fails(self):
        rc, out = Repo({".github/workflows/bad.yml": "jobs: [\n"}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("could not read this workflow", out)

    def test_judge_gaps_from_review(self):
        files = {
            "a.sh": "#!/bin/bash\nwhile [ 1 ]; do gh api x; done\n",
            "b.sh": "#!/bin/bash\nwhile :; do gh api x -f seen=\"$SECONDS\"; done\n",
            "c.sh": ("#!/bin/bash\npython3 - <<'PY'\nimport subprocess, time\nfor _ in range(60):\n"
                     "    subprocess.run([\"gh\", \"api\", \"x\"])\n    time.sleep(10)\nPY\n"),
            "d.sh": "#!/bin/bash\nwhile [[ 1 ]]; do gh api x; done\n",
        }
        rc, out = Repo(files).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("4 violations", out)

    def test_loop_words_in_a_python_string_are_not_a_loop(self):
        script = ("#!/bin/bash\npython3 - <<'PY'\nimport subprocess, time\nprint(\"Waiting for GitHub\")  # while it starts\n"
                  "time.sleep(1)\nsubprocess.run([\"gh\", \"api\", \"rate_limit\"])\nPY\n")
        rc, out = Repo({"scripts/once.sh": script}).scan()
        self.assertEqual(rc, 0, out)

    def test_interpreter_loops_are_read_as_code(self):
        def py(code):
            return "#!/bin/bash\npython3 - <<'PY'\n" + code + "PY\n"

        def js(code):
            return "#!/bin/bash\nnode - <<'JS'\n" + code + "JS\n"
        polls = {
            "p1.sh": py("import subprocess, time\nfor _ in range(60):\n    subprocess.run([\"gh\", \"api\", \"x\"])\n"
                        "    time.sleep(10)\n"),
            "j1.sh": js("const x = 0; for (;;) { setTimeout(f, 9); fetch(\"https://api.github.com/x\"); }\n"),
        }
        rc, out = Repo(polls).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("2 violations", out)
        once = {
            "p2.sh": py('"""\nfor x in values:\n    time.sleep(1)\n"""\nimport subprocess, time\ntime.sleep(1)\n'
                        'subprocess.run(["gh", "api", "rate_limit"])\n'),
            "j2.sh": js("// for (;;) setInterval(\nconsole.log(\"setInterval(\"); setTimeout(f, 1);\n"
                        "fetch(\"https://api.github.com/x\");\n"),
        }
        rc, out = Repo(once).scan()
        self.assertEqual(rc, 0, out)

    def test_indented_gh_commands_and_docstrings(self):
        def py(code):
            return "#!/bin/bash\npython3 - <<'PY'\n" + code + "PY\n"
        poll = py("import subprocess, time\nwhile True:\n    subprocess.run(\"\\n  gh api rate_limit\", shell=True)\n"
                  "    time.sleep(5)\n")
        rc, out = Repo({"p.sh": poll}).scan()
        self.assertEqual(rc, 1, out)
        doc = py("import time\nfor i in range(3):\n    def f():\n        \"\"\"api.github.com\"\"\"\n"
                 "    \"\"\"see api.github.com\"\"\"\n    time.sleep(1)\n")
        rc, out = Repo({"d.sh": doc}).scan()
        self.assertEqual(rc, 0, out)

    def test_python_helpers_and_gh_options(self):
        def py(code):
            return "#!/bin/bash\npython3 - <<'PY'\n" + code + "PY\n"
        polls = {
            "h.sh": py("import subprocess, time\ndef fetch():\n    subprocess.run(\"gh api rate_limit\", shell=True)\n"
                       "while True:\n    fetch()\n    time.sleep(5)\n"),
            "o.sh": py("import subprocess, time\nwhile True:\n    subprocess.run(\"gh -R o/r api x\", shell=True)\n"
                       "    time.sleep(5)\n"),
            "q.sh": py("import subprocess, time\nwhile True:\n    subprocess.run(\"gh --repo=o/r run view 1\", shell=True)\n"
                       "    time.sleep(5)\n"),
        }
        rc, out = Repo(polls).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("3 violations", out)

    def test_a_method_call_is_not_a_same_named_local_function(self):
        code = ("#!/bin/bash\npython3 - <<'PY'\nimport subprocess, time\ndef run():\n"
                "    subprocess.run([\"gh\", \"api\", \"rate_limit\"])\nrun()\n"
                "while subprocess.run([\"test\", \"-e\", \"/tmp/ready\"]).returncode:\n    time.sleep(1)\nPY\n")
        rc, out = Repo({"m.sh": code}).scan()
        self.assertEqual(rc, 0, out)

    def test_a_one_line_wrapper_with_a_trailing_comment_counts(self):
        script = "#!/bin/bash\napi() { gh api \"$@\"; }  # helper\nwhile :; do api x; sleep 9; done\n"
        rc, out = Repo({"scripts/c.sh": script}).scan()
        self.assertEqual(rc, 1, out)

    def test_a_comment_right_after_a_substitution_opens_is_data(self):
        script = "#!/bin/bash\nx=$(# it's (odd\necho hi)\necho \"$x\"\n"
        rc, out = Repo({"scripts/d.sh": script}).scan()
        self.assertEqual(rc, 0, out)

    def test_file_wait_loops_fail(self):
        script = "#!/bin/bash\nuntil [ -s out.txt ]; do sleep 5; done\n"
        rc, out = Repo({"scripts/f.sh": script}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("scripts/f.sh:2:", out)

    def test_a_slow_poll_is_still_a_poll_in_a_file(self):
        # The hook lets an agent sleep 300 s between reads; a checked-in loop runs again and again, so not here.
        script = "#!/bin/bash\nwhile :; do\n  gh run view 1 && break\n  sleep 600\ndone\n"
        rc, out = Repo({"scripts/slow.sh": script}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("scripts/slow.sh:2:", out)

    def test_quoted_shell_and_multiline_plain_run_are_scanned(self):
        wf = ("jobs:\n  a:\n    steps:\n      - shell: \"bash\"\n        run: |\n"
              "          while true; do gh run view 1; sleep 1; done\n"
              "      - run: while true; do\n          gh run view 1;\n          sleep 1;\n          done\n")
        rc, out = Repo({".github/workflows/q.yml": wf}).scan()
        self.assertEqual(rc, 1, out)
        self.assertIn("2 violations", out)

    def test_run_blocks_parse_single_line_and_quoted_values(self):
        blocks = polling_scan.run_blocks("steps:\n  - run: 'echo ${{ x }}'\n  - run: echo hi\n")
        self.assertEqual(blocks, [(2, "echo GH_EXPR"), (3, "echo hi")])


if __name__ == "__main__":
    unittest.main()
