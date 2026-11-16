import Foundation
import Postbox
import TelegramCore
import WGCore

/// The parts of wraith mode that can be switched per function and per chat.
public enum WGWraithFunction {
    case readReceipts
    case storyViews
    case online
    case typing
}

/// Why a chat is (or is not) an exception.
public enum WGWraithExceptionSource: Equatable {
    case none
    /// An explicit entry in the chat list of exceptions.
    case explicit(WGWraithException)
    /// «Все каналы» / «Все группы».
    case type
    /// A folder chosen as an exception.
    case folder
    /// The chat's type or folder is an exception, but the chat was pulled back into wraith mode.
    case forced
}

/// Wraith mode resolved for one account. Every answer is computed from the settings snapshot of
/// WGCore (no disk, no UserDefaults, no JSON) plus the in-memory peer kinds, so it may be asked on
/// any queue, inside Postbox transactions included.
public enum WGWraithPolicy {
    /// The master switch.
    public static func isEnabled(_ account: WGAccountID) -> Bool {
        return WGWraithSettings.isEnabled.value(for: account)
    }

    /// Whether the function is switched on for the account, regardless of chat.
    public static func isFunctionOn(_ function: WGWraithFunction, account: WGAccountID) -> Bool {
        if !WGWraithPolicy.isEnabled(account) {
            return false
        }
        switch function {
        case .readReceipts:
            return WGWraithSettings.hideReadReceipts.value(for: account)
        case .storyViews:
            return WGWraithSettings.hideStoryViews.value(for: account)
        case .online:
            return WGWraithSettings.hideOnline.value(for: account)
        case .typing:
            return WGWraithSettings.hideTyping.value(for: account)
        }
    }

    /// Explicit entry of a chat; a secret chat falls back to its user's entry.
    public static func explicitException(for peerId: PeerId, account: WGAccountID) -> WGWraithException? {
        let exceptions = WGWraithSettings.exceptions.value(for: account)
        if exceptions.isEmpty {
            return nil
        }
        if let exception = exceptions[peerId.ggWraithKey] {
            return exception
        }
        if peerId.namespace == Namespaces.Peer.SecretChat, case let .secretChat(user)? = WGWraithPeerTraits.shared.kind(of: peerId, account: account) {
            return exceptions[user.ggWraithKey]
        }
        return nil
    }

    /// Whether the chat's type or one of its folders is an exception.
    public static func isExceptedByTypeOrFolder(_ peerId: PeerId, account: WGAccountID) -> (byType: Bool, byFolder: Bool) {
        let allChannels = WGWraithSettings.exceptAllChannels.value(for: account)
        let allGroups = WGWraithSettings.exceptAllGroups.value(for: account)
        let folders = WGWraithSettings.exceptFolders.value(for: account)
        if !allChannels && !allGroups && folders.isEmpty {
            return (false, false)
        }
        let kind = WGWraithPeerTraits.shared.kind(of: peerId, account: account)
        var byType = false
        if let kind = kind {
            switch kind {
            case .channel:
                byType = allChannels
            case .basicGroup, .supergroup:
                byType = allGroups
            default:
                break
            }
        }
        let byFolder = WGWraithPeerTraits.shared.isInFolders(folders, peerId: peerId, kind: kind, account: account)
        return (byType, byFolder)
    }

    public static func exceptionSource(for peerId: PeerId, account: WGAccountID) -> WGWraithExceptionSource {
        let explicit = WGWraithPolicy.explicitException(for: peerId, account: account)
        if let explicit = explicit, explicit.kind == .exclude {
            return .explicit(explicit)
        }
        let (byType, byFolder) = WGWraithPolicy.isExceptedByTypeOrFolder(peerId, account: account)
        if !byType && !byFolder {
            return .none
        }
        if explicit?.kind == .include {
            return .forced
        }
        return byType ? .type : .folder
    }

    /// The exception that applies to the chat, nil when wraith mode applies in full.
    public static func effectiveException(for peerId: PeerId, account: WGAccountID) -> WGWraithException? {
        switch WGWraithPolicy.exceptionSource(for: peerId, account: account) {
        case .none, .forced:
            return nil
        case let .explicit(exception):
            return exception
        case .type, .folder:
            return .fullExclusion
        }
    }

