import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import tomllib
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


def test_sdk_ci_tracks_tui_verification_and_packaging_workflows() -> None:
    triggers = workflow_triggers(workflow("cmux-tui-sdks.yml"))
    required_paths = {
        ".github/workflows/cmux-tui-build-package.yml",
        ".github/workflows/cmux-tui.yml",
    }

    for event in ("push", "pull_request"):
        event_config = triggers[event]
        assert isinstance(event_config, dict)
        paths = event_config["paths"]
        assert isinstance(paths, list)
        assert required_paths <= set(paths)


def test_macos_tui_tests_use_a_short_temp_root_for_unix_sockets() -> None:
    tui = workflow("cmux-tui.yml")
    test_job = workflow_job(tui, "test")

    assert "name: Use short temporary directory for macOS socket tests" in test_job
    assert "if: runner.os == 'macOS'" in test_job
    assert 'echo "TMPDIR=/tmp" >> "$GITHUB_ENV"' in test_job


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


def test_raw_binary_manifests_use_canonical_runtime_schema() -> None:
    artifacts = workflow("cmux-tui-artifacts.yml")
    releasing = (ROOT / "cmux-tui" / "bindings" / "RELEASING.md").read_text()
    assert artifacts.count('"architecture":') >= 4
    assert artifacts.count('"libc": "none"') >= 4
    assert '"arch":' not in artifacts
    assert "architecture: x86_64" in releasing
    assert "libc: none" in releasing


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
    publish = workflow_job(bootstrap, "publish")
    sdk_ci = workflow("cmux-tui-sdks.yml")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()

    assert workflow_triggers(bootstrap) == {
        "repository_dispatch": {"types": ["sdk-bootstrap-npm"]}
    }
    for job in ("build", "preflight", "verify"):
        block = workflow_job(bootstrap, job)
        assert (
            "runs-on: ${{ vars.LINUX_RUNNER || "
            "'blacksmith-4vcpu-ubuntu-2404' }}" in block
        )
    assert (
        "runs-on: ubuntu-latest # github-hosted-required: npm provenance publishing"
        in publish
    )
    assert "id-token: write" in bootstrap
    assert "NPM_BOOTSTRAP_TOKEN" in bootstrap
    assert 'BOOTSTRAP_VERSION: "0.0.0-bootstrap.0"' in bootstrap
    assert "npm test" in bootstrap
    assert "npm pack --pack-destination" in bootstrap
    assert "CMUX_NPM_PACKAGE" in bootstrap
    assert 'npm publish "$(realpath "${packages[0]}")"' in bootstrap
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

    assert workflow_triggers(bootstrap) == {
        "repository_dispatch": {"types": ["sdk-bootstrap-pypi"]}
    }
    assert "runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}" in bootstrap
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
    assert "--owner lawrencecchen" in bootstrap
    assert sdk_ci.count('".github/workflows/sdk-bootstrap-pypi.yml"') == 2
    assert "sdk-bootstrap-pypi.yml" in releasing
    assert "0.0.0a0" in releasing

    publish = workflow_job(bootstrap, "publish")
    publisher = "gh-action-pypi-publish@cef221092ed1bacb1cc03d23a2d87d1d172e277b"
    assert '[[ "$GITHUB_REPOSITORY" == "manaflow-ai/cmux" ]]' in publish
    assert '[[ "$GITHUB_REF" == "refs/heads/main" ]]' in publish
    assert "git ls-remote" in publish
    assert '[[ "$main_sha" == "$GITHUB_SHA" ]]' in publish
    assert publish.index("git ls-remote") < publish.index(publisher)

    registry = workflow_job(release, "registry-preflight")
    cut_tags = release.index("  cut-tags:")
    ownership = release.index("Verify the PyPI ownership bootstrap")
    assert ownership < cut_tags
    assert "pypi-attestations==0.0.29" in registry
    assert "0.0.0a0" in registry
    assert "pypi-attestations verify pypi" in registry
    assert "--owner lawrencecchen" in registry


def test_crates_bootstrap_preserves_the_first_stable_version() -> None:
    bootstrap = workflow("sdk-bootstrap-crates.yml")
    sdk_ci = workflow("cmux-tui-sdks.yml")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()
    manifests = {
        name: tomllib.loads(
            (
                ROOT
                / "cmux-tui"
                / "bindings"
                / "bootstrap"
                / source
                / "Cargo.toml"
            ).read_text()
        )
        for name, source in (
            ("cmux-sdk", "rust-sdk"),
            ("cmux-sidebar", "rust-sidebar"),
        )
    }

    assert workflow_triggers(bootstrap) == {
        "repository_dispatch": {"types": ["sdk-bootstrap-crates"]}
    }
    assert "runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}" in bootstrap
    assert 'RUST_TOOLCHAIN: "1.95.0"' in bootstrap
    assert 'BOOTSTRAP_VERSION: "0.0.0-bootstrap.0"' in bootstrap
    assert "CARGO_BOOTSTRAP_TOKEN" in bootstrap
    assert "cargo test --manifest-path" in bootstrap
    assert "cargo package --manifest-path" in bootstrap
    assert bootstrap.count("reconcile_registry_artifact.py check") == 2
    assert bootstrap.count("verify_crates_ownership.py") == 2
    assert bootstrap.count("--bootstrap-ownership-only") == 2
    assert "--retry-missing-project" in bootstrap
    assert "--allow-missing-project" not in bootstrap
    assert 'cmp "$BOOTSTRAP_ARTIFACT" "$REPACKED_ARTIFACT"' in bootstrap
    assert "cargo publish" in bootstrap
    for name, manifest in manifests.items():
        assert manifest["package"]["name"] == name
        assert manifest["package"]["version"] == "0.0.0-bootstrap.0"
        assert "dependencies" not in manifest
        assert manifest["workspace"] == {}
    assert "cmux-sdk-bootstrap-crate" in bootstrap
    assert "cmux-sidebar-bootstrap-crate" in bootstrap
    assert "client_payload.package" not in bootstrap
    assert bootstrap.count("max-parallel: 1") == 2
    assert sdk_ci.count('".github/workflows/sdk-bootstrap-crates.yml"') == 2
    assert "sdk-bootstrap-crates.yml" in releasing
    assert "0.0.0-bootstrap.0" in releasing
    assert "publish `cmux-sidebar` interactively once" not in releasing
    bootstrap_probe = bootstrap.split(
        "- name: Inspect the crates.io bootstrap state",
        1,
    )[1].split("\n      - name:", 1)[0]
    assert "--user-agent" in bootstrap_probe
    assert "https://github.com/manaflow-ai/cmux" in bootstrap_probe
    assert "--retry-delay 1" in bootstrap_probe
    assert "sleep 1" in bootstrap_probe
    assert bootstrap.count("sleep 1") >= 3


