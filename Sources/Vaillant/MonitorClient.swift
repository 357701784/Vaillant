import Foundation

/// 威能云端实时通道。
///
/// 协议逆自 vaillant_plus_cn_api/websocket.py：
/// 1. `wss://vicapi.vaillant.com.cn/monitor/ws/app`，带 `Authorization: Bearer <token>`
/// 2. 连上后发 `{"type":"msg","productKey":..,"mac":..,"did":..}` 订阅
/// 3. 服务端推 `{"type":"2","did":..,"data":{...}}` —— 订阅后第一帧是全量属性，
///    之后每帧只带变化的字段
/// 4. 每 15 秒发 `{"type":"ping"}`，服务端回 `{"type":"pong"}`
@MainActor
final class MonitorClient: NSObject {
    enum State: Equatable {
        case idle
        case connecting
        case live
        case reconnecting(attempt: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var attrs: [String: Any] = [:]
    @Published private(set) var lastUpdate: Date?

    private var task: URLSessionWebSocketTask?
    private let client: APIClient
    private var device: Device?
    private var token: String?
    private var pingTimer: Timer?
    private var connectTimeout: Task<Void, Never>?
    private var retry = 0
    private var wantConnection = false

    /// 设备离线时属性不会更新，用它给界面一个信号。
    @Published private(set) var isStale: Bool = false

    /// 诊断信息：非预期消息的原文，排查连接问题时看这个
    @Published private(set) var diagnostic: String?

    /// 完整事件日志，带时间戳。在调试页里显示。
    @Published private(set) var log: [String] = []

    private func log(_ text: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(ts)] \(text)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
        print("[Monitor] \(text)")
    }

    func clearLog() { log.removeAll() }

    private let heartbeatInterval: TimeInterval = 15

    init(client: APIClient = APIClient()) {
        self.client = client
        super.init()
    }

    // MARK: 生命周期

    func connect(device: Device, token: String) {
        disconnect()
        self.device = device
        self.token = token
        wantConnection = true
        retry = 0
        // 先验证 token，再开 WebSocket
        Task { [weak self] in
            await self?.verifyToken(token, device)
            await MainActor.run { self?.open() }
        }
    }

    func disconnect() {
        wantConnection = false
        stopHeartbeat()
        teardown()
        state = .idle
        isStale = true
    }

    /// token 过期时外部调用，触发重连
    func invalidateToken() {
        wantConnection = false
        stopHeartbeat()
        teardown()
        state = .failed("登录已过期")
    }

    // MARK: 连接

    /// 连接前先验证 token 在 iOS 上确实能通过认证。
    /// 如果连普通 HTTP 都 401/424，说明问题不在 WebSocket 路径。
    private func verifyToken(_ token: String, _ device: Device) async {
        log("token 长度=\(token.count) 前后各12位=[\(token.prefix(12))…\(token.suffix(12))]")
        var req = URLRequest(url: URL(string:
            "https://vicapi.vaillant.com.cn/app/device/getBindList?appKey=\(Api.appKey)&version=1.0"
        )!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Api.appKey, forHTTPHeaderField: "appkey")
        req.setValue(Api.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["code"] ?? nil
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            log("token 验证：HTTP \(status) 业务码 \(String(describing: code))")
        } catch {
            log("token 验证失败：\(error.localizedDescription)")
        }
    }

    private func open() {
        guard let device, let token, wantConnection else { return }

        state = retry == 0 ? .connecting : .reconnecting(attempt: retry)
        diagnostic = nil
        log("开始连接 did=\(device.id) mac=\(device.mac) retry=\(retry)")

        var request = URLRequest(url: URL(string: "wss://vicapi.vaillant.com.cn/monitor/ws/app")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        log("用 URLSession.shared，无自定义 UA，Authorization 长度 \(token.count)")

        // 必须用 .shared。
        // 自建 URLSession(configuration:delegate:) 建立 WebSocket 时，
        // 服务端会在握手后立刻以 code 1001 关闭 —— 早期版本用 .shared 能正常
        // 收到 157 个字段，换成自建 session 就连不上了。
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()
        log("task 已 resume")

        // resume() 之后立即订阅。
        // 早期能读到数据的版本就是这个时序：先发订阅，服务端随后回 pong 再推属性。
        sendSubscribeNow()
        receiveNext()
        armConnectTimeout()
        startHeartbeat()
    }

    /// 立即发送订阅，不等握手回调
    private func sendSubscribeNow() {
        guard let device, let task else { return }
        let message: [String: Any] = [
            "type": "msg",
            "productKey": device.productKey,
            "mac": device.mac,
            "did": device.id,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: payload, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.log("❌ 订阅发送失败：\(error.localizedDescription)")
                } else {
                    self?.log("已发送订阅消息")
                }
            }
        }
    }

