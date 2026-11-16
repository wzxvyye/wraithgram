import Foundation
import WGCore
import WGFeaturesShared

/// Old Wraithgram keys of this zone → the new settings.
///
/// - `WraithMode.*`, `SendDelay.isEnabled`, `MiscSettings.alwaysOnline`, `MiscSettings.hideBlockedUserMessages`,
///   SG `storyStealthMode` become per-account (`legacyAccountValue`): with the old per-account profiles
///   off every account takes the shared value; with them on the shared keys are the active account's,
///   any other account takes its own profile only. These keys stay in place for the other accounts
///   (they are tiny). Folder exceptions are folder ids, an account's own: the shared list (profiles
///   off) is taken only when the device has one account.
/// - SG `warnOnStoriesOpen`, `confirmCalls`, `hidePhoneInSettings` → «Следы» (global); SG
///   `storyStealthMode` is folded into «Не читать истории» (one mechanism instead of two).
/// - Not moved on purpose: `WraithMode.forceOffline` (merged into «Не отправлять «онлайн»»), the
///   stored peer snapshots of type and folder exceptions (resolved live now), `serverSyncedReadIds`
///   and `locallyReadOnlyPeers` (the old app confirmed those reads as sent; the new ledger starts
///   clean, so nothing is kept local forever).
enum WGWraithMigrations {
    static func register() {
        WGMigrations.registerGlobal(id: "wraithMode.traces.v1") { legacy in
            if let value = legacy.bool("confirmCalls") {
                WGWraithSettings.confirmCalls.set(value)
                legacy.removeLegacyKey("confirmCalls")
            }
            if let value = legacy.bool("warnOnStoriesOpen") {
                WGWraithSettings.warnBeforeStories.set(value)
                legacy.removeLegacyKey("warnOnStoriesOpen")
            }
            if let value = legacy.bool("hidePhoneInSettings") {
                WGWraithSettings.hidePhoneInSettings.set(value)
                legacy.removeLegacyKey("hidePhoneInSettings")
            }
        }

        // «Вечный онлайн» lived behind the old «Прочее» master: only both on kept the account online
        // (`MiscSettingsManager.shouldAlwaysBeOnline`), and the master was global even with the
        // per-account profiles on. It is read here because `messages.v1` removes it later in this same
        // run (this module registers first); the account migrations of this launch, which run only
        // after it, gate every account's switch with it.
        WGMigrations.registerGlobal(id: "wraithMode.alwaysOnline.master.v1") { legacy in
            WGWraithMigrations.setLegacyMiscMaster(legacy.bool("MiscSettings.isEnabled") ?? false)
        }

        WGMigrations.registerAccount(id: "wraithMode.account.v1") { legacy, account in
            // With the old per-account profiles on, the shared keys are the active account's live
            // values: another account takes its own profile only, never those.
            func object(_ key: String) -> Any? {
                return legacy.legacyAccountValue(key, for: account)
            }
            func bool(_ key: String) -> Bool? {
                return WGWraithMigrations.legacyBool(object(key))
            }

            let wasEnabled = bool("WraithMode.isEnabled") ?? false
            let hideReads = bool("WraithMode.hideReadReceipts")
            let hideStories = bool("WraithMode.hideStoryViews")
            let hideOnline = bool("WraithMode.hideOnlineStatus")
            let forceOffline = bool("WraithMode.forceOffline")
            let hideTyping = bool("WraithMode.hideTypingIndicator")
            let storyStealth = bool("storyStealthMode") ?? false

            if wasEnabled {
                WGWraithSettings.isEnabled.set(true, for: account)
                // The old switches were on by default: an absent key meant "on".
                WGWraithSettings.hideReadReceipts.set(hideReads ?? true, for: account)
                WGWraithSettings.hideStoryViews.set((hideStories ?? true) || storyStealth, for: account)
                WGWraithSettings.hideOnline.set((hideOnline ?? true) || (forceOffline ?? true), for: account)
                WGWraithSettings.hideTyping.set(hideTyping ?? true, for: account)
            } else if storyStealth {
                // Swiftgram's story stealth worked without the wraith master: keep exactly that effect.
                WGWraithSettings.isEnabled.set(true, for: account)
                WGWraithSettings.hideStoryViews.set(true, for: account)
            }
            if let value = bool("WraithMode.readOnAction") {
                WGWraithSettings.readOnAction.set(value, for: account)
            }

            if let raw = object("WraithMode.hiddenActivityKinds") as? [String] {
                // Old list: hidden statuses. New switches: statuses still shown.
                let hidden = Set(raw.compactMap(WGWraithActivityKind.init(rawValue:)))
                for kind in WGWraithActivityKind.allCases {
                    WGWraithSettings.shownActivity(kind).set(!hidden.contains(kind), for: account)
                }
            }

            // The stealth session was removed (owner, 2026-10-27): its duration is not carried over.

            if let value = bool("WraithMode.excludeAllChannels") {
                WGWraithSettings.exceptAllChannels.set(value, for: account)
            }
            if let value = bool("WraithMode.excludeAllGroups") {
                WGWraithSettings.exceptAllGroups.set(value, for: account)
            }
            // Folder ids are an account's own: with the profiles off the shared list would except a
            // random folder of every other account (and wraith mode would send reads there).
            if legacy.legacyAccountProfilesEnabled || WGLegacyAccounts.isSingleAccount, let folders = object("WraithMode.excludedFolderIds") as? [NSNumber], !folders.isEmpty {
                WGWraithSettings.exceptFolders.set(Set(folders.map { $0.int32Value }), for: account)
            }

            WGWraithMigrations.migrateExceptions(ids: object("WraithMode.excludedPeerIds") as? [NSNumber], settingsData: (object("WraithMode.exclusionSettings") as? Data), account: account)

            if let value = bool("SendDelay.isEnabled") {
                WGWraithSettings.sendDelayEnabled.set(value, for: account)
            }
            if let value = bool("MiscSettings.alwaysOnline") {
                // Only with the global «Прочее» master on (read by `wraithMode.alwaysOnline.master.v1`;
                // in a later launch it is gone, and «off» is the safe answer).
                let master = WGWraithMigrations.legacyMiscMaster() ?? (legacy.bool("MiscSettings.isEnabled") ?? false)
                WGWraithSettings.alwaysOnline.set(value && master, for: account)
            }
            if let value = bool("MiscSettings.hideBlockedUserMessages") {
                WGWraithSettings.hideBlockedMessages.set(value, for: account)
            }
        }

        // Builds ≤ 185 had separate text and media delays; one since 2026-10-27: the larger of the
        // two, so no message leaves sooner than it did.
        WGMigrations.registerAccount(id: "sendDelay.merge.v1") { _, account in
            let text = WGRetiredSettings.value("sendDelay.textSeconds", as: Double.self, account: account)
            let media = WGRetiredSettings.value("sendDelay.mediaSeconds", as: Double.self, account: account)
            if let seconds = WGSendDelaySeconds.merged(text: text, media: media) {
                WGWraithSettings.sendDelaySeconds.set(seconds, for: account)
            }
            WGRetiredSettings.remove(keys: ["sendDelay.textSeconds", "sendDelay.mediaSeconds"], account: account)
        }

        // The stealth session was removed (owner, 2026-10-27): its stored start and duration go too.
        WGMigrations.registerAccount(id: "wraithMode.stealth.removed.v1") { _, account in
            WGRetiredSettings.remove(keys: ["wraithMode.stealthStartedAt", "wraithMode.stealthMinutes"], account: account)
        }
    }