def test_registry_setup_disables_long_lived_publish_credentials() -> None:
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()
    verifier = (
        ROOT / "cmux-tui" / "bindings" / "verify_crates_ownership.py"
    ).read_text()
    normalized = re.sub(r"\s+", " ", releasing)

    assert "Require two-factor authentication and disallow tokens" in normalized
    assert normalized.count("Require trusted publishing for all new versions") >= 2
    assert "revoke the npm access token" in normalized
    assert "revoke the crates.io API token" in normalized
    assert 'crate.get("trustpub_only") is not True' in verifier


def test_bootstrap_tokens_are_isolated_from_package_code() -> None:
    npm = workflow("sdk-bootstrap-npm.yml")
    crates = workflow("sdk-bootstrap-crates.yml")

    for text, token, package_commands in (
        (npm, "NPM_BOOTSTRAP_TOKEN", ("npm ci", "npm test")),
    ):
        build = workflow_job(text, "build")
        preflight = workflow_job(text, "preflight")
        publish = workflow_job(text, "publish")
        verify = workflow_job(text, "verify")

        assert token not in build
        assert token not in preflight
        assert token in publish
        assert token not in verify
        assert "actions/checkout@" not in publish
        assert "actions/download-artifact@" in publish
        assert "continue-on-error: true" in publish
        assert publish.rstrip().endswith("--no-verify") or publish.rstrip().endswith(
            "--access public"
        )
        for command in package_commands:
            assert command in build
            assert command not in publish

    npm_build = workflow_job(npm, "build")
    npm_publish = workflow_job(npm, "publish")
    assert "id-token: write" not in npm_build
    assert "id-token: write" in npm_publish
    assert "name: npm-bootstrap" in npm_publish
    assert "npm publish" in npm_publish
    assert npm_publish.count("--ignore-scripts") == 2
    assert "npm lifecycle scripts are disabled" in npm_publish

    crates_decisions = workflow_job(crates, "decisions")
    crates_publishes = {
        "publish-sdk": workflow_job(crates, "publish-sdk"),
        "publish-sidebar": workflow_job(crates, "publish-sidebar"),
    }
    crates_verify = workflow_job(crates, "verify")
    crates_build = workflow_job(crates, "build")
    crates_preflight = workflow_job(crates, "preflight")

    for block in (crates_build, crates_preflight, crates_decisions, crates_verify):
        assert "CARGO_BOOTSTRAP_TOKEN" not in block
    for command in ("cargo test --manifest-path", "cargo package --manifest-path"):
        assert command in crates_build
    assert "name: crates-bootstrap" not in crates_decisions
    assert "sdk_need_publish" in crates_decisions
    assert "sidebar_need_publish" in crates_decisions

    for name, crates_publish in crates_publishes.items():
        assert "CARGO_BOOTSTRAP_TOKEN" in crates_publish
        assert "name: crates-bootstrap" in crates_publish
        assert crates_publish.count("actions/download-artifact@") == 1
        assert "actions/checkout@" not in crates_publish
        assert "continue-on-error: true" in crates_publish
        assert '== "$PACKAGE-$BOOTSTRAP_VERSION.crate"' in crates_publish
        assert "member.isfile()" in crates_publish
        assert "archive.extractfile(member)" in crates_publish
        assert "cmp \"$BOOTSTRAP_ARTIFACT\" \"$REPACKED_ARTIFACT\"" in crates_publish
        assert "cargo package" in crates_publish
        assert "cargo publish" in crates_publish
        assert "cargo test" not in crates_publish
        assert crates_publish.rstrip().endswith("--no-verify")
        output = "sdk_need_publish" if name == "publish-sdk" else "sidebar_need_publish"
        assert f"needs.decisions.outputs.{output} == 'true'" in crates_publish

    assert "!cancelled()" in crates_publishes["publish-sidebar"]
    assert "always()" in crates_verify
    assert "needs.publish-sdk.result" not in crates_verify
    assert "needs.publish-sidebar.result" not in crates_verify
    assert "fail-fast: false" in crates_verify
    assert "--retry-missing-project" in crates_verify


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
    assert "--package cmux-sdk" in registry
    assert "--package cmux-sidebar" in registry
    assert "--owner-id 431397" in registry
    assert "--owner-login lawrencecchen" in registry
    assert registry.count("sleep 1") >= 2
    assert "npm bootstrap provenance" in releasing
    assert "431397" in releasing
    assert "sole PyPI owner `lawrencecchen`" in releasing


