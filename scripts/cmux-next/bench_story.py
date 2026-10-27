#!/usr/bin/env python3
"""The perf-lab story a bench run records result-v1 into (scripts/perf-lab/stories.d/<id>.json).

A story names one engine (its `engine` field), and its series hold that engine's samples only: the WebKit arms are
separate stories (palette-open-webkit, omnibar-click-webkit). `story_problem` is the check every bench runs before
it launches with --story, so a WebKit run never writes under a Chromium story.
"""
import json
import os
import re

STORIES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "perf-lab", "stories.d")
STORY_ID = re.compile(r"[a-z0-9][a-z0-9-]*")


def story_problem(story, engine, stories=STORIES):
    """None when `story` is in `stories` with engine `engine`; otherwise why a run of `engine` must not record
    result-v1 under it."""
    if not STORY_ID.fullmatch(story or ""):
        return f"--story {story!r} is not a story id (lowercase letters, digits and hyphens)"
    path = os.path.join(stories, f"{story}.json")
    try:
        with open(path) as handle:
            declared = json.load(handle).get("engine")
    except FileNotFoundError:
        return f"--story {story!r} is not in scripts/perf-lab/stories.d"
    except (OSError, ValueError) as error:
        return f"--story {story!r}: {path}: {error}"
    if declared != engine:
        return f"--story {story!r} has engine {declared!r} in stories.d; this run measures {engine!r}"
    return None
