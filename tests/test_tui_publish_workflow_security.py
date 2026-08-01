import json
import re
import tomllib
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]


def load_tests(
    loader: unittest.TestLoader,
    standard_tests: unittest.TestSuite,
    pattern: str | None,
) -> unittest.TestSuite:
    del loader, standard_tests, pattern
    suite = unittest.TestSuite()
    for name, test in sorted(globals().items()):
        if name.startswith("test_") and callable(test):
            suite.addTest(unittest.FunctionTestCase(test, description=name))
    return suite


def workflow(name: str) -> str:
    return (ROOT / ".github" / "workflows" / name).read_text()


def workflow_triggers(text: str) -> dict[str, object]:
    document = yaml.load(text, Loader=yaml.BaseLoader)
    assert isinstance(document, dict)
    triggers = document.get("on")
    if isinstance(triggers, dict):
        return triggers
    if isinstance(triggers, list):
        return {str(trigger): None for trigger in triggers}
    if isinstance(triggers, str):
        return {triggers: None}
    raise AssertionError("workflow has no valid on trigger")


def workflow_job(text: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
        text,
    )
    assert match is not None
    return match.group(1)


def workflow_dispatch_input(text: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      {re.escape(name)}:\n(.*?)(?=^      [A-Za-z0-9_-]+:\n|^permissions:)",
        text,
    )
    assert match is not None
    return match.group(1)


def test_sdk_registry_names_do_not_overlap_tui_cli_packages() -> None:
    bindings = ROOT / "cmux-tui" / "bindings"
    typescript = json.loads(
        (bindings / "typescript" / "package.json").read_text()
    )
    python = tomllib.loads(
        (bindings / "python" / "pyproject.toml").read_text()
    )
    tui_npm = json.loads(
        (ROOT / "cmux-tui" / "dist" / "npm" / "cmux" / "package.json").read_text()
    )
    tui_pypi = (
        ROOT / "cmux-tui" / "dist" / "scripts" / "package_pypi.py"
    ).read_text()

    assert typescript["name"] == "cmux-sdk"
    assert python["project"]["name"] == "cmux-sdk"
    assert python["build-system"]["requires"] == ["setuptools>=77"]
    assert tui_npm["name"] == "cmux"
    assert 'DIST_NAME = "cmux"' in tui_pypi
    assert 'PACKAGE_NAME = "cmux_tui"' in tui_pypi
    assert "cmux = cmux_tui._main:main" in tui_pypi


def test_typescript_sdk_publisher_cannot_publish_the_cli_package() -> None:
    preflight = workflow("sdk-publish-npm.yml")
    release = workflow("sdk-release-cut.yml")
    tui = workflow("tui-publish-npm.yml")

    assert "https://www.npmjs.com/package/cmux-sdk" in release
    assert "npm publish --provenance" in release
    assert "--tag latest" in release
    assert "npm publish" not in preflight
    assert "--tag sdk" not in release
    assert "confirm_npm_cmux" not in release
    assert "publish_target" not in tui
    assert "publish-sdk" not in tui
    assert "confirm_sdk_cmux" not in tui
    assert "https://www.npmjs.com/package/cmux" in tui


def test_npm_bootstrap_preserves_the_first_stable_version() -> None:
    bootstrap = workflow("sdk-bootstrap-npm.yml")
    sdk_ci = workflow("cmux-tui-sdks.yml")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()

    assert workflow_triggers(bootstrap) == {"workflow_dispatch": {"inputs": {
        "confirm_bootstrap": {
            "description": "Claim cmux-sdk with a tested prerelease artifact",
            "required": "true",
            "default": "false",
            "type": "boolean",
        }
    }}}
    assert "runs-on: ubuntu-24.04" in bootstrap
    assert "id-token: write" in bootstrap
    assert "NPM_BOOTSTRAP_TOKEN" in bootstrap
    assert 'BOOTSTRAP_VERSION: "0.0.0-bootstrap.0"' in bootstrap
    assert "npm test" in bootstrap
    assert "npm pack --pack-destination" in bootstrap
    assert "CMUX_NPM_PACKAGE" in bootstrap
    assert 'npm publish "${packages[0]}"' in bootstrap
    assert "--tag bootstrap" in bootstrap
    assert "--provenance" in bootstrap
    assert "--access public" in bootstrap
    assert sdk_ci.count('".github/workflows/sdk-bootstrap-npm.yml"') == 2
    assert "sdk-bootstrap-npm.yml" in releasing
    assert "0.0.0-bootstrap.0" in releasing
    assert "first `cmux-sdk` release interactively" not in releasing


