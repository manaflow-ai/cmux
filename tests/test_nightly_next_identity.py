#!/usr/bin/env python3
"""nightly-next ships as cmux NEXT, beside classic NIGHTLY (cx-x7hwx).

Both tracks shipped as cmux NIGHTLY (com.cmuxterm.app.nightly), so installing
one replaced the other. nightly-next is now a tagged-nightly identity: its own
app name, bundle id, socket, daemon session, sign-in scheme and feed, signed
without a provisioning profile, still auto-updating.
"""
from __future__ import annotations

from pathlib import Path
import plistlib
import itertools
import re
import sys
from nightly_workflow_text import nightly_text

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = nightly_text()


def identity_block() -> str:
    match = re.search(r"\n\s*'nightly-next': \{\n(.*?)\n\s*\},", WORKFLOW, re.S)
    assert match, "no nightly-next channelIdentity"
    return match.group(1)


def field(block: str, name: str) -> str:
    match = re.search(rf"{name}: ([^,\n]+),", block)
    assert match, f"no {name}"
    return match.group(1).strip().strip("'")


def env_value(name: str) -> str:
    match = re.search(rf"\n  {name}: (\S+)\n", WORKFLOW)
    assert match, f"no env {name}"
    return match.group(1)


def test_next_has_its_own_identity():
    block = identity_block()
    assert field(block, "bundleId") == "com.cmuxterm.app.nightly.cmux-next"
    assert field(block, "appName") == "cmux NEXT"
    assert field(block, "urlScheme") == "cmux-next"
    assert field(block, "dmgPrefix") == "cmux-nightly-next-macos"


def test_next_signs_without_a_provisioning_profile():
    entitlements = field(identity_block(), "entitlements")
    with open(ROOT / entitlements, "rb") as handle:
        keys = plistlib.load(handle)
    for restricted in ("com.apple.application-identifier", "keychain-access-groups",
                       "com.apple.developer.web-browser.public-key-credential"):
        assert restricted not in keys, f"{entitlements} requests {restricted}, which needs a profile"
    assert "core.setOutput('profile_channel', nightlyProbe ? 'NIGHTLY' : notaryProbe ? 'RELEASE' : track === 'nightly-next' ? '' :" in WORKFLOW
    assert "if: needs.decide.outputs.profile_channel != ''" in WORKFLOW
    assert "core.setOutput('sign_channel', nightlyProbe ? 'nightly' : notaryProbe ? 'stable' : track === 'nightly-next' ? 'next' : channel);" in WORKFLOW


def test_next_signs_in_through_its_own_scheme():
    assert 'Add :LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME string ${CHANNEL_URL_SCHEME}' in WORKFLOW


def test_next_feed_is_new_and_still_classified_as_nightly_next():
    base = env_value("NIGHTLY_NEXT_FEED_BASE")
    legacy = env_value("NIGHTLY_NEXT_LEGACY_FEED_BASE")
    # UpdateFeedResolver classifies the track by "/nightly-next/" in the feed URL.
    assert "/nightly-next/" in base + "/" and base != legacy
    assert env_value("NIGHTLY_NEXT_R2_PREFIX") == "nightly-next/next/"
    # Every build-number check keeps NEXT above the old feed and classic NIGHTLY,
    # and tolerates the new feed before its first publication.
    checks = re.findall(r'feeds\+=\(([^)]*)\)', WORKFLOW)
    next_checks = [c for c in checks if "NIGHTLY_NEXT_FEED_BASE" in c]
    assert next_checks
    for check in next_checks:
        assert '--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}"' in check, check
        assert '--feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}"' in check, check
        assert '--feed "https://files.cmux.com/nightly/${appcast}"' in check, check


