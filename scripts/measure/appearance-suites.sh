#!/usr/bin/env bash
# Settings, theme and launch appearance suites (green evidence).
set -uo pipefail
./scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext "LaunchAppearanceTests,SettingsControllerTests,SettingsWriteTests,SettingsWritePathTests,SettingsActionWritePathTests,SettingsPreviewTests,SocketSettingsWriteTests,BackdropArtSettingsTests,AppThemeGlobalStateTests,WindowBackgroundLiveTests,DefaultThemeTests,OnboardingThemeWriteTests,AppearanceAndTerminalFontSettingsTests,ManagedSettingActionTests" > /tmp/appearance-suites.log 2>&1; echo "lane exit $?"
grep -E "✘|Test run with|error:" /tmp/appearance-suites.log | grep -v " started" | head -40
tail -n 25 /tmp/appearance-suites.log