def test_pypi_bootstrap_reserves_the_project_before_release_tags() -> None:
    bootstrap = workflow("sdk-bootstrap-pypi.yml")
    sdk_ci = workflow("cmux-tui-sdks.yml")
    release = workflow("sdk-release-cut.yml")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()

    assert workflow_triggers(bootstrap) == {"workflow_dispatch": {"inputs": {
        "confirm_bootstrap": {
            "description": "Reserve cmux-sdk with an attested prerelease",
            "required": "true",
            "default": "false",
            "type": "boolean",
        }
    }}}
    assert "runs-on: ubuntu-24.04" in bootstrap
    assert "id-token: write" in bootstrap
    assert "name: pypi-bootstrap" in bootstrap
    assert "PYPI_BOOTSTRAP_TOKEN" not in bootstrap
    assert 'BOOTSTRAP_VERSION: "0.0.0a0"' in bootstrap
    assert "build==1.3.0" in bootstrap
    assert "setuptools==80.9.0" in bootstrap
    assert "wheel==0.45.1" in bootstrap
    assert "python3 -m build --no-isolation --sdist --wheel" in bootstrap
    assert "CMUX_PYTHON_DIST_DIR" in bootstrap
    assert "gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b" in bootstrap
    assert "skip-existing: true" in bootstrap
    assert "pypi-attestations==0.0.29" in bootstrap
    assert "pypi-attestations verify pypi" in bootstrap
    assert sdk_ci.count('".github/workflows/sdk-bootstrap-pypi.yml"') == 2
    assert "sdk-bootstrap-pypi.yml" in releasing
    assert "0.0.0a0" in releasing

    registry = workflow_job(release, "registry-preflight")
    cut_tags = release.index("  cut-tags:")
    ownership = release.index("Verify the PyPI ownership bootstrap")
    assert ownership < cut_tags
    assert "pypi-attestations==0.0.29" in registry
    assert "0.0.0a0" in registry
    assert "pypi-attestations verify pypi" in registry


def test_all_registry_names_are_owned_before_release_tags() -> None:
    release = workflow("sdk-release-cut.yml")
    registry = workflow_job(release, "registry-preflight")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()

    cut_tags = release.index("  cut-tags:")
    npm_ownership = release.index("Verify the npm ownership bootstrap")
    crates_ownership = release.index("Verify crates.io ownership")
    assert npm_ownership < cut_tags
    assert crates_ownership < cut_tags
    assert "verify_npm_provenance.py" in registry
    assert "0.0.0-bootstrap.0" in registry
    assert "git+https://github.com/manaflow-ai/cmux.git" in registry
    assert "cmux-tui/bindings/typescript" in registry
    assert "npm@11.5.1" in registry
    assert "npm audit signatures" in (
        ROOT / "cmux-tui" / "bindings" / "verify_npm_provenance.py"
    ).read_text()
    assert "verify_crates_ownership.py" in registry
    assert "--package cmux-client" in registry
    assert "--package cmux-sidebar" in registry
    assert "--owner-id 431397" in registry
    assert "--owner-login lawrencecchen" in registry
    assert "npm bootstrap provenance" in releasing
    assert "431397" in releasing


def test_python_ci_installs_its_build_backend_before_consumer_tests() -> None:
    packages = workflow_job(workflow("cmux-tui-sdks.yml"), "packages")
    install = packages.index('"setuptools==80.9.0"')
    tests = packages.index(
        "python3 -m unittest discover -s cmux-tui/bindings/python/tests -v"
    )
    assert install < tests


def test_python_sdk_publisher_cannot_publish_the_cli_package() -> None:
    preflight = workflow("sdk-publish-python.yml")
    release = workflow("sdk-release-cut.yml")
    tui = workflow("tui-publish-pypi.yml")

    assert "https://pypi.org/p/cmux-sdk" in release
    assert "gh-action-pypi-publish" in release
    assert "gh-action-pypi-publish" not in preflight
    assert "https://pypi.org/p/cmux" in tui