def test_packaging_scripts_know_the_next_channel():
    metadata = (ROOT / "scripts/verify-app-bundle-channel-metadata.sh").read_text()
    assert re.search(r'next\)\n\s*EXPECTED_NAME="cmux NEXT"\n\s*EXPECTED_BUNDLE_ID="com.cmuxterm.app.nightly.cmux-next"', metadata)
    notarize = (ROOT / "scripts/ci/notarize-nightly-dmg.sh").read_text()
    assert 'next) ENTITLEMENTS_NAME="cmux.next-dev.entitlements"' in notarize


def test_a_pending_notarization_keeps_its_recovery_artifact():
    # notarize-nightly-dmg.sh records CMUX_CHANNEL (sign_channel, `next`) in the
    # state file; the recovery artifact must compare against that, not the
    # release channel, or a submission past the wait is stranded.
    step = WORKFLOW[WORKFLOW.index("- name: Prepare pending notarization recovery artifact"):]
    step = step[:step.index("\n      - name:", 10)]
    assert "SIGN_CHANNEL: ${{ needs.decide.outputs.sign_channel }}" in step
    assert '"$SIGN_CHANNEL" <<' in step
    assert 'state["channel"] != sign_channel' in step


def test_release_notes_history_carries_over_from_the_old_feed():
    assert 'for base in "${NIGHTLY_NEXT_FEED_BASE}" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}"; do' in WORKFLOW


def job_block(name: str) -> str:
    match = re.search(rf"\n  {name}:\n(.*?)(?=\n  [a-z0-9-]+:\n|\Z)", WORKFLOW, re.S)
    assert match, f"no job {name}"
    return match.group(1)


def job_containing(text: str) -> str:
    at = WORKFLOW.index(text)
    name = re.findall(r"\n  ([a-z0-9-]+):\n", WORKFLOW[:at])[-1]
    return job_block(name)


def job_env(block: str, name: str) -> str:
    match = re.search(rf"\n      {name}: ([^\n]+)\n", block)
    assert match, f"no job env {name}"
    value = match.group(1)
    # A YAML anchor (`&name value`) or alias (`*name`, #30278 shares env values to keep nightly.yml
    # under GitHub's size limit) reads as the anchored value, as YAML does.
    alias = re.fullmatch(r"\*([A-Za-z0-9_-]+)", value)
    if alias:
        anchors = re.findall(rf"[ :]&{re.escape(alias[1])} ([^\n]+)\n", WORKFLOW)
        assert len(anchors) == 1, f"alias *{alias[1]} has {len(anchors)} anchors"
        value = anchors[0]
    return re.sub(r"^&[A-Za-z0-9_-]+ ", "", value)


