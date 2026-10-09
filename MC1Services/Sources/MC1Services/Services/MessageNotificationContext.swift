import Foundation

/// What an incoming-message notification is about, handed to
/// `NotificationService.decorateMessageNotification` so the app layer can turn
/// the notification into a communication notification (sender identity, Siri
/// announce and reply) without MC1Services depending on SiriKit.
public enum MessageNotificationContext: Sendable {
  case directMessage(contactID: UUID, senderName: String, text: String)
  case channelMessage(radioID: UUID, channelIndex: UInt8, channelName: String, senderName: String?, text: String)
}
