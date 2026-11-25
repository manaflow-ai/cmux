# 2026-11-24-app-compile-fleet-4

Above `pending) verdict=unavailable; summary="The build fleet kept the compile of \'$REF\' queued past t...` in the step `Compile-check the app at the pull request's head on the build fleet`'s script (job `app-compile-fleet`) in `.github/workflows/cmux-next.yml`.

pending: the controller holds this head's check but the fleet kept it queued or running past the wait. Like a
cmux-ci exit 75 (652 of 1030 red runs re-queued, 2026-11-23/24) it is a warning, and the
Release compile at land, plus the fallback where mac_release asks for it, still compile the head.