def test_each_app_reads_the_feed_its_publisher_writes():
    # Leo, 2026-10-25: "but where are the nightlies?" cmux NIGHTLY checks the old
    # feed; an app whose SUFeedURL names a feed no job writes never updates.
    host = "https://files-next.cmux.com/"
    next_base = env_value("NIGHTLY_NEXT_FEED_BASE")
    legacy_base = env_value("NIGHTLY_NEXT_LEGACY_FEED_BASE")
    # cmux NEXT: SUFeedURL is feedBase/appcast-<variant>.xml; the upload writes
    # NIGHTLY_NEXT_R2_PREFIX + each of the track's feeds, served from the same path.
    assert field(identity_block(), "feedBase") == "process.env.NIGHTLY_NEXT_FEED_BASE"
    # The signing job hands prepare_variant decide's feedBase, and prepare_variant
    # writes its third argument into SUFeedURL.
    builder = job_containing("          prepare_variant \\\n")
    # The cmux NIGHTLY identity's steps at the end of the same job bake the old feed (checked below).
    builder, folded = builder[:builder.index(FOLDED)], builder[builder.index(FOLDED):]
    assert job_env(builder, "CHANNEL_FEED_BASE") == "${{ needs.decide.outputs.feed_base }}"
    assert "\n      feed_base: ${{ steps.decide.outputs.feed_base }}\n" in job_block("decide")
    assert "core.setOutput('feed_base', channelIdentity.feedBase);" in WORKFLOW
    assert re.search(r'\n {10}prepare_variant \\\n {12}"\$APP_DIR" \\\n {12}"\$CHANNEL_BUNDLE_ID" \\\n {12}"\$\{CHANNEL_FEED_BASE\}/\$\{NIGHTLY_APPCAST\}"\n', builder)
    assert 'local feed_url="$3"' in builder and builder.count(":SUFeedURL string") == 1
    # ...and nothing reassigns the values between the checks above and their use.
    assert len(re.findall(r"\bfeed_url=", builder)) == 1
    decide = job_block("decide")
    assert len(re.findall(r"\b(?:variants|feeds)\b\s*(?:\[[^\]]*\]\s*)?(?:\.(?:push|unshift|splice|fill|reverse|sort)\b|=(?!=))", decide)) == 2
    assert 'Add :SUFeedURL string ${feed_url}"' in builder
    # The arm64 variant bakes appcast-arm64.xml (only universal keeps appcast.xml).
    assert ('          if [ "$NIGHTLY_VARIANT" = "universal" ]; then\n            NIGHTLY_APPCAST="appcast.xml"\n'
            '          else\n            NIGHTLY_APPCAST="appcast-${NIGHTLY_VARIANT}.xml"\n          fi\n') in builder
    assert builder.count("NIGHTLY_APPCAST=") == 3, "the two assignments above, and its export"
    # nightly-next builds only arm64, so it bakes and publishes only appcast-arm64.xml.
    assert "const variants = fastBuild || track === 'nightly-next' ? ['arm64'] :" in WORKFLOW
    assert "const feeds = track === 'nightly-next'\n              ? ['appcast-arm64.xml']\n" in WORKFLOW
    upload = WORKFLOW[WORKFLOW.index("- name: Upload nightly-next appcasts to R2"):]
    upload = upload[:upload.index("\n      - name:", 10)]
    # publish-nightly-next-r2.py write-feed puts nightly-out/<feed> at NIGHTLY_NEXT_R2_PREFIX + <feed>
    # in NIGHTLY_NEXT_R2_BUCKET (compare-and-swap).
    assert 'for appcast in $NIGHTLY_FEEDS; do' in upload
    assert 'publish-nightly-next-r2.py" write-feed --feed "nightly-out/$appcast"' in upload
    writer = (ROOT / "scripts/ci/publish-nightly-next-r2.py").read_text()
    assert 'key = env("NIGHTLY_NEXT_R2_PREFIX") + feed.name' in writer
    assert '"--bucket", env("NIGHTLY_NEXT_R2_BUCKET"), "--key", key' in writer
    # ...and NIGHTLY_FEEDS in that job is decide's feed list, the one checked above.
    publisher = job_containing("- name: Upload nightly-next appcasts to R2")
    assert job_env(publisher, "NIGHTLY_FEEDS") == "${{ needs.decide.outputs.feeds }}"
    assert "\n      feeds: ${{ steps.decide.outputs.feeds }}\n" in job_block("decide")
    assert "core.setOutput('feeds', feeds.join(' '));" in WORKFLOW
    assert next_base + "/" == host + env_value("NIGHTLY_NEXT_R2_PREFIX")
    # files-next.cmux.com serves this bucket; both uploaders write to it.
    assert env_value("NIGHTLY_NEXT_R2_BUCKET") == "cmux-nightly-next"
    assert len(re.findall(r"\bNIGHTLY_NEXT_R2_BUCKET\s*[:=]", WORKFLOW)) == 1
    # cmux NIGHTLY: the legacy sign job bakes LEGACY_BASE/LEGACY_APPCAST, and the
    # legacy publish job uploads that same key.
    sign = job_block("sign-nightly-identity-legacy")
    publish = job_block("publish-nightly-identity-legacy")
    assert job_env(sign, "LEGACY_APPCAST") == job_env(publish, "LEGACY_APPCAST") == "appcast-arm64.xml"
    assert sign.count("LEGACY_FEED_URL=") == 2, "one assignment, one pass to the script"
    assert 'LEGACY_FEED_URL="${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"' in sign
    # The script is handed that variable (no other value), and writes it into SUFeedURL.
    assert re.search(r'LEGACY_FEED_URL="\$LEGACY_FEED_URL" \\\n(?:\s+[A-Z_]+="[^"\n]*" \\\n)*\s+\./scripts/ci/nightly-next-legacy-identity\.sh ', sign)
    script = (ROOT / "scripts/ci/nightly-next-legacy-identity.sh").read_text()
    assert 'pb "Set :SUFeedURL $LEGACY_FEED_URL"' in script and script.count(":SUFeedURL") == 1
    assert f'prefix="${{NIGHTLY_NEXT_LEGACY_FEED_BASE#{host}}}"' in publish
    assert 'upload "legacy-out/$LEGACY_APPCAST" "$prefix/$LEGACY_APPCAST"' in publish
    # upload() puts its file at its second argument, the key checked above.
    assert publish.count("--key ") == 1 and publish.count("--bucket ") == 1
    assert '--bucket "$NIGHTLY_NEXT_R2_BUCKET" --key "$2"' in publish
    assert len(re.findall(r"\bprefix=", publish)) == 1
    for block in (sign, publish):
        assert not re.search(r"\bLEGACY_APPCAST=|\bLEGACY_FEED_URL\s*=\s*[^\"$]", block)
    # The same sign, folded into build-sign-notarize-nightly, bakes the same feed.
    main = job_block("build-sign-notarize-nightly")
    assert job_env(main, "LEGACY_APPCAST") == "appcast-arm64.xml"
    assert folded.count("LEGACY_FEED_URL=") == 2 and 'LEGACY_FEED_URL="${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"' in folded
    assert not re.search(r"\bLEGACY_APPCAST=|\bLEGACY_FEED_URL\s*=\s*[^\"$]", folded)
    assert legacy_base.startswith(host) and legacy_base != next_base
    # legacy-identity-target picks the candidate by comparing cmux NEXT's feed with this one.
    target = job_block("legacy-identity-target")
    assert '-o old-all.xml "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"' in target
    assert '-o next-all.xml "${NIGHTLY_NEXT_FEED_BASE}/${LEGACY_APPCAST}"' in target
    assert re.findall(r"\n\s+LEGACY_APPCAST: (\S+)\n", target) == ["appcast-arm64.xml"]


