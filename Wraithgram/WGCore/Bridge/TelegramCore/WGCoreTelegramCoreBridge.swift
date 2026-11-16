// Compiled into TelegramCore (filegroup //Wraithgram/WGCore:TelegramCoreBridgeSources): the parts of
// WGCore that need TelegramCore / Postbox types. WGCore itself can not see them, since
// TelegramCore depends on WGCore.

import Foundation
import Postbox
import SwiftSignalKit
import WGCore

// MARK: - Canonical keys

public extension AccountRecordId {
    /// The account's Wraithgram key (same raw value).
    var gg: WGAccountID {
        return WGAccountID(rawValue: self.int64)
    }

    init(gg: WGAccountID) {
        self.init(rawValue: gg.rawValue)
    }
}

public extension PeerId {
    /// The whole PeerId, namespace included. Use this, never `toInt64()`, as a stored key.
    var ggKey: WGPeerKey {
        guard let key = WGPeerKey(namespace: self.namespace._internalGetInt32Value(), id: self.id._internalGetInt64Value()) else {
            preconditionFailure("PeerId namespace out of range")
        }
        return key
    }

    init(ggKey: WGPeerKey) {
        self.init(namespace: PeerId.Namespace._internalFromInt32Value(ggKey.namespace), id: PeerId.Id._internalFromInt64Value(ggKey.id))
    }
}

public extension MessageId {
    /// Peer, message namespace and id.
    var ggKey: WGMessageKey {
        return WGMessageKey(peer: self.peerId.ggKey, namespace: self.namespace, id: self.id)
    }

    init(ggKey: WGMessageKey) {
        self.init(peerId: PeerId(ggKey: ggKey.peer), namespace: ggKey.namespace, id: ggKey.id)
    }
}

// MARK: - Account lifecycle

/// WRAITH hook target: call from `Account.init`, before the account's network starts. Loads the
/// account's Wraithgram settings (`<basePath>/wraithgram/settings.json`) and runs its migrations.
public func ggCoreAccountDidLoad(id: AccountRecordId, basePath: String) {
    #if DEBUG
    ggCoreBridgeSelfCheckOnce()
    #endif
    WGSettingsStore.shared.registerAccount(id.gg, basePath: basePath)
}

/// WRAITH hook target: call right after `ggCoreAccountDidLoad`, once the account's own peer is known
/// (`Account.init`, the notification service's standalone state manager). Runs the account's
/// migrations of old data keyed by that peer (`WGMigrations.registerAccountPeer`, app only).
public func ggCoreAccountPeerDidLoad(id: AccountRecordId, peerId: PeerId) {
    WGMigrations.accountPeerDidLoad(id.gg, peer: peerId.ggKey)
}

/// WRAITH hook target: call when the account is logged out / removed.
public func ggCoreAccountWillBeRemoved(id: AccountRecordId) {
    WGSettingsStore.shared.unregisterAccount(id.gg)
}

// MARK: - Proxy for WGNetwork

/// The SOCKS5 proxy for Wraithgram's own requests, or nil (MTProxy and WEB proxies can not carry
/// a `URLSession` request).
public func ggProxy(from server: ProxyServerSettings?) -> WGProxy? {
    guard let server = server else {
        return nil
    }
    switch server.connection {
    case let .socks5(username, password):
        return .socks5(host: server.host, port: Int(server.port), username: username, password: password)
    case .mtp, .web:
        return nil
    }
}

private struct WGProxyBridgeState {
    let proxy: WGProxy?
    let isDirectConnectionAllowed: Bool
}

private let ggProxyBridgeState = Atomic<WGProxyBridgeState>(value: WGProxyBridgeState(proxy: nil, isDirectConnectionAllowed: true))
private let ggProxyBridgeAttached = Atomic<Bool>(value: false)
private let ggProxyBridgeDisposable = MetaDisposable()

/// WRAITH hook target: call once after the `AccountManager` is created (app and extensions).
/// Keeps `WGNetwork.shared` on the user's active proxy: SOCKS5 is used, any other active proxy
/// blocks direct requests. Later calls do nothing.
public func ggCoreAttachProxySettings(accountManager: AccountManager<TelegramAccountManagerTypes>) {
    if ggProxyBridgeAttached.swap(true) {
        return
    }
    WGNetwork.shared.proxyProvider = {
        return ggProxyBridgeState.with { state in
            return state.proxy
        }
    }
    WGNetwork.shared.isDirectConnectionAllowedProvider = {
        return ggProxyBridgeState.with { state in
            return state.isDirectConnectionAllowed
        }
    }
    ggProxyBridgeDisposable.set((accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
    |> map { sharedData -> ProxyServerSettings? in
        return sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self)?.effectiveActiveServer
    }
    |> distinctUntilChanged).start(next: { server in
        let state = WGProxyBridgeState(proxy: ggProxy(from: server), isDirectConnectionAllowed: server == nil)
        let _ = ggProxyBridgeState.swap(state)
    }))
}

// MARK: - Debug self-check

#if DEBUG
private let ggCoreBridgeSelfChecked = Atomic<Bool>(value: false)

/// WGLegacyKeys mirrors the bit layout of `PeerId(Int64)`; make sure it still does.
private func ggCoreBridgeSelfCheckOnce() {
    if ggCoreBridgeSelfChecked.swap(true) {
        return
    }
    let samples: [PeerId] = [
        PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(777000)),
        PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(123456789)),
        PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(1234567890123)),
        PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(-5)),
        PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(5000000000))
    ]
    for peerId in samples {
        assert(WGLegacyKeys.peerKey(fromLegacyInt64: peerId.toInt64()) == peerId.ggKey, "WGLegacyKeys diverged from PeerId(Int64)")
        assert(WGLegacyKeys.legacyInt64(of: peerId.ggKey) == peerId.toInt64(), "WGLegacyKeys diverged from PeerId.toInt64()")
        assert(PeerId(ggKey: peerId.ggKey) == peerId, "PeerId(ggKey:) does not round-trip")
    }
}
#endif
