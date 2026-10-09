import Intents
import MC1Services
import os
import UserNotifications

private let logger = Logger(subsystem: "com.mc1", category: "SiriKit")

/// Turns direct and channel message notifications into communication
/// notifications by attaching an incoming `INSendMessageIntent`. The system then
/// shows the sender (and the channel as a group), Siri can announce the message
/// on AirPods and in the car, and a spoken reply comes back as an
/// `INSendMessageIntent` carrying the same conversation id, which
/// `SendMessageIntentHandler` routes to that contact or channel.
///
/// Any failure (unknown conversation, missing entitlement) falls back to the
/// original notification, so decoration can never drop an alert.
struct CommunicationNotificationDecorator {
  let store: PersistenceStore

  @MainActor
  func decorate(
    _ content: UNMutableNotificationContent,
    for context: MessageNotificationContext
  ) async -> UNNotificationContent {
    guard let intent = await intent(for: context),
          let messageContent = content.mutableCopy() as? UNMutableNotificationContent else {
      return content
    }
    // A communication notification names the sender itself, so a channel body
    // drops the "Sender: " prefix the plain notification needs.
    if case let .channelMessage(_, _, _, _, text) = context {
      messageContent.body = text
    }

    let interaction = INInteraction(intent: intent, response: nil)
    interaction.direction = .incoming
    do {
      try await interaction.donate()
    } catch {
      logger.debug("Message interaction donation failed: \(error.localizedDescription)")
    }

    do {
      return try messageContent.updating(from: intent)
    } catch {
      logger.warning("Communication notification update failed: \(error.localizedDescription)")
      return content
    }
  }

  // MARK: - Intent

  /// Builds the incoming-message intent for a notification, keyed by the same
  /// radio-scoped composite id SiriKit and App Intents use. `nil` when the
  /// contact or channel can no longer be found.
  @MainActor
  func intent(for context: MessageNotificationContext) async -> INSendMessageIntent? {
    switch context {
    case let .directMessage(contactID, senderName, text):
      guard let contact = try? await store.fetchContact(id: contactID) else { return nil }
      let conversationID = MessageTargetEntity(dto: contact).id
      let sender = Self.person(name: senderName, handle: conversationID, customIdentifier: conversationID)
      return INSendMessageIntent(
        recipients: nil,
        outgoingMessageType: .outgoingMessageText,
        content: text,
        speakableGroupName: nil,
        conversationIdentifier: conversationID,
        serviceName: nil,
        sender: sender,
        attachments: nil
      )

    case let .channelMessage(radioID, channelIndex, channelName, senderName, text):
      guard let channel = try? await store.fetchChannel(radioID: radioID, index: channelIndex) else { return nil }
      let conversationID = MessageTargetEntity(dto: channel).id
      // Channel senders are bare node names with no stable key the app can
      // address, so the sender carries no custom identifier; a reply targets
      // the channel through the conversation id instead.
      let name = senderName ?? channelName
      let sender = Self.person(name: name, handle: name, customIdentifier: nil)
      return INSendMessageIntent(
        recipients: nil,
        outgoingMessageType: .outgoingMessageText,
        content: text,
        speakableGroupName: INSpeakableString(spokenPhrase: channelName),
        conversationIdentifier: conversationID,
        serviceName: nil,
        sender: sender,
        attachments: nil
      )
    }
  }

  private static func person(name: String, handle: String, customIdentifier: String?) -> INPerson {
    INPerson(
      personHandle: INPersonHandle(value: handle, type: .unknown),
      nameComponents: nil,
      displayName: name,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: customIdentifier
    )
  }
}
