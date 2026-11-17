// The account's own state as features see it (W2-4, local Premium). Lives in the public WGHooks
// target, below TelegramUI: `AccountContext` and the profile header read it, the Appearance feature
// registers the provider.

import Foundation
import WGCore

public enum WGAccountStateHooks {
    /// Providers (any `true`): the account reports itself as Premium. Visual only — the server still
    /// decides what is allowed (upload limits, paid stickers), so premium-only actions it does not
    /// grant will fail. Registered by `WGAppearanceModule` from the «Локальный Premium» setting.
    public static let localPremium = WGHookPoint<() -> Bool>("account.localPremium")

    /// True when a provider says so. Called from hot paths (`AccountContext.isPremium`): read memory.
    public static func isLocalPremium() -> Bool {
        for handler in WGAccountStateHooks.localPremium.handlers {
            if handler() {
                return true
            }
        }
        return false
    }
}
