import Foundation
import SwiftSignalKit
import WGCore

/// Entry point of the WGProfileExport feature module (W4-1): the GCONNECT nick badge, fake gifts,
/// chat export.
public enum WGProfileExportModule {
    private static var fakeGiftsDisposable: Disposable?

    /// Declares settings, menu rows, hook handlers and migrations. Called once on the main
    /// thread from `WGFeatures.registerAll()`, before `WGHookRegistry.freeze()`.
    public static func register() {
        assert(Thread.isMainThread)
        WGNickBadgeSettings.declare()
        WGFakeGiftsSettings.declare()
        WGLocalStars.declare()
        WGChatExportSettings.declare()
        WGFakeGiftsLegacy.registerMigrations()

        // Nick badge: slots, the network side (off until the user turns badges on), menu.
        WGNickBadgeSlots.register()
        WGNickBadgeMenu.register()
        WGNickBadgeService.shared.start()

        // Fake gifts: the profile's list, the gift screen's menu, the store per account.
        WGFakeGiftsHooks.register()
        WGFakeGiftsMenu.register()
        WGProfileExportModule.fakeGiftsDisposable = (WGFakeGiftsSettings.isEnabled.signal
        |> distinctUntilChanged).start(next: { enabled in
            WGFakeGiftsStore.shared.setEnabled(enabled)
        })
        // Local stars: the Stars balance shown on this device (same tab, own section).
        WGLocalStars.register()

        // Chat export: entry points; temporary trees of old jobs are removed off the main thread.
        WGChatExportMenu.register()
        WGChatExportManager.shared.removeStaleJobs()
    }
}
