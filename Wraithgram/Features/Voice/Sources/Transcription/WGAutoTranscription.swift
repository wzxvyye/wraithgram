import Foundation
import UIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import AccountContext
import TelegramPresentationData
import UndoUI
import WGCore
import WGFeaturesShared
import WGVoiceTranscription

/// «Авторасшифровка своих»: after an own voice message (and, if switched on, an own round video)
/// without a caption has been delivered, it is transcribed and the text becomes its caption in the chosen
/// format, translated if asked.
///
/// Account-level, not tied to an open chat: `WGOutgoingHooks.didEnqueue` says in which chats something
/// was sent, the pending-message manager of that account reports deliveries there. One job at a time,
/// deduplicated by message id, with limits: up to 5 minutes of audio, not in Low Power Mode, not while the
/// device is hot. The engine follows the account's Premium at the moment of the job (owner's decision).
final class WGAutoTranscription {
    static let shared = WGAutoTranscription()

    static let maximumDuration: Double = 5.0 * 60.0
    private static let watchLifetime: Double = 15.0 * 60.0
    private static let maximumQueue = 20

    private struct ChatKey: Hashable {
        let account: AccountRecordId
        let peerId: PeerId
    }

    private final class Watcher {
        let disposable: Disposable
        var expiresAt: Double

        init(disposable: Disposable, expiresAt: Double) {
            self.disposable = disposable
            self.expiresAt = expiresAt
        }
    }

    private struct Job {
        let account: AccountRecordId
        let messageId: MessageId
    }

    private var watchers: [ChatKey: Watcher] = [:]
    private var queue: [Job] = []
    private var queued = Set<MessageId>()
    private var finished: [MessageId] = []
    private var finishedSet = Set<MessageId>()
    private var current: Job?
    private let jobDisposable = MetaDisposable()

    private init() {
    }

    static func register() {
        WGOutgoingHooks.didEnqueue.register({ context, ids in
            // Called after the messages are stored; only a cheap check here, the rest on the main queue.
            guard WGVoiceSettings.autoTranscribe.value, ids.contains(where: { $0 != nil }) else {
                return
            }
            let account = context.account.id
            let peerId = context.peerId
            Queue.mainQueue().async {
                WGAutoTranscription.shared.watch(account: account, peerId: peerId)
            }
        }, order: 500)
    }

    // MARK: Watching deliveries

    private func watch(account: AccountRecordId, peerId: PeerId) {
        guard let context = WGVoiceAccounts.shared.context(for: account) else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        self.dropExpiredWatchers(now: now)
        let key = ChatKey(account: account, peerId: peerId)
        if let watcher = self.watchers[key] {
            watcher.expiresAt = now + WGAutoTranscription.watchLifetime
            return
        }
        let disposable = (context.account.pendingMessageManager.deliveredMessageEvents(peerId: peerId)
        |> deliverOnMainQueue).start(next: { [weak self] events in
            guard let self else {
                return
            }
            for event in events where event.id.namespace == Namespaces.Message.Cloud {
                self.consider(account: account, messageId: event.id)
            }
        })
        self.watchers[key] = Watcher(disposable: disposable, expiresAt: now + WGAutoTranscription.watchLifetime)
    }

    private func dropExpiredWatchers(now: Double) {
        for (key, watcher) in self.watchers where watcher.expiresAt < now {
            watcher.disposable.dispose()
            self.watchers.removeValue(forKey: key)
        }
    }

    // MARK: Queue

    private func consider(account: AccountRecordId, messageId: MessageId) {
        guard WGVoiceSettings.autoTranscribe.value else {
            return
        }
        if self.queued.contains(messageId) || self.finishedSet.contains(messageId) || self.current?.messageId == messageId {
            return
        }
        if self.queue.count >= WGAutoTranscription.maximumQueue {
            return
        }
        self.queued.insert(messageId)
        self.queue.append(Job(account: account, messageId: messageId))
        self.runNext()
    }

    private func markFinished(_ messageId: MessageId) {
        if self.finishedSet.insert(messageId).inserted {
            self.finished.append(messageId)
            if self.finished.count > 500 {
                let removed = self.finished.removeFirst()
                self.finishedSet.remove(removed)
            }
        }
    }

