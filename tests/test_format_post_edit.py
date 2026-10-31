#!/usr/bin/env python3
"""The Claude Code and Codex post-edit hooks format exactly the file an edit touched.

Many agents share one checkout, so the hook must format only the edited file,
with the formatter version CI pins, from whatever directory the agent's shell
is in, and never fail the edit. The fixtures run the hook commands exactly as
.claude/settings.json and .codex/hooks.json spell them, against a recording
vp and rustfmt, so no real toolchain is needed. One test also drives the real
webviews vp when it is installed (the react-apps-check job installs it).
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
HOOK = "scripts/ci/format-post-edit.sh"
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI",
              "CODEX_THREAD_ID", "CODEX_SANDBOX", "CLAUDE_PROJECT_DIR", "CMUX_SKIP_FORMAT_HOOKS")
UNFORMATTED = "const   value=1\n"
FORMATTED = "const value = 1;\n"

# Rewrites UNFORMATTED to FORMATTED in each path argument and records one
# "cwd<TAB>args" line per run, so a test can see which files each run touched.
FAKE_VP = r"""#!/usr/bin/env python3
import os, sys
with open(os.environ["FAKE_VP_LOG"], "a") as log:
    log.write(os.getcwd() + "\t" + " ".join(sys.argv[1:]) + "\n")
for arg in sys.argv[2:]:
    if arg.startswith("-"):
        continue
    with open(arg) as handle:
        text = handle.read()
    with open(arg, "w") as handle:
        handle.write(text.replace("const   value=1\n", "const value = 1;\n"))
"""

# Formats stdin to stdout ("fn main(){}" gains spaces) and records its arguments.
FAKE_RUSTFMT = """#!/bin/sh
printf '%s %s\\n' "{name}" "$*" >> "$FAKE_RUSTFMT_LOG"
sed 's/fn main(){{}}/fn main() {{}}/'
"""

# `rustup which --toolchain X rustfmt` prints the pinned rustfmt only for an
# installed toolchain, like the real one.
FAKE_RUSTUP = """#!/bin/sh
if [ "$1" = which ] && [ "$2" = --toolchain ] && [ "$3" = "{installed}" ] && [ "$4" = rustfmt ]; then
    echo "{pinned}"
    exit 0
