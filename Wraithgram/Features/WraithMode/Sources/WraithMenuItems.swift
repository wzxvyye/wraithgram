import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import LocalizedPeerData
import AccountContext
import ContextUI
import AppBundle
import UndoUI
import WGCore
import WGHooks
import WGFeaturesShared

/// Toast at the bottom of the current screen.
func ggWraithToast(context: AccountContext, text: String) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    context.sharedContext.mainWindow?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: text, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in
        return false
    }), on: .root)
}

private func ggWraithMenuIcon(_ name: String) -> (PresentationTheme) -> UIImage? {
    return { theme in
        return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.contextMenu.primaryColor)
    }
}

/// «Прочитать» in the menus of messages, stories and media, and the wraith-mode items of a profile's
/// «…» menu («Исключения», «Подглядеть онлайн»).
enum WGWraithMenuItems {
    static func register() {
        WGMessageMenuHooks.items.register({ menuContext in
            return WGWraithMenuItems.messageItems(menuContext)
        }, order: 100)
        WGStoryHooks.menuItems.register({ menuContext in
            return WGWraithMenuItems.storyItems(menuContext)
        }, order: 100)
        WGGalleryHooks.menuItems.register({ menuContext in
            return WGWraithMenuItems.galleryItems(menuContext)
        }, order: 100)
        WGPeerInfoHooks.menuItems.register({ peerInfoContext in
            return WGWraithMenuItems.profileItems(peerInfoContext)
        }, order: 100)
    }

    // MARK: Message

    private static func messageItems(_ menuContext: WGMessageMenuContext) -> [WGMessageMenuEntry] {
        let context = menuContext.context
        let account = context.account.id.gg
        guard let message = menuContext.messages.max(by: { $0.id.id < $1.id.id }), message.flags.contains(.Incoming) else {
            return []
        }
        let peerId = message.id.peerId
        if peerId.namespace == Namespaces.Peer.SecretChat {
            if message.id.namespace != Namespaces.Message.SecretIncoming {
                return []
            }
        } else if message.id.namespace != Namespaces.Message.Cloud {
            return []
        }
        if !WGWraithPolicy.hides(.readReceipts, peerId: peerId, account: account) {
            return []
        }
        let threadId = menuContext.chatLocation.threadId
        let key = peerId.ggWraithReadKey(threadId: threadId)
        // Known to be read on the server already: nothing to send (no flag threaded through the menu's data).
        if peerId.namespace != Namespaces.Peer.SecretChat, let serverMax = WGWraithReadLedger.shared.serverReadMaxId(account: account, key: key), message.id.id <= serverMax {
            return []
        }
        let item = ContextMenuItem.action(ContextMenuActionItem(text: WGStrings.WraithMode.Action.read, icon: ggWraithMenuIcon("Chat/Context Menu/Read"), action: { _, f in
            f(.default)
            let _ = (WGWraithMenuItems.read(context: context, message: message, threadId: threadId)
            |> deliverOnMainQueue).start(next: { success in
                ggWraithToast(context: context, text: success ? WGStrings.WraithMode.Action.readDone : WGStrings.WraithMode.Action.failed)
            })
        }))
        return [WGMessageMenuEntry(position: .top, item: item)]
    }

    /// Reads the chat on the server up to the message (and the message's "listened" mark), then on the
    /// device. The push the local read schedules finds the server ahead and sends nothing.
    static func read(context: AccountContext, message: Message, threadId: Int64?) -> Signal<Bool, NoError> {
        let account = context.account
        let peerId = message.id.peerId
        var contents: Signal<Bool, NoError> = .single(true)
        if message.attributes.contains(where: { $0 is ConsumableContentMessageAttribute }) {
            contents = WGWraithExplicitReads.readContents(account: account, peerId: peerId, messageIds: [message.id.id])
        }
        return WGWraithExplicitReads.readHistory(account: account, peerId: peerId, threadId: threadId, maxId: message.id.id, maxTimestamp: message.timestamp)
        |> mapToSignal { success -> Signal<Bool, NoError> in
            if !success {
                return .single(false)
            }
            let local: Signal<Never, NoError>
            if threadId == nil {
                local = context.engine.messages.applyMaxReadIndexInteractively(index: message.index) |> ignoreValues
            } else {
                local = .complete()
            }
            return local
            |> mapToSignal { _ -> Signal<Bool, NoError> in
            }
            |> then(contents)
        }
    }

    // MARK: Story

    private static func storyItems(_ menuContext: WGStoryMenuContext) -> [ContextMenuItem] {
        let context = menuContext.context
        let account = context.account.id.gg
        let peerId = menuContext.peer.id
        if peerId == context.account.peerId || !WGWraithPolicy.hides(.storyViews, peerId: peerId, account: account) {
            return []
        }
        let storyId = menuContext.storyItem.id
        let isExpired = menuContext.storyItem.expirationTimestamp <= Int32(Date().timeIntervalSince1970)
        return [.action(ContextMenuActionItem(text: WGStrings.WraithMode.Action.readStory, icon: ggWraithMenuIcon("Chat/Context Menu/Eye"), action: { _, f in
            f(.default)
            let _ = (WGWraithExplicitReads.readStory(account: context.account, peerId: peerId, storyId: storyId, isExpired: isExpired)
            |> deliverOnMainQueue).start(next: { success in
                ggWraithToast(context: context, text: success ? WGStrings.WraithMode.Action.readStoryDone : WGStrings.WraithMode.Action.failed)
            })
        }))]
    }

    // MARK: Gallery (self-destructing media)