FOLDED = '      - name: "cmux NIGHTLY identity: '


def job_if(name: str) -> str:
    match = re.search(r'\n    if: "(.*)"\n', job_block(name))
    assert match, f"no if on {name}"
    return match.group(1)


def evaluate(expression: str, values: dict[str, str]) -> bool:
    """Evaluates a job `if` of ==/!= comparisons joined by &&, || and parentheses."""
    def term(match: re.Match[str]) -> str:
        left, op, right = match.group(1), match.group(2), match.group(3).strip("'")
        assert left in values, f"no value for {left}"
        return str((values[left] == right) == (op == "=="))
    expression = expression.replace("!cancelled()", "True")
    # The decision of whichever job signed (the main job's copy when legacy_ran, else legacy-identity-target);
    # without a main-job value the case reads the target's.
    def target(match: re.Match[str]) -> str:
        field = match.group(1)
        ran = values.get("needs.build-sign-notarize-nightly.outputs.legacy_ran") == "true"
        name = f"needs.build-sign-notarize-nightly.outputs.legacy_target_{field}"
        return name if ran and name in values else f"needs.legacy-identity-target.outputs.{field}"
    expression = re.sub(r"\(needs\.build-sign-notarize-nightly\.outputs\.legacy_ran == 'true' && "
                        r"needs\.build-sign-notarize-nightly\.outputs\.legacy_target_([a-z_]+) \|\| "
                        r"needs\.legacy-identity-target\.outputs\.\1\)", target, expression)
    expression = re.sub(r"(needs\.publish-nightly\.outputs\.build) == "
                        r"(needs\.(legacy-identity-target|build-sign-notarize-nightly)\.outputs\.(legacy_target_)?build)",
                        lambda _: str(values["same_build"] == "true"), expression)
    expression = re.sub(r"([a-z][\w.-]*) (==|!=) ('[^']*')", term, expression)
    return eval(expression.replace("&&", " and ").replace("||", " or "), {})  # noqa: S307 - only True/False remain


