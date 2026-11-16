// Compiled into IntentsExtensionLib (filegroup //Wraithgram/WGHooks:SiriIntentsHookSources):
// launch of Wraithgram in the Siri intents extension. «Mark as read» from Siri goes through
// `applyMaxReadIndexInteractively` → `WGPresenceHooks.sendReadReceipt`, whose wraith-mode handler
// lives in WGFeaturesShared; without this launch the point is empty there and Siri reads past
// wraith mode. Accounts opened by the extension go through `Account.init` (WGAccountHooks).

import Foundation
import WGCore
import WGFeaturesShared

private var ggSiriIntentsStarted = false
private let ggSiriIntentsLock = NSLock()

/// WRAITH hook target: before `initializeAccountManagement()` and before any account is opened. The
/// first call starts Wraithgram in the process; a later one (iOS keeps the process for the next
/// request) reads the settings files again, so chat protection and wraith mode changed in the app
/// apply at once.
func ggSiriIntentsDidStart(appGroupPath: String) {
    ggSiriIntentsLock.lock()
    defer {
        ggSiriIntentsLock.unlock()
    }
    if ggSiriIntentsStarted {
        WGCore.reloadSettings()
        return
    }
    ggSiriIntentsStarted = true
    WGCore.bootstrap(WGCoreEnvironment(appGroupPath: appGroupPath, process: .intents))
    // Handlers register on the main thread (WGHookPoint contract).
    if Thread.isMainThread {
        WGFeaturesShared.registerForExtension()
    } else {
        DispatchQueue.main.sync {
            WGFeaturesShared.registerForExtension()
        }
    }
    WGHookRegistry.freeze()
}
