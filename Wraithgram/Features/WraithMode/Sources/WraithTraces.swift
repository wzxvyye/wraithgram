import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import PresentationDataUtils
import AlertUI
import LocalizedPeerData
import WGCore
import WGHooks
import WGFeaturesShared

/// «Следы»: what gives you away besides wraith mode itself.
///
/// - «Скрыть свой номер в Настройках» — the number is decided at every display (Settings header and
///   row, own profile), so the switch applies at once, without a restart, and has one place.
/// - «Подтверждать звонки» — a question before an outgoing call (point `WGCallHooks.outgoingCall`,
///   request R1).
/// - «Предупреждать перед историей» — before stories open, and only when the view would really be
///   sent (wraith mode does not keep it); the stories wait and nothing is marked as seen until the
///   answer (point `WGStoryHooks.openGate`, request R2).
enum WGWraithTraces {
    static func register() {
        // Ahead of a replaced (fake) number: hiding wins.
        WGPeerInfoHooks.displayedPhoneNumber.register({ request in
            if request.isAccountPeer && WGWraithSettings.hidePhoneInSettings.value {
                return .hidden
            }
            return nil
        }, order: -100)

        WGCallHooks.outgoingCall.register({ request, proceed in
            if !WGWraithSettings.confirmCalls.value {
                return false
            }
            WGWraithTraces.confirmCall(request, proceed: proceed)
            return true
        }, order: 100)

        WGStoryHooks.openGate.register({ request, completion in
            if !WGWraithSettings.warnBeforeStories.value {
                return false
            }
            if let peerId = request.peerId, WGWraithPolicy.hides(.storyViews, peerId: peerId, account: request.context.account.id.gg) {
                // Wraith mode keeps the view: nothing to warn about.
                return false
            }
            WGWraithTraces.warnBeforeStories(request, completion: completion)
            return true
        }, order: 100)
    }

    private static func confirmCall(_ request: WGOutgoingCallRequest, proceed: @escaping () -> Void) {
        let context = request.context
        let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: request.peerId))
        |> deliverOnMainQueue).start(next: { peer in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let name = peer?.compactDisplayTitle ?? ""
            let text = request.isVideo ? WGStrings.WraithMode.Call.confirmVideo(name: name) : WGStrings.WraithMode.Call.confirmAudio(name: name)
            context.sharedContext.mainWindow?.present(textAlertController(context: context, title: nil, text: text, actions: [
                TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                TextAlertAction(type: .defaultAction, title: WGStrings.WraithMode.Call.call, action: {
                    proceed()
                })
            ]), on: .root)
        })
    }

    private static func warnBeforeStories(_ request: WGStoryOpenRequest, completion: @escaping (Bool) -> Void) {
        let context = request.context
        let alert = textAlertController(context: context, title: WGStrings.WraithMode.Stories.warnTitle, text: WGStrings.WraithMode.Stories.warnText, actions: [
            TextAlertAction(type: .genericAction, title: WGStrings.WraithMode.Stories.close, action: {
                completion(false)
            }),
            TextAlertAction(type: .defaultAction, title: WGStrings.WraithMode.Stories.watch, action: {
                completion(true)
            })
        ], dismissOnOutsideTap: false)
        if let controller = request.controller {
            controller.present(alert, in: .window(.root))
        } else {
            context.sharedContext.mainWindow?.present(alert, on: .root)
        }
    }
}
