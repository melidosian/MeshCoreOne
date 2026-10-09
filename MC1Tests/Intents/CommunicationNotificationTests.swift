import Foundation
import Intents
@testable import MC1
@testable import MC1Services
import Testing
import UserNotifications

/// Communication notifications attach an incoming `INSendMessageIntent` whose
/// conversation id must match the one `SendMessageIntentHandler` resolves, or a
/// spoken reply to an announced message would go nowhere (or somewhere else).
@MainActor
struct CommunicationNotificationTests {
  private static let radioID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

  private func makeStore() throws -> PersistenceStore {
    try PersistenceStore(modelContainer: PersistenceStore.createContainer(inMemory: true))
  }

  private static func makeContact(name: String) -> ContactDTO {
    ContactDTO(
      id: UUID(), radioID: radioID, publicKey: Data(repeating: 0xC3, count: 32), name: name,
      typeRawValue: ContactType.chat.rawValue, flags: 0, outPathLength: 0, outPath: Data(),
      lastAdvertTimestamp: 0, latitude: 0, longitude: 0, lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil, isBlocked: false, isMuted: false, isFavorite: false,
      lastMessageDate: nil, unreadCount: 0
    )
  }

  private static func makeChannel(name: String) -> ChannelDTO {
    ChannelDTO(
      id: UUID(), radioID: radioID, index: 2, name: name,
      secret: Data(repeating: 0x3C, count: 16), isEnabled: true,
      lastMessageDate: nil, unreadCount: 0
    )
  }

  @Test func `direct message intent is keyed by the contact conversation id`() async throws {
    let store = try makeStore()
    let alice = Self.makeContact(name: "Alice")
    try await store.saveContact(alice)

    let intent = await CommunicationNotificationDecorator(store: store).intent(
      for: .directMessage(contactID: alice.id, senderName: "Alice", text: "on my way")
    )

    #expect(intent?.conversationIdentifier == MessageTargetEntity(dto: alice).id)
    #expect(intent?.sender?.displayName == "Alice")
    #expect(intent?.content == "on my way")
    #expect(intent?.speakableGroupName == nil)
  }

  @Test func `channel message intent names the channel as the group`() async throws {
    let store = try makeStore()
    let channel = Self.makeChannel(name: "Public")
    try await store.saveChannel(channel)

    let intent = await CommunicationNotificationDecorator(store: store).intent(
      for: .channelMessage(
        radioID: Self.radioID, channelIndex: 2, channelName: "Public",
        senderName: "RidgeRunner", text: "net check"
      )
    )

    #expect(intent?.conversationIdentifier == MessageTargetEntity(dto: channel).id)
    #expect(intent?.speakableGroupName?.spokenPhrase == "Public")
    #expect(intent?.sender?.displayName == "RidgeRunner")
  }

  @Test func `reply to a channel notification resolves back to that channel`() async throws {
    let store = try makeStore()
    let channel = Self.makeChannel(name: "Public")
    try await store.saveChannel(channel)
    let intent = await CommunicationNotificationDecorator(store: store).intent(
      for: .channelMessage(
        radioID: Self.radioID, channelIndex: 2, channelName: "Public",
        senderName: "RidgeRunner", text: "net check"
      )
    )

    let replyTarget = try #require(intent?.conversationIdentifier)
    let resolved = resolveUniqueChannels(matching: [replyTarget], in: [channel])

    #expect(resolved.map(\.id) == [channel.id])
  }

  @Test func `unknown conversation leaves the notification unchanged`() async throws {
    let store = try makeStore()
    let content = UNMutableNotificationContent()
    content.title = "Ghost"
    content.body = "boo"

    let result = await CommunicationNotificationDecorator(store: store).decorate(
      content,
      for: .directMessage(contactID: UUID(), senderName: "Ghost", text: "boo")
    )

    #expect(result === content)
  }
}
