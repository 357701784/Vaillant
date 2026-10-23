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

        // 热水开启后，把待生效的设定温度补发下去
        monitor.onAttrsUpdated = { [weak self] attrs in
            Task { @MainActor in
                self?.updateDHWCache(attrs)
                self?.flushPendingIfPossible(attrs)
            }
        }

        // 恢复上次未生效的热水设定（不是敏感信息，放 UserDefaults 即可）
        if let pending = UserDefaults.standard.object(forKey: Self.pendingKey) as? Double {
            pendingDHWSetpoint = pending
        }
        dhwCache = UserDefaults.standard.object(forKey: Self.dhwCacheKey) as? Double

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

    /// 生活热水待生效的设定温度。
    ///
    /// 热水关闭时云端会静默忽略 `DHW_setpoint` 的写入（返回 200 但值不变），
    /// 所以这里先把用户设定的值存下来，等热水开启后自动补发。
    @Published private(set) var pendingDHWSetpoint: Double?

    /// UserDefaults 里存待生效设定值的键
    private static let pendingKey = "pending_dhw_setpoint"
    /// UserDefaults 里存「最后一次有效的热水设定值」的键
    private static let dhwCacheKey = "last_dhw_setpoint"

    /// 热水关闭时，设备会把 DHW_setpoint 重置成下限（实测 35），
    /// 云端读到的就是个废值。这个缓存记住最后一次有效值，
    /// 免得界面显示成 35 让用户以为温度被改了。
    private var dhwCache: Double?

    /// 是否有指令正在下发。用于禁用开关这类会引发状态跳变的操作。
    @Published private(set) var sending = false
    /// 等待发送的指令。连续按压时只保留最新值。
    private var pendingPayload: [String: Any] = [:]
    /// 驱动发送队列的任务
    private var sendTask: Task<Void, Never>?

    /// 按下 +/− 时调用。
    ///
    /// 基准值取自 monitor.attrs —— 它在乐观更新时是【同步】写入的，
    /// 所以连续快速按压时每次都能读到上一次的结果并逐次累加。
    /// 之前用 View 层的 @State 做基准，两次按压之间若 SwiftUI 还没重渲染，
    /// 第二次会读到旧值，导致按 7 次只生效 6 次。
    ///
    /// - Parameter needsEnabled: 该回路的写入是否要求先开启。
    ///   生活热水必须先开热水，否则云端静默忽略写入。
    func stepTemperature(
        key: String,
        readKeys: [String],
        delta: Double,
        min lower: Double,
        max upper: Double,
        needsEnabled: Bool = false
    ) {
        let current = ReadAttr.firstNumber(readKeys, in: monitor.attrs) ?? lower
        // 保留一位小数：((current + delta) * 10).rounded() / 10
        // 括号位置很关键 —— 写成 (current + delta * 10) 等于 current/10 + delta，
        // 会把 43 变成 5.3，远低于下限 35，云端直接返回 500。
        let next = ((current + delta) * 10).rounded() / 10
        // 夹在设备允许的范围内，超范围同样会被云端拒绝
        let clamped = min(upper, max(lower, next))

        if needsEnabled, !isCircuitEnabled(key) {
            // 回路没开：写下去会被云端静默忽略。
            // 存下目标值，等回路开启后自动补发。
            pendingDHWSetpoint = clamped
            UserDefaults.standard.set(clamped, forKey: Self.pendingKey)
            monitor.appendLog("回路未开启，暂存设定值 \(clamped)，待开启后自动生效")
            return
        }

        // send() 内部会同步写入本地状态（乐观更新），
        // 所以下一次按压能读到它 —— 累加才不会丢步。
        send([key: clamped])
    }

    /// 生活热水卡片该显示的温度。
    ///
    /// 优先级：用户刚设的待生效值 > 设备当前有效值 > 本地缓存的上次有效值。
    /// 设备在热水关闭时把 DHW_setpoint 重置成下限 35，
    /// 那时只能靠缓存还原用户上次设的值。
    var dhwDisplayValue: Double? {
        if let pending = pendingDHWSetpoint { return pending }
        let device = ReadAttr.firstNumber(ReadAttr.dhwSetpointKeys, in: monitor.attrs)
        if let device, isValidDHWSetpoint(device) { return device }
        return dhwCache
    }

    /// 设备上报的热水设定值是否有效（不是重置后的下限默认值）
    private func isValidDHWSetpoint(_ value: Double) -> Bool {
        let lower = ReadAttr.firstNumber([ReadAttr.dhwLowerLimitKey], in: monitor.attrs) ?? 35
        return value > lower
    }

    /// 更新热水设定缓存
    private func updateDHWCache(_ attrs: [String: Any]) {
        guard let value = ReadAttr.firstNumber(ReadAttr.dhwSetpointKeys, in: attrs),
              isValidDHWSetpoint(value)
        else { return }
        guard dhwCache != value else { return }
        dhwCache = value
        UserDefaults.standard.set(value, forKey: Self.dhwCacheKey)
    }

    /// 某个回路当前是否处于开启状态
    private func isCircuitEnabled(_ key: String) -> Bool {
        let enableKeys: [String]
        switch key {
        case WritableAttr.dhwSetpoint: enableKeys = ReadAttr.dhwEnableKeys
        case WritableAttr.chSetpoint:  enableKeys = ReadAttr.heatingEnableKeys
        default: return true
        }
        guard let raw = ReadAttr.first(enableKeys, in: monitor.attrs) else { return true }
        return Catalog.isOn(raw) ?? false
    }

    /// 回路开启后，把暂存的设定温度补发下去
    private func flushPendingIfPossible(_ attrs: [String: Any]) {
        guard let pending = pendingDHWSetpoint else { return }
        let enabled = ReadAttr.first(ReadAttr.dhwEnableKeys, in: attrs)
            .flatMap { Catalog.isOn($0) } ?? false
        guard enabled else { return }

        pendingDHWSetpoint = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
        monitor.appendLog("热水已开启，补发暂存的设定温度 \(pending)")
        Task { @MainActor [weak self] in
            await self?.send([WritableAttr.dhwSetpoint: pending])
        }
    }

    /// 下发控制指令。
    ///
    /// 连续快速按压时不能丢弃后发的指令 —— 用户按 7 次 + 应该得到 +7。
    /// 这里用一个常驻的「泵」任务驱动队列：
    /// 飞行期间的新指令合并进 pendingPayload，泵取走时只发最新值。
    func send(_ payload: [String: Any]) {
        guard device != nil, token != nil else { return }

        // 立即乐观更新：界面马上反映操作，也让后续按压基于新值计算。
        monitor.applyLocal(payload)

        // 合并待发指令（后来的覆盖先前的）
        pendingPayload.merge(payload) { _, new in new }

        // 没有泵在跑就启动一个。已有泵在跑时，新指令留在队列里等它取。
        if sendTask == nil {
            sending = true
            sendTask = Task { [weak self] in
                await self?.pumpQueue()
            }
        }
    }

    /// 发送队列泵。
    ///
    /// 之前用 `defer { sendInFlight = false }` 来标记空闲，但 defer 要等
    /// 函数【退出】才执行 —— 而退出前还有 3 秒的核对等待。那 3 秒里
    /// 新按压会被 `guard !sendInFlight` 挡掉，值卡在队列里没人取，
    /// 于是「按了没反应」。改成常驻任务后，等待期间的新指令会
    /// 被外层循环接住。
    private func pumpQueue() async {
        while true {
            // 把队列里所有待发指令发出去
            while !pendingPayload.isEmpty {
                let batch = pendingPayload
                pendingPayload = [:]

                guard let device, let token else { break }

                let keys = batch.keys.joined(separator: ",")
                let values = batch.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                monitor.appendLog("下发指令 \(keys) → \(values)")

                do {
                    let response = try await api.control(
                        device: device, token: token, attrs: batch
                    )
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

            // 队列空 → 等设备把改动应用并上报，再核对一次。
            // 分段等待：期间若有新按压，立刻结束等待去发它，
            // 而不是干等满 3 秒。
            var waited = 0.0
            while waited < 3.0 {
                try? await Task.sleep(for: .milliseconds(300))
                waited += 0.3
                if !pendingPayload.isEmpty { break }
            }
            await monitor.refreshNow()

            // 核对期间若又攒了新指令，回到上面继续发。
            // 这个检查与下面的 sendTask = nil 之间没有 await，
            // 在主线程上不会被打断，所以不会漏掉按压。
            if pendingPayload.isEmpty {
                sendTask = nil
                sending = false
                return
            }
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