    private static let legacyMiscMasterLock = NSLock()
    private static var legacyMiscMasterValue: Bool?

    private static func setLegacyMiscMaster(_ value: Bool) {
        WGWraithMigrations.legacyMiscMasterLock.lock()
        WGWraithMigrations.legacyMiscMasterValue = value
        WGWraithMigrations.legacyMiscMasterLock.unlock()
    }

    /// The old «Прочее» master as the global migration of this launch read it; nil in later launches.
    private static func legacyMiscMaster() -> Bool? {
        WGWraithMigrations.legacyMiscMasterLock.lock()
        defer {
            WGWraithMigrations.legacyMiscMasterLock.unlock()
        }
        return WGWraithMigrations.legacyMiscMasterValue
    }

    /// An old value as a Bool, read the way `WGLegacyDefaults.bool` reads one.
    private static func legacyBool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private struct LegacyException: Decodable {
        var readMessages: Bool?
        var readStories: Bool?
        var showOnlineStatus: Bool?
        var showTyping: Bool?
        var disableForceOffline: Bool?
        var readOnAction: Bool?
        var hiddenActivityKinds: [String]?
    }

    /// Old ids: `PeerId.toInt64()` (namespace bits set) or, from older builds, a bare id. A bare id
    /// can not be told apart from a user here (no database in a migration); it is checked on first use.
    private static func migrateExceptions(ids: [NSNumber]?, settingsData: Data?, account: WGAccountID) {
        var legacySettings: [Int64: LegacyException] = [:]
        if let data = settingsData, let decoded = try? JSONDecoder().decode([String: LegacyException].self, from: data) {
            for (key, value) in decoded {
                if let id = Int64(key) {
                    legacySettings[id] = value
                }
            }
        }
        guard let ids = ids, !ids.isEmpty else {
            return
        }
        var exceptions = WGWraithSettings.exceptions.value(for: account)
        var unresolved: [Int64] = []
        for number in ids {
            let value = number.int64Value
            let key = WGLegacyKeys.peerKey(fromLegacyInt64: value)
            if key.namespace == 0 {
                // A user stored by toInt64 looks the same as any bare id: stored as a user for now,
                // moved to its group or channel on first use if no such user exists.
                unresolved.append(key.id)
            }
            var exception = WGWraithException()
            if let old = legacySettings[value] {
                exception.readMessages = old.readMessages ?? true
                exception.readStories = old.readStories ?? true
                // «Показывать онлайн» and «Не форсить офлайн» did the same thing.
                exception.showOnline = (old.showOnlineStatus ?? true) || (old.disableForceOffline ?? false)
                exception.showTyping = old.showTyping ?? true
                if let hidden = old.hiddenActivityKinds {
                    let hiddenSet = Set(hidden.compactMap(WGWraithActivityKind.init(rawValue:)))
                    exception.ownShownActivities = WGWraithActivityKind.allCases.filter { !hiddenSet.contains($0) }
                }
                exception.readOnAction = old.readOnAction
            }
            exceptions[key.stringValue] = exception
        }
        WGWraithSettings.exceptions.set(exceptions, for: account)
        if !unresolved.isEmpty {
            WGWraithSettings.legacyUnresolvedPeers.set(unresolved, for: account)
        }
    }
}
