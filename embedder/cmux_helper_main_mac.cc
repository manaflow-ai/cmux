// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_helper_main_mac.cc -- entry point for the cmux helper apps
// (renderer/gpu/plugin/default). In a real build this forwards to
// //content's ContentMainRunner, the same way chrome/app/
// chrome_exe_main_mac.cc does for Chrome's helpers. In the stub
// build it simply returns 0 so each Helper.app's executable links
// and runs.
//
// Lands at src/cmux/embedder/cmux_helper_main_mac.cc in the fork.

int main(int /*argc*/, char** /*argv*/) {
  return 0;
}