def test_sdk_release_cut_preflights_then_owns_the_selected_publishers() -> None:
    release = workflow("sdk-release-cut.yml")
    validation = workflow_job(release, "validate-release")

    assert 'sdk_tag="cmux-sdk-v$VERSION"' in release
    assert 'go_tag="cmux-tui/bindings/go/v$VERSION"' in release
    assert 'git push --atomic origin "refs/tags/$sdk_tag" "refs/tags/$go_tag"' in release
    preflights = {
        "rust": "crates",
        "go": "go",
        "typescript": "npm",
        "python": "python",
    }
    tag_push = release.index("git push --atomic origin")
    for job, publisher in preflights.items():
        assert f"{job}-preflight:" in release
        assert f"uses: ./.github/workflows/sdk-publish-{publisher}.yml" in release
        assert release.index(f"{job}-preflight:") < tag_push
    assert 'existing_sha="$(git rev-parse' in release
    assert '"$existing_sha" != "$GITHUB_SHA"' in release
    assert "validate_release_version.py" in release
    assert "--require-newer-than-tags" in release
    assert "git tag --list 'cmux-sdk-v*'" in release
    assert "check-spec-inventory.py" in validation
    assert "codegen/generate.py --check" in validation
    surface_gate = validation.index("check-spec-inventory.py")
    assert validation.index('[[ "$GITHUB_REF" == "refs/heads/main" ]]') < surface_gate
    assert validation.index('[[ "$GITHUB_SHA" == "$main_sha" ]]') < surface_gate
    for language in ("rust", "go", "typescript", "python"):
        assert f"--language {language}" in validation
    assert "gh workflow run sdk-publish-" not in release
    assert "verify-go-tag:" in release
    assert release.index("verify-go-tag:") > tag_push
    for job, publisher in (
        ("publish-crate-client", "crates"),
        ("publish-crate-sidebar", "crates"),
        ("publish-npm", "npm"),
        ("publish-python-wheel", "python"),
        ("publish-python-sdist", "python"),
    ):
        assert f"{job}:" in release
        block = workflow_job(release, job)
        assert f"uses: ./.github/workflows/sdk-publish-{publisher}.yml" not in block
        assert "verify-go-tag" in block
        assert "Require the coordinated release source" in block
        assert "--require-latest-tag" in block
    assert "if: always()" in release
    for result in (
        "VALIDATE_RESULT",
        "RUST_PREFLIGHT_RESULT",
        "GO_PREFLIGHT_RESULT",
        "TYPESCRIPT_PREFLIGHT_RESULT",
        "PYTHON_PREFLIGHT_RESULT",
        "REGISTRY_PREFLIGHT_RESULT",
        "CUT_TAGS_RESULT",
        "CRATE_CLIENT_RESULT",
        "CRATE_SIDEBAR_RESULT",
        "GO_TAG_RESULT",
        "NPM_RESULT",
        "PYTHON_WHEEL_RESULT",
        "PYTHON_SDIST_RESULT",
    ):
        assert result in release
    assert "sdk-publish-java.yml" not in release


def test_registry_state_is_validated_before_irreversible_tags() -> None:
    release = workflow("sdk-release-cut.yml")
    registry = workflow_job(release, "registry-preflight")
    cut_tags = workflow_job(release, "cut-tags")

    for prerequisite in (
        "rust-preflight",
        "typescript-preflight",
        "python-preflight",
    ):
        assert prerequisite in registry
    for artifact in (
        "cmux-rust-client-crate",
        "cmux-rust-sidebar-crate",
        "cmux-npm-dist",
        "cmux-python-dist",
    ):
        assert f"name: {artifact}" in registry
    assert registry.count("reconcile_registry_artifact.py check") == 5
    assert "id-token: write" not in registry
    assert "registry-preflight" in cut_tags
    assert release.index("registry-preflight:") < release.index("cut-tags:")


