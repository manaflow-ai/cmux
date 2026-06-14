# CmuxCore embedder ABI changelog

Tracks every change to `cmux_browser.h`. Bump `CMUX_EMBEDDER_ABI_VERSION`
on any breaking change (function signature, struct layout, enum
value semantic). Additive changes (new function appended to header)
do not require a bump; consumers detect them via `dlsym`/weak-link.

The Swift package's `CmuxBrowserEngine.swift` pins
`CMUX_EMBEDDER_MIN_ABI` and `CMUX_EMBEDDER_MAX_ABI`. Framework load
fails with `CMUX_E_ABI_MISMATCH` if the loaded version is outside
that range.

## v1 — initial (unpublished, fork repo not yet created)

- Sessions: `cmux_session_{init,shutdown,run_once,last_error_string}`.
- Profiles: `cmux_profile_{open,close,get_cookies,set_cookie,delete_cookie,remove_data}`.
- Views: `cmux_view_{create,close,load_url,load_html,reload,go_back,go_forward,stop,can_go_back,can_go_forward,url,title,is_loading,estimated_progress,set_page_zoom,page_zoom,evaluate_js,set_script_message_handler,add_user_script,remove_all_user_scripts,set_navigation_action_cb,set_navigation_did_finish_cb,take_snapshot}`.
- Out of v1 (deferred): downloads, find-in-page, devtools/inspector,
  print, WebAuthn surface, extensions, WebRTC/getUserMedia permission
  decisions, push notifications.
