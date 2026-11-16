import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListPeerItem
import LocalizedPeerData
import PresentationDataUtils
import AlertUI
import ChatListUI
import WGCore
import WGSettingsUI
import WGFeaturesShared

// «Исключения»: the rows of its «Чаты» and «Папки» segments, one chat's exception and its own
// status list. Each screen / provider follows one signal (presentation data + the account's
// settings + Wraithgram's language) and owns its subscriptions; nothing is kept after it closes.

private func ggWraithLanguageAndSettings(_ setting: Signal<[String: WGWraithException], NoError>) -> Signal<[String: WGWraithException], NoError> {
    return combineLatest(setting, WGLocalization.shared.languageCodeSignal)
    |> map { value, _ -> [String: WGWraithException] in
        return value
    }
}

/// One line describing what a chat's exception lets through.
func ggWraithExceptionSummary(_ exception: WGWraithException) -> String {
    if exception.kind == .include {
        return WGStrings.WraithMode.Exceptions.summaryForced
    }
    var parts: [String] = []
    if exception.readMessages {
        parts.append(WGStrings.WraithMode.Exceptions.summaryReads)
    }
    if exception.readStories {
        parts.append(WGStrings.WraithMode.Exceptions.summaryStories)
    }
    if exception.showOnline {
        parts.append(WGStrings.WraithMode.Exceptions.summaryOnline)
    }
    if exception.showTyping {
        parts.append(WGStrings.WraithMode.Exceptions.summaryTyping)
    } else if exception.ownShownActivities != nil {
        parts.append(WGStrings.WraithMode.Exceptions.summaryOwnStatuses)
    }
    if parts.isEmpty {
        return WGStrings.WraithMode.Exceptions.summaryNone
    }
    return parts.joined(separator: " • ")
}

/// Writes the exceptions of an account and recomputes "online" (the chat on screen may have just
/// become an exception: it goes online without leaving and re-entering).
func ggWraithUpdateExceptions(account: WGAccountID, _ f: (inout [String: WGWraithException]) -> Void) {
    var exceptions = WGWraithSettings.exceptions.value(for: account)
    f(&exceptions)
    WGWraithSettings.exceptions.set(exceptions, for: account)
    WGWraithPresence.shared.exceptionsDidChange()
}

// MARK: - «Исключения» › «Чаты» and «Папки» (runtime rows of the segmented tab)

/// The «Чаты» and «Папки» segments of «Исключения»: rows built at runtime from the account's
/// exceptions and the user's folders (`WGMenuRegistry.register(dynamicRowsIn:)`). Each provider runs
/// one signal per opening of the tab and nothing is kept after it closes.
enum WGWraithExceptionRows {
    static let chatsSection = WGMenuSectionID("wraithMode.exceptions.chats")
    static let foldersSection = WGMenuSectionID("wraithMode.exceptions.folders")

