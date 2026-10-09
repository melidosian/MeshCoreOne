import Intents
import MC1Services
import os

private let logger = Logger(subsystem: "com.mc1", category: "SiriKit")

/// Handles SiriKit `INSearchForMessagesIntent`, which is how Siri reads messages
/// aloud ("read my MeshCore messages", or an announced notification). Only incoming messages are returned; Siri reads them oldest
/// first and then offers to reply, which arrives as an `INSendMessageIntent`.
final class SearchForMessagesIntentHandler: NSObject, INSearchForMessagesIntentHandling, Sendable {
  private let bridge: IntentBridge

  /// Messages per conversation returned when the request is not unread-only.
  private static let recentPerConversation = 5

  init(bridge: IntentBridge) {
    self.bridge = bridge
  }

  func handle(intent: INSearchForMessagesIntent) async -> INSearchForMessagesIntentResponse {
    let query = Query(
      conversationIDs: intent.conversationIdentifiers ?? [],
      senderNames: (intent.senders ?? []).map(\.displayName),
      groupNames: (intent.speakableGroupNames ?? []).map(\.spokenPhrase),
      unreadOnly: intent.attributes.contains(.unread) || intent.attributes.isEmpty
    )
    guard let messages = await search(query) else {
      return INSearchForMessagesIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil)
    }
    let response = INSearchForMessagesIntentResponse(code: .success, userActivity: nil)
    response.messages = messages.map(Self.inMessage(for:))
    return response
  }

  // MARK: - Main actor work

  /// The Sendable slice of an intent the main-actor search needs.
  private struct Query: Sendable {
    let conversationIDs: [String]
    let senderNames: [String]
    let groupNames: [String]
    let unreadOnly: Bool
  }

  /// Returns `nil` when no radio is available, so Siri can send the user to the
  /// app rather than claiming there are no messages.
  @MainActor
  private func search(_ query: Query) async -> [SiriMessage]? {
    guard currentRadioScope(bridge) != nil else { return nil }
    let resolver = SiriConversationResolver(bridge: bridge)
    do {
      var conversations = try await resolver.conversations()
      if !query.conversationIDs.isEmpty {
        let wanted = Set(query.conversationIDs)
        conversations = conversations.filter { wanted.contains($0.id) }
      } else if !query.senderNames.isEmpty || !query.groupNames.isEmpty {
        var named: [SiriConversation] = []
        for name in query.senderNames + query.groupNames {
          named += try await resolver.conversations(named: name)
        }
        let ids = Set(named.map(\.id))
        conversations = conversations.filter { ids.contains($0.id) }
      }
      if query.unreadOnly {
        return try await resolver.unreadMessages(in: conversations)
      }
      return try await resolver.recentMessages(in: conversations, perConversation: Self.recentPerConversation)
    } catch {
      logger.error("Siri message search failed: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - INMessage mapping

  static func inMessage(for message: SiriMessage) -> INMessage {
    let sender = INPerson(
      personHandle: INPersonHandle(value: message.senderName, type: .unknown),
      nameComponents: nil,
      displayName: message.senderName,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: message.groupName == nil ? message.conversationID : nil
    )
    return INMessage(
      identifier: message.id.uuidString,
      conversationIdentifier: message.conversationID,
      content: message.text,
      dateSent: message.date,
      sender: sender,
      recipients: nil,
      groupName: message.groupName.map { INSpeakableString(spokenPhrase: $0) },
      messageType: .text
    )
  }
}
