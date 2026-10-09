import AppIntents
import MC1Services

/// Stable indirection between App Intents and the live `AppState`. Registered
/// once with `AppDependencyManager`, it survives the before-first-unlock
/// `AppState` swap so an intent always reads the current connection state
/// rather than a captured throwaway. A `nil` `appState` means the app is still
/// launching; intents treat that as not-ready, never as disconnected.
@Observable
@MainActor
final class IntentBridge {
  /// The single bridge for the process. App Intents receive it through
  /// `AppDependencyManager`; UIKit-instantiated objects (the SiriKit app
  /// delegate and the CarPlay scene delegate) have no injection point, so they
  /// read it here.
  static let shared = IntentBridge()

  private(set) var appState: AppState?

  func adopt(_ appState: AppState) {
    self.appState = appState
  }
}
