import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import AccountContext
import ItemListUI
import WGCore
import WGSettingsUI

// The nick badge screen: the account's own badge, what a badge costs (from the server, only while
// this screen is open), and the way to the bot. Opened from the menu and from a bulletin's "More".

func ggMakeNickBadgeScreen(context: AccountContext) -> ViewController {
    let accountPeerId = context.account.peerId
    weak var controllerRef: ItemListController?

    let configSignal: Signal<WGNickBadgeServerConfig?, NoError> = WGNickBadgeSettings.isEnabled.signal
    |> distinctUntilChanged
    |> mapToSignal { _ -> Signal<WGNickBadgeServerConfig?, NoError> in
        return WGNickBadgeService.shared.serverConfig()
    }
    let changes: Signal<Void, NoError> = .single(Void()) |> then(WGNickBadgeService.shared.changes)

    let model = combineLatest(queue: .mainQueue(), WGNickBadgeSettings.isEnabled.signal, configSignal, changes, WGLocalization.shared.languageCodeSignal)
    |> map { isEnabled, config, _, _ -> WGPEScreenModel in
        var model = WGPEScreenModel(title: WGStrings.NickBadge.Screen.title)

        let badge = isEnabled ? WGNickBadgeService.shared.badge(for: accountPeerId) : nil
        let status: String
        if !isEnabled {
            status = WGStrings.NickBadge.Status.off
        } else if let badge = badge {
            status = badge.kind == .team ? WGStrings.NickBadge.Status.team : WGStrings.NickBadge.Status.active
        } else {
            status = WGStrings.NickBadge.Status.none
        }
        let icon = badge.flatMap { WGNickBadgeArt.image(for: $0, height: 28.0) } ?? WGNickBadgeArt.sampleImage(height: 28.0)
        var statusSection: [WGPERow] = [
            WGPERow(id: "statusHeader", kind: .header(WGStrings.NickBadge.Screen.statusHeader)),
            WGPERow(id: "status", kind: .disclosure(title: WGStrings.NickBadge.Screen.status, label: status, icon: WGPEImage(image: icon), enabled: true))
        ]
        if !isEnabled {
            statusSection.append(WGPERow(id: "statusFooter", kind: .footer(WGStrings.NickBadge.Screen.offFooter)))
        }
        model.tap["status"] = {
            if badge != nil {
                ggPresentNickBadgeBulletin(context: context, peerId: accountPeerId)
            }
        }
        model.sections.append(statusSection)

        var getSection: [WGPERow] = [WGPERow(id: "getHeader", kind: .header(WGStrings.NickBadge.Screen.getHeader))]
        if let config = config {
            if let price = config.standard {
                getSection.append(WGPERow(id: "planStandard", kind: .disclosure(title: WGStrings.NickBadge.Screen.planStandard, label: ggNickBadgePriceLabel(price), icon: nil, enabled: true)))
            }
            if let price = config.custom {
                getSection.append(WGPERow(id: "planCustom", kind: .disclosure(title: WGStrings.NickBadge.Screen.planCustom, label: ggNickBadgePriceLabel(price), icon: nil, enabled: true)))
            }
        } else {
            getSection.append(WGPERow(id: "pricesLoading", kind: .disclosure(title: WGStrings.NickBadge.Screen.pricesLoading, label: "", icon: nil, enabled: false)))
        }
        getSection.append(WGPERow(id: "openBot", kind: .action(title: WGStrings.NickBadge.Screen.openBot, destructive: false, enabled: true)))
        let bot = config?.bot ?? WGNickBadgeService.shared.botUsername
        getSection.append(WGPERow(id: "info", kind: .footer(WGStrings.NickBadge.Screen.info(bot: bot))))
        let openBot = {
            guard let navigationController = controllerRef?.navigationController as? NavigationController else {
                return
            }
            WGNickBadgeService.shared.noteWentToBot()
            ggProfileExportOpenTelegramLink(context: context, url: "https://t.me/" + bot, navigationController: navigationController)
        }
        model.tap["planStandard"] = openBot
        model.tap["planCustom"] = openBot
        model.tap["openBot"] = openBot
        model.sections.append(getSection)
        return model
    }

    let controller = ggPEMakeListController(context: context, model: model)
    controllerRef = controller
    return controller
}

/// «590 ₽ · 250 ⭐️», «$5 · 250 ⭐️» — whatever the server knows.
func ggNickBadgePriceLabel(_ price: WGNickBadgeServerConfig.Price) -> String {
    var parts: [String] = []
    if let local = price.local {
        parts.append(local)
    } else if let usd = price.usd {
        parts.append(WGStrings.NickBadge.Screen.priceUsd(amount: usd))
    }
    if let stars = price.stars {
        parts.append(WGStrings.NickBadge.Screen.priceStars(amount: "\(stars)"))
    }
    return parts.joined(separator: " · ")
}

// MARK: - Menu (More › Nick badge)

enum WGNickBadgeMenu {
    static func register() {
        WGMenuRegistry.register(WGMenuRow(
            id: "nickBadge.isEnabled",
            section: .main(of: .moreNickBadge),
            order: 100,
            title: { WGStrings.NickBadge.Menu.show },
            subtitle: { WGStrings.NickBadge.Menu.showInfo },
            kind: .toggle(.global(WGNickBadgeSettings.isEnabled)),
            searchKeywords: { [WGStrings.NickBadge.Menu.keywords] }
        ))
        WGMenuRegistry.register(WGMenuRow(
            id: "nickBadge.screen",
            section: .main(of: .moreNickBadge),
            order: 200,
            title: { WGStrings.NickBadge.Menu.screen },
            subtitle: { WGStrings.NickBadge.Menu.screenInfo },
            icon: .bundle("Chat/Context Menu/Tag"),
            kind: .action({ context in
                context.push(ggMakeNickBadgeScreen(context: context.context))
            }),
            searchKeywords: { [WGStrings.NickBadge.Menu.keywords] }
        ))
    }
}
