#!/usr/bin/env python3
"""Behavioral tests for the pane-bound ssh-tmux agent launcher."""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Resources/bin/cmux-tmux-agent.py"


def codex_override_paths(argv):
    """Key paths of the -c overrides as Codex applies them: the key is split
    on every '.', ignoring TOML quoting."""
    return [
        (setting.split("=", 1)[0].strip().split("."), setting.split("=", 1)[1])
        for flag, setting in zip(argv, argv[1:])
        if flag == "-c"
    ]


class RemoteTmuxAgentHelperTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tmux_log = self.root / "tmux.jsonl"
        self.provider_log = self.root / "provider.json"
        self._write_executable(
            self.bin / "tmux",
            """#!/usr/bin/env python3
import json, os, sys
log = os.environ['TMUX_LOG']
args = sys.argv[1:]
with open(log, 'a') as f: f.write(json.dumps(args) + '\\n')
if 'show-options' in args and '@cmux_agent_owner' in args:
    print(os.environ.get('TMUX_OWNER', 'owner'))
elif 'show-options' in args and 'default-command' in args:
    print(os.environ.get('TMUX_DEFAULT_COMMAND', ''))
elif 'show-options' in args and '@cmux_agent_default_command' in args:
    print(os.environ.get('TMUX_OWNED_COMMAND', ''))
elif 'show-options' in args and 'default-shell' in args:
    print(os.environ.get('TMUX_DEFAULT_SHELL', '/bin/sh'))
elif 'list-panes' in args:
    print('%7\\tbash\\t0')
elif 'capture-pane' in args:
    print(os.environ.get('TMUX_PROMPT', 'user@host:~$ '))
elif 'display-message' in args:
    print(os.environ.get('TMUX_CURSOR_Y', '0'))
""",
        )
        self._write_executable(
            self.bin / "codex",
            """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['PROVIDER_LOG'], 'w') as f: json.dump(sys.argv[1:], f)
""",
        )
        self._write_executable(
            self.bin / "claude",
            """#!/usr/bin/env python3
import json, os, sys
with open(os.environ['PROVIDER_LOG'], 'w') as f: json.dump(sys.argv[1:], f)
""",
        )

    def tearDown(self):
        self.temp.cleanup()

    def _write_executable(self, path, source):
        path.write_text(source)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _run(self, *args, owner="owner", extra_env=None):
        env = os.environ.copy()
        env.update(
            PATH=str(self.bin) + os.pathsep + os.defpath,
            HOME=str(self.root / "home"),
            TMUX_LOG=str(self.tmux_log),
            PROVIDER_LOG=str(self.provider_log),
            TMUX_OWNER=owner,
            TMUX=f"{self.root}/server,123,0",
            TMUX_PANE="%7",
        )
        if extra_env:
            env.update(extra_env)
        (self.root / "home").mkdir(exist_ok=True)
        return subprocess.run(
            [sys.executable, str(HELPER), *args], env=env, capture_output=True, text=True
        )

    def _tmux_calls(self):
        if not self.tmux_log.exists():
            return []
        return [json.loads(line) for line in self.tmux_log.read_text().splitlines()]

    def test_codex_launch_embeds_exact_pane_route_and_trust(self):
        result = self._run("--launch", "codex", "exec", "hello")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads(self.provider_log.read_text())
        self.assertEqual(argv[0:2], ["--enable", "hooks"])
        self.assertIn("hooks.SessionStart", " ".join(argv))
        self.assertIn("/<session-flags>/config.toml:session_start:0:0", " ".join(argv))
        # Every trust entry must land under hooks.state with its whole key:
        # a dotted override such as hooks.state."/<session-flags>/config.toml:..."
        # is split inside the quotes and never trusts the hook.
        state = [value for path, value in codex_override_paths(argv) if path[:2] == ["hooks", "state"]]
        self.assertEqual(len(state), 1, state)
        self.assertEqual(
            [path for path, _ in codex_override_paths(argv) if path[:2] == ["hooks", "state"]],
            [["hooks", "state"]],
        )
        for label in ("session_start", "user_prompt_submit", "stop"):
            self.assertIn(f'"/<session-flags>/config.toml:{label}:0:0"={{trusted_hash="sha256:', state[0])
        self.assertEqual(argv[-2:], ["exec", "hello"])
        calls = self._tmux_calls()
        self.assertTrue(any("@cmux_agent_owner" in call for call in calls))

    def test_hook_uses_embedded_route_without_environment(self):
        context = {
            "agent": "codex",
            "pane": "%7",
            "socket": str(self.root / "server"),
            "tmux": str(self.bin / "tmux"),
            "owner": "owner",
        }
        import base64

        encoded = base64.b64encode(json.dumps(context).encode()).decode()
        env = os.environ.copy()
        env.update(TMUX_LOG=str(self.tmux_log), TMUX_OWNER="owner")
        result = subprocess.run(
            [sys.executable, str(HELPER), "--hook", encoded, "working"],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._tmux_calls()
        set_calls = [call for call in calls if "set-option" in call]
        self.assertTrue(set_calls)
        self.assertIn("%7", set_calls[-1])
        self.assertIn('{"agent":"codex","state":"working"}', set_calls[-1])

    def test_late_hook_from_old_owner_is_ignored(self):
        context = {
            "agent": "claude",
            "pane": "%7",
            "socket": str(self.root / "server"),
            "tmux": str(self.bin / "tmux"),
            "owner": "old",
        }
        import base64

        encoded = base64.b64encode(json.dumps(context).encode()).decode()
        env = os.environ.copy()
        env.update(TMUX_LOG=str(self.tmux_log), TMUX_OWNER="new")
        result = subprocess.run(
            [sys.executable, str(HELPER), "--hook", encoded, "idle"],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertFalse(any("set-option" in call for call in self._tmux_calls()))

    def test_install_uses_the_existing_tmux_server(self):
        import base64

        payload = base64.b64encode(HELPER.read_bytes()).decode()
        result = self._run("--install", "$1", payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._tmux_calls()
        self.assertTrue(any("set-option" in call and "default-command" in call for call in calls))
        self.assertTrue(any(
            call[2:6] == ["list-panes", "-s", "-t", "$1"] for call in calls
        ))
        self.assertTrue(any(
            "show-options" in call and "-Aqv" in call for call in calls
        ))
        self.assertTrue(any("send-keys" in call and "init.sh" in " ".join(call) for call in calls))

    def test_install_does_not_inject_into_busy_shell_input(self):
        import base64

        payload = base64.b64encode(HELPER.read_bytes()).decode()
        result = self._run(
            "--install", "$1", payload,
            extra_env={"TMUX_PROMPT": "user@host:~$ codex --prompt"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("send-keys" in call for call in self._tmux_calls()))

    def test_custom_default_command_still_sources_idle_shells(self):
        import base64

        payload = base64.b64encode(HELPER.read_bytes()).decode()
        result = self._run(
            "--install", "$1", payload,
            extra_env={"TMUX_DEFAULT_COMMAND": "user-command"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("send-keys" in call and "init.sh" in " ".join(call)
                            for call in self._tmux_calls()))

    def test_install_does_not_inject_into_shell_continuation(self):
        import base64

        payload = base64.b64encode(HELPER.read_bytes()).decode()
        result = self._run(
            "--install", "$1", payload,
            extra_env={"TMUX_PROMPT": "> "},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("send-keys" in call for call in self._tmux_calls()))

    def test_install_does_not_inject_into_an_unfinished_comment(self):
        import base64

        payload = base64.b64encode(HELPER.read_bytes()).decode()
        result = self._run(
            "--install", "$1", payload,
            extra_env={"TMUX_PROMPT": "user@host:~$ rm -rf ~/data #"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("send-keys" in call for call in self._tmux_calls()))

    def test_management_commands_pass_through(self):
        module_source = HELPER.read_text()
        namespace = {"__name__": "cmux_tmux_agent_test"}
        exec(compile(module_source, str(HELPER), "exec"), namespace)
        self.assertFalse(namespace["session_launch"]("codex", ["--help"]))
        self.assertFalse(namespace["session_launch"]("codex", ["mcp", "list"]))
        self.assertTrue(namespace["session_launch"]("codex", ["exec", "hello"]))

    def test_managed_bash_and_zsh_keep_interactive_startup(self):
        module_source = HELPER.read_text()
        calls = []

        class ExecCalled(Exception):
            pass

        class FakeOS:
            environ = os.environ

            @staticmethod
            def execv(path, argv):
                calls.append((path, argv))
                raise ExecCalled

        namespace = {"__name__": "cmux_tmux_agent_test", "__file__": str(HELPER)}
        exec(compile(module_source, str(HELPER), "exec"), namespace)
        namespace["os"] = FakeOS
        for shell in ("/bin/bash", "/bin/zsh"):
            with self.assertRaises(ExecCalled):
                namespace["shell_launch"](shell)

        self.assertEqual(calls[0][1][:2], ["/bin/bash", "-lic"])
        self.assertIn("exec /bin/bash -i", calls[0][1][2])
        self.assertNotIn("--norc", calls[0][1][2])
        self.assertEqual(calls[1][1][:2], ["/bin/zsh", "-lic"])
        self.assertIn("exec /bin/zsh -i", calls[1][1][2])
        self.assertNotIn("-f", calls[1][1][2])


if __name__ == "__main__":
    unittest.main()
