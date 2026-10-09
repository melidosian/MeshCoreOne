import Intents
import MC1Services
import os

private let logger = Logger(subsystem: "com.mc1", category: "SiriKit")

/// Handles SiriKit `INSetMessageAttributeIntent`. Siri sends this after reading
/// messages aloud, so marking them read clears the conversation's unread count,
/// badge and delivered notifications, the same bookkeeping as opening the chat.
/// Only `.read` is supported; MeshCore has no unread-again or flag state.
final class SetMessageAttributeIntentHandler: NSObject, INSetMessageAttributeIntentHandling, Sendable {
  private let bridge: IntentBridge

  init(bridge: IntentBridge) {
    self.bridge = bridge
  }

  func resolveAttribute(for intent: INSetMessageAttributeIntent) async -> INMessageAttributeResolutionResult {
    switch intent.attribute {
    case .read: .success(with: .read)
    case .unknown: .needsValue()
    default: .unsupported()
    }
  }

  func handle(intent: INSetMessageAttributeIntent) async -> INSetMessageAttributeIntentResponse {
    let ids = (intent.identifiers ?? []).compactMap(UUID.init(uuidString:))
    guard intent.attribute == .read, !ids.isEmpty else {
      return INSetMessageAttributeIntentResponse(code: .failure, userActivity: nil)
    }
    let code = await markRead(ids)
    return INSetMessageAttributeIntentResponse(code: code, userActivity: nil)
  }

  @MainActor
  private func markRead(_ ids: [UUID]) async -> INSetMessageAttributeIntentResponseCode {
    do {
      let matched = try await SiriConversationResolver(bridge: bridge).markRead(messageIDs: ids)
      return matched ? .success : .failureMessageNotFound
    } catch {
      logger.error("Siri mark-read failed: \(error.localizedDescription)")
      return .failure
    }
  }
}
