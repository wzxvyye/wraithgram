import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import WGCore

// W1-3's own rows: «Настройки Wraithgram» (language, export / import with a diff / reset) and
// «О приложении» (version, links, license). Data operations are WGCore's (W1-1); this is the UI.

private let ggSourceCodeUrl = "https://github.com/TelegramMessenger/Telegram-iOS"
private let ggImportMaximumFileSize = 4 * 1024 * 1024

func ggRegisterBuiltInRows() {
    // Language: "" follows Telegram, otherwise one of the languages that have Wraithgram strings.
    WGMenuRegistry.register(WGMenuRow(
        id: "menu.language",
        section: .wraithgramSettingsLanguage,
        order: 100,
        title: { WGStrings.Menu.Settings.language },
        icon: .bundle("Chat/Context Menu/Translate"),
        kind: .choice(.global(WGLocalization.languageOverride), options: ggLanguageOptions())
    ))
    WGMenuRegistry.register(WGMenuRow(
        id: "menu.telegramLanguage",
        section: .wraithgramSettingsLanguage,
        order: 200,
        title: { WGStrings.Menu.Settings.telegramLanguage },
        icon: .bundle("Chat/Context Menu/Globe"),
        kind: .action({ menuContext in
            if let controller = WGSettingsUIEnvironment.shared.makeTelegramLanguageController?(menuContext.context) {
                menuContext.push(controller)
            }
        }),
        isVisible: { _ in
            return WGSettingsUIEnvironment.shared.makeTelegramLanguageController != nil
        }
    ))

    WGMenuRegistry.register(WGMenuRow(
        id: "menu.export",
        section: .wraithgramSettingsData,
        order: 100,
        title: { WGStrings.Menu.Settings.exportSettings },
        subtitle: { WGStrings.Menu.Settings.exportInfo },
        icon: .bundle("Chat/Context Menu/Share"),
        kind: .action({ menuContext in
            ggExportSettings(menuContext: menuContext)
        })
    ))
    WGMenuRegistry.register(WGMenuRow(
        id: "menu.import",
        section: .wraithgramSettingsData,
        order: 200,
        title: { WGStrings.Menu.Settings.importSettings },
        subtitle: { WGStrings.Menu.Settings.importInfo },
        icon: .bundle("Chat/Context Menu/Download"),
        kind: .action({ menuContext in
            ggPickSettingsFile(menuContext: menuContext)
        })
    ))
    WGMenuRegistry.register(WGMenuRow(
        id: "menu.reset",
        section: .wraithgramSettingsData,
        order: 300,
        title: { WGStrings.Menu.Settings.reset },
        kind: .action({ menuContext in
            ggConfirmResetAll(menuContext: menuContext)
        }),
        isDestructive: true
    ))

    WGMenuRegistry.register(WGMenuRow(
        id: "menu.about.version",
        section: .aboutInfo,
        order: 100,
        title: { WGStrings.Menu.About.version },
        icon: .wraith,
        kind: .action({ menuContext in
            UIPasteboard.general.string = ggAppVersionString()
            menuContext.presentToast(WGStrings.Menu.About.versionCopied)
        }),
        label: { _ in
            return ggAppVersionString()
        }
    ))
    for (index, link) in ggMenuLinks.enumerated() {
        let id = link.id
        let url = link.url
        let username = link.username
        WGMenuRegistry.register(WGMenuRow(
            id: "menu.about.\(id)",
            section: .aboutLinks,
            order: (index + 1) * 100,
            title: {
                return ggMenuLinkTitle(id)
            },
            icon: link.icon,
            kind: .action({ menuContext in
                menuContext.openTelegramLink(url)
            }),
            label: { _ in
                return username
            }
        ))
    }
    WGMenuRegistry.register(WGMenuRow(
        id: "menu.about.source",
        section: .aboutLicense,
        order: 100,
        title: { WGStrings.Menu.About.sourceCode },
        icon: .bundle("Chat/Context Menu/Browser"),
        kind: .action({ menuContext in
            menuContext.context.sharedContext.applicationBindings.openUrl(ggSourceCodeUrl)
        })
    ))
}

