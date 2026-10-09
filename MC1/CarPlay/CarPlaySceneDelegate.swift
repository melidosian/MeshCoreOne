import CarPlay
import Intents
import MC1Services
import os

private let logger = Logger(subsystem: "com.mc1", category: "CarPlay")

/// The CarPlay interface: a Chats tab (DMs) and a Channels tab, each listing
/// the current radio's conversations as `CPMessageListItem`s. Selecting a row
/// hands off to Siri with that conversation's id, which reads unread messages
/// aloud (`INSearchForMessagesIntent`) and offers to reply
/// (`INSendMessageIntent`), both handled in-app. CarPlay allows no custom UI and
/// no on-screen message text for messaging apps, so the lists are the whole UI.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var interfaceController: CPInterfaceController?
  private let chatsTemplate = CPListTemplate(title: L10n.Localizable.Carplay.Tab.chats, sections: [])
  private let channelsTemplate = CPListTemplate(title: L10n.Localizable.Carplay.Tab.channels, sections: [])
  private var reloadTask: Task<Void, Never>?

  /// Coalesces bursts of conversation changes (a sync can bump the version many
  /// times a second) into one list rebuild.
  private static let reloadDebounce: Duration = .milliseconds(300)

  /// Rows per tab; CarPlay may cap lists lower still on some head units.
  private static let maximumRows = 50

  private var bridge: IntentBridge { .shared }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    logger.info("CarPlay connected")
    self.interfaceController = interfaceController
    chatsTemplate.tabImage = UIImage(systemName: "person.fill")
    channelsTemplate.tabImage = UIImage(systemName: "person.3.fill")
    chatsTemplate.emptyViewTitleVariants = [L10n.Localizable.Carplay.Empty.chats]
    channelsTemplate.emptyViewTitleVariants = [L10n.Localizable.Carplay.Empty.channels]
    let tabs = CPTabBarTemplate(templates: [chatsTemplate, channelsTemplate])
    interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
    observeConversations()
    scheduleReload(debounced: false)
    requestSiriAuthorizationIfNeeded()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    logger.info("CarPlay disconnected")
    reloadTask?.cancel()
    reloadTask = nil
    self.interfaceController = nil
  }

  // MARK: - Updates

  /// Re-arms an observation of everything the lists depend on: the bridge's
  /// `AppState` (swapped once after a before-first-unlock launch), the
  /// conversations version, the selected radio and the connection rung.
  private func observeConversations() {
    guard interfaceController != nil else { return }
    withObservationTracking {
      if let appState = bridge.appState {
        _ = appState.conversationsVersion
        _ = appState.currentRadioID
        _ = appState.connectionState
      }
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        scheduleReload(debounced: true)
        observeConversations()
      }
    }
  }

  private func scheduleReload(debounced: Bool) {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      if debounced {
        try? await Task.sleep(for: Self.reloadDebounce)
      }
      guard !Task.isCancelled else { return }
      await self?.reload()
    }
  }

  private func reload() async {
    guard let appState = bridge.appState, appState.currentRadioID != nil else {
      showNoRadio()
      return
    }
    let conversations: [SiriConversation]
    do {
      conversations = try await SiriConversationResolver(bridge: bridge).conversations()
    } catch {
      logger.error("CarPlay reload failed: \(error.localizedDescription)")
      return
    }
    guard !Task.isCancelled else { return }
    let isConnected = appState.connectionState == .ready || appState.connectionState == .syncing
    let header = isConnected ? nil : L10n.Localizable.Carplay.radioDisconnected
    let chats = conversations.filter { !$0.isChannel }.prefix(Self.maximumRows).map(item(for:))
    let channels = conversations.filter(\.isChannel).prefix(Self.maximumRows).map(item(for:))
    chatsTemplate.updateSections([CPListSection(items: Array(chats), header: header, sectionIndexTitle: nil)])
    channelsTemplate.updateSections([CPListSection(items: Array(channels), header: header, sectionIndexTitle: nil)])
  }

  private func showNoRadio() {
    let item = CPListItem(text: L10n.Localizable.Carplay.noRadio, detailText: nil)
    item.isEnabled = false
    chatsTemplate.updateSections([CPListSection(items: [item])])
    channelsTemplate.updateSections([CPListSection(items: [item])])
  }

  // MARK: - Rows

  private func item(for conversation: SiriConversation) -> CPMessageListItem {
    let leading = CPMessageListItemLeadingConfiguration(
      leadingItem: .none,
      leadingImage: UIImage(systemName: conversation.isChannel ? "person.3.fill" : "person.crop.circle.fill"),
      unread: conversation.unreadCount > 0
    )
    let trailing = CPMessageListItemTrailingConfiguration(trailingItem: .none, trailingImage: nil)
    let item = CPMessageListItem(
      conversationIdentifier: conversation.id,
      text: conversation.displayName,
      leadingConfiguration: leading,
      trailingConfiguration: trailing,
      detailText: Self.unreadText(conversation.unreadCount),
      trailingText: conversation.lastMessageDate.map(Self.relativeTime(_:))
    )
    return item
  }

  private static func unreadText(_ count: Int) -> String? {
    count > 0 ? L10n.Localizable.Carplay.unread(count) : nil
  }

  private static func relativeTime(_ date: Date) -> String {
    date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
  }

  // MARK: - Siri

  /// A tap on a conversation is fulfilled by Siri, which needs the user's
  /// permission once. The prompt appears on the phone, not the car display.
  private func requestSiriAuthorizationIfNeeded() {
    guard INPreferences.siriAuthorizationStatus() == .notDetermined else { return }
    INPreferences.requestSiriAuthorization { status in
      logger.info("Siri authorization: \(status.rawValue)")
    }
  }
}
