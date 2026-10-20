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

    /// 是否有指令正在下发。用于禁用开关这类会引发状态跳变的操作。
    @Published private(set) var sending = false
    /// 等待发送的指令。连续按压时只保留最新值。
    private var pendingPayload: [String: Any] = [:]
    /// 是否有指令正在飞行中
    private var sendInFlight = false

    /// 按下 +/− 时调用。
    ///
    /// 基准值取自 monitor.attrs —— 它在乐观更新时是【同步】写入的，
    /// 所以连续快速按压时每次都能读到上一次的结果并逐次累加。
    /// 之前用 View 层的 @State 做基准，两次按压之间若 SwiftUI 还没重渲染，
    /// 第二次会读到旧值，导致按 7 次只生效 6 次。
    func stepTemperature(
        key: String,
        readKeys: [String],
        delta: Double,
        min lower: Double,
        max upper: Double
    ) {
        let current = ReadAttr.firstNumber(readKeys, in: monitor.attrs) ?? lower
        // 保留一位小数：((current + delta) * 10).rounded() / 10
        // 括号位置很关键 —— 写成 (current + delta * 10) 等于 current/10 + delta，
        // 会把 43 变成 5.3，远低于下限 35，云端直接返回 500。
        let next = ((current + delta) * 10).rounded() / 10
        // 夹在设备允许的范围内，超范围同样会被云端拒绝
        let clamped = min(upper, max(lower, next))

        // 同步写入本地状态：界面立刻更新，且下一次按压能读到它
        monitor.applyLocal([key: clamped])
        Task { await send([key: clamped]) }
    }

    /// 下发控制指令。
    ///
    /// 连续快速按压时不能丢弃后发的指令 —— 用户按 5 次 + 应该得到 +5，
    /// 而不是 +1。所以这里合并待发指令：飞行期间的新指令覆盖旧的，
    /// 当前这条发完后立刻把合并后的值发出去。
    func send(_ payload: [String: Any]) async {
        guard let device, let token else { return }

        // 立即乐观更新：界面马上反映操作，也让后续按压基于新值计算。
        monitor.applyLocal(payload)

        // 合并待发指令（后来的覆盖先前的）
        pendingPayload.merge(payload) { _, new in new }

        // 已有指令在飞：等它完成后由下面的循环统一处理
        guard !sendInFlight else { return }
        sendInFlight = true
        sending = true
        defer {
            sendInFlight = false
            sending = false
        }

        while !pendingPayload.isEmpty {
            let batch = pendingPayload
            pendingPayload = [:]

            let keys = batch.keys.joined(separator: ",")
            let values = batch.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            monitor.appendLog("下发指令 \(keys) → \(values)")

            do {
                let response = try await api.control(device: device, token: token, attrs: batch)
                let code = response["code"].map { "\($0)" } ?? "-"
                let msg = response["msg"].map { "\($0)" } ?? ""
                monitor.appendLog("云端响应 code=\(code) \(msg)")
                if let number = response["code"] as? Int, number != 200 {
                    errorMessage = msg.isEmpty ? "控制指令被拒绝（code \(number)）" : msg
                }
            } catch let e as ApiError where e.isTokenExpired {
                await reauthenticate()
            } catch {
                let message = (error as? ApiError)?.message ?? error.localizedDescription
                monitor.appendLog("❌ 指令失败 \(message)")
                errorMessage = message
            }
        }

        // 队列排空后再核对一次。
        // 云端接受指令后设备需要几秒才实际应用并上报，立刻拉取会读到旧值。
        // 注意这里在循环【之外】—— 放在循环里会让每条指令都等 3 秒，
        // 连续按压时指令被拉得很开，体感像卡顿。
        try? await Task.sleep(for: .seconds(3))
        await monitor.refreshNow()
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
