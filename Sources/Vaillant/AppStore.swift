import Foundation
import SwiftUI
import Security

/// App 全局状态。
///
/// token 存进 Keychain 而不是 UserDefaults —— 登录凭据不该落在 plist 里。
/// 每次重新登录都会让官方 App 的登录态失效，所以 token 必须尽量复用。
@MainActor
final class AppStore: ObservableObject {
    enum Phase {
        case signedOut
        case loadingDevices
        case ready(Device)
    }

    @Published private(set) var phase: Phase = .signedOut
    @Published var errorMessage: String?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var device: Device?
    @Published private(set) var sending = false
    @Published private(set) var username: String?

    let monitor: MonitorClient
    private let api = APIClient()
    private var token: String?

    init() {
        monitor = MonitorClient(client: api)
        if let saved = Keychain.readToken() {
            token = saved
            username = Keychain.readUsername()
            // 恢复 token 后直接取设备；失败会退回 .signedOut
            Task { await loadDevices() }
        }
    }

    var isSignedIn: Bool {
        if case .signedOut = phase { return false }
        return true
    }

    // MARK: 登录

    func signIn(username: String, password: String) async {
        errorMessage = nil
        do {
            let token = try await api.login(username: username, password: password)
            self.token = token
            self.username = username

            Keychain.writeToken(token)
            Keychain.writeUsername(username)
            try? Keychain.writePassword(password)   // 供 token 过期时静默重登

            await loadDevices()
        } catch {
            errorMessage = (error as? ApiError)?.message ?? error.localizedDescription
            self.token = nil
            phase = .signedOut
        }
    }

    func signOut() {
        monitor.disconnect()
        Keychain.clear()
        token = nil
        username = nil
        device = nil
        devices = []
        phase = .signedOut
    }

    // MARK: 设备

    private func loadDevices() async {
        guard let token else { return }
        phase = .loadingDevices
        do {
            let list = try await api.devices(token: token)
            devices = list
            switch list.count {
            case 0:
                errorMessage = "账号下没有绑定设备"
                phase = .signedOut
            case 1:
                select(list[0])
            default:
                phase = .ready(list[0])   // 多设备时界面会显示列表
            }
        } catch let e as ApiError where e.isTokenExpired {
            await reauthenticate()
        } catch {
            errorMessage = (error as? ApiError)?.message ?? error.localizedDescription
            phase = .signedOut
        }
    }

    func select(_ device: Device) {
        self.device = device
        phase = .ready(device)
        if let token {
            monitor.connect(device: device, token: token)
        }
    }

    func reconnect() {
        guard let device, let token else { return }
        monitor.connect(device: device, token: token)
    }

    // MARK: 控制

    func send(_ attrs: [String: Any]) async {
        guard let device, let token, !sending else { return }
        sending = true
        defer { sending = false }

        do {
            try await api.control(device: device, token: token, attrs: attrs)
            // 云端确认后属性会通过 WebSocket 推回来，这里不手动改本地状态
        } catch let e as ApiError where e.isTokenExpired {
            await reauthenticate()
        } catch {
            errorMessage = (error as? ApiError)?.message ?? error.localizedDescription
        }
    }

    /// token 过期：用 Keychain 里的密码静默重登一次。
    private func reauthenticate() async {
        guard let password = Keychain.readPassword() else {
            monitor.invalidateToken()
            signOut()
            errorMessage = "登录已过期，请重新登录"
            return
        }
        do {
            let fresh = try await api.login(username: username ?? "", password: password)
            token = fresh
            Keychain.writeToken(fresh)
            if let device { monitor.connect(device: device, token: fresh) }
        } catch {
            signOut()
            errorMessage = "登录已过期，请重新登录"
        }
    }
}

// MARK: - Keychain

private enum Keychain {
    private static let service = "cn.vaillant.selfuse"
    private static let account = "default"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private static func write(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        var q = query
        q[kSecAttrAccount as String] = key
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func read(_ key: String) -> String? {
        var q = query
        q[kSecAttrAccount as String] = key
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeToken(_ v: String) { write(v, for: "token") }
    static func readToken() -> String? { read("token") }
    static func writeUsername(_ v: String) { write(v, for: "username") }
    static func readUsername() -> String? { read("username") }
    static func writePassword(_ v: String) throws { write(v, for: "password") }
    static func readPassword() -> String? { read("password") }

    static func clear() {
        for key in ["token", "username", "password"] {
            var q = query
            q[kSecAttrAccount as String] = key
            SecItemDelete(q as CFDictionary)
        }
    }
}
