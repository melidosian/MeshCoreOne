import Intents
import MC1Services
import os

private let logger = Logger(subsystem: "com.mc1", category: "SiriKit")

/// Handles SiriKit `INSendMessageIntent` in-app, so Siri can send
/// to a contact (DM) or a channel. Handled in the app process rather than an
/// Intents extension because only the app holds the radio connection.
///
/// The send reuses `SendMessageIntent`'s routing, validation and durable-queue
/// path, so a Siri send behaves exactly like a Shortcuts send: it is queued at
/// the radio, never reported as delivered, and refused when the radio is not
/// ready. Siri itself confirms the message before `handle` runs.
final class SendMessageIntentHandler: NSObject, INSendMessageIntentHandling, Sendable {
  private let bridge: IntentBridge

  init(bridge: IntentBridge) {
    self.bridge = bridge
  }

  // MARK: - Resolve

  func resolveRecipients(for intent: INSendMessageIntent) async -> [INSendMessageRecipientResolutionResult] {
    // A notification reply names the conversation directly; a
    // person Siri already resolved (e.g. after disambiguation) carries its id.
    let conversationID = intent.conversationIdentifier ?? Self.resolvedID(in: intent)
    let names = (intent.recipients ?? []).map(Self.spokenName(of:))
    let groupName = intent.speakableGroupName?.spokenPhrase

    if let conversationID {
      guard let conversation = await lookUp(id: conversationID) else {
        return [.unsupported(forReason: .noAccount)]
      }
      return [.success(with: Self.person(for: conversation))]
    }
    // A spoken channel name may arrive as the group name with no recipients.
    if names.isEmpty, groupName != nil {
      return []
    }
    guard !names.isEmpty else { return [.needsValue()] }
    // One message, one target: a radio send cannot fan out to several people.
    guard names.count == 1 else { return [.unsupported(forReason: .noAccount)] }

    let matches = await lookUp(name: names[0])
    switch matches.count {
    case 0:
      return [.unsupported(forReason: .noAccount)]
    case 1:
      return [.success(with: Self.person(for: matches[0]))]
    default:
      return [.disambiguation(with: matches.prefix(5).map(Self.person(for:)))]
    }
  }

  func resolveSpeakableGroupName(for intent: INSendMessageIntent) async -> INSpeakableStringResolutionResult {
    guard let groupName = intent.speakableGroupName?.spokenPhrase else { return .notRequired() }
    let channels = await lookUp(name: groupName).filter(\.isChannel)
    switch channels.count {
    case 0: return .unsupported()
    case 1: return .success(with: INSpeakableString(spokenPhrase: channels[0].displayName))
    default: return .disambiguation(with: channels.prefix(5).map { INSpeakableString(spokenPhrase: $0.displayName) })
    }
  }

  func resolveContent(for intent: INSendMessageIntent) async -> INStringResolutionResult {
    guard let text = intent.content, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .needsValue()
    }
    return .success(with: text)
  }

  // MARK: - Handle

  func handle(intent: INSendMessageIntent) async -> INSendMessageIntentResponse {
    let request = Request(
      conversationID: intent.conversationIdentifier ?? Self.resolvedID(in: intent),
      recipientName: intent.recipients?.first.map(Self.spokenName(of:)),
      groupName: intent.speakableGroupName?.spokenPhrase,
      text: intent.content ?? ""
    )
    let code = await send(request)
    return INSendMessageIntentResponse(code: code, userActivity: nil)
  }

  // MARK: - Main actor work

  /// The Sendable slice of an intent the main-actor send needs.
  private struct Request: Sendable {
    let conversationID: String?
    let recipientName: String?
    let groupName: String?
    let text: String
  }

  @MainActor
  private func send(_ request: Request) async -> INSendMessageIntentResponseCode {
    guard let appState = bridge.appState else { return .failureRequiringAppLaunch }
    switch SendMessageIntent.route(for: appState.connectionManager.connectionState) {
    case .headlessQueue, .queueAfterSync:
      break
    case .foregroundEscalate, .notConnected:
      return .failureRequiringAppLaunch
    }

    let resolver = SiriConversationResolver(bridge: bridge)
    let conversation: SiriConversation?
    do {
      if let id = request.conversationID {
        conversation = try await resolver.conversation(id: id)
      } else if let name = request.recipientName ?? request.groupName {
        let matches = try await resolver.conversations(named: name)
        conversation = matches.count == 1 ? matches[0] : nil
      } else {
        conversation = nil
      }
    } catch {
      logger.error("Siri send lookup failed: \(error.localizedDescription)")
      return .failure
    }
    guard let conversation else { return .failure }

    do {
      let nodeNameByteCount = appState.connectedDevice?.nodeName.utf8.count ?? 0
      try SendMessageIntent.validate(message: request.text, for: conversation.recipient, nodeNameByteCount: nodeNameByteCount)
      switch try await SendMessageIntent.performSend(message: request.text, recipient: conversation.recipient, in: appState) {
      case .queued:
        return .success
      case .mustForeground:
        return .failureRequiringAppLaunch
      }
    } catch {
      logger.error("Siri send failed: \(error.localizedDescription)")
      return .failure
    }
  }

  @MainActor
  private func lookUp(id: String) async -> SiriConversation? {
    try? await SiriConversationResolver(bridge: bridge).conversation(id: id)
  }

  @MainActor
  private func lookUp(name: String) async -> [SiriConversation] {
    (try? await SiriConversationResolver(bridge: bridge).conversations(named: name)) ?? []
  }

  // MARK: - INPerson mapping

  /// The person Siri shows and speaks for a conversation. The composite id
  /// rides in `customIdentifier` and the handle so a follow-up intent can be
  /// re-resolved without matching on the name again.
  static func person(for conversation: SiriConversation) -> INPerson {
    INPerson(
      personHandle: INPersonHandle(value: conversation.id, type: .unknown),
      nameComponents: nil,
      displayName: conversation.displayName,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: conversation.id
    )
  }

  /// The composite id of a recipient this handler produced earlier, if any.
  private static func resolvedID(in intent: INSendMessageIntent) -> String? {
    guard let recipients = intent.recipients, recipients.count == 1,
          let id = recipients[0].customIdentifier,
          parseCompositeID(id) != nil else { return nil }
    return id
  }

  private static func spokenName(of person: INPerson) -> String {
    person.displayName
  }
}
