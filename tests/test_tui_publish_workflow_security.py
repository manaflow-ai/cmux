from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def workflow(name: str) -> str:
    return (ROOT / ".github" / "workflows" / name).read_text()


def test_stable_registry_publishers_are_exact_tag_bound() -> None:
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
        assert "checkout_ref: ${{ needs.validate-version.outputs.release_sha }}" in text
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


def test_release_cut_dispatches_top_level_publishers_at_the_tagged_main_commit() -> None:
    release_cut = workflow("cmux-tui-release-cut.yml")
    assert "ref: ${{ github.sha }}" in release_cut
    assert 'gh workflow run tui-publish-npm.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"' in release_cut
    assert 'gh workflow run tui-publish-pypi.yml --repo "$GITHUB_REPOSITORY" --ref "$TAG"' in release_cut
    for name in ("tui-publish-npm.yml", "tui-publish-pypi.yml"):
        assert "workflow_call:" not in workflow(name)