    /// «Выбрать чаты»: Telegram's chat picker over the chats excluded so far.
    static func presentPicker(_ menuContext: WGMenuContext) {
        let context = menuContext.context
        let account = context.account.id.gg
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        var selected = Set<EnginePeer.Id>()
        for (key, exception) in WGWraithSettings.exceptions.value(for: account) where exception.kind == .exclude {
            if let peerKey = WGPeerKey(string: key) {
                selected.insert(PeerId(ggKey: peerKey))
            }
        }
        let controller = context.sharedContext.makeContactMultiselectionController(ContactMultiselectionControllerParams(context: context, mode: .chatSelection(ContactMultiselectionControllerMode.ChatSelection(
            title: WGStrings.WraithMode.Exceptions.addTitle,
            searchPlaceholder: presentationData.strings.Common_Search,
            selectedChats: selected,
            additionalCategories: nil,
            chatListFilters: nil
        )), alwaysEnabled: true))
        let _ = (controller.result
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak controller] result in
            guard case let .result(peerIds, _) = result else {
                controller?.dismiss()
                return
            }
            var chosen = Set<EnginePeer.Id>()
            for peerId in peerIds {
                if case let .peer(value) = peerId {
                    chosen.insert(value)
                }
            }
            ggWraithUpdateExceptions(account: account) { exceptions in
                for (key, exception) in exceptions where exception.kind == .exclude {
                    if let peerKey = WGPeerKey(string: key), !chosen.contains(PeerId(ggKey: peerKey)) {
                        exceptions.removeValue(forKey: key)
                    }
                }
                for peerId in chosen where exceptions[peerId.ggWraithKey]?.kind != .exclude {
                    exceptions[peerId.ggWraithKey] = WGWraithException()
                }
            }
            controller?.dismiss()
        })
        menuContext.present(controller, arguments: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }

    /// Every chat with its own exception, sorted by name, with what it lets through; swipe to remove.
    static func chatRows(_ providerContext: WGMenuContext) -> Signal<[WGMenuRow], NoError> {
        let context = providerContext.context
        let account = context.account.id.gg
        let revealed = ValuePromise<EnginePeer.Id?>(nil, ignoreRepeated: true)

        let peers: Signal<[EnginePeer.Id: EnginePeer], NoError> = WGWraithSettings.exceptions.signal(for: account)
        |> map { exceptions -> [EnginePeer.Id] in
            return exceptions.keys.compactMap { key -> EnginePeer.Id? in
                return WGPeerKey(string: key).flatMap { PeerId(ggKey: $0) }
            }
        }
        |> distinctUntilChanged
        |> mapToSignal { peerIds -> Signal<[EnginePeer.Id: EnginePeer], NoError> in
            return context.engine.data.subscribe(EngineDataMap(peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)))
            |> map { map -> [EnginePeer.Id: EnginePeer] in
                var result: [EnginePeer.Id: EnginePeer] = [:]
                for (peerId, peer) in map {
                    if let peer = peer {
                        result[peerId] = peer
                    }
                }
                return result
            }
        }

        return combineLatest(WGWraithSettings.exceptions.signal(for: account), peers, revealed.get(), context.sharedContext.presentationData)
        |> map { exceptions, peers, revealedPeerId, presentationData -> [WGMenuRow] in
            var items: [(EnginePeer, WGWraithException)] = []
            for (key, exception) in exceptions {
                guard let peerKey = WGPeerKey(string: key), let peer = peers[PeerId(ggKey: peerKey)] else {
                    continue
                }
                items.append((peer, exception))
            }
            items.sort(by: { lhs, rhs in
                let lhsTitle = lhs.0.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                let rhsTitle = rhs.0.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
            })
            if items.isEmpty {
                return [WGMenuRow(id: "wraithMode.exceptions.chatsEmpty", section: WGWraithExceptionRows.chatsSection, order: 1000, title: { "" }, kind: .custom({ rowContext in
                    return ItemListTextItem(presentationData: rowContext.itemListPresentationData, text: .plain(WGStrings.WraithMode.Exceptions.empty), sectionId: rowContext.sectionId)
                }))]
            }
            var rows: [WGMenuRow] = []
            for (index, item) in items.enumerated() {
                let peer = item.0
                let exception = item.1
                let peerId = peer.id
                let isRevealed = revealedPeerId == peerId
                rows.append(WGMenuRow(id: "wraithMode.exceptions.peer.\(peerId.ggKey.stringValue)", section: WGWraithExceptionRows.chatsSection, order: 1000 + index, title: { "" }, kind: .custom({ rowContext in
                    let presentationData = rowContext.presentationData
                    let remove: (EnginePeer.Id) -> Void = { peerId in
                        ggWraithUpdateExceptions(account: account) { exceptions in
                            exceptions.removeValue(forKey: peerId.ggWraithKey)
                        }
                    }
                    return ItemListPeerItem(presentationData: rowContext.itemListPresentationData, systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, context: rowContext.context, peer: peer, presence: nil, text: .text(ggWraithExceptionSummary(exception), .secondary), label: .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: isRevealed), revealOptions: ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .destructive, title: WGStrings.WraithMode.Exceptions.remove, action: {
                        remove(peerId)
                    })]), switchValue: nil, enabled: true, selectable: true, sectionId: rowContext.sectionId, action: {
                        rowContext.push(ggWraithExceptionController(context: rowContext.context, peerId: peerId))
                    }, setPeerIdWithRevealedOptions: { peerId, fromPeerId in
                        if peerId != nil || fromPeerId != nil {
                            revealed.set(peerId)
                        }
                    }, removePeer: { peerId in
                        remove(peerId)
                    })
                })))
            }
            return rows
        }
    }

    /// The user's folders as switches. Membership is resolved live from the folder definitions (no
    /// stored snapshots of peer ids that go stale); a deleted folder simply stops matching.
    static func folderRows(_ providerContext: WGMenuContext) -> Signal<[WGMenuRow], NoError> {
        let context = providerContext.context
        let account = context.account.id.gg
        let toggle: (Int32, Bool) -> Void = { id, value in
            var folders = WGWraithSettings.exceptFolders.value(for: account)
            if value {
                folders.insert(id)
            } else {
                folders.remove(id)
            }
            WGWraithSettings.exceptFolders.set(folders, for: account)
            WGWraithPresence.shared.exceptionsDidChange()
        }
        // A folder hidden from the app (a locked secret folder) is not listed; an exception already
        // set on it stays in force.
        return combineLatest(WGWraithSettings.exceptFolders.signal(for: account), ggChatListFolders(context.engine.peers.updatedChatListFilters(), context: context))
        |> map { selected, filters -> [WGMenuRow] in
            var rows: [WGMenuRow] = []
            var order = 1000
            for filter in filters {
                guard case let .filter(id, title, _, _) = filter else {
                    continue
                }
                let text = title.text.isEmpty ? "#\(id)" : title.text
                let isOn = selected.contains(id)
                rows.append(WGMenuRow(id: "wraithMode.exceptFolders.\(id)", section: WGWraithExceptionRows.foldersSection, order: order, title: { text }, kind: .custom({ rowContext in
                    return ItemListSwitchItem(presentationData: rowContext.itemListPresentationData, systemStyle: .glass, title: text, value: isOn, sectionId: rowContext.sectionId, style: .blocks, updated: { value in
                        toggle(id, value)
                    })
                })))
                order += 1
            }
            if rows.isEmpty {
                rows.append(WGMenuRow(id: "wraithMode.exceptFolders.empty", section: WGWraithExceptionRows.foldersSection, order: 1000, title: { "" }, kind: .custom({ rowContext in
                    return ItemListTextItem(presentationData: rowContext.itemListPresentationData, text: .plain(WGStrings.WraithMode.Exceptions.foldersEmpty), sectionId: rowContext.sectionId)
                })))
            }
            return rows
        }
    }
}

