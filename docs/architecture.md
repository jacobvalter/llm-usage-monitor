# Architecture

## Option A — Apple-native + CloudKit (chosen)

Swift + SwiftUI everywhere. macOS `MenuBarExtra` tray app, iOS companion app with WidgetKit,
CloudKit private database for sync, no backend service to operate.

## Who this is for (v0.1)

A single user on **Claude Max/Pro** and **ChatGPT Plus/Pro** subscriptions, using Claude Code
and Codex CLI. The headline numbers are the subscriptions' rolling limits — the same
5‑hour and weekly percentages the CLIs show in `/usage` and `/status`.

Subscription limits are **not** exposed by the documented Admin/Usage APIs (those cover
API-key billing in a Console/Platform organization and are unavailable to individual accounts),
so v0.1 reads the same undocumented endpoints the CLIs themselves call, using the login tokens
the CLIs already store on the Mac.

## Data sources

| Source | `UsageSource` | What it gives | How | Auth |
|---|---|---|---|---|
| Claude subscription limits | `claude_oauth_usage` | 5‑hour, weekly, per-model weekly %, reset times, extra-usage credits | `GET api.anthropic.com/api/oauth/usage` (undocumented; what Claude Code calls) | Claude Code OAuth token: macOS Keychain item **"Claude Code-credentials"**, or `~/.claude/.credentials.json`, or `CLAUDE_CODE_OAUTH_TOKEN` |
| Codex subscription limits | `codex_wham_usage` | 5‑hour / weekly windows (classified by duration), plan type, extra metered limits | `GET chatgpt.com/backend-api/wham/usage` (undocumented; what Codex CLI polls every 60 s) | `~/.codex/auth.json` (`tokens.access_token`, `tokens.account_id` or the JWT's `https://api.openai.com/auth.chatgpt_account_id`) |
| Claude Code sessions | `claude_code_jsonl` | per-turn tokens (input / output / cache read / cache write), model, timestamps → "tokens today", per-model rows, API-equivalent cost | tail `~/.claude/projects/**/*.jsonl` with FSEvents | none |
| Codex CLI sessions | `codex_jsonl` | per-turn tokens (input / cached / output / reasoning), model | tail `~/.codex/sessions/**/*.jsonl` (`event_msg.payload.type == "token_count"`) | none |
| Anthropic Admin Usage/Cost API | `admin_usage_api` | org-level API-key usage and $ | `/v1/organizations/usage_report/messages`, `/v1/organizations/cost_report` | Admin API key — **optional provider**, off by default |
| OpenAI Admin Usage/Costs API | `admin_usage_api` | org-level API-key usage and $ | `/v1/organization/usage/completions`, `/v1/organization/costs` | Admin API key — **optional provider**, not implemented yet |

Required request details (learned from Claude Code / Codex CLI behaviour and open-source
monitors such as CodexBar, ccusage):

- Claude: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`,
  and **`User-Agent: claude-code/<version>`** — without that UA the request lands in a heavily
  rate-limited bucket and returns persistent 429s. `expiresAt` in the credential JSON is Unix
  **milliseconds**. Response: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`,
  `seven_day_oauth_apps` (`utilization` %, `resets_at` RFC 3339 with microseconds),
  `extra_usage`, and a newer generic `limits[]` list with model-scoped entries.
- Codex: `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account id>`.
  Response: `rate_limit.primary_window` / `secondary_window` with `used_percent`,
  `limit_window_seconds`, `reset_after_seconds`, `reset_at` (Unix seconds), plus `plan_type`,
  `additional_rate_limits[]`. Windows ≤ 6 h are the session window, longer ones weekly; some
  plans return a single weekly window as `primary_window`.

## Token policy

The app **never refreshes OAuth tokens**. Refreshing rotates the refresh token out from under
the CLI and would log the user out of Claude Code / Codex. When a stored token is expired the
app shows a "run `claude` / `codex` once to refresh" state and keeps the last good reading.
Tokens are read on the Mac only and never leave it (not written to CloudKit).

## Data flow

1. macOS app polls both subscription endpoints every **60 s** (with exponential back-off on
   429 honouring `retry-after`) → `QuotaSnapshot` per provider.
2. macOS app tails the two JSONL trees → `UsageEvent` per turn (deduped by session + turn).
3. Both are stored locally (SwiftData) and mirrored to the CloudKit private database in the
   custom zone `UsageZone`: `QuotaSnapshot` records (latest per provider) and hourly
   `UsageEvent` roll-ups.
4. iOS subscribes via `CKDatabaseSubscription` → silent push → pulls deltas → widgets refresh.

## Models

- `QuotaSnapshot` — provider, plan, `[QuotaWindow]` (kind `5h` / `7d` / `7d_model` /
  `monthly_extra` / `other`, `usedPercent`, `resetsAt`, `windowSeconds`, `model`), `fetchedAt`.
  Drives the bars and the status-bar ring.
- `UsageEvent` — provider, source, time bucket, model, token breakdown, request count,
  optional cost. Drives "tokens today", per-model rows and sparklines. Schema in
  `schemas/usage-event.schema.json`.

## UsageCore layout

```
Sources/UsageCore/
  Models/        UsageEvent, QuotaSnapshot
  Providers/     ClaudeSubscriptionClient, CodexSubscriptionClient, AnthropicAdminClient (optional), OpenAIAdminClient (stub)
  Keychain/      ClaudeCredentialsReader, CodexCredentialsReader, KeychainStore (app settings)
  Polling/       PollScheduler
  Store/         SwiftDataStore
  Sync/          CloudKitSync
  Support/       DateParsing
```

Every network client has a pure `parse…Response(from:)` and an injectable transport, so the
golden-file tests in `tests/UsageCoreTests/Fixtures/` run without network or credentials.

## Cross-platform escape hatch

`UsageCore` is structured so its responsibilities map 1:1 onto a future Rust `usage-core`
crate (Option C). The app shells would stay in Swift; only the shared library would be
rewritten and bound via UniFFI.
