# cmux-next.yml generated-files-linux: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `generated-files-linux` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"`

An inherited socket would still name another home's daemon; empty is unset.

## 2

Stood above: `CMUX_ACTION_EXPORTS_BUILD: "true"`

The Linux export builds nothing from the package: a base export only checks the base's inputs out.
