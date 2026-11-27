# App Store (manifest only)

The App Store page is built into cmux (native pane `app-store` today, the React page after R62). This manifest gives it the same `presentation` fields as every other app (app-platform.md 16): sidebar item at the top with order 10, the `app` screen, Open as Tab, and the search field as the typing target. Its backend is the `cmux.apps.*` ops (section 15).
