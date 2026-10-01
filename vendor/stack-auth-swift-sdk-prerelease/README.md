# Stack Auth Swift SDK

Swift SDK for Stack Auth. Supports iOS, macOS, watchOS, tvOS, and visionOS.

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 12+ / watchOS 8+ / tvOS 15+ / visionOS 1+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/stack-auth/swift-sdk-prerelease", from: <version>)
]
```

## Quick Start

```swift
import StackAuth

let stack = StackClientApp(
    projectId: "your-project-id",
    publishableClientKey: "your-key"
)

// Sign in with email/password
try await stack.signInWithCredential(email: "user@example.com", password: "password")

// Get current user
if let user = try await stack.getUser() {
    print("Signed in as \(user.displayName ?? "Unknown")")
}

// Sign out
try await stack.signOut()
```

## Design Decisions

### Error Handling

All functions that can fail use Swift's native `throws`. Errors conform to `StackAuthError`:

```swift
do {
    try await stack.signInWithCredential(email: email, password: password)
} catch let error as StackAuthError {
    switch error.code {
    case "email_password_mismatch":
        print("Wrong password")
    default:
        print(error.message)
    }
}
```

### Token Storage

- **Default**: Keychain (secure, persists across app launches)
- **Option**: Memory (for testing or ephemeral sessions)
- **Option**: Custom `TokenStoreProtocol` implementation

```swift
// Memory storage (for testing)
let stack = StackClientApp(
    projectId: "...",
    publishableClientKey: "...",
    tokenStore: .memory
)

// Custom storage
let stack = StackClientApp(
    projectId: "...",
    publishableClientKey: "...",
    tokenStore: .custom(MyTokenStore())
)
```

### OAuth Flows

Two approaches for OAuth authentication:

**1. Integrated (recommended)** - Uses `ASWebAuthenticationSession`:

```swift
// Opens auth session, handles callback automatically
// Uses fixed callback scheme: stack-auth-mobile-oauth-url://
try await stack.signInWithOAuth(provider: "google")
```

**2. Manual URL handling** - For custom implementations:

> **Note:** The `stack-auth-mobile-oauth-url://` scheme is automatically accepted. 

```swift
// Get the OAuth URL (must provide absolute URLs)
let oauth = try await stack.getOAuthUrl(
    provider: "google",
    redirectUrl: "stack-auth-mobile-oauth-url://success",
    errorRedirectUrl: "stack-auth-mobile-oauth-url://error"
)

// Open oauth.url in your own browser/webview
// Store oauth.state, oauth.codeVerifier, and oauth.redirectUrl

// When callback received:
try await stack.callOAuthCallback(
    url: callbackUrl,
    codeVerifier: oauth.codeVerifier,
    redirectUrl: oauth.redirectUrl
)
```

### Async/Await

All async operations use Swift's native concurrency:

```swift
Task {
    let user = try await stack.getUser()
    let teams = try await user?.listTeams()
}
```

## Key Differences from JavaScript SDK

| Aspect | JavaScript | Swift |
|--------|-----------|-------|
| Token Storage | Cookies | Keychain |
| OAuth | Browser redirect | ASWebAuthenticationSession |
| Redirect methods | Available | Not available (browser-only) |
| React hooks | `useUser()` etc. | Not applicable |

### Not Available in Swift

The following are browser-only and not exposed:

- `redirectToSignIn()`, `redirectToSignUp()`, etc.
- Cookie-based token storage
- `redirectMethod` constructor option

## Examples

Interactive example apps are available for testing all SDK functions:

### macOS Example

```bash
cd Examples/StackAuthMacOS
swift run
```

Features a sidebar-based UI for testing authentication, user management, teams, OAuth, tokens, and server-side operations.

### iOS Example

```bash
cd Examples/StackAuthiOS
open Package.swift  # Opens in Xcode
```

Features a tab-based UI optimized for iOS with the same comprehensive SDK coverage.

Both examples include:
- Configurable API endpoints
- Real-time operation logs
- Error testing scenarios (wrong password, unauthorized access, etc.)
- Client and server app operations

## Testing

Tests use Swift Testing framework against a running backend.

### Running Tests

1. Start the development server:
   ```bash
   pnpm dev
   ```

2. Run tests:
   ```bash
   cd sdks/implementations/swift
   swift test
   ```

The tests connect to `http://localhost:8102` (or `${NEXT_PUBLIC_STACK_PORT_PREFIX}02`).

## API Reference

See the [SDK Specification](../../spec/README.md) for complete API documentation.
