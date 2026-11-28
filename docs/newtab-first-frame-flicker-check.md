# New Tab first-frame flicker check

The New Tab and split composer must show the same pixels in their first frame and after the
page settles. A late model/effort label, project reorder, theme read, or remount is a perceived
flicker even when the page eventually reaches the right state.

`NewTabPerceivedFlickerTests` is the detector. It stores the native `AgentPaneNewTabFrame` at a
full New Tab size and at a split target size, then compares every RGBA pixel with the settled
frame. A non-zero count fails the test. Keep both sizes in the test when changing cover,
prewarm, or first-frame adoption code.
