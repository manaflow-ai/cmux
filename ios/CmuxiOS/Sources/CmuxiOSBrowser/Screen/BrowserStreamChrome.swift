/// What surrounds a streamed surface: a Mac browser tab gets the address bar,
/// history and tabs (C2); a device stream such as an iOS simulator (C14) gets
/// only the keyboard and paste, and one-finger drags are touches.
public enum BrowserStreamChrome: Hashable, Sendable {
    case page
    case device
}
