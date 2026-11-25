# cmux-next.yml release-compile-fast: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `release-compile-fast` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `- name: Check out the fleet compile reader`

(scripts/ci/fleet_compile_result.py) and compile here only when it has none. Trusted base copy.

## 2

Stood above: `release-compile-fast:`

The fleet compile check is the first Release gate. It checks the exact
