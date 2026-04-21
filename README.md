# LLM Usage Monitor

A macOS menu-bar app and iOS companion app for monitoring Claude (Anthropic) and Codex (OpenAI) token usage in real time.

## Overview

LLM Usage Monitor polls the Anthropic and OpenAI Admin Usage APIs on a 60-second interval and displays aggregated token counts and estimated costs in the macOS menu bar. An iOS app mirrors the same data via iCloud (CloudKit private database).

## Architecture

- **UsageCore** — shared Swift package containing API clients, polling scheduler, local SwiftData store, CloudKit sync, and Keychain helpers. Used by both the macOS and iOS apps.
- **MacApp** — macOS `MenuBarExtra` app. Writes usage events and syncs them to CloudKit.
- **iOSApp** — read-only SwiftUI app with WidgetKit extension. Receives updates via CloudKit silent push.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Requirements

- macOS 14+ / iOS 17+
- Xcode 15+
- An Anthropic Admin API key (`sk-ant-admin...`) and/or an OpenAI Admin API key
- Apple Developer account (for CloudKit and TestFlight)

## Getting started

```bash
# Open the Xcode workspace
open apps/MacApp/MacApp.xcodeproj

# Or build the shared package independently
swift build
swift test
```

## Project structure

```
Package.swift              SwiftPM manifest for UsageCore
Sources/UsageCore/         Shared library
apps/MacApp/               macOS menu-bar app
apps/iOSApp/               iOS app + widget
tests/UsageCoreTests/      Unit tests + JSON fixtures (Fixtures/)
schemas/                   Language-agnostic schema (for future ports)
docs/                      Architecture documentation
```

## License

MIT
