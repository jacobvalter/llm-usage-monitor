import Foundation

/// Optional provider: OpenAI Admin Usage and Costs APIs for API-key (platform org) billing.
///
///   GET https://api.openai.com/v1/organization/usage/completions
///   GET https://api.openai.com/v1/organization/costs
///
/// Not part of v0.1 — the user is on a ChatGPT subscription, whose limits come from
/// `CodexSubscriptionClient`. Kept as a stub so an API-key user can be supported later.
public struct OpenAIAdminClient: Sendable {
    // TODO: implement when an API-key provider is needed.
}