def test_npm_bootstrap_recovers_an_accepted_publish() -> None:
    bootstrap = workflow("sdk-bootstrap-npm.yml")

    assert "already exists; this one-time workflow is disabled" not in bootstrap
    assert "steps.project.outputs.status == 'missing'" in bootstrap
    publish_step = bootstrap.split(
        "- name: Publish the exact tested prerelease artifact", 1
    )[1].split("\n      - name:", 1)[0]
    assert "continue-on-error: true" in publish_step
    assert "npm publish" in publish_step
    assert bootstrap.count("verify_npm_provenance.py") >= 2
    assert bootstrap.count("--artifact") >= 2


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

    assert workflow_triggers(release) == {
        "repository_dispatch": {"types": ["sdk-release-cut"]}
    }
    assert 'sdk_tag="cmux-sdk-v$VERSION"' in release
    assert 'go_tag="cmux-tui/bindings/go/v$VERSION"' in release
    assert 'git push --atomic "$release_repository"' in release
    assert '"refs/tags/$SDK_TAG"' in release
    assert '"refs/tags/$GO_TAG"' in release
    preflights = {
        "rust": "crates",
        "go": "go",
        "typescript": "npm",
        "python": "python",
    }
    tag_push = release.index('git push --atomic "$release_repository"')
    for job, publisher in preflights.items():
        assert f"{job}-preflight:" in release
        assert f"uses: ./.github/workflows/sdk-publish-{publisher}.yml" in release
        assert release.index(f"{job}-preflight:") < tag_push
    assert 'existing_sha="$(git rev-parse' in release
    assert '"$existing_sha" != "$GITHUB_SHA"' in release
    assert "validate_release_version.py" in release
    assert "--require-newer-than-tags" not in validation
    assert "--require-latest-tag" in validation
    assert "sdk_existing_sha" in validation
    assert "go_existing_sha" in validation
    assert "existing coordinated SDK tags must both name $GITHUB_SHA" in validation
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
        ("publish-crate-sdk", "crates"),
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
        "REVALIDATE_TAGS_RESULT",
        "CUT_TAGS_RESULT",
        "CRATE_SDK_RESULT",
        "CRATE_SIDEBAR_RESULT",
        "GO_TAG_RESULT",
        "NPM_RESULT",
        "PYTHON_WHEEL_RESULT",
        "PYTHON_SDIST_RESULT",
        "STABLE_PROVENANCE_RESULT",
    ):
        assert result in release
    assert "sdk-publish-java.yml" not in release


def test_privileged_sdk_workflows_use_external_release_authority() -> None:
    release = workflow("sdk-release-cut.yml")
    crates_bootstrap = workflow("sdk-bootstrap-crates.yml")
    npm_bootstrap = workflow("sdk-bootstrap-npm.yml")
    pypi_bootstrap = workflow("sdk-bootstrap-pypi.yml")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()

    for text, event_type in (
        (release, "sdk-release-cut"),
        (crates_bootstrap, "sdk-bootstrap-crates"),
        (npm_bootstrap, "sdk-bootstrap-npm"),
        (pypi_bootstrap, "sdk-bootstrap-pypi"),
    ):
        assert workflow_triggers(text) == {
            "repository_dispatch": {"types": [event_type]}
        }
        assert "github.event.client_payload" in text

    revalidate_tags = workflow_job(release, "revalidate-tags")
    cut_tags = workflow_job(release, "cut-tags")
    assert "    permissions:\n      contents: write" not in cut_tags
    assert "    permissions: {}" in cut_tags
    assert "name: sdk-release" in revalidate_tags
    assert "name: sdk-release-credentials" in cut_tags
    assert (
        "actions/create-github-app-token@"
        "bcd2ba49218906704ab6c1aa796996da409d3eb1"
    ) in cut_tags
    assert "client-id: ${{ vars.SDK_RELEASE_APP_CLIENT_ID }}" in cut_tags
    assert (
        "private-key: ${{ secrets.SDK_RELEASE_APP_PRIVATE_KEY }}"
        in cut_tags
    )
    assert "permission-contents: write" in cut_tags
    assert (
        "RELEASE_TOKEN: ${{ steps.release_app_token.outputs.token }}"
        in cut_tags
    )

    for phrase in (
        "protected branches only",
        "prevent self-review",
        "disable administrator bypass",
        "crates-bootstrap",
        "sdk-release-credentials",
        "SDK release GitHub App",
        "refs/tags/cmux-sdk-v*",
        "refs/tags/cmux-tui/bindings/go/v*",
    ):
        assert phrase in releasing


def test_registry_state_is_validated_before_irreversible_tags() -> None:
    release = workflow("sdk-release-cut.yml")
    registry = workflow_job(release, "registry-preflight")
    revalidate_tags = workflow_job(release, "revalidate-tags")

    for prerequisite in (
        "rust-preflight",
        "typescript-preflight",
        "python-preflight",
    ):
        assert prerequisite in registry
    for artifact in ("cmux-rust-sdk-crate", "cmux-rust-sidebar-crate"):
        assert f"name: {artifact}" in registry
    assert (
        "artifact-ids: ${{ needs.typescript-preflight.outputs.artifact_id }}"
        in registry
    )
    assert (
        "artifact-ids: ${{ needs.python-preflight.outputs.artifact_id }}"
        in registry
    )
    assert registry.count("reconcile_registry_artifact.py check") == 5
    assert "id-token: write" not in registry
    assert "registry-preflight" in revalidate_tags
    assert release.index("registry-preflight:") < release.index("revalidate-tags:")
    assert release.index("revalidate-tags:") < release.index("cut-tags:")


