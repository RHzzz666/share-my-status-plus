//
//  StateModels.swift
//  share-my-status-client
//


import Foundation

// State Service API Models (from state_service.thrift)

/// Batch report request
struct BatchReportRequest: Codable {
    let events: [ReportEvent]
}

/// Batch report response
struct BatchReportResponse: Codable {
    let base: BaseResponse
    let accepted: Int32?
    let deduped: Int32?
}

/// Query state request
struct QueryStateRequest: Codable {
    let sharingKey: String
}

/// Query state response
struct QueryStateResponse: Codable {
    let base: BaseResponse
    let snapshot: StatusSnapshot?
}

// MARK: - Token Usage DTOs (from common.thrift TokenUsage / TokenWindowUsage / TokenModelUsage)
//
// Wire contract (camelCase keys, matched exactly to the IDL).
//
// The client SENDS the four per-window counters + `byModel` (top models). It does
// NOT send `totalTokens` / `estimatedCostUsd` — the backend computes those. Both
// are declared optional and left nil; Swift's synthesized Codable uses
// `encodeIfPresent` for optionals, so nil values are omitted from the JSON.

/// Per-model token usage (matches IDL `TokenModelUsage`).
nonisolated struct TokenModelUsageDTO: Codable {
    let model: String                  // required (e.g. "claude-opus-4-8")
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cachedInputTokens: Int64?
    let reasoningOutputTokens: Int64?
}

/// Token usage for one time window (matches IDL `TokenWindowUsage`).
nonisolated struct TokenWindowUsageDTO: Codable {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let cachedInputTokens: Int64?
    let reasoningOutputTokens: Int64?
    // Server-computed — always nil on the client so Codable omits them.
    let totalTokens: Int64?
    let estimatedCostUsd: Double?
    let byModel: [TokenModelUsageDTO]?

    init(inputTokens: Int64?,
         outputTokens: Int64?,
         cachedInputTokens: Int64?,
         reasoningOutputTokens: Int64?,
         byModel: [TokenModelUsageDTO]?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = nil          // server-computed
        self.estimatedCostUsd = nil     // server-computed
        self.byModel = byModel
    }
}

/// Token usage block reported with each event (matches IDL `TokenUsage`).
nonisolated struct TokenUsageDTO: Codable {
    let today: TokenWindowUsageDTO?
    let last7d: TokenWindowUsageDTO?
    let total: TokenWindowUsageDTO?
    let topModel: String?
    let sessionCount: Int64?
    let windowDays: Int32?
    let ts: Int64                       // required (computation time, ms)
}

