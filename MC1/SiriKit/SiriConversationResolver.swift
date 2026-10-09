import Foundation
import MC1Services

/// A chat contact or channel addressed by SiriKit. The `id` is the
/// same radio-scoped, kind-tagged composite id `MessageTargetEntity` uses, so a
/// SiriKit `conversationIdentifier` and an App Intents target id agree.
struct SiriConversation: Sendable {
  let id: String
  let recipient: MessageRecipient
  let displayName: String
  let unreadCount: Int
  let lastMessageDate: Date?

  var isChannel: Bool {
    if case .channel = recipient { return true }
    return false
  }

  init(contact: ContactDTO) {
    id = MessageTargetEntity(dto: contact).id
    recipient = .contact(contact)
    displayName = contact.displayName
    unreadCount = contact.unreadCount
    lastMessageDate = contact.lastMessageDate
  }

  init(channel: ChannelDTO) {
    id = MessageTargetEntity(dto: channel).id
    recipient = .channel(channel)
    displayName = channel.displayName
    unreadCount = channel.unreadCount
    lastMessageDate = channel.lastMessageDate
  }
}

/// An incoming message flattened for SiriKit, carrying only Sendable values so
/// handlers can build `INMessage`s outside the main actor.
struct SiriMessage: Sendable {
  let id: UUID
  let conversationID: String
  let text: String
  let date: Date
  let senderName: String
  /// The channel name for a channel message, `nil` for a DM.
  let groupName: String?
}

extension SiriMessage {
  /// Maps one stored incoming message to its SiriKit form. A channel message's
  /// sender is the node name the firmware attached; a DM's is the contact.
  init(message: MessageDTO, in conversation: SiriConversation) {
    id = message.id
    conversationID = conversation.id
    text = message.text
    date = message.sortDate
    if conversation.isChannel {
      senderName = message.senderNodeName ?? conversation.displayName
      groupName = conversation.displayName
    } else {
      senderName = conversation.displayName
      groupName = nil
    }
  }
}

/// Resolves SiriKit conversation references against the radio that
/// is connected now. Every lookup re-fetches rather than trusting a cached id,
/// matching `SendMessageIntent`: an id minted for another radio resolves to
/// nothing instead of mis-routing a send.
@MainActor
struct SiriConversationResolver {
  let bridge: IntentBridge

  /// Upper bound on messages handed to Siri for reading aloud in one request.
  static let readAloudLimit = 50

  /// Chat contacts and channels for the current radio, most recent activity
  /// first. Empty when no radio is selected.
  func conversations() async throws -> [SiriConversation] {
    guard let scope = currentRadioScope(bridge) else { return [] }
    let contacts = try await scope.store.fetchContacts(radioID: scope.radioID)
    let channels = try await scope.store.fetchChannels(radioID: scope.radioID)
    let all = chatContacts(contacts).map(SiriConversation.init(contact:))
      + uniqueChannels(channels).map(SiriConversation.init(channel:))
    return all.sorted { ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast) }
  }

  /// The conversation with this composite id on the current radio, if any.
  func conversation(id: String) async throws -> SiriConversation? {
    try await conversations().first { $0.id == id }
  }

  /// Conversations whose name matches a spoken name. An exact
  /// (case-insensitive) match wins outright so "Public" never prompts a
  /// disambiguation against "Public Safety"; otherwise every contains-match is
  /// returned for the caller to disambiguate.
  func conversations(named name: String) async throws -> [SiriConversation] {
    let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return [] }
    let all = try await conversations()
    let exact = all.filter { $0.displayName.lowercased() == needle }
    if !exact.isEmpty { return exact }
    return all.filter { $0.displayName.lowercased().contains(needle) }
  }

  /// The unread incoming messages in each conversation, oldest first. The
  /// stored unread count is the source of truth (channel rows do not flip a
  /// per-message read flag), so this takes that many trailing incoming
  /// messages.
  func unreadMessages(in conversations: [SiriConversation]) async throws -> [SiriMessage] {
    guard let scope = currentRadioScope(bridge) else { return [] }
    var result: [SiriMessage] = []
    for conversation in conversations where conversation.unreadCount > 0 {
      let wanted = min(conversation.unreadCount, Self.readAloudLimit)
      let recent = try await recentMessages(in: conversation, store: scope.store, limit: wanted * 2)
      let incoming = recent.filter { $0.direction == .incoming }.suffix(wanted)
      result += incoming.map { SiriMessage(message: $0, in: conversation) }
    }
    return Array(result.sorted { $0.date < $1.date }.suffix(Self.readAloudLimit))
  }

  /// The latest incoming messages in each conversation regardless of read
  /// state, for requests that do not ask for unread only.
  func recentMessages(in conversations: [SiriConversation], perConversation: Int) async throws -> [SiriMessage] {
    guard let scope = currentRadioScope(bridge) else { return [] }
    var result: [SiriMessage] = []
    for conversation in conversations {
      let recent = try await recentMessages(in: conversation, store: scope.store, limit: perConversation * 2)
      let incoming = recent.filter { $0.direction == .incoming }.suffix(perConversation)
      result += incoming.map { SiriMessage(message: $0, in: conversation) }
    }
    return Array(result.sorted { $0.date < $1.date }.suffix(Self.readAloudLimit))
  }

  /// Clears unread state for the conversations owning these message ids, the
  /// same bookkeeping opening the chat performs, then refreshes the Chats list
  /// and badge. Returns whether any id matched a message on the current radio.
  func markRead(messageIDs: [UUID]) async throws -> Bool {
    guard let appState = bridge.appState,
          let scope = currentRadioScope(bridge) else { return false }
    let store = scope.store
    var matched = false
    var clearedContacts = Set<UUID>()
    var clearedChannels = Set<UInt8>()
    for id in messageIDs {
      guard let message = try await store.fetchMessage(id: id),
            message.radioID == scope.radioID else { continue }
      matched = true
      try await store.markMessageAsRead(id: id)
      if let contactID = message.contactID, clearedContacts.insert(contactID).inserted {
        try await store.clearUnreadCount(contactID: contactID)
        try await store.clearUnreadMentionCount(contactID: contactID)
        await appState.services?.notificationService.removeDeliveredNotifications(forContactID: contactID)
      } else if let index = message.channelIndex, clearedChannels.insert(index).inserted {
        try await store.clearChannelUnreadCount(radioID: scope.radioID, index: index)
        await appState.services?.notificationService.removeDeliveredNotifications(
          forChannelIndex: index,
          radioID: scope.radioID
        )
      }
    }
    if matched {
      await appState.services?.notificationService.updateBadgeCount()
      appState.refreshConversations()
    }
    return matched
  }

  // MARK: - Private

  private func recentMessages(
    in conversation: SiriConversation,
    store: PersistenceStore,
    limit: Int
  ) async throws -> [MessageDTO] {
    switch conversation.recipient {
    case let .contact(dto):
      try await store.fetchMessages(contactID: dto.id, limit: limit)
    case let .channel(dto):
      try await store.fetchMessages(radioID: dto.radioID, channelIndex: dto.index, limit: limit)
    }
  }

  /// Drops channels whose secret digest collides, since a send could not tell
  /// them apart; the same fail-safe the Shortcuts picker applies.
  private func uniqueChannels(_ channels: [ChannelDTO]) -> [ChannelDTO] {
    let ids = channels.map { MessageTargetEntity(dto: $0).id }
    return resolveUniqueChannels(matching: ids, in: channels)
  }
}
