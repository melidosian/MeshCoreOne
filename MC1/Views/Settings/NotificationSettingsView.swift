import SwiftUI

struct NotificationSettingsView: View {
  @Environment(\.appTheme) private var theme

  var body: some View {
    List {
      NotificationSettingsSection()
      SiriSettingsSection()
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.Notifications.header)
    .navigationBarTitleDisplayMode(.inline)
  }
}