    /// 握手迟迟不完成时给出明确失败，而不是无限期停在「连接中」
    private func armConnectTimeout() {
        connectTimeout?.cancel()
        connectTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !self.isLive else { return }
            self.state = .failed("连接超时（20 秒未建立）")
            self.handleDisconnect()
        }
    }

    private func cancelConnectTimeout() {
        connectTimeout?.cancel()
        connectTimeout = nil
    }

    private var isLive: Bool { if case .live = state { return true }; return false }

    /// 发订阅消息
    private func subscribe() {
        guard let device, let task else { return }
        // 连接可能已经被服务端关闭，此时发送只会报 "Socket is not connected"
        if task.state != .running {
            log("⚠️ 连接非 running（state=\(task.state.rawValue)），跳过订阅")
            return
        }
        let message: [String: Any] = [
            "type": "msg",
            "productKey": device.productKey,
            "mac": device.mac,
            "did": device.id,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: payload, encoding: .utf8)
        else { return }

        task.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.log("❌ 订阅发送失败：\(error.localizedDescription)")
                    self?.state = .failed("订阅失败：\(error.localizedDescription)")
                }
            } else {
                Task { @MainActor in self?.log("已发送订阅消息") }
            }
        }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.cancelConnectTimeout()
                    self.handle(message)
                    self.receiveNext()

                case .failure(let error):
                    Task { @MainActor in
                        let ns = error as NSError
                        self.log("❌ receive 失败 domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription)")
                        if self.state == .connecting {
                            self.state = .failed("连接失败：\(error.localizedDescription)")
                        }
                    }
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // 非 JSON 帧（例如服务端错误文本）也记下来，便于排查
            diagnostic = "收到非 JSON 帧：\(text.prefix(120))"
            return
        }

        switch json["type"] as? String {
        case "2":
            // 订阅帧是全量，增量帧只含变化字段 —— 合并即可
            if let update = json["data"] as? [String: Any] {
                attrs.merge(update) { _, new in new }
                if lastUpdate == nil {
                    log("收到全量属性帧，共 \(update.count) 个字段")
                }
            }
            retry = 0
            isStale = false
            lastUpdate = Date()
            state = .live
            diagnostic = nil

        case "pong":
            // 订阅确认。不改状态，等属性帧才置为 live
            diagnostic = nil

        case "3":
            // ping 的响应。同样说明连接活着
            diagnostic = nil

        default:
            // 记录未知类型，避免静默失败导致界面永远停在「连接中」
            diagnostic = "未知消息类型 \(json["type"].map { "\($0)" } ?? "nil")：\(text.prefix(120))"
        }
    }

    private func handleDisconnect() {
        stopHeartbeat()
        teardown()
        guard wantConnection else { return }

        // 指数退避，最多 5 分钟，和集成里的策略一致
        retry += 1
        isStale = true

        if retry > 6 {
            wantConnection = false
            state = .failed("连接断开，点此重试")
            return
        }
        // 指数退避：1s 2s 4s 8s 16s 32s。重连太密会把真正的错误淹掉。
        let delay = min(pow(2.0, Double(retry - 1)), 60)
        state = .reconnecting(attempt: retry)
        log("第 \(retry) 次重连将在 \(Int(delay)) 秒后进行")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            self.open()
        }
    }

    // MARK: 心跳

    private func startHeartbeat() {
        stopHeartbeat()
        pingTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPing() }
        }
    }

    private func sendPing() {
        guard let task else { return }
        task.send(.string(#"{"type":"ping"}"#)) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.handleDisconnect() }
            }
        }
    }

    private func stopHeartbeat() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    /// 释放 task，避免重连时堆积
    private func teardown() {
        cancelConnectTimeout()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
