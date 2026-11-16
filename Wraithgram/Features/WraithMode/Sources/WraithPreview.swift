import Foundation
import UIKit
import WGCore
import WGSettingsUI
import WGFeaturesShared

/// The «Приватность» preview: a mini chat as the other person sees you. The header is your own
/// avatar with «в сети» / «был(а) недавно»; while wraith mode keeps your read receipt their message
/// stays at one check (no mark by the time — the owner had it removed). It follows the switches of
/// the account the menu is open for.
enum WGWraithPreview {
    static func register() {
        WGMenuRegistry.register(WGMenuRow(
            id: "wraithMode.preview",
            section: .privacyPreview,
            order: 100,
            title: { "" },
            kind: .preview(.miniChat(WGMiniChatConfiguration(scope: "wraithMode", height: 196.0, content: { context in
                let account = context.accountID
                let hidesOnline = WGWraithPolicy.isFunctionOn(.online, account: account)
                let hidesReads = WGWraithPolicy.isFunctionOn(.readReceipts, account: account)
                let status: String
                let statusIsAccent: Bool
                if hidesOnline {
                    status = WGStrings.WraithMode.Preview.recently
                    statusIsAccent = false
                } else {
                    status = WGStrings.WraithMode.Preview.online
                    statusIsAccent = true
                }
                var question = WGPreviewMessage(id: 1, isOutgoing: true, text: WGStrings.WraithMode.Preview.question, ageSeconds: 240)
                if hidesReads {
                    question.isUnread = true
                }
                var messages = [question]
                if !hidesReads {
                    messages.append(WGPreviewMessage(id: 2, isOutgoing: false, text: WGStrings.WraithMode.Preview.answer, ageSeconds: 120))
                }
                return WGMiniChatContent(header: WGMiniChatHeader(peer: .account, status: status, statusIsAccent: statusIsAccent), messages: messages)
            })))
        ))
    }
}
