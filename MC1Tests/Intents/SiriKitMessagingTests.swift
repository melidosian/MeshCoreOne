import Foundation
import Intents
@testable import MC1
@testable import MC1Services
import MeshCore
import Testing

/// SiriKit messaging backs hands-free Siri ("read my MeshCore messages") and
/// replies to announced notifications, which carry a conversation's composite
/// id. These tests drive the resolver and the three handlers directly, the way
/// Siri calls them, against an in-memory store behind a test `AppState`. Speech and the Siri UI
/// are not exercised: the simulator cannot download Siri's speech assets.
@MainActor
struct SiriKitMessagingTests {
  private static let radioID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
  private static let otherRadioID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

  // MARK: - Fixtures

  private struct Harness {
    let appState: AppState
    let bridge: IntentBridge
    let store: PersistenceStore
  }

  /// A test `AppState` whose current radio is `radioID`, at the given rung,
  /// with services over the same store `currentRadioScope` reads.
  private func makeHarness(state: DeviceConnectionState = .ready) throws -> Harness {
    let container = try PersistenceStore.createContainer(inMemory: true)
    let appState = AppState(modelContainer: container)
    let store = appState.connectionManager.persistenceStore
    let services = ServiceContainer(
      session: MeshCoreSession(transport: MockTransport()),
      dataStore: store,
      radioID: Self.radioID
    )
    appState.connectionManager.setTestState(
      connectionState: state,
      services: services,
      connectedDevice: Self.makeDevice()
    )
    let bridge = IntentBridge()
    bridge.adopt(appState)
    return Harness(appState: appState, bridge: bridge, store: store)
  }

  private static func makeContact(
    radioID: UUID = radioID,
    name: String,
    keyByte: UInt8,
    type: ContactType = .chat,
    unread: Int = 0,
    lastMessage: Date? = nil
  ) -> ContactDTO {
    ContactDTO(
      id: UUID(), radioID: radioID, publicKey: Data(repeating: keyByte, count: 32), name: name,
      typeRawValue: type.rawValue, flags: 0, outPathLength: 0, outPath: Data(),
      lastAdvertTimestamp: 0, latitude: 0, longitude: 0, lastModified: 0,
      lastHeardTimestamp: nil,
      nickname: nil, isBlocked: false, isMuted: false, isFavorite: false,
      lastMessageDate: lastMessage, unreadCount: unread
    )
  }

  private static func makeChannel(
    radioID: UUID = radioID,
    index: UInt8,
    name: String,
    secretByte: UInt8,
    unread: Int = 0,
    lastMessage: Date? = nil
  ) -> ChannelDTO {
    ChannelDTO(
      id: UUID(), radioID: radioID, index: index, name: name,
      secret: Data(repeating: secretByte, count: 16), isEnabled: true,
      lastMessageDate: lastMessage, unreadCount: unread
    )
  }

  private static func makeMessage(
    contactID: UUID? = nil,
    channelIndex: UInt8? = nil,
    text: String,
    secondsAgo: TimeInterval,
    incoming: Bool = true,
    sender: String? = nil
  ) -> MessageDTO {
    let date = Date(timeIntervalSinceNow: -secondsAgo)
    return MessageDTO(
      id: UUID(), radioID: radioID, contactID: contactID, channelIndex: channelIndex,
      text: text, timestamp: UInt32(date.timeIntervalSince1970), createdAt: date, sortDate: date,
      direction: incoming ? .incoming : .outgoing, status: incoming ? .delivered : .sent,
      textType: .plain, ackCode: nil, pathLength: 0, snr: nil, senderKeyPrefix: nil,
      senderNodeName: sender, isRead: false, replyToID: nil, roundTripTime: nil,
      heardRepeats: 0, retryAttempt: 0, maxRetryAttempts: 0
    )
  }

  private static func makeDevice() -> DeviceDTO {
    DeviceDTO(
      id: UUID(), radioID: radioID, publicKey: Data(repeating: 0x01, count: 32),
      nodeName: "Base Camp", firmwareVersion: 8, firmwareVersionString: "1.10",
      manufacturerName: "Test", buildDate: "", maxContacts: 100, maxChannels: 16,
      frequency: 0, bandwidth: 0, spreadingFactor: 0, codingRate: 0, txPower: 0,
      maxTxPower: 0, latitude: 0, longitude: 0, blePin: 0, clientRepeat: false,
      pathHashMode: 0, manualAddContacts: false, autoAddConfig: 0, autoAddMaxHops: 0,
      multiAcks: 0, telemetryModeBase: 0, telemetryModeLoc: 0, telemetryModeEnv: 0,
      advertLocationPolicy: 0, lastConnected: Date(), lastContactSync: 0, isActive: true,
      ocvPreset: nil, customOCVArrayString: nil, connectionMethods: []
    )
  }