// MARK: - One chat

private final class WGWraithExceptionArguments {
    let update: ((inout WGWraithException) -> Void) -> Void
    let openStatuses: () -> Void
    let chooseReadOnAction: () -> Void
    let remove: () -> Void

    init(update: @escaping ((inout WGWraithException) -> Void) -> Void, openStatuses: @escaping () -> Void, chooseReadOnAction: @escaping () -> Void, remove: @escaping () -> Void) {
        self.update = update
        self.openStatuses = openStatuses
        self.chooseReadOnAction = chooseReadOnAction
        self.remove = remove
    }
}

private enum WGWraithExceptionEntry: ItemListNodeEntry {
    case info(String)
    case readMessages(String, Bool)
    case readStories(String, Bool)
    case showOnline(String, String, Bool)
    case showTyping(String, Bool)
    case statuses(String, String)
    case readOnAction(String, String)
    case footer(String)
    case remove(String)

    var section: ItemListSectionId {
        switch self {
        case .info:
            return 0
        case .readMessages, .readStories, .showOnline, .showTyping, .statuses, .readOnAction, .footer:
            return 1
        case .remove:
            return 2
        }
    }

    var stableId: Int {
        switch self {
        case .info:
            return 0
        case .readMessages:
            return 1
        case .readStories:
            return 2
        case .showOnline:
            return 3
        case .showTyping:
            return 4
        case .statuses:
            return 5
        case .readOnAction:
            return 6
        case .footer:
            return 7
        case .remove:
            return 8
        }
    }