def test_tag_cut_revalidates_release_order_after_its_final_fetch() -> None:
    release = workflow("sdk-release-cut.yml")
    cut_tags = workflow_job(release, "cut-tags")

    fetch = cut_tags.rindex("git fetch --force origin main --tags")
    tag_list = cut_tags.index("git tag --list 'cmux-sdk-v*'", fetch)
    revalidate = cut_tags.index("--require-latest-tag", tag_list)
    create = cut_tags.index('ensure_tag "$sdk_tag"', revalidate)
    push = cut_tags.index("git push --atomic origin", create)
    assert fetch < tag_list < revalidate < create < push


def test_go_publisher_uses_the_nested_module_semver_tag() -> None:
    go = workflow("sdk-publish-go.yml")
    java = workflow("sdk-publish-java.yml")

    assert "cmux-tui/bindings/go/vX.Y.Z" in go
    assert 'version="${GITHUB_REF_NAME#cmux-tui/bindings/go/v}"' in go
    assert "workflow_call:" in go
    assert '"cmux-sdk-v*"' not in go
    assert '"cmux-sdk-v*"' not in java


def test_sdk_preflight_workflows_cannot_write_to_registries() -> None:
    for name in (
        "sdk-publish-crates.yml",
        "sdk-publish-npm.yml",
        "sdk-publish-python.yml",
    ):
        text = workflow(name)
        assert "push" not in workflow_triggers(text)
        assert "workflow_call:" in text
        dispatch_inputs = text.split("workflow_dispatch:", 1)[1].split(
            "permissions:", 1
        )[0]
        assert "confirm_publish:" not in dispatch_inputs
        assert "github.event_name == 'push'" not in text
        assert "validate_release_version.py" in text
        assert "id-token: write" not in text
        assert "  publish:\n" not in text

    release = workflow("sdk-release-cut.yml")
    assert release.count("id-token: write") == 5
    assert release.count("Require the coordinated release source") == 5
    assert release.count("--require-latest-tag") == 6

    go = workflow("sdk-publish-go.yml")
    assert "push:\n    tags:" not in go
    assert "workflow_call:" in go
    assert "workflow_dispatch:" in go
    assert "if: inputs.verify_tag != true" in go
    assert "if: inputs.verify_tag == true" in go
    assert "CALLER_WORKFLOW_REF: ${{ github.workflow_ref }}" in go
    assert ".github/workflows/sdk-release-cut.yml@$GITHUB_REF" in go
    public_probe = go.split("verify-versioned-go-module:", 1)[1]
    setup = public_probe.split("Resolve the public module tag", 1)[0]
    assert "cache: false" in setup
    assert "GOPROXY=https://proxy.golang.org" in public_probe
    assert "GOSUMDB=sum.golang.org" in public_probe
    assert "GOPROXY=direct" not in public_probe
    assert "GONOSUMDB=none" in public_probe
    assert '"$module/raw"' in public_probe
    assert "go mod download" in public_probe
    assert "go mod verify" in public_probe
    assert "go test" in public_probe


def test_go_public_tag_probe_retries_proxy_propagation() -> None:
    go = workflow("sdk-publish-go.yml")
    public_probe = workflow_job(go, "verify-versioned-go-module")

    assert "timeout-minutes: 35" in public_probe
    wait = public_probe.index("wait_for_go_module.py")
    assert "--wait-seconds 1800" in public_probe[wait:]
    assert "--retry-seconds 30" in public_probe[wait:]
    assert wait < public_probe.index('go get "$module@$expected"')
    assert "export GOENV=off" in public_probe
    assert "export GOPROXY=https://proxy.golang.org" in public_probe
    assert "export GOSUMDB=sum.golang.org" in public_probe
    assert 'export GOPRIVATE=""' in public_probe
    assert "export GONOPROXY=none" in public_probe
    assert "export GONOSUMDB=none" in public_probe


def test_workflow_trigger_guard_parses_flow_style_yaml() -> None:
    triggers = workflow_triggers(
        "name: fixture\non: {push: {tags: ['v*']}, workflow_dispatch: {}}\n"
    )
    assert "push" in triggers
    assert "tags" in triggers["push"]