    private func runNext() {
        if self.current != nil || self.queue.isEmpty {
            return
        }
        let job = self.queue.removeFirst()
        self.queued.remove(job.messageId)
        guard let context = WGVoiceAccounts.shared.context(for: job.account) else {
            self.markFinished(job.messageId)
            self.runNext()
            return
        }
        self.current = job
        self.jobDisposable.set((WGAutoTranscription.process(context: context, messageId: job.messageId)
        |> deliverOnMainQueue).start(next: { [weak self] outcome in
            if case .translationFailed = outcome {
                WGAutoTranscription.presentTranslationFailure(context: context)
            }
            self?.jobFinished(job)
        }, completed: { [weak self] in
            self?.jobFinished(job)
        }))
    }

    private func jobFinished(_ job: Job) {
        guard self.current?.messageId == job.messageId else {
            return
        }
        self.current = nil
        self.markFinished(job.messageId)
        self.runNext()
    }

    // MARK: One message

    private enum Outcome {
        case done
        case skipped
        case translationFailed
    }

    private static func eligibleFile(_ message: Message, accountPeerId: PeerId) -> TelegramMediaFile? {
        if message.flags.contains(.Incoming) || message.author?.id != accountPeerId {
            return nil
        }
        if !message.text.isEmpty {
            return nil
        }
        guard let file = WGVoiceTranscription.transcribableFile(in: message) else {
            return nil
        }
        if file.isInstantVideo && !WGVoiceSettings.autoTranscribeRoundVideos.value {
            return nil
        }
        var duration: Double = 0.0
        for attribute in file.attributes {
            switch attribute {
            case let .Audio(_, value, _, _, _):
                duration = Double(value)
            case let .Video(value, _, _, _, _, _):
                duration = value
            default:
                break
            }
        }
        if duration <= 0.0 || duration > WGAutoTranscription.maximumDuration {
            return nil
        }
        return file
    }