fi
echo "error: toolchain '$3' is not installed" >&2
exit 1
"""

FAKE_BUN = """#!/bin/sh
printf '%s %s\\n' "$(pwd)" "$*" >> "$FAKE_BUN_LOG"
"""


class FormatPostEditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-format-post-edit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repository"
        self.repo.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key not in AGENT_VARS}
        self.global_config = self.root / "gitconfig"
        self.global_config.write_text("")
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.global_config),
                        HOME=str(self.root))
        git_fixture_env.without_auto_maintenance(self.env)
        subprocess.run(["git", "init", "--quiet", "--initial-branch=main", str(self.repo)],
                       env=self.env, check=True, capture_output=True)
        for relative in (HOOK, ".claude/settings.json", ".codex/hooks.json"):
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / relative, target)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.vp_log = self.root / "vp.log"
        self.rustfmt_log = self.root / "rustfmt.log"
        self.bun_log = self.root / "bun.log"
        self.env.update(FAKE_VP_LOG=str(self.vp_log), FAKE_RUSTFMT_LOG=str(self.rustfmt_log),
                        FAKE_BUN_LOG=str(self.bun_log))
        self.env["PATH"] = f"{self.bin}:{self.env.get('PATH', '/usr/bin:/bin')}"

    # Fixtures

    def tool(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def webviews(self, vite_plus="1.0.0", oxfmt="0.70.0", installed=("1.0.0", "0.70.0")):
        """A vite-plus webviews package whose bun.lock pins vite_plus and oxfmt."""
        web = self.repo / "webviews"
        (web / "src").mkdir(parents=True, exist_ok=True)
        (web / "package.json").write_text(json.dumps({"devDependencies": {"vite-plus": vite_plus}}))
        (web / "bun.lock").write_text(
            "{\n  \"packages\": {\n"
            f"    \"oxfmt\": [\"oxfmt@{oxfmt}\", \"\", {{}}, \"sha512-x\"],\n"
            f"    \"vite-plus\": [\"vite-plus@{vite_plus}\", \"\", {{ \"dependencies\": {{ \"oxfmt\": \"={oxfmt}\" }} }}, \"sha512-y\"],\n"
            "  }\n}\n")
        self.tool(web / "node_modules/.bin/vp", FAKE_VP)
        for name, version in zip(("vite-plus", "oxfmt"), installed):
            manifest = web / "node_modules" / name / "package.json"
            manifest.parent.mkdir(parents=True, exist_ok=True)
            manifest.write_text(json.dumps({"name": name, "version": version}))
        return web

    def edit(self, relative, text=UNFORMATTED):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def hook_commands(self, agent):
        if agent == "claude":
            config = json.loads((self.repo / ".claude/settings.json").read_text())
        else:
            config = json.loads((self.repo / ".codex/hooks.json").read_text())
        commands = [hook["command"] for group in config["hooks"]["PostToolUse"]
                    for hook in group["hooks"] if "format-post-edit" in hook["command"]]
        self.assertEqual(len(commands), 1, commands)
        return commands[0]

    def payload(self, agent, path, cwd):
        if agent == "claude":
            return {"hook_event_name": "PostToolUse", "tool_name": "Edit", "cwd": str(cwd),
                    "tool_input": {"file_path": str(path)}}
        # Codex patch paths are relative to the session working directory.
        relative = os.path.relpath(path, cwd)
        patch = f"*** Begin Patch\n*** Update File: {relative}\n@@\n-old\n+new\n*** End Patch\n"
        return {"hook_event_name": "PostToolUse", "tool_name": "apply_patch", "cwd": str(cwd),
                "tool_input": {"command": patch}}

    def start_hook(self, agent, path, cwd=None, **env):
        cwd = cwd or self.repo
        run_env = dict(self.env, **env)
        if agent == "claude":
            run_env["CLAUDE_PROJECT_DIR"] = str(self.repo)
        process = subprocess.Popen(["bash", "-c", self.hook_commands(agent)], cwd=cwd, env=run_env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        process.stdin.write(json.dumps(self.payload(agent, path, cwd)))
        process.stdin.close()
        return process

    def run_hook(self, agent, path, cwd=None, **env):
        process = self.start_hook(agent, path, cwd, **env)
        stdout, stderr = process.stdout.read(), process.stderr.read()
        process.wait(timeout=60)
        process.stdout.close()
        process.stderr.close()
        return process.returncode, stdout, stderr

    def assert_hook_ok(self, agent, returncode, stdout):
        self.assertEqual(returncode, 0)
        if agent == "codex":
            # Codex parses the hook's stdout as JSON.
            self.assertEqual(json.loads(stdout), {})

    def vp_runs(self):
        if not self.vp_log.exists():
            return []
        return [line.split("\t", 1) for line in self.vp_log.read_text().splitlines()]

    # Tests

    def test_an_edit_made_from_a_subdirectory_is_formatted(self):
        # Agents `cd webviews` to run bun; the hook command must still resolve.
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                web = self.webviews()
                path = self.edit(f"webviews/src/{agent}.ts")
                returncode, stdout, stderr = self.run_hook(agent, path, cwd=web)
                self.assert_hook_ok(agent, returncode, stdout)
                self.assertEqual(path.read_text(), FORMATTED, stderr)

    def test_an_edit_made_from_the_checkout_root_is_formatted(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                self.webviews()
                path = self.edit(f"webviews/src/root-{agent}.tsx")
                returncode, stdout, stderr = self.run_hook(agent, path)
                self.assert_hook_ok(agent, returncode, stdout)
                self.assertEqual(path.read_text(), FORMATTED, stderr)
                self.assertEqual(stderr, "", "a clean format is silent")

    def test_concurrent_edits_each_format_only_their_own_file(self):
        self.webviews()
        first = self.edit("webviews/src/first.ts")
        second = self.edit("webviews/src/second.ts")
        # Another agent's unsaved work in the same checkout.
        bystander = self.edit("webviews/src/bystander.ts")
        processes = [self.start_hook("claude", first), self.start_hook("codex", second)]
        for process in processes:
            process.wait(timeout=60)
            process.stdout.close()
            process.stderr.close()
            self.assertEqual(process.returncode, 0)
        self.assertEqual(first.read_text(), FORMATTED)
        self.assertEqual(second.read_text(), FORMATTED)
        self.assertEqual(bystander.read_text(), UNFORMATTED)
        touched = sorted(args.split()[-1] for _, args in self.vp_runs())
        self.assertEqual(touched, ["src/first.ts", "src/second.ts"])

    def test_cmux_tui_web_frontend_edits_use_its_own_vp(self):
        frontend = self.repo / "cmux-tui/frontends/web"
        frontend.mkdir(parents=True)
        (frontend / "package.json").write_text(json.dumps({"devDependencies": {"vite-plus": "1.0.0"}}))
        self.tool(frontend / "node_modules/.bin/vp", FAKE_VP)
        path = self.edit("cmux-tui/frontends/web/src/app.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertEqual(path.read_text(), FORMATTED, stderr)
        self.assertEqual([Path(cwd) for cwd, _ in self.vp_runs()], [frontend])

    def test_stale_webviews_packages_are_reinstalled_from_the_lockfile_first(self):
        # node_modules from before a vite-plus bump would format differently from CI.
        self.webviews(installed=("0.9.0", "0.60.0"))
        self.tool(self.bin / "bun", FAKE_BUN)
        path = self.edit("webviews/src/stale.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        installs = self.bun_log.read_text().splitlines() if self.bun_log.exists() else []
        self.assertEqual(len(installs), 1, stderr)
        self.assertIn("install --frozen-lockfile --ignore-scripts", installs[0])

    def test_a_lock_left_by_a_killed_install_does_not_block_later_installs(self):
        # A hook killed mid-install (the agent's hook timeout) leaves its lock behind.
        self.webviews(installed=("0.9.0", "0.60.0"))
        self.tool(self.bin / "bun", FAKE_BUN)
        dead = subprocess.Popen(["true"])
        dead.wait()
        lock = self.repo / ".git/cmux-format-install-webviews.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{dead.pid}\n")
        path = self.edit("webviews/src/stale.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        installs = self.bun_log.read_text().splitlines() if self.bun_log.exists() else []
        self.assertEqual(len(installs), 1, stderr)
        self.assertFalse(lock.exists(), "the hook releases the lock it took over")

    def test_a_live_install_lock_is_respected(self):
        self.webviews(installed=("0.9.0", "0.60.0"))
        self.tool(self.bin / "bun", FAKE_BUN)
        lock = self.repo / ".git/cmux-format-install-webviews.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{os.getpid()}\n")
        path = self.edit("webviews/src/stale.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertFalse(self.bun_log.exists(), stderr)
        self.assertIn("another agent is installing", stderr)
        self.assertTrue(lock.exists())

    def test_a_taken_over_hook_leaves_its_successors_lock_alone(self):
        # The install outlives the takeover age: a successor takes the lock over
        # mid-install (simulated by the fake bun), and the first hook's exit must
        # not remove the successor's lock.
        self.webviews(installed=("0.9.0", "0.60.0"))
        lock = self.repo / ".git/cmux-format-install-webviews.lock"
        self.tool(self.bin / "bun", FAKE_BUN + 'printf "%s\\n" "$SUCCESSOR_PID" > "$LOCK/pid"\n')
        self.env.update(LOCK=str(lock), SUCCESSOR_PID=str(os.getpid()))
        path = self.edit("webviews/src/stale.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertTrue(self.bun_log.exists(), stderr)
        self.assertTrue(lock.is_dir(), "the successor's lock survives the first hook's exit")
        self.assertEqual((lock / "pid").read_text().strip(), str(os.getpid()))

    def test_a_held_lock_with_an_empty_pid_is_released(self):
        # A hook stopped between mkdir and writing its PID leaves an empty PID file;
        # that lock is still its own to release.
        self.webviews(installed=("0.9.0", "0.60.0"))
        lock = self.repo / ".git/cmux-format-install-webviews.lock"
        self.tool(self.bin / "bun", FAKE_BUN + ': > "$LOCK/pid"\n')
        self.env.update(LOCK=str(lock))
        path = self.edit("webviews/src/stale.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertTrue(self.bun_log.exists(), stderr)
        self.assertFalse(lock.exists(), stderr)

    def test_a_stale_lock_is_moved_aside_and_leaves_nothing_behind(self):
        self.webviews(installed=("0.9.0", "0.60.0"))
        self.tool(self.bin / "bun", FAKE_BUN)
        dead = subprocess.Popen(["true"])
        dead.wait()
        lock = self.repo / ".git/cmux-format-install-webviews.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{dead.pid}\n")
        path = self.edit("webviews/src/stale.ts")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertTrue(self.bun_log.exists(), stderr)
        leftovers = sorted(p.name for p in (self.repo / ".git").glob("cmux-format-install-*"))
        self.assertEqual(leftovers, [], stderr)

    def test_current_webviews_packages_are_not_reinstalled(self):
        self.webviews()
        self.tool(self.bin / "bun", FAKE_BUN)
        path = self.edit("webviews/src/current.ts")
        self.run_hook("claude", path)
        self.assertFalse(self.bun_log.exists())

    def test_rust_output_never_lands_in_the_checkout(self):
        # A hook killed mid-rustfmt would leave its output file for a sibling's `git add -A`.
        package = self.repo / "probe"
        (package / "src").mkdir(parents=True)
        (package / "Cargo.toml").write_text('[package]\nname = "probe"\nedition = "2021"\n')
        listing = self.root / "listing.log"
        self.tool(self.bin / "rustfmt", f"""#!/bin/sh
