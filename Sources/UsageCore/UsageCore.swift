/// UsageCore is the shared Swift package used by both the macOS and iOS apps.
/// It contains API clients, polling, local storage, CloudKit sync, and Keychain helpers.
///
/// Platform-agnostic logic lives here so that only the thin app shells differ per platform.
public enum UsageCore {
    public static let version = "0.1.0"
}
