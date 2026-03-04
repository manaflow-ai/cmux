# cmux iOS

iOS companion app for cmux. Connects to Mac terminals over SSH using libssh2 for transport and libghostty for terminal rendering.

## Status

Skeleton phase. SSH protocol types and key management are defined. libssh2 integration is pending.

## Building libssh2 for iOS

Build libssh2 as an xcframework targeting iOS arm64:

```bash
# Clone libssh2
git clone https://github.com/libssh2/libssh2.git
cd libssh2 && mkdir build-ios && cd build-ios

# Configure for iOS
cmake .. \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCRYPTO_BACKEND=SecureTransport \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_TESTING=OFF

cmake --build . --config Release

# Create xcframework
xcodebuild -create-xcframework \
  -library lib/libssh2.a -headers ../include \
  -output libssh2.xcframework
```

Place the resulting `libssh2.xcframework` in `ios/Frameworks/` and add it to the Xcode project.

## Architecture

- `SSHClientProtocol` / `LibSSH2Client`: protocol-based SSH client, swappable for testing
- `SSHKeyStore`: Ed25519 key generation and iOS Keychain storage
- `SSHKeyManagementView`: SwiftUI UI for managing keys
- `SavedConnection`: model for bookmarked SSH hosts

## Key management flow

1. User generates an Ed25519 key pair (stored in Keychain)
2. User copies the public key in OpenSSH format
3. User pastes it into `~/.ssh/authorized_keys` on their Mac
4. Connections authenticate with the private key from Keychain