ls -a "{package / 'src'}" > "{listing}"
cat
""")
        path = self.edit("probe/src/main.rs", "fn main() {}\n")
        returncode, stdout, stderr = self.run_hook("claude", path)
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertEqual(listing.read_text().split(), [".", "..", "main.rs"], stderr)

    def test_rust_uses_the_toolchain_its_package_pins(self):
        package = self.repo / "cmux-tui"
        (package / "src").mkdir(parents=True)
        (package / "Cargo.toml").write_text('[package]\nname = "probe"\nedition = "2021"\n')
        (package / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        pinned = self.root / "toolchains/1.95.0/rustfmt"
        self.tool(pinned, FAKE_RUSTFMT.format(name="pinned"))
        self.tool(self.bin / "rustfmt", FAKE_RUSTFMT.format(name="default"))
        self.tool(self.bin / "rustup", FAKE_RUSTUP.format(installed="1.95.0", pinned=pinned))
        path = self.edit("cmux-tui/src/main.rs", "fn main(){}\n")
        returncode, stdout, stderr = self.run_hook("claude", path, cwd=package / "src")
        self.assert_hook_ok("claude", returncode, stdout)
        calls = self.rustfmt_log.read_text().splitlines() if self.rustfmt_log.exists() else []
        self.assertEqual(len(calls), 1, stderr)
        self.assertTrue(calls[0].startswith("pinned --edition 2021 "), calls)
        self.assertEqual(path.read_text(), "fn main() {}\n", stderr)

    def test_a_missing_pinned_toolchain_falls_back_to_path_rustfmt_with_a_warning(self):
        # rustfmt keeps a stable style across versions, so the PATH rustfmt
        # beats leaving the edit unformatted.
        package = self.repo / "cmux-tui"
        (package / "src").mkdir(parents=True)
        (package / "Cargo.toml").write_text('[package]\nname = "probe"\nedition = "2021"\n')
        (package / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "1.95.0"\n')
        self.tool(self.bin / "rustfmt", FAKE_RUSTFMT.format(name="default"))
        self.tool(self.bin / "rustup", FAKE_RUSTUP.format(installed="1.99.0", pinned="/nonexistent"))
        path = self.edit("cmux-tui/src/main.rs", "fn main(){}\n")
        returncode, stdout, stderr = self.run_hook("codex", path)
        self.assert_hook_ok("codex", returncode, stdout)
        self.assertIn("rustup toolchain install 1.95.0", stderr)
        calls = self.rustfmt_log.read_text().splitlines() if self.rustfmt_log.exists() else []
        self.assertEqual(len(calls), 1, stderr)
        self.assertTrue(calls[0].startswith("default --edition 2021 "), calls)

    @unittest.skipUnless(shutil.which("rustfmt"), "rustfmt is not installed")
    def test_rust_edit_never_reformats_child_modules(self):
        # rustfmt given a path follows `mod child;` and rewrites child.rs, which
        # another agent may be editing in the same checkout.
        package = self.repo / "probe"
        (package / "src").mkdir(parents=True)
        (package / "Cargo.toml").write_text('[package]\nname = "probe"\nedition = "2021"\n')
        child = package / "src/child.rs"
        child.write_text("pub fn   child( ){}\n")
        path = self.edit("probe/src/lib.rs", "mod child;\npub fn   lib( ){}\n")
        # The fixture HOME hides rustup's toolchains from its rustfmt proxy.
        rustup_home = os.environ.get("RUSTUP_HOME", str(Path.home() / ".rustup"))
        returncode, stdout, stderr = self.run_hook("codex", path, RUSTUP_HOME=rustup_home)
        self.assert_hook_ok("codex", returncode, stdout)
        self.assertEqual(path.read_text(), "mod child;\npub fn lib() {}\n", stderr)
        self.assertEqual(child.read_text(), "pub fn   child( ){}\n")

    def test_skip_variable_leaves_the_edit_alone(self):
        self.webviews()
        path = self.edit("webviews/src/skip.ts")
        returncode, stdout, _ = self.run_hook("claude", path, CMUX_SKIP_FORMAT_HOOKS="1")
        self.assert_hook_ok("claude", returncode, stdout)
        self.assertEqual(path.read_text(), UNFORMATTED)

    def test_a_failing_formatter_never_fails_the_edit(self):
        web = self.webviews()
        self.tool(web / "node_modules/.bin/vp", "#!/bin/sh\nexit 3\n")
        path = self.edit("webviews/src/broken.ts")
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                returncode, stdout, stderr = self.run_hook(agent, path)
                self.assert_hook_ok(agent, returncode, stdout)
                self.assertIn("vp fmt could not format", stderr)

    @unittest.skipUnless((SOURCE / "webviews/node_modules/.bin/vp").exists(),
                         "webviews packages are not installed")
    def test_real_vp_formats_an_edited_webviews_file(self):
        probe = SOURCE / "webviews/test" / f"format-hook-probe-{uuid.uuid4().hex}.ts"
        self.addCleanup(lambda: probe.unlink(missing_ok=True))
        probe.write_text("export const   probe=[1,2,\n3]\n")
        env = dict(self.env, CLAUDE_PROJECT_DIR=str(SOURCE))
        payload = {"tool_name": "Write", "tool_input": {"file_path": str(probe)}}
        result = subprocess.run(["bash", str(SOURCE / HOOK)], cwd=SOURCE / "webviews", env=env,
                                input=json.dumps(payload), text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(probe.read_text(), "export const probe = [1, 2, 3];\n", result.stderr)


if __name__ == "__main__":
    unittest.main()
