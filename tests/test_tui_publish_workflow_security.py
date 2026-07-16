from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def workflow(name: str) -> str:
    return (ROOT / ".github" / "workflows" / name).read_text()


def test_stable_registry_publishers_are_main_only_and_tag_bound() -> None:
    for name, environment in (
        ("tui-publish-npm.yml", "npm-tui"),
        ("tui-publish-pypi.yml", "pypi-tui"),
    ):
        text = workflow(name)
        assert 'if [[ "$GITHUB_REF" != "refs/heads/main" ]]' in text
        assert 'tag="cmux-tui-v$DISPATCH_VERSION"' in text
        assert 'git rev-parse "refs/tags/$tag^{commit}"' in text
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