def test_registry_state_is_revalidated_after_release_approval() -> None:
    release = workflow("sdk-release-cut.yml")
    revalidate_tags = workflow_job(release, "revalidate-tags")
    cut_tags = workflow_job(release, "cut-tags")
    verifier = (
        ROOT
        / "cmux-tui"
        / "bindings"
        / "verify_release_registry_state.sh"
    ).read_text()

    assert "actions: read" in revalidate_tags
    assert "name: sdk-release" in revalidate_tags
    for artifact in ("cmux-rust-sdk-crate", "cmux-rust-sidebar-crate"):
        assert f"name: {artifact}" in revalidate_tags
    assert (
        "artifact-ids: ${{ needs.typescript-preflight.outputs.artifact_id }}"
        in revalidate_tags
    )
    assert (
        "artifact-ids: ${{ needs.python-preflight.outputs.artifact_id }}"
        in revalidate_tags
    )
    assert revalidate_tags.count("verify_release_registry_state.sh") == 1
    assert 'validated-rust-sdk/cmux-sdk-$version.crate' in verifier
    assert "validated-client" not in verifier
    assert "remote_state_sha256" in revalidate_tags
    assert "revalidate-tags" in cut_tags
    assert "verify_release_registry_state.sh" not in cut_tags
    assert verifier.count("reconcile_registry_artifact.py check") == 5
    assert verifier.count("sleep 1") >= 2
    assert "verify_crates_ownership.py" in verifier
    assert "verify_npm_provenance.py" in verifier
    assert "verify_pypi_provenance.py" in verifier
    assert verifier.count('--expected-commit "$expected_commit"') == 2
    assert "--expected-ref refs/heads/main" in verifier


def test_release_app_token_is_scoped_to_the_atomic_push() -> None:
    release = workflow("sdk-release-cut.yml")
    revalidate_tags = workflow_job(release, "revalidate-tags")
    cut_tags = workflow_job(release, "cut-tags")

    assert "SDK_RELEASE_APP_PRIVATE_KEY" not in revalidate_tags
    assert "actions/create-github-app-token@" not in revalidate_tags
    assert "runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}" in cut_tags
    assert "actions/checkout@" not in cut_tags
    assert "actions/download-artifact@" not in cut_tags
    assert "actions/setup-node@" not in cut_tags
    assert "actions/setup-python@" not in cut_tags
    assert cut_tags.count("uses:") == 1
    assert cut_tags.count("${{ secrets.") == 1
    prepare = cut_tags.index("Verify fresh release authority and prepare tags")
    mint = cut_tags.rindex("actions/create-github-app-token@")
    push = cut_tags.rindex('git push --atomic "$release_repository"')
    assert prepare < mint < push
    assert "token: ${{ steps.release_app_token.outputs.token }}" not in cut_tags
    assert "verify_release_registry_state.sh" not in cut_tags
    assert "python3 " not in cut_tags
    assert "npm " not in cut_tags
    assert "cargo " not in cut_tags
    assert "REMOTE_STATE_SHA256" in cut_tags

    push_step = cut_tags.split(
        "- name: Push protected release tags", 1
    )[1].split("\n      - name:", 1)[0]
    assert (
        "RELEASE_TOKEN: ${{ steps.release_app_token.outputs.token }}"
        in push_step
    )
    assert "GIT_CONFIG_COUNT=1" in push_step
    assert "GIT_CONFIG_VALUE_0" in push_step
    assert "verify_release_registry_state.sh" not in push_step
    assert "git rev-parse" not in push_step
    assert "python3 " not in push_step
    assert "npm " not in push_step


def test_stable_registry_provenance_gates_recovery_and_completion() -> None:
    release = workflow("sdk-release-cut.yml")
    registry = workflow_job(release, "registry-preflight")
    stable = workflow_job(release, "verify-stable-provenance")
    summary = workflow_job(release, "summarize")

    assert "id: registry_state" in registry
    for output in ("npm", "python_wheel", "python_sdist"):
        assert f"--github-output-name {output}" in registry
    before_tags = release.index("Verify any existing stable provenance")
    assert before_tags < release.index("  cut-tags:")
    assert "--publisher github-actions" in registry
    assert "--dist-tag latest" in registry
    assert "--workflow .github/workflows/sdk-release-cut.yml" in registry
    assert "--workflow sdk-release-cut.yml" in registry
    assert "--environment pypi" in registry
    assert registry.count('--expected-commit "$GITHUB_SHA"') == 2
    assert "--expected-ref refs/heads/main" in registry

    for dependency in (
        "typescript-preflight",
        "python-preflight",
        "publish-npm",
        "publish-python-wheel",
        "publish-python-sdist",
    ):
        assert dependency in stable
    assert (
        "artifact-ids: ${{ needs.typescript-preflight.outputs.artifact_id }}"
        in stable
    )
    assert (
        "artifact-ids: ${{ needs.python-preflight.outputs.artifact_id }}"
        in stable
    )
    assert "verify_npm_provenance.py" in stable
    assert "verify_pypi_provenance.py" in stable
    assert "publish-crate-sdk" in stable
    assert "publish-crate-sidebar" in stable
    assert "verify_crates_ownership.py" in stable
    assert "--package cmux-sdk" in stable
    assert "--package cmux-sidebar" in stable
    assert "--publisher github-actions" in stable
    assert "--dist-tag latest" in stable
    assert "--workflow .github/workflows/sdk-release-cut.yml" in stable
    assert "--workflow sdk-release-cut.yml" in stable
    assert "--environment pypi" in stable
    assert stable.count('--expected-commit "$GITHUB_SHA"') == 2
    assert "--expected-ref refs/heads/main" in stable
    assert "verify-stable-provenance" in summary
    assert "STABLE_PROVENANCE_RESULT" in summary