    static func <(lhs: WGWraithExceptionEntry, rhs: WGWraithExceptionEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WGWraithExceptionArguments
        switch self {
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .readMessages(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update { $0.readMessages = value }
            })
        case let .readStories(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update { $0.readStories = value }
            })
        case let .showOnline(title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, maximumNumberOfLines: 2, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update { $0.showOnline = value }
            })
        case let .showTyping(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.update { $0.showTyping = value }
            })
        case let .statuses(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.openStatuses()
            })
        case let .readOnAction(title, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.chooseReadOnAction()
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .remove(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.remove()
            })
        }
    }
}

/// The exception of one chat (from the list or from the profile's «…»).
func ggWraithExceptionController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let account = context.account.id.gg
    let key = peerId.ggWraithKey
    var pushImpl: ((ViewController) -> Void)?
    var presentImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?

    let arguments = WGWraithExceptionArguments(update: { f in
        ggWraithUpdateExceptions(account: account) { exceptions in
            var exception = exceptions[key] ?? WGWraithException()
            f(&exception)
            exceptions[key] = exception
        }
    }, openStatuses: {
        pushImpl?(ggWraithExceptionStatusesController(context: context, peerId: peerId))
    }, chooseReadOnAction: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let set: (Bool?) -> Void = { value in
            ggWraithUpdateExceptions(account: account) { exceptions in
                var exception = exceptions[key] ?? WGWraithException()
                exception.readOnAction = value
                exceptions[key] = exception
            }
        }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: WGStrings.WraithMode.Exception.readOnActionGlobal, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                set(nil)
            }),
            ActionSheetButtonItem(title: WGStrings.WraithMode.Exception.readOnActionOn, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                set(true)
            }),
            ActionSheetButtonItem(title: WGStrings.WraithMode.Exception.readOnActionOff, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                set(false)
            })
        ]), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        presentImpl?(actionSheet)
    }, remove: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentImpl?(textAlertController(context: context, title: WGStrings.WraithMode.Exception.removeConfirmTitle, text: WGStrings.WraithMode.Exception.removeConfirmText, actions: [
            TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: WGStrings.WraithMode.Exception.remove, action: {
                ggWraithUpdateExceptions(account: account) { exceptions in
                    exceptions.removeValue(forKey: key)
                }
                dismissImpl?()
            })
        ]))
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ggWraithLanguageAndSettings(WGWraithSettings.exceptions.signal(for: account)), context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)))
    |> map { presentationData, exceptions, peer -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let exception = exceptions[key] ?? WGWraithException()
        var entries: [WGWraithExceptionEntry] = []
        let title = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder) ?? WGStrings.WraithMode.Exception.title
        if exception.kind == .include {
            entries.append(.info(WGStrings.WraithMode.Exception.forcedInfo))
        } else {
            entries.append(.info(WGStrings.WraithMode.Exception.info))
            entries.append(.readMessages(WGStrings.WraithMode.Exception.readMessages, exception.readMessages))
            entries.append(.readStories(WGStrings.WraithMode.Exception.readStories, exception.readStories))
            entries.append(.showOnline(WGStrings.WraithMode.Exception.showOnline, WGStrings.WraithMode.Exception.showOnlineInfo, exception.showOnline))
            entries.append(.showTyping(WGStrings.WraithMode.Exception.showTyping, exception.showTyping))
            if !exception.showTyping {
                let label = exception.ownShownActivities == nil ? WGStrings.WraithMode.Exception.statusesGlobal : WGStrings.WraithMode.Exception.statusesOwn
                entries.append(.statuses(WGStrings.WraithMode.Exception.statuses, label))
            }
            if !exception.readMessages {
                let label: String
                switch exception.readOnAction {
                case .none:
                    label = WGStrings.WraithMode.Exception.readOnActionGlobal
                case .some(true):
                    label = WGStrings.WraithMode.Exception.readOnActionOn
                case .some(false):
                    label = WGStrings.WraithMode.Exception.readOnActionOff
                }
                entries.append(.readOnAction(WGStrings.WraithMode.Exception.readOnAction, label))
            }
            entries.append(.footer(WGStrings.WraithMode.Exception.footer))
        }
        if exceptions[key] != nil {
            entries.append(.remove(exception.kind == .include ? WGStrings.WraithMode.Exception.restore : WGStrings.WraithMode.Exception.remove))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root), with: nil)
    }
    dismissImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}

