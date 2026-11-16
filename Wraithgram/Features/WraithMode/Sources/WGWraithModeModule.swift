import Foundation
import SwiftSignalKit
import TelegramCore
import WGCore
import WGFeaturesShared

/// Entry point of the WGWraithMode feature module. Owner: W2-1.
///
/// The decisions about what leaves the device live in `WGFeaturesShared` (`WGWraithModeShared`,
/// registered by the aggregator for the app and the extensions alike). This module is the app's
/// side: the menu, the chat-screen tracking, the explicit reads and the menu items.
public enum WGWraithModeModule {
    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `WGFeatures.registerAll()`, before `WGHookRegistry.freeze()`.
    public static func register() {
        WGWraithMigrations.register()
        WGWraithMenu.register()
        WGWraithMenuItems.register()
        WGWraithChatTracking.register()
        WGWraithBlockedPeers.register()
        WGWraithTraces.register()
        WGWraithQuickActions.register()

        WGAccountHooks.accountWillBeRemoved.register({ id in
            let account = id.gg
            Queue.mainQueue().async {
                WGWraithAccounts.shared.accountWillBeRemoved(account)
                WGWraithBlockedPeers.shared.clear(account: account)
            }
        }, order: 100)

        // Throttled work on return to the app (never on every activation, never in the background):
        // the blocked lists of the accounts that hide them, and «Прочитать локально» re-applied
        // after a server reset of the read state.
        WGForegroundTaskScheduler.shared.register(id: "wraithMode.refresh", minimumInterval: 30.0 * 60.0, delay: 4.0, task: { done in
            let contexts = WGWraithAccounts.shared.contexts
            var signals: [Signal<Never, NoError>] = []
            for context in contexts {
                let account = context.account.id.gg
                if WGWraithSettings.hideBlockedMessages.value(for: account) {
                    // The current list stays in use until the new one is complete.
                    WGWraithBlockedPeers.shared.reload(context: context)
                }
                signals.append(WGWraithAccounts.reapplyLocalReads(context: context))
            }
            if signals.isEmpty {
                done()
                return EmptyDisposable
            }
            return combineLatest(signals).start(completed: {
                done()
            })
        })
    }
}
