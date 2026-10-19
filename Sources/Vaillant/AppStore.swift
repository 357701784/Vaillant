import Foundation
import SwiftUI
import Security
import Combine

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
    /// 把 monitor 的变化转发出去。
    /// MonitorClient 是独立的 ObservableObject，界面通过 @EnvironmentObject(store)
    /// 观察 AppStore —— 两层之外的变化不会触发重绘，必须手动转发。
    private var monitorObserver: AnyCancellable?

    init() {
        monitor = MonitorClient(client: api)

        monitorObserver = monitor.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }

        if let saved = Keychain.readToken() {
            token = saved
            username = Keychain.readUsername()
            // 恢复 token 后直接取设备；失败会退回 .signedOut
            Task { await loadDevices() }
        }
    }

    deinit {
        monitorObserver?.cancel()
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

    func send(_ payload: [String: Any]) async {
        guard let device, let token, !sending else { return }
        sending = true
        defer { sending = false }

        // 记录下发前后的关键值：控制指令常被云端静默忽略，
        // 没有日志就无从判断是键名不对还是设备拒绝。
        let keys = payload.keys.joined(separator: ",")
        monitor.appendLog("下发指令 \(keys)")

        do {
            let response = try await api.control(device: device, token: token, attrs: payload)
            let code = response["code"].map { "\($0)" } ?? "-"
            let msg = response["msg"].map { "\($0)" } ?? ""
            monitor.appendLog("云端响应 code=\(code) \(msg)")
            if let number = response["code"] as? Int, number != 200 {
                errorMessage = msg.isEmpty ? "控制指令被拒绝（code \(number)）" : msg
            }
            // 云端确认后属性会通过轮询推回来，这里不手动改本地状态
        } catch let e as ApiError where e.isTokenExpired {
            await reauthenticate()
        } catch {
            let message = (error as? ApiError)?.message ?? error.localizedDescription
            monitor.appendLog("❌ 指令失败 \(message)")
            errorMessage = message
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
