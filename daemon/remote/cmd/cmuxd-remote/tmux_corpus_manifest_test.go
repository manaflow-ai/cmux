package main

import "testing"

func TestTmuxCorpusPRLaneSourcesExerciseRuntimeBehavior(t *testing.T) {
	cases := []struct {
		source string
		run    func(*testing.T)
	}{
		{"regress/command-order.sh", TestTmuxCorpusNewSessionAndNewWindowCommandsDispatchShellText},
		{"regress/control-client-sanity.sh", TestTmuxCorpusHasSessionReturnSemantics},
		{"regress/control-client-size.sh", TestTmuxCorpusWebSocketPTYInitialSizeAndResizeControl},
		{"regress/format-strings.sh", TestTmuxCorpusFormatStringsSupportedSubset},
		{"regress/has-session-return.sh", TestTmuxCorpusHasSessionReturnSemantics},
		{"regress/input-keys.sh", TestTmuxCorpusSendKeysAndTTYKeyTokens},
		{"regress/kill-session-process-exit.sh", TestWebSocketPTYRunsShellOverBinaryFrames},
		{"regress/new-session-command.sh", TestTmuxCorpusNewSessionAndNewWindowCommandsDispatchShellText},
		{"regress/new-session-environment.sh", TestWebSocketPTYSeedsUTF8LocaleAndTerminalEnv},
		{"regress/new-session-no-client.sh", TestTmuxCorpusNewSessionAndNewWindowCommandsDispatchShellText},
		{"regress/new-session-size.sh", TestTmuxCorpusWebSocketPTYInitialSizeAndResizeControl},
		{"regress/new-window-command.sh", TestTmuxCorpusNewSessionAndNewWindowCommandsDispatchShellText},
		{"regress/session-group-resize.sh", TestWebSocketPTYMultiAttachUsesSmallestResize},
	}

	for _, tc := range cases {
		t.Run(tc.source, tc.run)
	}
}