def test_tag_cut_revalidates_release_order_after_its_final_fetch() -> None:
    release = workflow("sdk-release-cut.yml")
    revalidate_tags = workflow_job(release, "revalidate-tags")
    cut_tags = workflow_job(release, "cut-tags")

    fetch = revalidate_tags.rindex("git fetch --force origin main --tags")
    tag_list = revalidate_tags.index("git tag --list 'cmux-sdk-v*'", fetch)
    revalidate = revalidate_tags.index("--require-latest-tag", tag_list)
    snapshot = revalidate_tags.index("remote_state_sha256", revalidate)
    compare = cut_tags.index('[[ "$remote_state_sha256" == "$REMOTE_STATE_SHA256" ]]')
    create = cut_tags.index('ensure_tag "$SDK_TAG"', compare)
    push = cut_tags.index('git push --atomic "$release_repository"', create)
    assert fetch < tag_list < revalidate < snapshot
    assert compare < create < push


def test_tag_cut_retry_requires_fresh_authority_or_safe_poststate() -> None:
    release = workflow("sdk-release-cut.yml")
    revalidate_tags = workflow_job(release, "revalidate-tags")
    cut_tags = workflow_job(release, "cut-tags")
    releasing = (
        ROOT / "cmux-tui" / "bindings" / "RELEASING.md"
    ).read_text()

    for output in (
        "authorization_run_id",
        "authorization_run_attempt",
        "authorized_at",
        "remote_state_sha256",
        "remote_tag_state_sha256",
    ):
        assert output in revalidate_tags
        assert output.upper() in cut_tags
    assert '[[ "$AUTHORIZATION_RUN_ID" == "$GITHUB_RUN_ID" ]]' in cut_tags
    assert (
        '[[ "$AUTHORIZATION_RUN_ATTEMPT" == "$GITHUB_RUN_ATTEMPT" ]]'
        in cut_tags
    )
    assert "authorization_age" in cut_tags
    assert "authorization_age <= 900" in cut_tags
    assert "normalized_tag_state_sha256" in cut_tags
    assert "verify_release_commit_on_main" in cut_tags
    assert "remote_release_state=published" in cut_tags
    assert "both coordinated tags already name the release commit" in cut_tags
    assert "id: prepare" in cut_tags
    assert cut_tags.count(
        "if: steps.prepare.outputs.tags_exist != 'true'"
    ) == 2
    assert "**Re-run all jobs**" in releasing
    assert "release commit remains an ancestor" in releasing


def test_revalidation_snapshot_excludes_current_coordinated_tags() -> None:
    release = workflow("sdk-release-cut.yml")
    revalidate_tags = workflow_job(release, "revalidate-tags")
    snapshot_start = revalidate_tags.index('remote_tag_state="$(')
    snapshot_end = revalidate_tags.index(
        'remote_tag_state_sha256="$(',
        snapshot_start,
    )
    snapshot = revalidate_tags[snapshot_start:snapshot_end]

    assert 'sdk_ref="refs/tags/$SDK_TAG"' in revalidate_tags
    assert 'go_ref="refs/tags/$GO_TAG"' in revalidate_tags
    for ref in ("sdk_ref", "sdk_peeled_ref", "go_ref", "go_peeled_ref"):
        assert f'-v {ref}="${ref}"' in snapshot
        assert f"$2 != {ref}" in snapshot


