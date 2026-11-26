# After a TUI crashes, the next prompt sometimes still gets mouse garbage

`ShellMarks` in `promptmark.py` sits on a terminal's output and puts terminal-mode resets in front of
shell-integration marks (`MARK`, `ESC ] 133 ;` and a letter): `KEYBOARD_RESET` before a command-finished mark `D`
after a command started (`C`), and `PROMPT_RESET` before a prompt-start mark `A` when no command is running, so a
program that died with mouse reporting on does not leave the next prompt broken.

It works most of the time, but now and then after a crash my prompt still prints mouse reports when I move the mouse.
The output comes from a pty in reads of any size, and when a read ends in the middle of a mark (`...\x1b]13` in one
read, `3;A\x07` in the next) the mark gets no reset at all. The result must not depend on how the stream is cut into
reads; `flush()` is called at the end of the stream. Output that cannot be the start of a mark should not be delayed.