def test_the_old_feed_signs_only_a_build_its_publisher_can_publish():
    # Run 41931011216 yielded its sign to a newer build (publish-nightly skipped), yet its legacy sign held the
    # only signing runner for a DMG publish-nightly-identity-legacy then refused, while two newer runs waited.
    sign, publish = job_if("sign-nightly-identity-legacy"), job_if("publish-nightly-identity-legacy")
    fixed = {
        "github.repository": "manaflow-ai/cmux", "github.ref": "refs/heads/nightly-next",
        "needs.decide.outputs.track": "nightly-next", "needs.decide.outputs.environment": "release-next",
        "needs.decide.outputs.notary_paused": "false", "needs.legacy-identity-target.result": "success",
        "needs.legacy-identity-target.outputs.build": "4193101121601", "vars.NIGHTLY_NEXT_LEGACY_IDENTITY": "",
        "needs.sign-nightly-identity-legacy.result": "success",
    }
    checked = 0
    for result in ("success", "skipped", "failure", "cancelled"):
        for refused in ("true", "false"):
            for same in ("true", "false"):
                for action in ("new", "continue"):
                    for source_run, legacy_ran in itertools.product(("41931011216", ""), ("true", "")):
                        values = dict(fixed, same_build=same, **{
                            "needs.build-sign-notarize-nightly.outputs.legacy_ran": legacy_ran,
                            "needs.publish-nightly.result": result, "needs.publish-nightly.outputs.refused": refused,
                            "needs.legacy-identity-target.outputs.action": action,
                            "needs.legacy-identity-target.outputs.source_run": source_run})
                        case = (f"publish-nightly {result} refused={refused} same build={same} {action} "
                                f"source={source_run!r} signed in the main job={legacy_ran!r}")
                        # Signed once: by the main job (legacy_ran) or here, and only what the publish can publish.
                        assert evaluate(sign, values) == (evaluate(publish, values) and legacy_ran != "true"), case
                        checked += 1
    yielded = dict(fixed, same_build="false", **{
        "needs.publish-nightly.result": "skipped", "needs.publish-nightly.outputs.refused": "",
        "needs.legacy-identity-target.outputs.action": "new",
        "needs.legacy-identity-target.outputs.source_run": "41931011216",
        "needs.build-sign-notarize-nightly.outputs.legacy_ran": ""})
    assert not evaluate(sign, yielded), "a yielded run's legacy sign still takes the signing runner"
    published = dict(yielded, same_build="true", **{"needs.publish-nightly.result": "success",
                                                    "needs.publish-nightly.outputs.refused": "false"})
    assert evaluate(sign, published), "the run cmux NEXT published no longer signs the old feed"
    assert checked == 128
    assert not evaluate(sign, dict(published, **{"needs.build-sign-notarize-nightly.outputs.legacy_ran": "true"})), \
        "the old feed's build signed twice: in the main job and again here"