def test_tag_cut_retry_behavior_accepts_tags_after_main_advances() -> None:
    document = yaml.safe_load(workflow("sdk-release-cut.yml"))
    prepare_script = next(
        step["run"]
        for step in document["jobs"]["cut-tags"]["steps"]
        if step.get("id") == "prepare"
    )

    def git(*arguments: str, cwd: Path) -> str:
        return subprocess.run(
            ("git", *arguments),
            cwd=cwd,
            check=True,
            text=True,
            capture_output=True,
        ).stdout.strip()

    with tempfile.TemporaryDirectory(prefix="cmux-sdk-tag-retry-") as raw:
        temporary = Path(raw)
        source = temporary / "source"
        remote = temporary / "remote.git"
        source.mkdir()
        git("init", "-b", "main", cwd=source)
        git("config", "user.name", "cmux release test", cwd=source)
        git("config", "user.email", "release-test@cmux.dev", cwd=source)
        git("commit", "--allow-empty", "-m", "release", cwd=source)
        release_sha = git("rev-parse", "HEAD", cwd=source)
        git("init", "--bare", str(remote), cwd=temporary)
        git("remote", "add", "origin", str(remote), cwd=source)
        git("push", "origin", "main", cwd=source)

        prestate = f"{release_sha}\trefs/heads/main\n"
        prestate_sha256 = hashlib.sha256(prestate.encode()).hexdigest()
        pretag_state_sha256 = hashlib.sha256(b"\n").hexdigest()

        def prepare(attempt: int) -> tuple[subprocess.CompletedProcess[str], str, Path]:
            run_root = temporary / f"run-{attempt}"
            run_root.mkdir()
            output_path = run_root / "output"
            output_path.touch()
            environment = os.environ.copy()
            environment.update(
                {
                    "AUTHORIZATION_RUN_ATTEMPT": "1",
                    "AUTHORIZATION_RUN_ID": "123456789",
                    "AUTHORIZED_AT": str(int(time.time()) - 3600),
                    "CONFIRM_PUBLISH": "true",
                    "DISPATCH_VERSION": "1.0.1",
                    "GITHUB_OUTPUT": str(output_path),
                    "GITHUB_REF": "refs/heads/main",
                    "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                    "GITHUB_RUN_ATTEMPT": "2",
                    "GITHUB_RUN_ID": "123456789",
                    "GITHUB_SHA": release_sha,
                    "GO_TAG": "cmux-tui/bindings/go/v1.0.1",
                    "REMOTE_STATE_SHA256": prestate_sha256,
                    "REMOTE_TAG_STATE_SHA256": pretag_state_sha256,
                    "RUNNER_TEMP": str(run_root),
                    "SDK_TAG": "cmux-sdk-v1.0.1",
                    "VERSION": "1.0.1",
                    "GIT_CONFIG_COUNT": "1",
                    "GIT_CONFIG_KEY_0": f"url.{remote.as_uri()}.insteadOf",
                    "GIT_CONFIG_VALUE_0": "https://github.com/manaflow-ai/cmux.git",
                }
            )
            result = subprocess.run(
                ("bash",),
                input=prepare_script,
                env=environment,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            return result, output_path.read_text(), run_root

        stale, stale_output, stale_root = prepare(1)
        assert stale.returncode != 0
        assert "release authorization is stale" in stale.stdout
        assert stale_output == ""
        assert not (stale_root / "cmux-sdk-release").exists()

        for tag, message in (
            ("cmux-sdk-v1.0.1", "cmux SDK 1.0.1"),
            ("cmux-tui/bindings/go/v1.0.1", "cmux Go SDK 1.0.1"),
        ):
            git("tag", "-a", tag, "-m", message, cwd=source)
            git("push", "origin", f"refs/tags/{tag}", cwd=source)

        git("commit", "--allow-empty", "-m", "advance main", cwd=source)
        git("push", "origin", "main", cwd=source)

        recovered, recovered_output, recovered_root = prepare(2)
        assert recovered.returncode == 0, recovered.stdout
        assert "both coordinated tags already name the release commit" in recovered.stdout
        assert recovered_output == "tags_exist=true\n"
        assert not (recovered_root / "cmux-sdk-release").exists()

        git("tag", "-a", "cmux-sdk-v0.9.9", "-m", "unrelated release", cwd=source)
        git("push", "origin", "refs/tags/cmux-sdk-v0.9.9", cwd=source)
        changed_tags, changed_tags_output, _ = prepare(3)
        assert changed_tags.returncode != 0
        assert "remote release tags changed" in changed_tags.stdout
        assert changed_tags_output == ""

        git("push", "origin", ":refs/tags/cmux-sdk-v0.9.9", cwd=source)
        git("checkout", "--orphan", "rewritten-main", cwd=source)
        git("commit", "--allow-empty", "-m", "rewrite main", cwd=source)
        git("push", "--force", "origin", "HEAD:main", cwd=source)
        rewritten, rewritten_output, _ = prepare(4)
        assert rewritten.returncode != 0
        assert "is no longer on protected main" in rewritten.stdout
        assert rewritten_output == ""


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
    assert release.count("--require-latest-tag") == 7

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


def test_go_public_tag_probe_binds_downloaded_tree_to_release_commit() -> None:
    go = workflow("sdk-publish-go.yml")
    public_probe = workflow_job(go, "verify-versioned-go-module")

    verifier = public_probe.index("verify_go_module_source.py")
    assert 'module_dir="$(go list -m -f' in public_probe
    assert '--repository "$GITHUB_WORKSPACE"' in public_probe
    assert '--commit "$GITHUB_SHA"' in public_probe
    assert "--module-subdir cmux-tui/bindings/go" in public_probe
    assert '--downloaded-root "$module_dir"' in public_probe
    assert public_probe.index("go mod download") < verifier
    assert verifier < public_probe.index("go test")


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

    for artifact in ("cmux-rust-sdk-crate", "cmux-rust-sidebar-crate"):
        assert rust.count(f"name: {artifact}") == 1
        assert release.count(f"name: {artifact}") >= 1

    assert npm.count("name: cmux-npm-dist") == 1
    assert release.count("name: cmux-npm-dist") == 0
    assert "npm pack --pack-destination" in npm
    npm_publish = workflow_job(release, "publish-npm")
    assert "Download the validated npm artifact" in npm_publish
    assert "npm test" not in npm_publish

    assert python.count("name: cmux-python-dist") == 1
    assert release.count("name: cmux-python-dist") == 0
    for job in ("publish-python-wheel", "publish-python-sdist"):
        python_publish = workflow_job(release, job)
        assert "Download distributions" in python_publish
        assert "python3 -m build" not in python_publish


def test_credentialed_publishers_bind_immutable_preflight_artifacts() -> None:
    npm = workflow("sdk-publish-npm.yml")
    python = workflow("sdk-publish-python.yml")
    bootstrap_python = workflow("sdk-bootstrap-pypi.yml")
    release = workflow("sdk-release-cut.yml")

    for preflight, job, artifact in (
        (npm, "bindings-e2e-typescript", "cmux-npm-dist"),
        (python, "build", "cmux-python-dist"),
        (bootstrap_python, "build", "cmux-python-bootstrap-dist"),
    ):
        assert "steps.upload.outputs.artifact-id" in preflight
        assert "artifact_sha256:" in preflight
        producer = workflow_job(preflight, job)
        assert "overwrite: true" not in producer
        assert f"name: {artifact}-${{{{ github.run_attempt }}}}" in producer

    for job in ("registry-preflight", "revalidate-tags", "verify-stable-provenance"):
        block = workflow_job(release, job)
        assert "artifact-ids: ${{ needs.typescript-preflight.outputs.artifact_id }}" in block
        assert "artifact-ids: ${{ needs.python-preflight.outputs.artifact_id }}" in block

    for job in ("preflight", "publish", "verify"):
        block = workflow_job(bootstrap_python, job)
        assert "artifact-ids: ${{ needs.build.outputs.artifact_id }}" in block

    npm_publish = workflow_job(release, "publish-npm")
    assert "artifact-ids: ${{ needs.typescript-preflight.outputs.artifact_id }}" in npm_publish
    assert "EXPECTED_ARTIFACT_SHA256" in npm_publish
    assert 'sha256sum "${packages[0]}"' in npm_publish
    assert 'package["name"] == "cmux-sdk"' in npm_publish
    assert 'package["version"] == os.environ["CMUX_SDK_VERSION"]' in npm_publish

    for job in ("publish-python-wheel", "publish-python-sdist"):
        block = workflow_job(release, job)
        assert "artifact-ids: ${{ needs.python-preflight.outputs.artifact_id }}" in block
        assert "EXPECTED_ARTIFACT_SHA256" in block
        assert "sha256sum" in block
        assert "cmux_sdk-${CMUX_SDK_VERSION}" in block

    bootstrap_publish = workflow_job(bootstrap_python, "publish")
    assert "artifact-ids: ${{ needs.build.outputs.artifact_id }}" in bootstrap_publish
    assert "EXPECTED_ARTIFACT_SHA256" in bootstrap_publish
    assert "sha256sum" in bootstrap_publish


def test_publishers_revalidate_registry_authority_after_environment_approval() -> None:
    release = workflow("sdk-release-cut.yml")
    authority_helper = (
        ROOT
        / "cmux-tui"
        / "bindings"
        / "verify_release_registry_authority.sh"
    ).read_text()

    for job in ("publish-crate-sdk", "publish-crate-sidebar"):
        block = workflow_job(release, job)
        revalidate = block.index(
            "- name: Revalidate crates.io ownership immediately before authentication"
        )
        authenticate = block.index("- name: Authenticate")
        authority = block[revalidate:authenticate]
        assert revalidate < authenticate
        assert "verify_release_registry_authority.sh crates" in authority

    npm = workflow_job(release, "publish-npm")
    npm_setup = npm.index("- name: Install npm with OIDC trusted publishing support")
    npm_revalidate = npm.index(
        "- name: Revalidate npm ownership immediately before publishing"
    )
    npm_publish = npm.index("- name: Publish package to npm")
    npm_authority = npm[npm_revalidate:npm_publish]
    assert npm_setup < npm_revalidate < npm_publish
    assert "verify_release_registry_authority.sh npm" in npm_authority

    for job, state, artifact in (
        ("publish-python-wheel", "wheel_state", "wheel"),
        ("publish-python-sdist", "sdist_state", "source distribution"),
    ):
        block = workflow_job(release, job)
        state_check = block.index(f"- name: Check the PyPI {artifact} state")
        revalidate = block.index(
            f"- name: Revalidate PyPI ownership immediately before {artifact} upload"
        )
        publish = block.index(f"- name: Publish {artifact} to PyPI")
        authority = block[revalidate:publish]
        assert state_check < revalidate < publish
        assert f"if: steps.{state}.outputs.status == 'missing'" in authority
        assert "verify_release_registry_authority.sh pypi" in authority
        assert "pypi-attestations" not in block
        assert "actions/setup-python@" not in block

    assert "verify_crates_ownership.py" in authority_helper
    assert "--package cmux-sdk" in authority_helper
    assert "--package cmux-sidebar" in authority_helper
    assert "--owner-id 431397" in authority_helper
    assert "--owner-login lawrencecchen" in authority_helper
    assert "verify_npm_provenance.py" in authority_helper
    assert "--version 0.0.0-bootstrap.0" in authority_helper
    assert "--publisher owner" in authority_helper
    assert "--workflow-ref refs/heads/main" in authority_helper
    assert "verify_pypi_provenance.py" in authority_helper
    assert "--authority-only" in authority_helper
    assert "--version 0.0.0a0" in authority_helper
    assert "--workflow sdk-bootstrap-pypi.yml" in authority_helper
    assert "--environment pypi-bootstrap" in authority_helper


def test_irreversible_registry_writes_are_independently_rerunnable() -> None:
    release = workflow("sdk-release-cut.yml")

    sdk = workflow_job(release, "publish-crate-sdk")
    sidebar = workflow_job(release, "publish-crate-sidebar")
    assert "Publish cmux-sdk" in sdk
    assert "Publish cmux-sidebar" not in sdk
    assert "publish-crate-sdk" in sidebar
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

    for job in ("publish-crate-sdk", "publish-crate-sidebar", "publish-npm"):
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


def test_irreversible_registry_writes_have_bounded_processes_and_jobs() -> None:
    release = workflow("sdk-release-cut.yml")

    for job in (
        "publish-crate-sdk",
        "publish-crate-sidebar",
        "publish-npm",
    ):
        block = workflow_job(release, job)
        assert "timeout-minutes: 30" in block
        assert "--publish-timeout-seconds 600" in block

    for job in ("publish-python-wheel", "publish-python-sdist"):
        assert "timeout-minutes: 30" in workflow_job(release, job)


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
    assert "cmux-sdk-$CMUX_SDK_VERSION.crate" in preflight
    assert "patch.crates-io.cmux-sdk.path" in preflight
    assert "--all-targets" in preflight

    for job in ("publish-crate-sdk", "publish-crate-sidebar"):
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


def test_python_release_artifacts_use_the_commit_timestamp() -> None:
    preflight = workflow("sdk-publish-python.yml")
    build = workflow_job(preflight, "build")

    timestamp = 'SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$GITHUB_SHA")"'
    assert timestamp in build
    assert build.index(timestamp) < build.index("python3 -m build")
    assert "normalize_python_sdist.py" in build
    assert build.index("python3 -m build") < build.index(
        "normalize_python_sdist.py"
    )

    bootstrap = workflow("sdk-bootstrap-pypi.yml")
    assert "normalize_python_sdist.py" in bootstrap
    assert bootstrap.index("python3 -m build") < bootstrap.index(
        "normalize_python_sdist.py"
    )


def test_python_preflight_provisions_the_declared_build_backend() -> None:
    preflight = workflow("sdk-publish-python.yml")
    package_tests = preflight.index("Test Python SDK package")
    backend = preflight.index('"setuptools==80.9.0"')

    assert backend < package_tests


def test_python_preflight_pins_the_interpreter_before_installing_tools() -> None:
    preflight = workflow("sdk-publish-python.yml")
    setup_action = "actions/setup-python@a309ff8b426b58ec0e2a45f0f869d46889d02405"

    for name in ("bindings-e2e-python", "build"):
        job = workflow_job(preflight, name)
        setup = job.index(setup_action)
        install = job.index("python3 -m pip install")
        assert 'python-version: "3.12.8"' in job
        assert setup < install


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
        "relay-publish-npm.yml",
        "sdk-bootstrap-crates.yml",
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


def test_relay_publisher_owns_the_cmux_relay_dist_tags_exclusively() -> None:
    # The chatmux machine relay publishes ONLY through the cmux-relay-v* tag
    # family. If the coordinated TUI publish or the nightly lane ever grows a
    # cmux-relay npm publish back, a routine TUI release could silently take
    # over cmux-relay@latest from the shipping relay (chatmux relay Rust
    # cutover, chatmux docs/RELAY-RUST.md).
    for name in ("tui-publish-npm.yml", "cmux-tui-nightly.yml"):
        text = workflow(name)
        assert "npm publish --provenance dist/npm-packages/cmux-relay" not in text
        assert (
            "npm publish --provenance --tag nightly dist/npm-packages/cmux-relay"
            not in text
        )
        publish_lists = re.findall(r"packages=\((.*?)\)", text, flags=re.DOTALL)
        assert publish_lists
        for block in publish_lists:
            assert "cmux-relay" not in block


def test_relay_publisher_is_tag_bound_rc_aware_and_attested() -> None:
    text = workflow("relay-publish-npm.yml")

    # Tag-only trigger: no workflow_dispatch bypass, tags pinned to the
    # cmux-relay-v family, and the tag must be an ancestor of protected main.
    triggers = workflow_triggers(text)
    assert set(triggers) == {"push"}
    assert triggers["push"] == {"tags": ["cmux-relay-v*"]}
    assert (
        '[[ "$GITHUB_REF_NAME" =~ ^cmux-relay-v[0-9]+\\.[0-9]+\\.[0-9]+(-rc\\.[0-9]+)?$ ]]'
        in text
    )
    assert 'git merge-base --is-ancestor "$GITHUB_SHA" origin/main' in text

    # Release candidates ride the next dist-tag; only stable versions take
    # latest. Every publish passes the resolved tag explicitly.
    assert 'dist_tag="next"' in text
    assert 'dist_tag="latest"' in text
    assert 'if [[ "$version" == *-rc.* ]]' in text
    assert text.count('npm publish --provenance --tag "$DIST_TAG"') == 2
    assert "npm publish --provenance dist/npm-packages" not in text

    # Same provenance posture as the TUI publisher: trusted-publisher
    # environment, OIDC-capable npm, github-hosted publish runner, contract
    # revalidation, and non-self-hosted attestation verification of every
    # relay binary against the reusable build workflow at this exact ref.
    assert "name: npm-tui" in text
    assert "npm install -g npm@11.5.1" in text
    assert "runs-on: ubuntu-latest" in text
    assert "uses: ./.github/workflows/cmux-tui-build-package.yml" in text
    assert "attest_packages: true" in text
    assert "include_windows: true" in text
    assert "package_pypi: false" in text
    assert "validate_package_contract.py" in text
    assert "--install-npm-relay-package cmux-relay-linux-x64" in text
    assert "gh attestation verify" in text
    assert "--deny-self-hosted-runners" in text
    assert '--source-digest "$GITHUB_SHA"' in text
    assert '--source-ref "$GITHUB_REF"' in text
    assert "persist-credentials: false" in text


if __name__ == "__main__":
    unittest.main()