/// Wraithgram's languages (owner's decision: en, ru, uk, ar). Names are resolved at display time,
/// so registering the row at launch does not parse every string table.
private let ggMenuLanguageCodes = ["en", "ru", "uk", "ar"]

private func ggLanguageOptions() -> [WGMenuChoiceOption] {
    var options: [WGMenuChoiceOption] = [WGMenuChoiceOption(value: "", title: { WGStrings.Core.Language.followTelegram })]
    for code in ggMenuLanguageCodes {
        options.append(WGMenuChoiceOption(value: code, title: {
            return WGLocalization.shared.availableLanguages.first(where: { $0.code == code })?.nativeName ?? code
        }))
    }
    return options
}

// MARK: - Export

/// The export goes to a temporary file that is removed when the share sheet closes; the file is
/// written off the main thread.
private func ggExportSettings(menuContext: WGMenuContext) {
    let store = WGSettingsStore.shared
    let data = store.exportData(accounts: store.registeredAccounts)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let fileName = "wraithgram-settings-\(formatter.string(from: Date())).json"

    Queue.concurrentDefaultQueue().async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wraithgram-export", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        let written = (try? data.write(to: url, options: .atomic)) != nil
        Queue.mainQueue().async {
            guard written else {
                menuContext.presentToast(WGStrings.Menu.Settings.exportFailed)
                return
            }
            let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activityController.completionWithItemsHandler = { _, _, _, _ in
                Queue.concurrentDefaultQueue().async {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            menuContext.presentNative(activityController)
        }
    }
}

// MARK: - Import

/// `UIDocumentPickerViewController` holds its delegate weakly; this one keeps itself alive until a callback.
private final class WGDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let completion: (URL?) -> Void
    private var lifetime: WGDocumentPickerDelegate?

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
        super.init()
        self.lifetime = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.completion(urls.first)
        self.lifetime = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.completion(nil)
        self.lifetime = nil
    }
}

private func ggPickSettingsFile(menuContext: WGMenuContext) {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json, UTType.data], asCopy: true)
    picker.allowsMultipleSelection = false
    let delegate = WGDocumentPickerDelegate(completion: { url in
        guard let url else {
            return
        }
        // The picked copy lives in our tmp/Inbox: read it off the main thread and delete it right away.
        Queue.concurrentDefaultQueue().async {
            var data: Data?
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 && size <= ggImportMaximumFileSize {
                data = try? Data(contentsOf: url)
            }
            try? FileManager.default.removeItem(at: url)
            Queue.mainQueue().async {
                ggPreviewImport(data: data, menuContext: menuContext)
            }
        }
    })
    picker.delegate = delegate
    menuContext.presentNative(picker)
}

private func ggPreviewImport(data: Data?, menuContext: WGMenuContext) {
    guard let data else {
        menuContext.presentToast(WGSettingsImportError.invalidFormat.localizedText)
        return
    }
    let diff: WGSettingsImportDiff
    do {
        diff = try WGSettingsStore.shared.importPreview(data)
    } catch let error as WGSettingsImportError {
        menuContext.presentToast(error.localizedText)
        return
    } catch {
        menuContext.presentToast(WGSettingsImportError.invalidFormat.localizedText)
        return
    }
    if diff.isEmpty {
        menuContext.presentToast(WGStrings.Menu.Settings.importNoChanges)
        return
    }
    menuContext.push(ggMakeImportDiffController(diff: diff, menuContext: menuContext))
}

/// Compact JSON of a value → what a person reads.
private func ggImportValueText(_ json: String) -> String {
    switch json {
    case "true":
        return WGStrings.Menu.Settings.valueOn
    case "false":
        return WGStrings.Menu.Settings.valueOff
    case "null", "":
        return "—"
    default:
        break
    }
    var text = json
    if text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"") {
        text = String(text.dropFirst().dropLast())
    }
    if text.count > 48 {
        text = String(text.prefix(47)) + "…"
    }
    return text
}