  // MARK: - Conversation listing

  @Test func `lists chat contacts and channels for the current radio only`() async throws {
    let harness = try makeHarness()
    try await harness.store.saveContact(Self.makeContact(name: "Alice", keyByte: 0xA1))
    try await harness.store.saveContact(Self.makeContact(name: "Ridge Repeater", keyByte: 0xA2, type: .repeater))
    try await harness.store.saveContact(Self.makeContact(radioID: Self.otherRadioID, name: "Stranger", keyByte: 0xA3))
    try await harness.store.saveChannel(Self.makeChannel(index: 0, name: "Public", secretByte: 0x11))

    let conversations = try await SiriConversationResolver(bridge: harness.bridge).conversations()

    #expect(Set(conversations.map(\.displayName)) == ["Alice", "Public"])
  }

  @Test func `most recent conversation is listed first`() async throws {
    let harness = try makeHarness()
    try await harness.store.saveContact(Self.makeContact(name: "Old", keyByte: 0xA1, lastMessage: Date(timeIntervalSinceNow: -3600)))
    try await harness.store.saveChannel(Self.makeChannel(index: 0, name: "Fresh", secretByte: 0x11, lastMessage: Date()))

    let conversations = try await SiriConversationResolver(bridge: harness.bridge).conversations()

    #expect(conversations.map(\.displayName) == ["Fresh", "Old"])
  }

  @Test func `no current radio yields no conversations`() async throws {
    let bridge = IntentBridge()
    bridge.adopt(AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!))