// MARK: - Own statuses of one chat

private final class WGWraithStatusesArguments {
    let setOwn: (Bool) -> Void
    let toggle: (WGWraithActivityKind, Bool) -> Void

    init(setOwn: @escaping (Bool) -> Void, toggle: @escaping (WGWraithActivityKind, Bool) -> Void) {
        self.setOwn = setOwn
        self.toggle = toggle
    }
}

private enum WGWraithStatusesEntry: ItemListNodeEntry {
    case own(String, String, Bool)
    case kind(Int, WGWraithActivityKind, String, Bool, Bool)
    case footer(String)

    var section: ItemListSectionId {
        switch self {
        case .own:
            return 0
        case .kind, .footer:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .own:
            return 0
        case let .kind(index, _, _, _, _):
            return 10 + index
        case .footer:
            return 1000
        }
    }

    static func <(lhs: WGWraithStatusesEntry, rhs: WGWraithStatusesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WGWraithStatusesArguments
        switch self {
        case let .own(title, text, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, text: text, value: value, maximumNumberOfLines: 3, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setOwn(value)
            })
        case let .kind(_, kind, title, value, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggle(kind, value)
            })
        case let .footer(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// Statuses a chat still sees while wraith mode hides «печатает» in it: the global list, or its own.
func ggWraithExceptionStatusesController(context: AccountContext, peerId: EnginePeer.Id) -> ViewController {
    let account = context.account.id.gg
    let key = peerId.ggWraithKey
    let update: ((inout WGWraithException) -> Void) -> Void = { f in
        ggWraithUpdateExceptions(account: account) { exceptions in
            var exception = exceptions[key] ?? WGWraithException()
            f(&exception)
            exceptions[key] = exception
        }
    }
    let globalList: () -> [WGWraithActivityKind] = {
        return WGWraithActivityKind.allCases.filter { WGWraithSettings.shownActivity($0).value(for: account) }
    }
    let arguments = WGWraithStatusesArguments(setOwn: { value in
        update { exception in
            // Turning the own list on starts from the global one, so nothing changes until edited.
            exception.ownShownActivities = value ? globalList() : nil
        }
    }, toggle: { kind, value in
        update { exception in
            var list = exception.ownShownActivities ?? globalList()
            list.removeAll(where: { $0 == kind })
            if value {
                list.append(kind)
            }
            exception.ownShownActivities = list
        }
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, ggWraithLanguageAndSettings(WGWraithSettings.exceptions.signal(for: account)), WGSettingsStore.shared.revision)
    |> map { presentationData, exceptions, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let exception = exceptions[key] ?? WGWraithException()
        let own = exception.ownShownActivities
        let shown = Set(own ?? globalList())
        var entries: [WGWraithStatusesEntry] = [.own(WGStrings.WraithMode.Exception.ownList, WGStrings.WraithMode.Exception.ownListInfo, own != nil)]
        for (index, kind) in WGWraithActivityKind.allCases.enumerated() {
            entries.append(.kind(index, kind, WGWraithMenu.activityTitle(kind), shown.contains(kind), own != nil))
        }
        entries.append(.footer(WGStrings.WraithMode.Menu.activitiesFooter))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(WGStrings.WraithMode.Menu.activities), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    return ItemListController(context: context, state: signal)
}