private enum WGImportDiffEntry: ItemListNodeEntry {
    case changesHeader(String)
    case change(index: Int, title: String, detail: String, scope: String?)
    case notes(String)
    case apply(String)

    var section: ItemListSectionId {
        switch self {
        case .changesHeader, .change, .notes:
            return 0
        case .apply:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .changesHeader:
            return 0
        case let .change(index, _, _, _):
            return 1 + index
        case .notes:
            return Int.max - 1
        case .apply:
            return Int.max
        }
    }

    static func <(lhs: WGImportDiffEntry, rhs: WGImportDiffEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let apply = arguments as! () -> Void
        switch self {
        case let .changesHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text.uppercased(), sectionId: self.section)
        case let .change(_, title, detail, scope):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: scope ?? "", labelStyle: .text, additionalDetailLabel: detail, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .notes(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .apply(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .center, sectionId: self.section, style: .blocks, action: {
                apply()
            })
        }
    }
}

private func ggMakeImportDiffController(diff: WGSettingsImportDiff, menuContext: WGMenuContext) -> ViewController {
    let context = menuContext.context
    var dismissImpl: (() -> Void)?
    let apply: () -> Void = {
        WGSettingsStore.shared.applyImport(diff)
        dismissImpl?()
        menuContext.presentToast(WGStrings.Menu.Settings.importDone)
    }

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, WGLocalization.shared.languageCodeSignal)
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, () -> Void)) in
        let storage = WGMenuStorage.shared
        var entries: [WGImportDiffEntry] = [.changesHeader(WGStrings.Menu.Settings.importChanges(count: diff.changes.count))]
        for (index, change) in diff.changes.enumerated() {
            var title = change.key
            if let row = storage.row(forSettingKey: change.key) {
                title = row.title()
                // A child of «Скрыть в сообщениях» is «Время» on its own: name its group too.
                if let groupId = storage.groupByChildId[row.id], let group = storage.rowsById[groupId] {
                    title = group.title() + " › " + title
                }
            }
            let scope: String?
            switch change.scope {
            case .account:
                scope = WGStrings.Menu.Settings.scopeAccount
            case .global, .appGroup:
                scope = nil
            }
            entries.append(.change(index: index, title: title, detail: "\(ggImportValueText(change.oldValue)) → \(ggImportValueText(change.newValue))", scope: scope))
        }
        var notes: [String] = []
        if !diff.skippedKeys.isEmpty {
            notes.append(WGStrings.Menu.Settings.importSkipped(count: diff.skippedKeys.count))
        }
        if !diff.unknownKeys.isEmpty {
            notes.append(WGStrings.Menu.Settings.importUnknown(count: diff.unknownKeys.count))
        }
        if !diff.unmatchedAccounts.isEmpty {
            notes.append(WGStrings.Menu.Settings.importUnmatchedAccounts(count: diff.unmatchedAccounts.count))
        }
        if !notes.isEmpty {
            entries.append(.notes(notes.joined(separator: "\n")))
        }
        entries.append(.apply(WGStrings.Menu.Settings.importApply))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(WGStrings.Menu.Settings.importTitle), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, apply))
    }

    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        if let navigationController = controller?.navigationController as? NavigationController {
            let _ = navigationController.popViewController(animated: true)
        }
    }
    return controller
}

// MARK: - Reset

private func ggConfirmResetAll(menuContext: WGMenuContext) {
    let presentationData = menuContext.presentationData
    menuContext.present(textAlertController(context: menuContext.context, title: WGStrings.Menu.Settings.resetTitle, text: WGStrings.Menu.Settings.resetText, actions: [
        TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
        TextAlertAction(type: .destructiveAction, title: WGStrings.Menu.Settings.resetConfirm, action: {
            let store = WGSettingsStore.shared
            store.resetAll(accounts: store.registeredAccounts)
            menuContext.presentToast(WGStrings.Menu.Settings.resetDone)
        })
    ]))
}