    /// Whether wraith mode keeps `function` from the chat (`peerId == nil`: "any chat", i.e. the
    /// function itself).
    public static func hides(_ function: WGWraithFunction, peerId: PeerId?, account: WGAccountID) -> Bool {
        if !WGWraithPolicy.isFunctionOn(function, account: account) {
            return false
        }
        guard let peerId = peerId else {
            return true
        }
        guard let exception = WGWraithPolicy.effectiveException(for: peerId, account: account) else {
            return true
        }
        switch function {
        case .readReceipts:
            return !exception.readMessages
        case .storyViews:
            return !exception.readStories
        case .online:
            return !exception.showOnline
        case .typing:
            return !exception.showTyping
        }
    }

    /// Statuses still sent in the chat while «печатает» is hidden there.
    public static func shownActivities(for peerId: PeerId, account: WGAccountID) -> Set<WGWraithActivityKind> {
        if let exception = WGWraithPolicy.effectiveException(for: peerId, account: account), let own = exception.ownShownActivities {
            return Set(own)
        }
        var result = Set<WGWraithActivityKind>()
        for kind in WGWraithActivityKind.allCases where WGWraithSettings.shownActivity(kind).value(for: account) {
            result.insert(kind)
        }
        return result
    }

    /// «Читать при действиях» for the chat: the exception's own value, else the global switch. Only
    /// meaningful while wraith mode keeps read receipts there.
    public static func readsOnAction(in peerId: PeerId, account: WGAccountID) -> Bool {
        if let exception = WGWraithPolicy.effectiveException(for: peerId, account: account), let value = exception.readOnAction {
            return value
        }
        return WGWraithSettings.readOnAction.value(for: account)
    }
}

/// Send delay («Отложенная отправка»): the one decision every path uses — the stored sends and the
/// standalone senders (share extension, quick forward, Siri) ask the same `WGOutgoingHooks.sendDelay`.
public enum WGSendDelayPolicy {
    /// nil = send now. One delay for text and media. `peer` is the chat as stored (asked inside the
    /// transaction); only when Postbox does not know it does the peer kind cache decide «bot».
    public static func scheduleTime(account: WGAccountID, accountPeerId: PeerId, peerId: PeerId, peer: Peer?, serverTime: Double) -> Int32? {
        if !WGWraithSettings.sendDelayEnabled.value(for: account) {
            return nil
        }
        // «Избранное» is a notebook: a scheduled message there is a reminder, not a hidden send.
        if peerId == accountPeerId {
            return nil
        }
        // Secret chats can not schedule; bots refuse scheduled messages (SCHEDULE_BOT_NOT_ALLOWED).
        if peerId.namespace == Namespaces.Peer.SecretChat {
            return nil
        }
        if let peer {
            if let user = peer as? TelegramUser, user.botInfo != nil {
                return nil
            }
        } else if WGWraithPeerTraits.shared.isBot(peerId, account: account) {
            return nil
        }
        // The server sends at once anything scheduled less than ~10 s ahead: the range keeps a margin.
        let delay = WGSendDelaySeconds.clamped(WGWraithSettings.sendDelaySeconds.value(for: account))
        return Int32(serverTime + delay)
    }

    /// Whether a batch must go out as is: already scheduled, paid, or self-destructing. `attributes`
    /// — of every message of the batch.
    public static func mustSendImmediately(_ attributes: [[MessageAttribute]]) -> Bool {
        for messageAttributes in attributes {
            for attribute in messageAttributes {
                if attribute is OutgoingScheduleInfoMessageAttribute {
                    return true
                }
                if attribute is PaidStarsMessageAttribute {
                    return true
                }
                if let attribute = attribute as? AutoremoveTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout {
                    return true
                }
                if let attribute = attribute as? AutoclearTimeoutMessageAttribute, attribute.timeout == viewOnceTimeout {
                    return true
                }
            }
        }
        return false
    }
}
