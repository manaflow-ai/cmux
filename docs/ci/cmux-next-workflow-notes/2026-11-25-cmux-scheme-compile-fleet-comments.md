# cmux-next.yml cmux-scheme-compile-fleet: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `cmux-scheme-compile-fleet` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `- name: Read the build fleet's app build`

The controller builds this head's whole Debug app when it sees this job queued (or this
read names the head) and serves the result; this job holds no Mac and never fails: a red or missing verdict
sends the Mac job to compile, as before.
