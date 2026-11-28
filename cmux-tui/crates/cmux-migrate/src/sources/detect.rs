//! A repo's `[setup] run` from the files at its root (lockfiles, version pins), shared by every
//! reader that sees a checkout's file list (the laptop, an SSH host, a competitor's workspace).

/// The setup commands a fresh clone with these root files needs, in order: version pins first
/// (`mise install`), then one install per ecosystem (one JS package manager, picked by lockfile).
pub fn setup_for(files: &[&str]) -> Vec<String> {
    let has = |f: &str| files.contains(&f);
    let mut run = Vec::new();
    if has(".tool-versions") || has("mise.toml") || has(".mise.toml") {
        run.push("mise install".to_owned());
    }
    if has("pnpm-lock.yaml") {
        run.push("pnpm install --frozen-lockfile".to_owned());
    } else if has("yarn.lock") {
        run.push("yarn install --frozen-lockfile".to_owned());
    } else if has("bun.lockb") || has("bun.lock") {
        run.push("bun install --frozen-lockfile".to_owned());
    } else if has("package-lock.json") {
        run.push("npm ci".to_owned());
    }
    if has("uv.lock") {
        run.push("uv sync".to_owned());
    } else if has("poetry.lock") {
        run.push("poetry install".to_owned());
    } else if has("Pipfile.lock") {
        run.push("pipenv install --deploy".to_owned());
    } else if has("requirements.txt") {
        run.push("pip install -r requirements.txt".to_owned());
    }
    if has("Cargo.lock") {
        run.push("cargo fetch".to_owned());
    }
    if has("go.mod") {
        run.push("go mod download".to_owned());
    }
    if has("Gemfile.lock") {
        run.push("bundle install".to_owned());
    }
    if has("composer.lock") {
        run.push("composer install".to_owned());
    }
    if has("mix.lock") {
        run.push("mix deps.get".to_owned());
    }
    run
}

#[cfg(test)]
#[path = "detect_tests.rs"]
mod tests;
