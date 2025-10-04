# cmux-env

cmux-env is a small daemon (`envd`) and client (`envctl`) that coordinate shared environment variables across shells and projects. The daemon keeps track of global and directory-scoped key/value pairs, while the client provides commands to set, unset, list, or export variables in shell-friendly formats.

## Usage

Start the daemon in the background:

```sh
cargo run --bin envd
```

Interact with it via the `envctl` client:

```sh
# Set a global value
envctl set FOO=bar

# Scope a variable to a directory
envctl set SERVICE=api --dir /path/to/project

# List effective values for the current directory
envctl list

# Export shell diffs since the last generation
envctl export bash --since 0
```

### Shell integration

To keep interactive shells synchronized with the daemon, install the
prompt hook into your shell's rc file:

```sh
envctl install-hook bash
envctl install-hook zsh
envctl install-hook fish
```

The command writes the hook between marker comments in `~/.bashrc`,
`~/.zshrc`, or `~/.config/fish/config.fish` by default. Use
`--rcfile <path>` to install the hook into a custom file. You can still
inspect or embed the raw hook script with `envctl hook <shell>` if you want
to manage the integration manually.

### Loading .env data

`envctl load` can ingest dotenv-style files from disk or standard input:

```sh
echo "FOO=bar" | envctl load -
```

You can also load content that is base64-encoded (for example, when passing entire dotenv files through CI secrets). Provide the encoded string directly, or use `-` to read it from stdin:

```sh
# Literal base64 string
envctl load --base64 RU9PPSdCYXIn

# From stdin
cat .env | base64 | envctl load --base64 -
```

Invalid payloads or malformed dotenv entries will fail with descriptive errors and will not modify stored variables.

## Testing

Run the integration suite with:

```sh
cargo test
```

Several tests spawn real `envd`/`envctl` binaries, so they expect the current project to be built with `cargo`.

## Release Process

To create a new release:

```sh
# Option 1: Fully automated (recommended)
scripts/prepare-release.sh 0.0.4

# Option 2: Manual with auto-update
scripts/release.sh 0.0.4 --auto-update

# Option 3: Fully manual
# 1. Update version in Cargo.toml
# 2. Commit: git commit -am "chore: bump version to 0.0.4"
# 3. Run: scripts/release.sh 0.0.4
```

The `prepare-release.sh` script will:
- Pull latest changes from main
- Run tests to ensure everything works
- Update Cargo.toml version if needed
- Commit the version change
- Create and push the release tag
- Wait for GitHub Actions to build release artifacts

The release workflow automatically:
- Builds Linux x86_64 and aarch64 binaries
- Creates GitHub release with artifacts
- Makes binaries available for the install script

## License

This project is provided as-is for experimentation.
