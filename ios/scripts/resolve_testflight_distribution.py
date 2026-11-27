#!/usr/bin/env python3
"""Resolve one TestFlight distribution lane for GitHub Actions and tests."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import NamedTuple


class DistributionDecision(NamedTuple):
    bundle_id: str
    display_name: str
    profile_type: str
    expected_app_id: str
    assign_external_group: bool
    assign_internal_group: bool
    metadata_artifact: str
    upload_mode: str
    audience: str
    review_note: str


def resolve_distribution(
    variant: str,
    marketing_version_override: str,
) -> DistributionDecision:
    override = marketing_version_override.strip()
    if variant not in {"internal", "demo"}:
        raise ValueError(f"unsupported TestFlight variant: {variant}")
    if override and variant == "demo":
        raise ValueError(
            "variant=demo cannot be combined with marketing_version_override"
        )
    if override:
        return DistributionDecision(
            bundle_id="dev.cmux.app.beta",
            display_name="cmux BETA",
            profile_type="beta",
            expected_app_id="7WLXT3NR37.dev.cmux.app.beta",
            assign_external_group=True,
            assign_internal_group=False,
            metadata_artifact="ios-testflight-build-metadata-override",
            upload_mode="marketing_version_override",
            audience="external TestFlight testers",
            review_note="Beta App Review may be required",
        )
    if variant == "demo":
        return DistributionDecision(
            bundle_id="dev.cmux.app.demo",
            display_name="cmux DEMO",
            profile_type="demo",
            expected_app_id="7WLXT3NR37.dev.cmux.app.demo",
            assign_external_group=False,
            assign_internal_group=True,
            metadata_artifact="ios-testflight-build-metadata-demo",
            upload_mode="checked_in_version",
            audience="internal TestFlight group",
            review_note="no beta review needed",
        )
    return DistributionDecision(
        bundle_id="dev.cmux.app.internal",
        display_name="cmux INTERNAL",
        profile_type="internal",
        expected_app_id="7WLXT3NR37.dev.cmux.app.internal",
        assign_external_group=False,
        assign_internal_group=True,
        metadata_artifact="ios-testflight-build-metadata",
        upload_mode="checked_in_version",
        audience="internal TestFlight group",
        review_note="no beta review needed",
    )


def _values(decision: DistributionDecision) -> dict[str, str]:
    return {
        "bundle_id": decision.bundle_id,
        "display_name": decision.display_name,
        "profile_type": decision.profile_type,
        "expected_app_id": decision.expected_app_id,
        "assign_external_group": "1" if decision.assign_external_group else "0",
        "assign_internal_group": "1" if decision.assign_internal_group else "0",
        "metadata_artifact": decision.metadata_artifact,
        "upload_mode": decision.upload_mode,
        "audience": decision.audience,
        "review_note": decision.review_note,
    }


def _append_values(path: Path, values: dict[str, str]) -> None:
    with path.open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", required=True)
    parser.add_argument("--marketing-version-override", default="")
    parser.add_argument("--github-env", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    args = parser.parse_args()
    try:
        decision = resolve_distribution(
            args.variant,
            args.marketing_version_override,
        )
    except ValueError as error:
        parser.error(str(error))

    values = _values(decision)
    _append_values(args.github_output, values)
    _append_values(args.github_env, {
        "IOS_BETA_BUNDLE_ID": decision.bundle_id,
        "IOS_BETA_DISPLAY_NAME": decision.display_name,
        "IOS_BETA_PROFILE_TYPE": decision.profile_type,
        "IOS_BETA_EXPECTED_APP_ID": decision.expected_app_id,
        "CMUX_TESTFLIGHT_ASSIGN_EXTERNAL_GROUP": values[
            "assign_external_group"
        ],
        "IOS_TESTFLIGHT_UPLOAD_MODE": decision.upload_mode,
        "IOS_TESTFLIGHT_AUDIENCE": decision.audience,
        "IOS_TESTFLIGHT_REVIEW_NOTE": decision.review_note,
    })


if __name__ == "__main__":
    main()
