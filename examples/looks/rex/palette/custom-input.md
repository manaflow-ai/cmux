# Custom input: source contract and cmux alternative

Source: [official Custom UI, Asking for Text](https://www.superlogical.com/rex/docs/customize/custom-ui#asking-for-text).

The source `ui.input` API requires a title, accepts placeholder, initial value,
confirmation label and timeout, and returns the exact submitted text. Leading
and trailing spaces and an empty answer are valid. The timeout defaults to
**300 seconds**, maximum **3,600 seconds**. Input and pick return no answer with
one of **six reasons**: `cancelled`, `timeout`, `no_client`, `unsupported`,
`busy`, `failed`; only `failed` carries a detail sentence. Invalid arguments
raise an error rather than returning a cancellation.

This profile's Opt+Cmd+R invokes `renameTab` without a name, which opens the
native rename UI for the current tab. Submit to rename; cancel to leave its
name unchanged. This does not promise whitespace or empty-string behavior
identical to the source API. It never types shell commands or interpolates
untrusted input into a command line.

For an extension-owned form, cmux's command contribution supports `mode:
"form"` and an `arguments` JSON schema. See the `new` command in
`samples/apps/palette-notes/cmux-app.json`: title is required, 1–120 characters;
body allows up to 4,000 characters. These are that sample's schema limits,
not a generic input limit. A command receives validated arguments on submit;
this is not the source's suspended Lua call. A waiting caller, empty-answer
parity, default timeout, source error reasons and multi-client prompt routing
are not supplied by this profile.
