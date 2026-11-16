import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import AlertUI
import WGCore
import WGSettingsUI
import WGFeaturesShared

extension WGMenuTabID {
    static let wraithActivities = WGMenuTabID("wraithMode.activities")
}

extension WGMenuSectionID {
    static let wraithActivitiesMain = WGMenuSectionID("wraithMode.activities.main")
    static let wraithExceptionTypes = WGMenuSectionID("wraithMode.exceptions.types")
}

/// Rows of the «Приватность» category (PLAN §2.1): preview, the wraith-mode group and its rows, the
/// exceptions and send-delay tabs, «Следы»; plus «Скрыть сообщения заблокированных» in the
/// «Сообщения › Чаты» section where PLAN §2.2 puts it.
enum WGWraithMenu {
    static func register() {
        WGWraithPreview.register()
        WGWraithMenu.registerWraithSection()
        WGWraithMenu.registerActivitiesTab()
        WGWraithMenu.registerExceptionsTab()
        WGWraithMenu.registerSendDelayTab()
        WGWraithMenu.registerTraces()
        WGWraithMenu.registerChatsSection()
    }

    // MARK: Wraith mode

    private static func registerWraithSection() {
        let section = WGMenuSectionID.privacyWraithMode

        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.group",
            section: section,
            order: 100,
            title: { WGStrings.WraithMode.Menu.group },
            subtitle: { WGStrings.WraithMode.Menu.groupInfo },
            kind: .expandableGroup(master: .account(WGWraithSettings.isEnabled), children: [
                WGMenuRow(id: "wraithMode.hideReadReceipts", section: section, order: 100, title: { WGStrings.WraithMode.Menu.hideReadReceipts }, subtitle: { WGStrings.WraithMode.Menu.hideReadReceiptsInfo }, kind: .toggle(.account(WGWraithSettings.hideReadReceipts)), searchKeywords: { [WGStrings.WraithMode.Menu.keywordRead] }),
                WGMenuRow(id: "wraithMode.hideStoryViews", section: section, order: 200, title: { WGStrings.WraithMode.Menu.hideStoryViews }, subtitle: { WGStrings.WraithMode.Menu.hideStoryViewsInfo }, kind: .toggle(.account(WGWraithSettings.hideStoryViews)), searchKeywords: { [WGStrings.WraithMode.Menu.keywordStories] }),
                WGMenuRow(id: "wraithMode.hideOnline", section: section, order: 300, title: { WGStrings.WraithMode.Menu.hideOnline }, subtitle: { WGStrings.WraithMode.Menu.hideOnlineInfo }, kind: .toggle(.account(WGWraithSettings.hideOnline)), searchKeywords: { [WGStrings.WraithMode.Menu.keywordOnline] }),
                WGMenuRow(id: "wraithMode.hideTyping", section: section, order: 400, title: { WGStrings.WraithMode.Menu.hideTyping }, subtitle: { WGStrings.WraithMode.Menu.hideTypingInfo }, kind: .toggle(.account(WGWraithSettings.hideTyping)), searchKeywords: { [WGStrings.WraithMode.Menu.keywordTyping] })
            ]),
            searchKeywords: { [WGStrings.WraithMode.Menu.keywordWraith] }
        ))

        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.readOnAction",
            section: section,
            order: 300,
            title: { WGStrings.WraithMode.Menu.readOnAction },
            subtitle: { WGStrings.WraithMode.Menu.readOnActionInfo },
            kind: .toggle(.account(WGWraithSettings.readOnAction)),
            isEnabled: { context in
                return WGWraithSettings.isEnabled.value(for: context.accountID)
            }
        ))

        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.alwaysOnline",
            section: section,
            order: 400,
            title: { WGStrings.WraithMode.Menu.alwaysOnline },
            subtitle: { WGStrings.WraithMode.Menu.alwaysOnlineInfo },
            kind: .toggle(.account(WGWraithSettings.alwaysOnline)),
            searchKeywords: { [WGStrings.WraithMode.Menu.keywordOnline] },
            // Grey while wraith mode hides "online": the switch must not look active when it is not.
            isEnabled: { context in
                return !WGWraithPolicy.isFunctionOn(.online, account: context.accountID)
            }
        ))

        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.readLocally",
            section: section,
            order: 700,
            title: { WGStrings.WraithMode.Menu.readLocally },
            subtitle: { WGStrings.WraithMode.Menu.readLocallyInfo },
            icon: .bundle("Chat/Context Menu/ReadAll"),
            kind: .action({ context in
                WGWraithMenu.confirm(context, title: WGStrings.WraithMode.Menu.readLocallyConfirmTitle, text: WGStrings.WraithMode.Menu.readLocallyConfirmText, action: WGStrings.WraithMode.Menu.readLocally, perform: {
                    let accountContext = context.context
                    let _ = (WGWraithReadAll.readLocally(context: accountContext)
                    |> deliverOnMainQueue).start(next: { count in
                        context.presentToast(WGStrings.WraithMode.Menu.readLocallyDone(count: count))
                    })
                })
            }),
            searchKeywords: { [WGStrings.WraithMode.Menu.keywordRead] },
            label: { context in
                let count = WGWraithReadLedger.shared.localReadCount(account: context.accountID)
                return count > 0 ? "\(count)" : nil
            }
        ))

        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.readOnServer",
            section: section,
            order: 800,
            title: { WGStrings.WraithMode.Menu.readOnServer },
            subtitle: { WGStrings.WraithMode.Menu.readOnServerInfo },
            icon: .bundle("Chat/Context Menu/MarkAsRead"),
            kind: .action({ context in
                WGWraithMenu.confirm(context, title: WGStrings.WraithMode.Menu.readOnServerConfirmTitle, text: WGStrings.WraithMode.Menu.readOnServerConfirmText, action: WGStrings.WraithMode.Menu.readOnServer, perform: {
                    let accountContext = context.context
                    let _ = (WGWraithReadAll.readOnServer(context: accountContext)
                    |> deliverOnMainQueue).start(next: { count in
                        context.presentToast(WGStrings.WraithMode.Menu.readOnServerDone(count: count))
                    })
                })
            }),
            searchKeywords: { [WGStrings.WraithMode.Menu.keywordRead] },
            label: { context in
                let pending = WGWraithReadLedger.shared.pendingKeys(account: context.accountID)
                let count = pending.kept.count + pending.local.count
                return count > 0 ? "\(count)" : nil
            }
        ))
    }

    static func confirm(_ context: WGMenuContext, title: String, text: String, action: String, perform: @escaping () -> Void) {
        let presentationData = context.presentationData
        let alert = textAlertController(context: context.context, title: title, text: text, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .defaultAction, title: action, action: perform)
        ])
        context.present(alert)
    }

    // MARK: Activity statuses

    static func activityTitle(_ kind: WGWraithActivityKind) -> String {
        switch kind {
        case .typingText:
            return WGStrings.WraithMode.Activity.typingText
        case .recordingVoice:
            return WGStrings.WraithMode.Activity.recordingVoice
        case .recordingInstantVideo:
            return WGStrings.WraithMode.Activity.recordingInstantVideo
        case .uploadingInstantVideo:
            return WGStrings.WraithMode.Activity.uploadingInstantVideo
        case .uploadingVideo:
            return WGStrings.WraithMode.Activity.uploadingVideo
        case .uploadingPhoto:
            return WGStrings.WraithMode.Activity.uploadingPhoto
        case .uploadingFile:
            return WGStrings.WraithMode.Activity.uploadingFile
        case .choosingSticker:
            return WGStrings.WraithMode.Activity.choosingSticker
        case .playingGame:
            return WGStrings.WraithMode.Activity.playingGame
        case .speakingInGroupCall:
            return WGStrings.WraithMode.Activity.speakingInGroupCall
        case .interactingWithEmoji:
            return WGStrings.WraithMode.Activity.interactingWithEmoji
        case .seeingEmojiInteraction:
            return WGStrings.WraithMode.Activity.seeingEmojiInteraction
        }
    }

    private static func registerActivitiesTab() {
        // Shown only while «Не отправлять «печатает»» is on: an empty tab has no link (no dead screen).
        WGMenuRegistry.register(
            tab: WGMenuTabDescriptor(
                id: .wraithActivities,
                parent: .category(.privacy),
                title: { WGStrings.WraithMode.Menu.activities },
                topView: WGMenuTopView(content: .emoji("✍️"), text: { WGStrings.WraithMode.Menu.activitiesInfo }),
                searchKeywords: { [WGStrings.WraithMode.Menu.keywordTyping] }
            ),
            linkIn: .privacyWraithMode,
            order: 200,
            subtitle: { WGStrings.WraithMode.Menu.activitiesInfo },
            icon: .bundle("Chat/Context Menu/Edit"),
            label: { context in
                let account = context.accountID
                var shown = 0
                for kind in WGWraithActivityKind.allCases where WGWraithSettings.shownActivity(kind).value(for: account) {
                    shown += 1
                }
                return WGStrings.WraithMode.Menu.activitiesShown(shown: "\(shown)", total: "\(WGWraithActivityKind.allCases.count)")
            }
        )
        WGMenuRegistry.register(section: WGMenuSectionDescriptor(
            id: .wraithActivitiesMain,
            screen: .tab(.wraithActivities),
            order: 200,
            header: { WGStrings.WraithMode.Menu.activitiesHeader },
            footer: { _ in WGStrings.WraithMode.Menu.activitiesFooter },
            isVisible: { context in
                return WGWraithSettings.hideTyping.value(for: context.accountID)
            }
        ))
        var order = 100
        for kind in WGWraithActivityKind.allCases {
            WGMenuRegistry.register(WGMenuRow(
                id: "wraithMode.activityShown.\(kind.rawValue)",
                section: .wraithActivitiesMain,
                order: order,
                title: { WGWraithMenu.activityTitle(kind) },
                kind: .toggle(.account(WGWraithSettings.shownActivity(kind)))
            ))
            order += 100
        }
    }

    // MARK: Exceptions

    /// PLAN §2.1: «Чаты / Папки / Типы» as a segment in the navbar of the skeleton's tab. Chats and
    /// folders are runtime rows of their sections (WGWraithExceptionRows); the types are settings.
    private static func registerExceptionsTab() {
        let tab = WGMenuTabID.privacyWraithExceptions
        WGMenuRegistry.register(segments: [
            WGMenuSegment(id: "chats", title: { WGStrings.WraithMode.Exceptions.chats }),
            WGMenuSegment(id: "folders", title: { WGStrings.WraithMode.Exceptions.folders }),
            WGMenuSegment(id: "types", title: { WGStrings.WraithMode.Exceptions.typesSegment })
        ], for: tab)

        WGMenuRegistry.register(section: WGMenuSectionDescriptor(
            id: WGWraithExceptionRows.chatsSection,
            screen: .tab(tab),
            order: 300,
            segment: "chats",
            footer: { _ in WGStrings.WraithMode.Exceptions.chatsInfo }
        ))
        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.exceptions.add",
            section: WGWraithExceptionRows.chatsSection,
            order: 100,
            title: { WGStrings.WraithMode.Exceptions.add },
            icon: .bundle("Chat/Context Menu/AddUser"),
            kind: .action({ context in
                WGWraithExceptionRows.presentPicker(context)
            }),
            searchKeywords: { [WGStrings.WraithMode.Exceptions.chatsInfo] },
            label: { context in
                let count = WGWraithSettings.exceptions.value(for: context.accountID).count
                return count > 0 ? "\(count)" : nil
            }
        ))
        WGMenuRegistry.register(dynamicRowsIn: WGWraithExceptionRows.chatsSection, { context in
            return WGWraithExceptionRows.chatRows(context)
        })

        WGMenuRegistry.register(section: WGMenuSectionDescriptor(
            id: WGWraithExceptionRows.foldersSection,
            screen: .tab(tab),
            order: 400,
            segment: "folders",
            header: { WGStrings.WraithMode.Exceptions.foldersInfo },
            footer: { _ in WGStrings.WraithMode.Exceptions.foldersFooter }
        ))
        WGMenuRegistry.register(dynamicRowsIn: WGWraithExceptionRows.foldersSection, { context in
            return WGWraithExceptionRows.folderRows(context)
        })

        WGMenuRegistry.register(section: WGMenuSectionDescriptor(
            id: .wraithExceptionTypes,
            screen: .tab(tab),
            order: 500,
            segment: "types",
            header: { WGStrings.WraithMode.Exceptions.typesHeader },
            footer: { _ in WGStrings.WraithMode.Exceptions.typesFooter }
        ))
        WGMenuRegistry.register(WGMenuRow(id: "wraithMode.exceptAllChannels", section: .wraithExceptionTypes, order: 100, title: { WGStrings.WraithMode.Exceptions.allChannels }, kind: .toggle(.account(WGWraithSettings.exceptAllChannels))))
        WGMenuRegistry.register(WGMenuRow(id: "wraithMode.exceptAllGroups", section: .wraithExceptionTypes, order: 200, title: { WGStrings.WraithMode.Exceptions.allGroups }, kind: .toggle(.account(WGWraithSettings.exceptAllGroups))))
    }

    // MARK: Send delay

    private static func registerSendDelayTab() {
        let main = WGMenuSectionID.main(of: .privacySendDelay)
        WGMenuRegistry.register(WGMenuRow(
            id: "sendDelay.isEnabled",
            section: main,
            order: 100,
            title: { WGStrings.WraithMode.SendDelay.toggle },
            subtitle: { WGStrings.WraithMode.SendDelay.toggleInfo },
            kind: .toggle(.account(WGWraithSettings.sendDelayEnabled))
        ))
        // One delay for text and media since 2026-10-27 (were two sliders).
        WGMenuRegistry.register(WGMenuRow(
            id: "sendDelay.seconds",
            section: main,
            order: 200,
            title: { WGStrings.WraithMode.SendDelay.delay },
            kind: .slider(.account(WGWraithSettings.sendDelaySeconds), range: WGSendDelaySeconds.range, step: 1.0, format: { value in
                return WGStrings.WraithMode.SendDelay.seconds(count: Int(value))
            }),
            isVisible: { context in
                return WGWraithSettings.sendDelayEnabled.value(for: context.accountID)
            }
        ))
    }

    // MARK: Traces

    private static func registerTraces() {
        WGMenuRegistry.register(WGMenuRow(id: "wraithMode.confirmCalls", section: .privacyTraces, order: 100, title: { WGStrings.WraithMode.Traces.confirmCalls }, subtitle: { WGStrings.WraithMode.Traces.confirmCallsInfo }, kind: .toggle(.global(WGWraithSettings.confirmCalls))))
        WGMenuRegistry.register(WGMenuRow(id: "wraithMode.warnBeforeStories", section: .privacyTraces, order: 200, title: { WGStrings.WraithMode.Traces.warnBeforeStories }, subtitle: { WGStrings.WraithMode.Traces.warnBeforeStoriesInfo }, kind: .toggle(.global(WGWraithSettings.warnBeforeStories))))
        WGMenuRegistry.register(WGMenuRow(id: "wraithMode.hidePhoneInSettings", section: .privacyTraces, order: 300, title: { WGStrings.WraithMode.Traces.hidePhone }, subtitle: { WGStrings.WraithMode.Traces.hidePhoneInfo }, kind: .toggle(.global(WGWraithSettings.hidePhoneInSettings))))
    }

    // MARK: Messages › Chats

    private static func registerChatsSection() {
        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.hideBlockedMessages",
            section: .messagesChats,
            order: 450,
            title: { WGStrings.WraithMode.Blocked.toggle },
            subtitle: { WGStrings.WraithMode.Blocked.toggleInfo },
            kind: .toggle(.account(WGWraithSettings.hideBlockedMessages))
        ))
    }
}
