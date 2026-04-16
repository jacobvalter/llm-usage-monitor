# Architecture

## Option A — Apple-native + CloudKit (chosen for v0.1)

Swift + SwiftUI everywhere. macOS `MenuBarExtra` tray app, iOS companion, CloudKit private database for sync.

## Data flow

1. macOS app polls Anthropic Admin Usage API and OpenAI Admin Usage API every 60 seconds.
2. Responses are normalized into `UsageEvent` records and upserted into a local SwiftData store (deduplicated by provider + source + bucket + model + workspace + apiKey).
3. New records are pushed to a CloudKit private database custom zone (`UsageZone`).
4. iOS app subscribes to `CKDatabaseSubscription` and receives silent push notifications on new records.
5. iOS pulls deltas and updates its local SwiftData cache.

## Key constraints

- **Admin API keys stay on the Mac.** Stored in macOS Keychain (`com.llm-usage-monitor.providerkeys`), never synced to CloudKit.
- **iOS is read-only.** Only the Mac writes UsageEvent records.
- **Idempotent ingest.** Re-polling the same time window upserts (not duplicates) records.
- **API freshness.** Both providers lag by ~5 minutes; the most recent 5-minute window is re-fetched on every tick.

## Polling details

| Provider | Endpoint | Auth | Bucket width | Poll interval |
|---|---|---|---|---|
| Anthropic | `/v1/organizations/usage_report/messages` | `x-api-key` (admin) | 1m | 60s |
| Anthropic | `/v1/organizations/cost_report` | `x-api-key` (admin) | 1d | 60s |
| OpenAI | `/v1/organization/usage/completions` | `Bearer` (admin) | 1m | 60s |
| OpenAI | `/v1/organization/costs` | `Bearer` (admin) | 1d | 60s |

## Future data sources (not in v0.1)

- `~/.claude/projects/**/*.jsonl` — Claude Code session logs (real-time via FSEvents)
- `~/.codex/sessions/*.jsonl` — Codex CLI session logs (real-time via notify)
- OpenTelemetry export from Claude Code
- `chatgpt.com/backend-api/wham/usage` — ChatGPT Plus/Pro quota

These will be added as additional `UsageSource` variants without schema migration.

## Cross-platform escape hatch

`UsageCore` is structured so its responsibilities map 1:1 onto a future Rust `usage-core` crate (Option C). The app shells would stay in Swift; only the shared library would be rewritten and bound via UniFFI.