def test_registry_publishers_reuse_preflight_artifacts() -> None:
    rust = workflow("sdk-publish-crates.yml")
    npm = workflow("sdk-publish-npm.yml")
    python = workflow("sdk-publish-python.yml")
    release = workflow("sdk-release-cut.yml")

    for artifact in ("cmux-rust-client-crate", "cmux-rust-sidebar-crate"):
        assert rust.count(f"name: {artifact}") == 1
        assert release.count(f"name: {artifact}") >= 1

    assert npm.count("name: cmux-npm-dist") == 1
    assert release.count("name: cmux-npm-dist") == 2
    assert "npm pack --pack-destination" in npm
    npm_publish = workflow_job(release, "publish-npm")
    assert "Download the validated npm artifact" in npm_publish
    assert "npm test" not in npm_publish

    assert python.count("name: cmux-python-dist") == 1
    assert release.count("name: cmux-python-dist") == 3
    for job in ("publish-python-wheel", "publish-python-sdist"):
        python_publish = workflow_job(release, job)
        assert "Download distributions" in python_publish
        assert "python3 -m build" not in python_publish


def test_irreversible_registry_writes_are_independently_rerunnable() -> None:
    release = workflow("sdk-release-cut.yml")

    client = workflow_job(release, "publish-crate-client")
    sidebar = workflow_job(release, "publish-crate-sidebar")
    assert "Publish cmux-client" in client
    assert "Publish cmux-sidebar" not in client
    assert "publish-crate-client" in sidebar
    assert "Publish cmux-sidebar" in sidebar

    wheel = workflow_job(release, "publish-python-wheel")
    sdist = workflow_job(release, "publish-python-sdist")
    assert "--artifact upload/*.whl" in wheel
    assert "--artifact upload/*.tar.gz" not in wheel
    assert "--artifact upload/*.tar.gz" in sdist
    assert "--artifact upload/*.whl" not in sdist
    assert "gh-action-pypi-publish" in wheel
    assert "gh-action-pypi-publish" in sdist


def test_registry_writes_reconcile_ambiguous_publish_failures() -> None:
    release = workflow("sdk-release-cut.yml")

    for job in ("publish-crate-client", "publish-crate-sidebar", "publish-npm"):
        block = workflow_job(release, job)
        assert "reconcile_registry_artifact.py publish" in block
        assert "--wait-seconds 120" in block

    for job in ("publish-python-wheel", "publish-python-sdist"):
        block = workflow_job(release, job)
        assert block.count("reconcile_registry_artifact.py check") == 2
        assert "--allowed-artifact dist/*.whl" in block
        assert "--allowed-artifact dist/*.tar.gz" in block
        assert "continue-on-error: true" in block
        assert "--require-match" in block
        assert "--wait-seconds 120" in block


def test_rust_release_uses_pinned_cargo_and_verifies_packaged_sidebar() -> None:
    preflight = workflow("sdk-publish-crates.yml")
    release = workflow("sdk-release-cut.yml")

    for text in (preflight, release):
        assert 'RUST_TOOLCHAIN: "1.95.0"' in text
        assert 'rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal' in text
        assert 'rustup default "$RUST_TOOLCHAIN"' in text

    assert "-p cmux-sidebar" in preflight
    assert "--no-verify" in preflight
    assert "cmux-sidebar-$CMUX_SDK_VERSION.crate" in preflight
    assert "cmux-client-$CMUX_SDK_VERSION.crate" in preflight
    assert "patch.crates-io.cmux-client.path" in preflight
    assert "--all-targets" in preflight

    for job in ("publish-crate-client", "publish-crate-sidebar"):
        block = workflow_job(release, job)
        assert "Install pinned Rust toolchain" in block
        assert "Download the validated" in block
        assert "validated crate digest mismatch" in block
        assert "cargo package" in block
        assert "cargo publish" in block
        assert block.count("--no-verify") >= 2
        assert "sleep " not in block


def test_python_preflight_tests_the_exact_pinned_distributions() -> None:
    preflight = workflow("sdk-publish-python.yml")
    build = workflow_job(preflight, "build")

    for requirement in (
        '"build==1.3.0"',
        '"setuptools==80.9.0"',
        '"wheel==0.45.1"',
    ):
        assert requirement in build
    assert "python3 -m build --no-isolation --sdist --wheel" in build
    assert "CMUX_PYTHON_DIST_DIR" in build
    assert build.index("python3 -m build") < build.index("CMUX_PYTHON_DIST_DIR")
    assert build.index("CMUX_PYTHON_DIST_DIR") < build.index("Upload distributions")

    consumer = (
        ROOT
        / "cmux-tui"
        / "bindings"
        / "python"
        / "tests"
        / "test_package_consumer.py"
    ).read_text()
    assert "CMUX_PYTHON_DIST_DIR" in consumer
    assert "*.whl" in consumer
    assert "*.tar.gz" in consumer


