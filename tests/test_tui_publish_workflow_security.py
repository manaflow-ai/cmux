from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def workflow(name: str) -> str:
    return (ROOT / ".github" / "workflows" / name).read_text()


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
