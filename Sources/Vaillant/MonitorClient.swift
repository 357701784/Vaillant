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
    private var retry = 0
    private var wantConnection = false

    /// 设备离线时属性不会更新，用它给界面一个信号。
    @Published private(set) var isStale: Bool = false

    /// 诊断信息：非预期消息的原文，排查连接问题时看这个
    @Published private(set) var diagnostic: String?

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
        open()
    }

    func disconnect() {
        wantConnection = false
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
        isStale = true
    }

    /// token 过期时外部调用，触发重连
    func invalidateToken() {
        wantConnection = false
        stopHeartbeat()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .failed("登录已过期")
    }

    // MARK: 连接

    private func open() {
        guard let device, let token, wantConnection else { return }

        state = retry == 0 ? .connecting : .reconnecting(attempt: retry)

        var request = URLRequest(url: URL(string: "wss://vicapi.vaillant.com.cn/monitor/ws/app")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let socket = URLSession(configuration: .default)
            .webSocketTask(with: request)
        task = socket
        socket.resume()

        // 订阅消息必须在握手完成后发。
        // 提前 send 会被服务端丢弃 —— 表现为永远停在「连接中」。
        // 先挂接收回调，等第一帧（哪怕是 pong）回来再订阅。
        receiveNext(onReady: true)

        startHeartbeat()
    }

    /// 发订阅消息
    private func subscribe() {
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
            if let error {
                Task { @MainActor in
                    self?.state = .failed("订阅失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveNext(onReady: Bool = false) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if onReady {
                        // 收到第一帧说明握手已完成，此时订阅才有效
                        self.subscribe()
                    }
                    self.handle(message)
                    self.receiveNext()

                case .failure(let error):
                    Task { @MainActor in
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
            }
            retry = 0
            isStale = false
            lastUpdate = Date()
            state = .live
            diagnostic = nil

        case "pong":
            diagnostic = diagnostic  // 心跳正常，不改状态

        default:
            // 记录未知类型，避免静默失败导致界面永远停在「连接中」
            diagnostic = "未知消息类型 \(json["type"].map { "\($0)" } ?? "nil")：\(text.prefix(120))"
        }
    }

    private func handleDisconnect() {
        stopHeartbeat()
        guard wantConnection else { return }

        // 指数退避，最多 5 分钟，和集成里的策略一致
        retry += 1
        isStale = true

        if retry > 8 {
            wantConnection = false
            state = .failed("连接断开，点此重试")
            return
        }
        let delay = min(pow(2.0, Double(retry - 1)) * 2, 60)
        state = .reconnecting(attempt: retry)
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
}