    private static func galleryItems(_ menuContext: WGGalleryMenuContext) -> [ContextMenuItem] {
        let context = menuContext.context
        let account = context.account.id.gg
        guard let message = menuContext.message, message.flags.contains(.Incoming), message.ggRawContainsSecretMedia else { // raw: kept media opens in the regular gallery (WGRestrictionHooks.secretMediaDisplay)
            return []
        }
        let peerId = message.id.peerId
        // Secret chats report "opened" through their own layer, which an explicit read here can
        // not reach; wraith mode keeps that report on the device (`.messageContents`).
        if peerId.namespace == Namespaces.Peer.SecretChat || message.id.namespace != Namespaces.Message.Cloud {
            return []
        }
        if !WGWraithPolicy.hides(.readReceipts, peerId: peerId, account: account) {
            return []
        }
        let messageId = message.id
        return [.action(ContextMenuActionItem(text: WGStrings.WraithMode.Action.readMedia, icon: ggWraithMenuIcon("Chat/Context Menu/Eye"), action: { _, f in
            f(.default)
            let _ = (WGWraithExplicitReads.readContents(account: context.account, peerId: peerId, messageIds: [messageId.id])
            |> deliverOnMainQueue).start(next: { success in
                ggWraithToast(context: context, text: success ? WGStrings.WraithMode.Action.readMediaDone : WGStrings.WraithMode.Action.failed)
            })
        }))]
    }

    // MARK: Profile

    private static func profileItems(_ peerInfoContext: WGPeerInfoContext) -> [ContextMenuItem] {
        if peerInfoContext.isSettings {
            return []
        }
        let context = peerInfoContext.context
        let account = context.account.id.gg
        let peer = peerInfoContext.peer
        if peer.id == context.account.peerId {
            return []
        }
        WGWraithPeerTraits.shared.learn(peer, account: account)
        var items: [ContextMenuItem] = []

        let explicit = WGWraithPolicy.explicitException(for: peer.id, account: account)
        let source = WGWraithPolicy.exceptionSource(for: peer.id, account: account)
        if WGWraithPolicy.isEnabled(account) || explicit != nil {
            let key = peer.id.ggWraithKey
            let navigationController = peerInfoContext.controller?.navigationController as? NavigationController
            switch source {
            case .explicit:
                items.append(.action(ContextMenuActionItem(text: WGStrings.WraithMode.Profile.editException, icon: ggWraithMenuIcon("Chat/Context Menu/Settings"), action: { _, f in
                    f(.default)
                    navigationController?.pushViewController(ggWraithExceptionController(context: context, peerId: peer.id))
                })))
                items.append(.action(ContextMenuActionItem(text: WGStrings.WraithMode.Profile.removeException, textColor: .destructive, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
                }, action: { _, f in
                    f(.default)
                    ggWraithUpdateExceptions(account: account) { exceptions in
                        exceptions.removeValue(forKey: key)
                    }
                    ggWraithToast(context: context, text: WGStrings.WraithMode.Profile.removed)
                })))
            case .type, .folder:
                // Excepted through its type or a folder: «Убрать» pulls this one chat back into wraith mode.
                items.append(.action(ContextMenuActionItem(text: WGStrings.WraithMode.Profile.removeException, icon: ggWraithMenuIcon("Chat/Context Menu/EyeLocked"), action: { _, f in
                    f(.default)
                    ggWraithUpdateExceptions(account: account) { exceptions in
                        exceptions[key] = .forcedWraith
                    }
                    ggWraithToast(context: context, text: WGStrings.WraithMode.Profile.forced)
                })))
            case .forced:
                items.append(.action(ContextMenuActionItem(text: WGStrings.WraithMode.Profile.restoreException, icon: ggWraithMenuIcon("Chat/Context Menu/Eye"), action: { _, f in
                    f(.default)
                    ggWraithUpdateExceptions(account: account) { exceptions in
                        exceptions.removeValue(forKey: key)
                    }
                    ggWraithToast(context: context, text: WGStrings.WraithMode.Profile.added)
                })))
            case .none:
                items.append(.action(ContextMenuActionItem(text: WGStrings.WraithMode.Profile.addException, icon: ggWraithMenuIcon("Chat/Context Menu/Eye"), action: { _, f in
                    f(.default)
                    ggWraithUpdateExceptions(account: account) { exceptions in
                        exceptions[key] = WGWraithException()
                    }
                    ggWraithToast(context: context, text: WGStrings.WraithMode.Profile.added)
                })))
            }
        }

        if case let .user(user) = peer, user.botInfo == nil, !user.flags.contains(.isSupport), !user.isDeleted {
            items.append(.action(ContextMenuActionItem(text: WGStrings.WraithMode.Profile.peek, icon: ggWraithMenuIcon("Chat/Context Menu/Eye"), action: { _, f in
                f(.default)
                let _ = (WGWraithPeekOnline.peek(context: context, peerId: user.id)
                |> deliverOnMainQueue).start(next: { result in
                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                    let name = EnginePeer.user(user).compactDisplayTitle
                    switch result {
                    case let .presence(presence):
                        if let presence = presence {
                            let (status, _) = stringAndActivityForUserPresence(strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, presence: presence, relativeTo: Int32(Date().timeIntervalSince1970))
                            ggWraithToast(context: context, text: WGStrings.WraithMode.Profile.peekResult(name: name, status: status))
                        } else {
                            ggWraithToast(context: context, text: WGStrings.WraithMode.Profile.peekHidden(name: name))
                        }
                    case .failed:
                        ggWraithToast(context: context, text: WGStrings.WraithMode.Action.failed)
                    }
                })
            })))
        }
        return items
    }
}
