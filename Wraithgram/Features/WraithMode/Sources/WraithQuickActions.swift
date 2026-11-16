import Foundation
import WGCore
import WGFeaturesShared

/// The zone's buttons of «Кнопки быстрого доступа» in a chat (W2-5's `WGQuickActions`): wraith mode
/// and delayed sending of the account, as switches. The buttons themselves are drawn by WGInterface.
enum WGWraithQuickActions {
    static func register() {
        WGQuickActions.actions.register(WGQuickAction(
            id: WGQuickActionIds.wraithMode,
            order: 100,
            title: { WGStrings.WraithMode.Menu.group },
            iconName: "Chat/Context Menu/EyeLocked",
            isOn: { context in
                return WGWraithSettings.isEnabled.value(for: context.accountID)
            },
            perform: { context in
                let account = context.accountID
                WGWraithSettings.isEnabled.set(!WGWraithSettings.isEnabled.value(for: account), for: account)
            }
        ))
        WGQuickActions.actions.register(WGQuickAction(
            id: WGQuickActionIds.sendDelay,
            order: 400,
            title: { WGStrings.Menu.Tab.Privacy.sendDelay },
            iconName: "Chat/Context Menu/Schedule",
            isOn: { context in
                return WGWraithSettings.sendDelayEnabled.value(for: context.accountID)
            },
            perform: { context in
                let account = context.accountID
                WGWraithSettings.sendDelayEnabled.set(!WGWraithSettings.sendDelayEnabled.value(for: account), for: account)
            }
        ))
    }
}
