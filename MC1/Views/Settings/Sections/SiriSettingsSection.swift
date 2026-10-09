import Intents
import SwiftUI

/// Siri permission for hands-free messaging. Siri only routes messaging
/// requests to the app after the user allows it, so this offers the one-time
/// prompt and points to Settings when access was declined.
struct SiriSettingsSection: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @State private var status: INSiriAuthorizationStatus = INPreferences.siriAuthorizationStatus()

  var body: some View {
    Section {
      switch status {
      case .notDetermined:
        Button {
          INPreferences.requestSiriAuthorization { newStatus in
            Task { @MainActor in status = newStatus }
          }
        } label: {
          TintedLabel(L10n.Settings.Siri.enable, systemImage: "mic")
        }

      case .denied, .restricted:
        VStack(alignment: .leading, spacing: 8) {
          Label(L10n.Settings.Siri.disabled, systemImage: "mic.slash")
            .foregroundStyle(.secondary)

          Button(L10n.Settings.Notifications.openSettings) {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              openURL(url)
            }
          }
          .font(.subheadline)
        }

      default:
        Label(L10n.Settings.Siri.enabled, systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      }
    } header: {
      Text(L10n.Settings.Siri.header)
    } footer: {
      Text(L10n.Settings.Siri.footer)
    }
    .themedRowBackground(theme)
    .onChange(of: scenePhase) {
      if scenePhase == .active {
        status = INPreferences.siriAuthorizationStatus()
      }
    }
  }
}
