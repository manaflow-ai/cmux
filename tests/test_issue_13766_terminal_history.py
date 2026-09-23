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
    def run_shell(self, shell, directory, surface, commands, exit_cleanly=False):
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
            if exit_cleanly:
                # A clean exit runs the shell's own history save on top of
                # the per-prompt persistence.
                os.write(descriptor, b'exit\n')
                if self.reap(pid, descriptor):
                    pid = None
            return results
        finally:
            if pid is not None:
                # Closing a cmux terminal hangs up its shell (Ghostty sends
                # SIGHUP), so persistence must not need `exit`. SIGHUP also
                # runs bash's own exit-time history save, which is what
                # double-wrote entries; SIGKILL skipped that path.
                os.kill(pid, signal.SIGHUP)
                if not self.reap(pid, descriptor):
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
            os.close(descriptor)

    @staticmethod
    def reap(pid, descriptor, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                return True
            if select.select([descriptor], [], [], 0.05)[0]:
                try:
                    os.read(descriptor, 65536)
                except OSError:
                    pass
        return False

    def write_startup(self, shell, directory, lines):
        name = Path(shell).name
        integration = ROOT / 'Resources/shell-integration' / (
            'cmux-zsh-integration.zsh' if name == 'zsh' else 'cmux-bash-integration.bash'
        )
        startup = directory / ('.zshrc' if name == 'zsh' else 'bashrc')
        startup.write_text(
            ''.join(f'{line}\n' for line in lines)
            + f'PS1="PROBE> "\nsource "{integration}"\n'
        )

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


    def test_explicit_history_opt_out(self):
        for shell in ('/bin/zsh', '/bin/bash'):
            for opt_out in ('unset HISTFILE', 'HISTFILE=', 'HISTFILE=/dev/null'):
                with self.subTest(shell=shell, opt_out=opt_out), tempfile.TemporaryDirectory(prefix='cmux13766-private-') as temp:
                    directory = Path(temp)
                    name = Path(shell).name
                    integration = ROOT / 'Resources/shell-integration' / (
                        'cmux-zsh-integration.zsh' if name == 'zsh' else 'cmux-bash-integration.bash'
                    )
                    startup = directory / ('.zshrc' if name == 'zsh' else 'bashrc')
                    startup.write_text(
                        f'HISTSIZE=2000\nSAVEHIST=2000\n{opt_out}\n'
                        f'PS1="PROBE> "\nsource "{integration}"\n'
                    )
                    self.run_shell(shell, directory, 'private', [b'echo PRIVATE_13766\n'])
                    self.assertFalse((directory / 'private').exists())

    def test_clean_exit_records_each_command_once(self):
        # bash saves history at exit on top of the per-prompt write; a
        # full-list `history -w` plus the exit append stored every command
        # twice, and the file doubled on every restart.
        for shell in ('/bin/zsh', '/bin/bash'):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(prefix='cmux13766-exit-') as temp:
                directory = Path(temp)
                global_history = directory / 'global'
                global_history.write_text('echo OTHER_TERMINAL\n')
                self.write_startup(shell, directory, [
                    f'HISTFILE="{global_history}"', 'HISTSIZE=2000', 'SAVEHIST=2000',
                ])
                for _ in range(3):
                    self.run_shell(
                        shell, directory, 'a', [b'echo ONCE_13766\n'], exit_cleanly=True
                    )
                recorded = (directory / 'a').read_bytes()
                self.assertEqual(recorded.count(b'echo ONCE_13766'), 3, recorded)
                self.assertEqual(global_history.read_text(), 'echo OTHER_TERMINAL\n')

    def test_zsh_unset_savehist_is_not_persisted(self):
        # With HISTFILE set but SAVEHIST unset, stock zsh writes nothing to
        # disk; the surface file must not start persisting commands.
        with tempfile.TemporaryDirectory(prefix='cmux13766-savehist-') as temp:
            directory = Path(temp)
            global_history = directory / 'global'
            self.write_startup('/bin/zsh', directory, [
                f'HISTFILE="{global_history}"', 'HISTSIZE=2000', 'unset SAVEHIST',
            ])
            self.run_shell('/bin/zsh', directory, 'private', [b'echo PRIVATE_13766\n'], exit_cleanly=True)
            surface = directory / 'private'
            recorded = surface.read_bytes() if surface.exists() else b''
            self.assertNotIn(b'PRIVATE_13766', recorded)
            self.assertFalse(global_history.exists())


if __name__ == '__main__':
    unittest.main()