    private static func deviceAllowsWork() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return false
        default:
            return true
        }
    }

    private static func process(context: AccountContext, messageId: MessageId) -> Signal<Outcome, NoError> {
        let accountPeerId = context.account.peerId
        return context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> mapToSignal { message -> Signal<Outcome, NoError> in
            guard let message = message?._asMessage(), let _ = WGAutoTranscription.eligibleFile(message, accountPeerId: accountPeerId), WGAutoTranscription.deviceAllowsWork() else {
                return .single(.skipped)
            }
            return WGAutoTranscription.transcribedText(context: context, message: message)
            |> mapToSignal { text -> Signal<Outcome, NoError> in
                guard let text, !text.isEmpty else {
                    return .single(.skipped)
                }
                return WGAutoTranscription.translatedIfNeeded(context: context, text: text)
                |> mapToSignal { finalText, translationFailed -> Signal<Outcome, NoError> in
                    return WGAutoTranscription.applyCaption(context: context, messageId: messageId, text: finalText)
                    |> map { applied -> Outcome in
                        if !applied {
                            return .skipped
                        }
                        return translationFailed ? .translationFailed : .done
                    }
                }
            }
        }
    }

    /// The engine follows Premium now: Telegram's server transcription, or Apple Speech (which also keeps
    /// the words for the bubbles). Both store the text in the message as an ordinary transcription.
    private static func transcribedText(context: AccountContext, message: Message) -> Signal<String?, NoError> {
        let messageId = message.id
        let readBack: Signal<String?, NoError> = context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> map { message -> String? in
            guard let message else {
                return nil
            }
            for attribute in message.attributes {
                if let attribute = attribute as? AudioTranscriptionMessageAttribute, !attribute.text.isEmpty, !attribute.isPending {
                    return attribute.text
                }
            }
            return nil
        }
        if WGVoiceTranscription.usesAppleSpeech(context: context) {
            return WGVoiceTranscription.transcribeWithAppleSpeech(context: context, message: message)
            |> mapToSignal { outcome -> Signal<String?, NoError> in
                switch outcome {
                case .stored:
                    return readBack
                case .failed, .notAuthorized:
                    return .single(nil)
                }
            }
        } else {
            return context.engine.messages.transcribeAudio(messageId: messageId)
            |> mapToSignal { result -> Signal<String?, NoError> in
                switch result {
                case .success:
                    return readBack
                case .error:
                    return .single(nil)
                }
            }
        }
    }

    /// Translated text and whether a translation was asked for and failed (then the original is used,
    /// and the user is told — never silently).
    private static func translatedIfNeeded(context: AccountContext, text: String) -> Signal<(String, Bool), NoError> {
        guard WGVoiceSettings.autoTranscribeTranslate.value else {
            return .single((text, false))
        }
        var language = WGVoiceSettings.autoTranscribeLanguage.value
        if language.isEmpty {
            language = context.sharedContext.currentPresentationData.with({ $0 }).strings.baseLanguageCode
        }
        return context.engine.messages.translate(text: text, toLang: language)
        |> map { result -> (String, Bool) in
            if let result, !result.0.isEmpty {
                return (result.0, false)
            }
            return (text, true)
        }
        |> `catch` { _ -> Signal<(String, Bool), NoError> in
            return .single((text, true))
        }
    }

    private static func entities(for text: String) -> [MessageTextEntity] {
        let length = (text as NSString).length
        guard length > 0, let format = WGTranscriptionFormat(rawValue: WGVoiceSettings.autoTranscribeFormat.value) else {
            return []
        }
        let type: MessageTextEntityType
        switch format {
        case .plain:
            return []
        case .quote:
            type = .BlockQuote(isCollapsed: false)
        case .bold:
            type = .Bold
        case .italic:
            type = .Italic
        case .underline:
            type = .Underline
        case .strikethrough:
            type = .Strikethrough
        case .monospace:
            type = .Code
        case .spoiler:
            type = .Spoiler
        }
        return [MessageTextEntity(range: 0 ..< length, type: type)]
    }

    /// Edits the caption (only if the message still has none). The caption mark is written first, so the
    /// edit that comes back from the server already finds it and stores its «edited» mark hidden
    /// (WGVoiceMessageAttributes); a failed edit removes the mark again.
    private static func applyCaption(context: AccountContext, messageId: MessageId, text: String) -> Signal<Bool, NoError> {
        let entities = WGAutoTranscription.entities(for: text)
        let engine = context.engine
        return engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> mapToSignal { message -> Signal<Bool, NoError> in
            guard let message, message.text.isEmpty else {
                return .single(false)
            }
            let edit: Signal<Bool, NoError> = engine.messages.requestEditMessage(messageId: messageId, text: text, media: .keep, entities: entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: entities), richText: nil, inlineStickers: [:])
            |> map { result -> Bool? in
                if case let .done(value) = result {
                    return value
                }
                return nil
            }
            |> filter { $0 != nil }
            |> map { $0 ?? false }
            |> take(1)
            |> `catch` { _ -> Signal<Bool, NoError> in
                return .single(false)
            }
            return WGAutoTranscription.setCaptionMark(engine: engine, messageId: messageId, text: text)
            |> mapToSignal { _ -> Signal<Bool, NoError> in
                return edit
            }
            |> mapToSignal { applied -> Signal<Bool, NoError> in
                if applied {
                    return .single(true)
                }
                return WGAutoTranscription.setCaptionMark(engine: engine, messageId: messageId, text: nil)
                |> map { _ -> Bool in
                    return false
                }
            }
        }
    }

    /// Writes (text) or removes (nil) the caption mark; emits once when stored.
    private static func setCaptionMark(engine: TelegramEngine, messageId: MessageId, text: String?) -> Signal<Void, NoError> {
        let update = engine.messages.updateLocallyDerivedData(messageId: messageId, update: { data in
            var data = data
            if let text, let entry = CodableEntry(WGVoiceAutoCaptionMark(text: text)) {
                data[WGVoiceDerivedDataKeys.autoCaption] = entry
            } else {
                data.removeValue(forKey: WGVoiceDerivedDataKeys.autoCaption)
            }
            return data
        })
        return Signal { subscriber in
            return update.start(completed: {
                subscriber.putNext(Void())
                subscriber.putCompletion()
            })
        }
    }

    private static func presentTranslationFailure(context: AccountContext) {
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let controller = UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: WGStrings.Voice.AutoTranscribe.translationFailed, timeout: nil, customUndoText: nil), elevatedLayout: false, position: .top, animateInAsReplacement: false, action: { _ in return false })
        context.sharedContext.mainWindow?.presentInGlobalOverlay(controller)
    }
}

/// The caption formats of the auto-transcription.
enum WGTranscriptionFormat: String, CaseIterable {
    case plain
    case quote
    case bold
    case italic
    case underline
    case strikethrough
    case monospace
    case spoiler

    var title: String {
        switch self {
        case .plain:
            return WGStrings.Voice.Format.plain
        case .quote:
            return WGStrings.Voice.Format.quote
        case .bold:
            return WGStrings.Voice.Format.bold
        case .italic:
            return WGStrings.Voice.Format.italic
        case .underline:
            return WGStrings.Voice.Format.underline
        case .strikethrough:
            return WGStrings.Voice.Format.strikethrough
        case .monospace:
            return WGStrings.Voice.Format.monospace
        case .spoiler:
            return WGStrings.Voice.Format.spoiler
        }
    }
}
