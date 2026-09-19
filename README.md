# LLM Usage Monitor

A macOS menu-bar app and iOS companion app for monitoring Claude (Anthropic) and Codex (OpenAI) token usage in real time.

## Overview

LLM Usage Monitor shows the rolling limits of your **Claude Max/Pro** and **ChatGPT Plus/Pro** subscriptions — the same 5‑hour and weekly percentages Claude Code and Codex CLI report — in the macOS menu bar, alongside today's token usage parsed from the CLIs' local session logs. An iOS app mirrors the same data via iCloud (CloudKit private database).

It reuses the login tokens the CLIs already store on your Mac (macOS Keychain "Claude Code-credentials", `~/.codex/auth.json`) and calls the same usage endpoints the CLIs call. It never refreshes or modifies those tokens, and they never leave the Mac. Admin Usage APIs for API-key billing are available as an optional provider.

## Architecture

- **UsageCore** — shared Swift package containing API clients, polling scheduler, local SwiftData store, CloudKit sync, and Keychain helpers. Used by both the macOS and iOS apps.
- **MacApp** — macOS `MenuBarExtra` app. Writes usage events and syncs them to CloudKit.
- **iOSApp** — read-only SwiftUI app with WidgetKit extension. Receives updates via CloudKit silent push.

See [docs/architecture.md](docs/architecture.md) for the full design.

## Requirements

- macOS 14+ / iOS 17+
- Xcode 15+ (and `xcodegen` to generate the app projects)
- Claude Code and/or Codex CLI installed and signed in with your subscription
- Apple Developer account (for CloudKit and TestFlight)
- Optional: an Anthropic Admin API key if you also want API-key (Console org) usage

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
