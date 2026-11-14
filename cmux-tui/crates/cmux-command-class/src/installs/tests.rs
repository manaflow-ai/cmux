use super::*;

fn installs(command: &str) -> Vec<(&'static str, Vec<String>)> {
    package_installs(command).into_iter().map(|i| (i.manager, i.packages)).collect()
}

fn one(manager: &'static str, packages: &[&str]) -> Vec<(&'static str, Vec<String>)> {
    vec![(manager, packages.iter().map(|p| (*p).to_owned()).collect())]
}

#[test]
fn node_managers_name_registry_packages_without_versions() {
    assert_eq!(
        installs("npm install react@18 @types/node -D"),
        one("npm", &["react", "@types/node"])
    );
    assert_eq!(installs("npm i -g typescript"), one("npm", &["typescript"]));
    assert_eq!(installs("pnpm add zod --filter web"), one("pnpm", &["zod"]));
    assert_eq!(installs("yarn add vite@latest"), one("yarn", &["vite"]));
    assert_eq!(installs("bun add hono"), one("bun", &["hono"]));
}

#[test]
fn a_bare_install_is_the_manifest() {
    assert_eq!(installs("npm install"), one("npm", &[]));
    assert_eq!(installs("npm ci"), one("npm", &[]));
    assert_eq!(installs("yarn"), one("yarn", &[]));
    assert_eq!(installs("uv sync"), one("uv", &[]));
}

#[test]
fn paths_urls_and_git_sources_are_never_names() {
    assert!(installs("npm install ./packages/lib").is_empty());
    assert!(installs("npm install git+ssh://git@example.com/secret.git").is_empty());
    assert!(installs("npm install https://example.com/x.tgz").is_empty());
    assert!(installs("pip install -r requirements.txt").is_empty());
    assert!(installs("pip install -e .").is_empty());
    assert!(installs("pip install https://example.com/a.whl").is_empty());
    assert!(installs("cargo install --path .").is_empty());
    assert!(installs("cargo install --git https://example.com/x").is_empty());
    assert!(installs("go install ./cmd/tool").is_empty());
    assert!(installs("sudo apt install ./local.deb").is_empty());
    assert!(installs("npm install Secret_Thing").is_empty());
}

#[test]
fn python_names_are_normalized() {
    assert_eq!(
        installs("pip install Flask==3.0 'fastapi[all]>=0.1'"),
        one("pip", &["flask", "fastapi"])
    );
    assert_eq!(installs("python3 -m pip install --user ruamel.yaml"), one("pip", &["ruamel-yaml"]));
    assert_eq!(
        installs("uv pip install numpy pydantic_core"),
        one("uv", &["numpy", "pydantic-core"])
    );
    assert_eq!(installs("uv add httpx --dev"), one("uv", &["httpx"]));
}

#[test]
fn other_managers() {
    assert_eq!(installs("cargo add serde@1 --features derive"), one("cargo", &["serde"]));
    assert_eq!(
        installs("go install golang.org/x/tools/gopls@latest"),
        one("go", &["golang.org/x/tools/gopls"])
    );
    assert_eq!(
        installs("sudo apt-get install -y ripgrep jq=1.6-2"),
        one("apt", &["ripgrep", "jq"])
    );
    assert_eq!(installs("brew install gh"), one("brew", &["gh"]));
    assert_eq!(installs("gem install bundler -v 2.5"), one("gem", &["bundler"]));
}

#[test]
fn wrappers_chains_and_shells_are_followed() {
    assert_eq!(
        installs("cd web && CI=1 npm install vite && bash -lc 'pip install requests'"),
        vec![("npm", vec!["vite".to_owned()]), ("pip", vec!["requests".to_owned()])]
    );
    assert_eq!(installs("timeout 300 env FOO=1 sudo -u cmux pnpm add zod"), one("pnpm", &["zod"]));
    assert_eq!(installs("echo $(npm i left-pad)"), one("npm", &["left-pad"]));
}

#[test]
fn non_installs_are_nothing() {
    for command in [
        "npm run build",
        "npm test",
        "cargo build",
        "go build ./...",
        "pip list",
        "uv run pytest",
        "apt list",
        "ls",
        "echo 'npm install x'",
        "git commit -m 'npm i x'",
    ] {
        assert!(installs(command).is_empty(), "{command}");
    }
    assert!(installs("unclosed 'quote npm i x").is_empty());
}
