# cmux-next.yml dev-landing-place: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `dev-landing-place` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `git init -q --bare "$GAP_REPO"`

Commits only, for the distance to each host's last compile.
