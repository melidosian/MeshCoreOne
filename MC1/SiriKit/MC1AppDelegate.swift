import Intents
import UIKit

/// Routes in-app SiriKit intents to their handlers. SiriKit messaging must run
/// in the app process (not an Intents extension) because only the app holds the
/// radio connection.
final class MC1AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    let bridge = IntentBridge.shared
    switch intent {
    case is INSendMessageIntent:
      return SendMessageIntentHandler(bridge: bridge)
    case is INSearchForMessagesIntent:
      return SearchForMessagesIntentHandler(bridge: bridge)
    case is INSetMessageAttributeIntent:
      return SetMessageAttributeIntentHandler(bridge: bridge)
    default:
      return nil
    }
  }
}
