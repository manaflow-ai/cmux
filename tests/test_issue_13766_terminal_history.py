"""Exercise real Up-arrow recall after independent interactive shell restarts."""
import os
from pathlib import Path
import pty
import select
import signal
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TerminalHistoryTests(unittest.TestCase):
    def run_shell(self, shell, directory, surface, commands):
        pid, descriptor = pty.fork()
        if pid == 0:
            # Do not let the harness publish activity to a running cmux app.
            for key in list(os.environ):
                if key.startswith(('CMUX_', '_CMUX_')):
                    del os.environ[key]
            os.environ.update(
                ZDOTDIR=str(directory),
                CMUX_HISTORY_FILE=str(directory / surface),
                CMUX_SHELL_INTEGRATION='1',
            )
            argv = [shell, '-i'] if shell.endswith('zsh') else [
                shell, '--noprofile', '--rcfile', str(directory / 'bashrc'), '-i'
            ]
            os.execv(shell, argv)

        def read_prompt():
            output = b''
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([descriptor], [], [], 0.5)[0]:
                    try:
                        output += os.read(descriptor, 65536)
                    except OSError:
                        break
                    if b'PROBE> ' in output:
                        return output
            self.fail(f'Shell did not produce a prompt: {output!r}')

        try:
            read_prompt()
            results = []
            for command in commands:
                os.write(descriptor, command)
                results.append(read_prompt())
            return results
        finally:
            # Abrupt termination also proves persistence does not need `exit`.
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            os.close(descriptor)

    def test_arrow_recall_after_restart(self):
        for shell in ('/bin/zsh', '/bin/bash'):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix='cmux13766-') as temp:
                directory = Path(temp)
                global_history = directory / 'global'
                global_history.write_text('echo OTHER_TERMINAL\n')
                name = Path(shell).name
                integration = ROOT / 'Resources/shell-integration' / (
                    'cmux-zsh-integration.zsh' if name == 'zsh' else 'cmux-bash-integration.bash'
                )
                startup = directory / ('.zshrc' if name == 'zsh' else 'bashrc')
                startup.write_text(
                    f'HISTFILE="{global_history}"\nHISTSIZE=2000\nSAVEHIST=2000\n'
                    f'PS1="PROBE> "\nsource "{integration}"\n'
                )
                self.run_shell(shell, directory, 'a', [b'echo ALPHA_13766\n'])
                self.run_shell(shell, directory, 'b', [b'echo BRAVO_13766\n'])
                for surface, own, other in (
                    ('a', b'ALPHA_13766', b'BRAVO_13766'),
                    ('b', b'BRAVO_13766', b'ALPHA_13766'),
                ):
                    output = self.run_shell(shell, directory, surface, [b'\x1b[A\n'])[0]
                    self.assertIn(own, output)
                    self.assertNotIn(other, output)
                    self.assertNotIn(b'OTHER_TERMINAL', output)
                self.assertEqual(global_history.read_text(), 'echo OTHER_TERMINAL\n')


if __name__ == '__main__':
    unittest.main()