def test_the_old_feed_is_signed_in_the_same_job_as_cmux_next():
    # Leo, 2026-11-05: "JUST POINT ME TO THE ONE APP/THE ONE FEED", "THERE SHOULDN'T BE 2". Run 41900945757 published
    # cmux NEXT at 00:2xZ while its cmux NIGHTLY sign queued behind three newer runs' signs on the one signing runner.
    raw = (ROOT / ".github/workflows/nightly.yml").read_text()
    main = re.search(r"\n  build-sign-notarize-nightly:\n(.*?)(?=\n  [a-z0-9-]+:\n)", raw, re.S).group(1)
    assert FOLDED in main, "cmux NIGHTLY is signed only by a later, separately queued job"
    steps = main[main.index(FOLDED):main.index("\n      - name: Cleanup keychain\n")]
    assert main.index("        id: notarize-nightly\n") < main.index(FOLDED), "the copy runs after cmux NEXT's DMG is final"
    blocks = steps.split("\n      - name: ")
    assert len(blocks) == 17, len(blocks)
    for block in blocks:
        # A failed or slow copy never fails or times out cmux NEXT's job.
        assert "\n        continue-on-error: true\n" in block, block[:80]
        assert "\n        timeout-minutes: " in block or "uses: actions/upload-artifact@" in block, block[:80]
    # The same scripts as the separate job for a new build of this run (no continue, no pending download).
    separate = job_block("sign-nightly-identity-legacy")
    raw_separate = re.search(r"\n  sign-nightly-identity-legacy:\n(.*?)(?=\n  [a-z0-9-]+:\n)", raw, re.S).group(1)
    used = set(re.findall(r"scripts/ci/nightly-steps/(legacy-identity-[a-z-]+\.sh)", steps))
    assert used == set(re.findall(r"scripts/ci/nightly-steps/(legacy-identity-[a-z-]+\.sh)", raw_separate)) - {
        "legacy-identity-sign-download-pending.sh"} | {"legacy-identity-compare-feeds.sh"}, used
    assert separate
    # Only this run's own new build, at this commit; everything else stays with the separate job.
    here = re.search(r"\n      LEGACY_HERE: \$\{\{ (.*) && 'true' \|\| 'false' \}\}\n", main).group(1)
    order = re.search(r"\n        id: legacy-order\n        if: (.*)\n", main).group(1)
    base = {
        "needs.decide.outputs.track": "nightly-next", "matrix.variant": "arm64",
        "needs.decide.outputs.environment": "release-next", "needs.decide.outputs.notary_probe": "false",
        "needs.decide.outputs.build_only": "false", "vars.NIGHTLY_NEXT_LEGACY_IDENTITY": "",
        "steps.legacy-target.outcome": "success", "steps.legacy-target.outputs.decided": "true",
        "steps.legacy-target.outputs.action": "new",
    }
    def run_here(**changes: str) -> bool:
        values = dict(base, **changes)
        expression = here.replace("needs.resolve-nightly-cmux-tui-client.outputs.build_sha == github.sha",
                                  str(values.pop("own_commit", "true") == "true"))
        decided = order.replace("steps.legacy-target.outputs.source_run == format('{0}', github.run_id)",
                                str(values.pop("own_run", "true") == "true"))
        decided = decided.replace("steps.legacy-target.outputs.build == needs.build-nightly-app.outputs.daemon_build",
                                  str(values.pop("own_build", "true") == "true"))
        return evaluate(expression, values) and evaluate(decided, values)
    assert run_here()
    assert not run_here(own_run="false"), "another run's build (a recovered or source-less target)"
    assert not run_here(own_build="false") and not run_here(own_commit="false")
    assert not run_here(**{"steps.legacy-target.outputs.action": "continue"})
    assert not run_here(**{"steps.legacy-target.outcome": "failure"}), "a failed comparison leaves the copy to the separate job"
    assert not run_here(**{"steps.legacy-target.outputs.decided": ""})
    assert not run_here(**{"needs.decide.outputs.track": "nightly"}) and not run_here(**{"matrix.variant": "x86_64"})
    assert not run_here(**{"vars.NIGHTLY_NEXT_LEGACY_IDENTITY": "off"})
    # Whichever job signed, verify, publish and the report read its outputs.
    outputs = set(re.findall(r"\n      (legacy_[a-z0-9_]+): ", main))
    assert "legacy_ran" in outputs
    for job in ("verify-nightly-identity-legacy", "publish-nightly-identity-legacy", "nightly-identity-legacy-published"):
        block = job_block(job)
        assert "build-sign-notarize-nightly" in re.search(r"(?:^|\n)    needs: \[(.*)\]\n", block).group(1), job
        for field in re.findall(r"needs\.sign-nightly-identity-legacy\.outputs\.([a-z0-9_]+)", block):
            folded = (f"(needs.build-sign-notarize-nightly.outputs.legacy_ran == 'true' && "
                      f"needs.build-sign-notarize-nightly.outputs.legacy_{field} || "
                      f"needs.sign-nightly-identity-legacy.outputs.{field})")
            assert block.count(folded) == block.count(f"needs.sign-nightly-identity-legacy.outputs.{field}"), (job, field)
            assert f"legacy_{field}" in outputs, field
        # legacy-identity-target's decision: the main job's own when it signed (legacy_ran).
        for field in re.findall(r"needs\.legacy-identity-target\.outputs\.([a-z0-9_]+)", block):
            if field in ("pending_run", "bundle_run"):
                # The main job copies only a new build: no pending submission to continue.
                read = (f"needs.build-sign-notarize-nightly.outputs.legacy_ran != 'true' && "
                        f"needs.legacy-identity-target.outputs.{field} || ''")
            else:
                read = (f"(needs.build-sign-notarize-nightly.outputs.legacy_ran == 'true' && "
                        f"needs.build-sign-notarize-nightly.outputs.legacy_target_{field} || "
                        f"needs.legacy-identity-target.outputs.{field})")
                assert f"legacy_target_{field}" in outputs, field
            assert block.count(read) == block.count(f"needs.legacy-identity-target.outputs.{field}"), (job, field)
    assert ("SIGN_RESULT: ${{ needs.build-sign-notarize-nightly.outputs.legacy_ran == 'true' && 'success' || "
            "needs.sign-nightly-identity-legacy.result }}") in job_block("publish-nightly-identity-legacy")


