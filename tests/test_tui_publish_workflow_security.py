import json
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def workflow(name: str) -> str:
    return (ROOT / ".github" / "workflows" / name).read_text()


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
    sdk = workflow("sdk-publish-npm.yml")
    tui = workflow("tui-publish-npm.yml")

    assert "https://www.npmjs.com/package/cmux-sdk" in sdk
    assert "npm publish --provenance" in sdk
    assert "--tag sdk" not in sdk
    assert "confirm_npm_cmux" not in sdk
    assert "publish_target" not in tui
    assert "publish-sdk" not in tui
    assert "confirm_sdk_cmux" not in tui
    assert "https://www.npmjs.com/package/cmux" in tui


def test_python_sdk_publisher_cannot_publish_the_cli_package() -> None:
    sdk = workflow("sdk-publish-python.yml")
    tui = workflow("tui-publish-pypi.yml")

    assert "https://pypi.org/p/cmux-sdk" in sdk
    assert "https://pypi.org/p/cmux" in tui


def test_sdk_release_cut_dispatches_only_the_selected_four_languages() -> None:
    release = workflow("sdk-release-cut.yml")

    assert 'sdk_tag="cmux-sdk-v$VERSION"' in release
    assert 'go_tag="cmux-tui/bindings/go/v$VERSION"' in release
    assert 'git push --atomic origin "refs/tags/$sdk_tag" "refs/tags/$go_tag"' in release
    assert "go-preflight:" in release
    assert "uses: ./.github/workflows/sdk-publish-go.yml" in release
    assert release.index("go-preflight:") < release.index("git push --atomic origin")
    assert 'existing_sha="$(git rev-parse' in release
    assert '"$existing_sha" != "$GITHUB_SHA"' in release
    assert release.count("gh workflow run sdk-publish-") == 4
    for publisher in ("crates", "go", "npm", "python"):
        assert f"dispatch-{publisher}:" in release
        assert f"gh workflow run sdk-publish-{publisher}.yml" in release
    assert "sdk-publish-java.yml" not in release
    for publisher in ("crates", "npm", "python"):
        command = next(
            line
            for line in release.splitlines()
            if f"gh workflow run sdk-publish-{publisher}.yml" in line
        )
        assert "-f confirm_publish=true" in command


def test_go_publisher_uses_the_nested_module_semver_tag() -> None:
    go = workflow("sdk-publish-go.yml")
    java = workflow("sdk-publish-java.yml")

    assert '"cmux-tui/bindings/go/v*"' in go
    assert "cmux-tui/bindings/go/vX.Y.Z" in go
    assert 'version="${GITHUB_REF_NAME#cmux-tui/bindings/go/v}"' in go
    assert "workflow_call:" in go
    assert '"cmux-sdk-v*"' not in go
    assert '"cmux-sdk-v*"' not in java


def test_required_sdk_ci_checks_only_the_publish_set_version() -> None:
    sdk_ci = workflow("cmux-tui-sdks.yml")

    assert "check-versions.py --published-only" in sdk_ci


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
        assert "required: true" in text
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
    for name in ("tui-publish-npm.yml", "cmux-tui-nightly.yml"):
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
