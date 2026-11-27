# cmux-next.yml: job `path_route`, step "Classify pull request paths"

Moved out of `.github/workflows/cmux-next.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A ready-to-land head that only merges the base onto a head whose full tier passed runs the cheap tier and
carries cmux/land-tier success (head_tier.py's land carry rule); 0 turns that off.