def test_cmux_next_never_waits_for_the_old_feeds_target_job():
    # The Codex review of #35994 (P1, issue #36103): build-sign-notarize-nightly needed legacy-identity-target, whose
    # feed and API reads may take its full 65 minutes, so a GitHub API outage held cmux NEXT's sign and publication
    # for up to an hour. The copy now decides in its own first step, bounded by 10 minutes.
    raw = (ROOT / ".github/workflows/nightly.yml").read_text()
    main = re.search(r"\n  build-sign-notarize-nightly:\n(.*?)(?=\n  [a-z0-9-]+:\n)", raw, re.S).group(1)
    needs = re.search(r"\n    needs: \[(.*)\]\n", main).group(1).split(", ")
    assert "legacy-identity-target" not in needs, "cmux NEXT's sign waits for legacy-identity-target"
    assert "needs.legacy-identity-target." not in main
    first = main[main.index(FOLDED):].split("\n      - name: ")[0]
    assert "\n        id: legacy-target\n" in first, "the copy's first step is not its own feed comparison"
    minutes = int(re.search(r"\n        timeout-minutes: (\d+)\n", first).group(1))
    assert minutes <= 10 and "\n        continue-on-error: true\n" in first, minutes
    assert "bash scripts/ci/nightly-steps/legacy-identity-compare-feeds.sh" in first
    # legacy-identity-target still records refusals on the failure issue and deletes refused pending artifacts.
    assert '\n          LEGACY_TARGET_RECORD: "off"\n' in first
    script = (ROOT / "scripts/ci/nightly-steps/legacy-identity-compare-feeds.sh").read_text()
    assert 'if [ "$record" = on ] && [ "$action" = continue ]' in script
    assert 'if [ "$record" = on ] && [ -n "$notes" ]; then' in script
    assert "gh api -X DELETE" in script.split('if [ "$record" = on ] && [ "$action" = continue ]')[1].split("\ndone\n")[0]


def main() -> int:
    tests = [(name, fn) for name, fn in globals().items() if name.startswith("test_") and callable(fn)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"ok   {name}")
        except Exception as error:  # noqa: BLE001 - report every failure
            failed += 1
            print(f"FAIL {name}: {error!r}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
