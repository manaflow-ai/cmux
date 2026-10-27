set +e
cd webviews
FILES=$(ls test/*.test.tsx test/*.test.ts | grep -E 'new-tab-|environment-picker|chat-new-worktree|started-chat-folder|composer-location-strip|composer-searchable-pickers|composer-menu-width|hideable-chrome' | grep -v -E 'no-entry-motion|field-on-art|paste-attachments|folder-keeps-pick|composer-location-strip|composer-menu-width' )
bun test $FILES src/agent-session/acpmux/ComposerContext.test.ts src/agent-session/acpmux/newtab/NewTabScreen.test.tsx 2>&1 | grep -E '\(fail\)|^ *[0-9]+ (pass|fail)|Ran |error:' | head -60
echo "=== TYPECHECK"
bun run typecheck 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'TS[0-9]+|\]$|Found' | head -40
echo "=== LINT"
bun run lint -- src/agent-session/acpmux/EnvironmentPicker.tsx src/agent-session/acpmux/ComposerContext.tsx src/agent-session/acpmux/environments.ts src/agent-session/acpmux/newtab/NewTabScreen.tsx src/agent-session/acpmux/direct.ts test/environment-picker.test.tsx test/new-tab-saved-environments.test.tsx 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -30
echo "=== PRETTIER"
bunx prettier --check src/agent-session/acpmux/EnvironmentPicker.tsx src/agent-session/acpmux/ComposerContext.tsx src/agent-session/acpmux/environments.ts src/agent-session/acpmux/newtab/NewTabScreen.tsx test/environment-picker.test.tsx test/new-tab-saved-environments.test.tsx src/agent-session/acpmux/composerLocation.css 2>&1 | tail -10
