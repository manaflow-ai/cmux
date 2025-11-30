Do not use .unwrap (except in tests).
Make sure to run clippy and fix all lint warnings.
Before finishing, make sure to run tests and cargo fmt.
After tests pass, ALWAYS run `./scripts/reload.sh` to rebuild the CLI, rebuild the Docker container, and restart the dev server. This ensures the user has the latest changes immediately available.
After finishing, use the macOS `say` command to notify the user with a short description of what to check/the next action the user should take (like a shell command/url/program they should interact with to veriy).