def test_python_preflight_provisions_the_declared_build_backend() -> None:
    preflight = workflow("sdk-publish-python.yml")
    package_tests = preflight.index("Test Python SDK package")
    backend = preflight.index('"setuptools==80.9.0"')

    assert backend < package_tests


def test_typescript_spec_uses_the_sdk_registry_name() -> None:
    spec = (ROOT / "cmux-tui" / "spec" / "bindings.md").read_text()
    typescript = spec.split("### TypeScript", 1)[1].split("### Go", 1)[0]

    for entry_point in (
        "cmux-sdk",
        "cmux-sdk/browser",
        "cmux-sdk/node",
        "cmux-sdk/raw",
    ):
        assert f"`{entry_point}`" in typescript
    assert "`cmux/browser`" not in typescript
    assert "`cmux/node`" not in typescript
    assert "`cmux/raw`" not in typescript


def test_required_sdk_ci_checks_only_the_publish_set_version() -> None:
    sdk_ci = workflow("cmux-tui-sdks.yml")

    assert "check-versions.py --published-only" in sdk_ci
    assert "python3 tests/test_tui_publish_workflow_security.py -v" in sdk_ci
    for publisher in ("crates", "go", "npm", "python"):
        assert f'".github/workflows/sdk-publish-{publisher}.yml"' in sdk_ci
    assert '".github/workflows/sdk-release-cut.yml"' in sdk_ci
    assert '"tests/test_tui_publish_workflow_security.py"' in sdk_ci


def test_workflow_guard_runs_for_every_workflow_it_validates() -> None:
    sdk_ci = workflow("cmux-tui-sdks.yml")
    guarded = (
        "cmux-tui-nightly.yml",
        "cmux-tui-release-cut.yml",
        "cmux-tui-release.yml",
        "cmux-tui-sdks.yml",
        "sdk-publish-crates.yml",
        "sdk-publish-go.yml",
        "sdk-publish-java.yml",
        "sdk-publish-npm.yml",
        "sdk-publish-python.yml",
        "sdk-release-cut.yml",
        "tui-publish-npm.yml",
        "tui-publish-pypi.yml",
    )
    for name in guarded:
        assert sdk_ci.count(f'".github/workflows/{name}"') == 2


def test_python_wheel_consumer_derives_the_manifest_version() -> None:
    test = (
        ROOT
        / "cmux-tui"
        / "bindings"
        / "python"
        / "tests"
        / "test_package_consumer.py"
    ).read_text()

    assert "CMUX_EXPECTED_SDK_VERSION" in test
    assert "version('cmux-sdk') == '1.0.0'" not in test
    assert "import tomllib" in test
    assert '["project"]["version"]' in test
    assert "VERSION_MATCH" not in test


def test_stable_registry_publishers_are_exact_tag_and_artifact_bound() -> None:
    for name, environment in (
        ("tui-publish-npm.yml", "npm-tui"),
        ("tui-publish-pypi.yml", "pypi-tui"),
    ):
        text = workflow(name)
        assert 'tag="cmux-tui-v$DISPATCH_VERSION"' in text
        assert 'expected_ref="refs/tags/$tag"' in text
        assert 'if [[ "$GITHUB_REF" != "$expected_ref" ]]' in text
        assert 'git rev-parse "refs/tags/$tag^{commit}"' in text
        assert 'if [[ "$release_sha" != "$GITHUB_SHA" ]]' in text
        assert "artifact_run_id:" in text
        artifact_input = workflow_dispatch_input(text, "artifact_run_id")
        assert "required: true" in artifact_input
        assert '[[ "$ARTIFACT_RUN_ID" =~ ^[0-9]+$ ]]' in text
        assert 'artifact_path=".github/workflows/cmux-tui-release.yml"' in text
        assert 'if [[ "$artifact_head_sha" != "$release_sha" ]]' in text
        assert 'if [[ "$artifact_conclusion" != "success" ]]' in text
        assert "actions: read" in text
        assert "run-id: ${{ inputs.artifact_run_id }}" in text
        assert "github-token: ${{ github.token }}" in text
        assert "uses: ./.github/workflows/cmux-tui-build-package.yml" not in text
        assert f"name: {environment}" in text