    #expect(try await SiriConversationResolver(bridge: bridge).conversations().isEmpty)
  }

  @Test func `conversation id round trips through the resolver`() async throws {
    let harness = try makeHarness()
    let alice = Self.makeContact(name: "Alice", keyByte: 0xA1)
    try await harness.store.saveContact(alice)
    let resolver = SiriConversationResolver(bridge: harness.bridge)

    let found = try await resolver.conversation(id: MessageTargetEntity(dto: alice).id)

    #expect(found?.displayName == "Alice")
    #expect(try await resolver.conversation(id: "not-an-id") == nil)
  }

  // MARK: - Spoken name matching

  @Test func `exact name match wins over contains match`() async throws {
    let harness = try makeHarness()
    try await harness.store.saveChannel(Self.makeChannel(index: 0, name: "Public", secretByte: 0x11))
    try await harness.store.saveChannel(Self.makeChannel(index: 1, name: "Public Safety", secretByte: 0x12))

    let matches = try await SiriConversationResolver(bridge: harness.bridge).conversations(named: "public")

    #expect(matches.map(\.displayName) == ["Public"])
  }

  @Test func `partial name returns every candidate for disambiguation`() async throws {
    let harness = try makeHarness()
    try await harness.store.saveContact(Self.makeContact(name: "Alice Chen", keyByte: 0xA1))
    try await harness.store.saveContact(Self.makeContact(name: "Alice Park", keyByte: 0xA2))

    let matches = try await SiriConversationResolver(bridge: harness.bridge).conversations(named: "Alice")

    #expect(Set(matches.map(\.displayName)) == ["Alice Chen", "Alice Park"])
  }

  // MARK: - Unread messages

  @Test func `unread messages are the trailing incoming ones oldest first`() async throws {
    let harness = try makeHarness()
    let alice = Self.makeContact(name: "Alice", keyByte: 0xA1, unread: 2)
    try await harness.store.saveContact(alice)
    try await harness.store.saveMessage(Self.makeMessage(contactID: alice.id, text: "already read", secondsAgo: 400))
    try await harness.store.saveMessage(Self.makeMessage(contactID: alice.id, text: "my reply", secondsAgo: 300, incoming: false))
    try await harness.store.saveMessage(Self.makeMessage(contactID: alice.id, text: "first new", secondsAgo: 200))
    try await harness.store.saveMessage(Self.makeMessage(contactID: alice.id, text: "second new", secondsAgo: 100))
    let resolver = SiriConversationResolver(bridge: harness.bridge)

    let messages = try await resolver.unreadMessages(in: resolver.conversations())

    #expect(messages.map(\.text) == ["first new", "second new"])
    #expect(messages.allSatisfy { $0.senderName == "Alice" && $0.groupName == nil })
  }

  @Test func `channel messages carry their sender and channel name`() async throws {
    let harness = try makeHarness()
    try await harness.store.saveChannel(Self.makeChannel(index: 0, name: "Public", secretByte: 0x11, unread: 1))
    try await harness.store.saveMessage(
      Self.makeMessage(channelIndex: 0, text: "net check", secondsAgo: 60, sender: "RidgeRunner")
    )
    let resolver = SiriConversationResolver(bridge: harness.bridge)

    let messages = try await resolver.unreadMessages(in: resolver.conversations())

    #expect(messages.count == 1)
    #expect(messages.first?.senderName == "RidgeRunner")
    #expect(messages.first?.groupName == "Public")
  }

  // MARK: - INSearchForMessagesIntent

  @Test func `search by conversation id returns only that conversation`() async throws {
    let harness = try makeHarness()
    let alice = Self.makeContact(name: "Alice", keyByte: 0xA1, unread: 1)
    let bob = Self.makeContact(name: "Bob", keyByte: 0xB1, unread: 1)
    try await harness.store.saveContact(alice)
    try await harness.store.saveContact(bob)
    try await harness.store.saveMessage(Self.makeMessage(contactID: alice.id, text: "from alice", secondsAgo: 60))
    try await harness.store.saveMessage(Self.makeMessage(contactID: bob.id, text: "from bob", secondsAgo: 30))
    let aliceID = MessageTargetEntity(dto: alice).id

    let intent = INSearchForMessagesIntent(
      recipients: nil, senders: nil, searchTerms: nil, attributes: .unread, dateTime: nil,
      identifiers: nil, notificationIdentifiers: nil, speakableGroupNames: nil,
      conversationIdentifiers: [aliceID]
    )
    let response = await SearchForMessagesIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .success)
    #expect(response.messages?.map(\.content) == ["from alice"])
    #expect(response.messages?.first?.conversationIdentifier == aliceID)
  }

  @Test func `search without a radio asks to open the app`() async {
    let bridge = IntentBridge()
    bridge.adopt(AppState(defaults: UserDefaults(suiteName: UUID().uuidString)!))

    let response = await SearchForMessagesIntentHandler(bridge: bridge).handle(intent: INSearchForMessagesIntent())

    #expect(response.code == .failureRequiringAppLaunch)
  }

  // MARK: - INSetMessageAttributeIntent

  @Test func `marking read clears the conversation unread count and refreshes chats`() async throws {
    let harness = try makeHarness()
    let alice = Self.makeContact(name: "Alice", keyByte: 0xA1, unread: 1)
    try await harness.store.saveContact(alice)
    let message = Self.makeMessage(contactID: alice.id, text: "hello", secondsAgo: 60)
    try await harness.store.saveMessage(message)
    let before = harness.appState.conversationsVersion

    let intent = INSetMessageAttributeIntent(identifiers: [message.id.uuidString], attribute: .read)
    let response = await SetMessageAttributeIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .success)
    #expect(try await harness.store.fetchContact(id: alice.id)?.unreadCount == 0)
    #expect(harness.appState.conversationsVersion > before)
  }

  @Test func `marking a channel message read clears the channel unread count`() async throws {
    let harness = try makeHarness()
    let channel = Self.makeChannel(index: 0, name: "Public", secretByte: 0x11, unread: 2)
    try await harness.store.saveChannel(channel)
    let message = Self.makeMessage(channelIndex: 0, text: "net check", secondsAgo: 60, sender: "RidgeRunner")
    try await harness.store.saveMessage(message)

    let intent = INSetMessageAttributeIntent(identifiers: [message.id.uuidString], attribute: .read)
    let response = await SetMessageAttributeIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .success)
    #expect(try await harness.store.fetchChannel(id: channel.id)?.unreadCount == 0)
  }

  @Test func `marking an unknown message read reports not found`() async throws {
    let harness = try makeHarness()

    let intent = INSetMessageAttributeIntent(identifiers: [UUID().uuidString], attribute: .read)
    let response = await SetMessageAttributeIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .failureMessageNotFound)
  }

  @Test func `only the read attribute is supported`() async throws {
    let harness = try makeHarness()

    let intent = INSetMessageAttributeIntent(identifiers: [UUID().uuidString], attribute: .flagged)
    let response = await SetMessageAttributeIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .failure)
  }

  // MARK: - INSendMessageIntent

  /// The notification-reply path: the conversation's composite id arrives as
  /// the conversation identifier, and the send lands in the durable queue.
  @Test func `send to a conversation id queues the message`() async throws {
    let harness = try makeHarness(state: .ready)
    let channel = Self.makeChannel(index: 0, name: "Public", secretByte: 0x11)
    try await harness.store.saveChannel(channel)

    let intent = INSendMessageIntent(
      recipients: nil, outgoingMessageType: .outgoingMessageText, content: "copy that",
      speakableGroupName: nil, conversationIdentifier: MessageTargetEntity(dto: channel).id,
      serviceName: nil, sender: nil, attachments: nil
    )
    let response = await SendMessageIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .success)
    #expect(try await harness.store.fetchPendingSends(radioID: Self.radioID).count == 1)
  }

  @Test func `send to a spoken contact name queues the message`() async throws {
    let harness = try makeHarness(state: .ready)
    try await harness.store.saveContact(Self.makeContact(name: "Alice", keyByte: 0xA1))
    let person = INPerson(
      personHandle: INPersonHandle(value: "Alice", type: .unknown), nameComponents: nil,
      displayName: "Alice", image: nil, contactIdentifier: nil, customIdentifier: nil
    )

    let intent = INSendMessageIntent(
      recipients: [person], outgoingMessageType: .outgoingMessageText, content: "on my way",
      speakableGroupName: nil, conversationIdentifier: nil,
      serviceName: nil, sender: nil, attachments: nil
    )
    let response = await SendMessageIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .success)
    #expect(try await harness.store.fetchPendingSends(radioID: Self.radioID).count == 1)
  }

  @Test func `send while disconnected writes nothing`() async throws {
    let harness = try makeHarness(state: .disconnected)
    let alice = Self.makeContact(name: "Alice", keyByte: 0xA1)
    try await harness.store.saveContact(alice)

    let intent = INSendMessageIntent(
      recipients: nil, outgoingMessageType: .outgoingMessageText, content: "hello",
      speakableGroupName: nil, conversationIdentifier: MessageTargetEntity(dto: alice).id,
      serviceName: nil, sender: nil, attachments: nil
    )
    let response = await SendMessageIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .failureRequiringAppLaunch)
    #expect(try await harness.store.fetchPendingSends(radioID: Self.radioID).isEmpty)
  }

  @Test func `ambiguous spoken name does not send`() async throws {
    let harness = try makeHarness(state: .ready)
    try await harness.store.saveContact(Self.makeContact(name: "Alice Chen", keyByte: 0xA1))
    try await harness.store.saveContact(Self.makeContact(name: "Alice Park", keyByte: 0xA2))
    let person = INPerson(
      personHandle: INPersonHandle(value: "Alice", type: .unknown), nameComponents: nil,
      displayName: "Alice", image: nil, contactIdentifier: nil, customIdentifier: nil
    )

    let intent = INSendMessageIntent(
      recipients: [person], outgoingMessageType: .outgoingMessageText, content: "hi",
      speakableGroupName: nil, conversationIdentifier: nil,
      serviceName: nil, sender: nil, attachments: nil
    )
    let response = await SendMessageIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .failure)
    #expect(try await harness.store.fetchPendingSends(radioID: Self.radioID).isEmpty)
  }

  @Test func `conversation id from another radio does not send`() async throws {
    let harness = try makeHarness(state: .ready)
    let stranger = Self.makeContact(radioID: Self.otherRadioID, name: "Stranger", keyByte: 0xA9)
    try await harness.store.saveContact(stranger)

    let intent = INSendMessageIntent(
      recipients: nil, outgoingMessageType: .outgoingMessageText, content: "hi",
      speakableGroupName: nil, conversationIdentifier: MessageTargetEntity(dto: stranger).id,
      serviceName: nil, sender: nil, attachments: nil
    )
    let response = await SendMessageIntentHandler(bridge: harness.bridge).handle(intent: intent)

    #expect(response.code == .failure)
    #expect(try await harness.store.fetchPendingSends(radioID: Self.radioID).isEmpty)
    #expect(try await harness.store.fetchPendingSends(radioID: Self.otherRadioID).isEmpty)
  }
}