def test_stable_pypi_publish_is_not_triggered_directly_by_a_tag() -> None:
    text = workflow("tui-publish-pypi.yml")
    assert "push:\n    tags:" not in text


def test_npm_publishers_pin_the_oidc_capable_npm_version() -> None:
    for name in (
        "tui-publish-npm.yml",
        "cmux-tui-nightly.yml",
        "sdk-release-cut.yml",
    ):
        text = workflow(name)
        assert "npm install -g npm@11.5.1" in text
        assert "npm@^11.5.1" not in text


def test_nightly_build_is_pinned_to_its_provenance_commit() -> None:
    text = workflow("cmux-tui-nightly.yml")
    assert "ref: ${{ github.sha }}" in text
    assert 'if [[ "$head_sha" != "$GITHUB_SHA" ]]' in text
    assert "checkout_ref: ${{ needs.version.outputs.head_sha }}" in text


def test_sdk_publish_conformance_runs_live_against_exact_built_binary() -> None:
    for name, language in (
        ("sdk-publish-crates.yml", "rust"),
        ("sdk-publish-go.yml", "go"),
        ("sdk-publish-java.yml", "java"),
        ("sdk-publish-npm.yml", "typescript"),
        ("sdk-publish-python.yml", "python"),
    ):
        text = workflow(name)
        assert "cargo build -p cmux-tui --bin cmux-tui --locked" in text
        assert (
            '--cmux-tui-bin "$GITHUB_WORKSPACE/cmux-tui/target/debug/cmux-tui"'
            in text
        )
        assert (
            f"grep -Eq '^PASS +{language} "
            "+live-creation-exit-restart-unix$'"
        ) in text

    typescript = workflow("sdk-publish-npm.yml")
    assert 'node-version: "22.14.0"' in typescript
    assert (
        "cache-dependency-path: cmux-tui/bindings/typescript/package-lock.json"
        in typescript
    )
    assert "npm ci --no-audit --no-fund" in typescript
    assert (
        "test \"$(node -p 'typeof WebSocket')\" = \"function\""
        in typescript
    )
    assert (
        "grep -Eq '^PASS +typescript "
        "+live-creation-exit-restart-websocket$'"
    ) in typescript


def test_stable_release_builds_and_tests_once_before_dispatching_publishers() -> None:
    release_cut = workflow("cmux-tui-release-cut.yml")
    release = workflow("cmux-tui-release.yml")
    npm = workflow("tui-publish-npm.yml")
    pypi = workflow("tui-publish-pypi.yml")

    assert "ref: ${{ github.sha }}" in release_cut
    assert release_cut.count("gh workflow run cmux-tui-release.yml") == 1
    assert "gh workflow run tui-publish-npm.yml" not in release_cut
    assert "gh workflow run tui-publish-pypi.yml" not in release_cut
    assert "-f publish_npm=true" in release_cut
    assert "-f publish_pypi=true" in release_cut
    assert "-f confirm_tui_cmux=true" in release_cut

    stable_workflows = (release, npm, pypi)
    reusable_build = "uses: ./.github/workflows/cmux-tui-build-package.yml"
    assert sum(text.count(reusable_build) for text in stable_workflows) == 1
    assert "publish_npm:" in release
    assert "publish_pypi:" in release
    assert 'if [[ "${GITHUB_REF_TYPE:-}" != "tag" ]]' in release
    assert "Stable artifacts require a cmux-tui-vX.Y.Z tag ref." in release
    assert "needs: build-package" in release
    assert 'gh workflow run tui-publish-npm.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"' in release
    assert 'gh workflow run tui-publish-pypi.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"' in release
    assert '-f artifact_run_id="$ARTIFACT_RUN_ID"' in release

    for name in ("tui-publish-npm.yml", "tui-publish-pypi.yml"):
        assert "workflow_call:" not in workflow(name)


if __name__ == "__main__":
    unittest.main()
