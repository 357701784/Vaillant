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
    /// 必须强持有 session。
    /// 用 `URLSession(configuration:)` 现场创建却不保存，ARC 可能在
    /// TLS 握手完成前就释放它 —— 表现为永远停在「连接中」，无任何回调。
    private var session: URLSession?
    /// 捕获握手阶段的错误。URLSessionWebSocketTask 自身不回报握手失败。
    private var delegate: SessionDelegate?
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
        open()
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

    private func open() {
        guard let device, let token, wantConnection else { return }

        state = retry == 0 ? .connecting : .reconnecting(attempt: retry)
        diagnostic = nil
        log("开始连接 did=\(device.id) mac=\(device.mac) retry=\(retry)")

        var request = URLRequest(url: URL(string: "wss://vicapi.vaillant.com.cn/monitor/ws/app")!)
        request.setValue("Bearer \(token.prefix(12))…", forHTTPHeaderField: "Authorization")
        // 威能按 UA 区分客户端；缺省 UA 会被网关拒绝。
        request.setValue(Api.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Api.appKey, forHTTPHeaderField: "appkey")
        request.timeoutInterval = 20

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        let delegate = SessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session          // 强持有
        self.delegate = delegate
        log("session 已创建 delegate=\(delegate)")

        delegate.onError = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let ns = error as NSError
                self.log("❌ delegate 错误 domain=\(ns.domain) code=\(ns.code) info=\(ns.userInfo)")
                self.diagnostic = "\(ns.domain) \(ns.code)：\(error.localizedDescription)"
                self.state = .failed("握手失败：\(error.localizedDescription)")
                self.handleDisconnect()
            }
        }
        delegate.onOpen = { [weak self] protocolName in
            Task { @MainActor in
                guard let self else { return }
                self.log("✅ 握手完成 subprotocol=\(protocolName ?? "无")")
                self.subscribe()
                self.receiveNext()
                self.cancelConnectTimeout()
            }
        }

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        log("task 已 resume")

        armConnectTimeout()
        startHeartbeat()
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

    /// 释放 session 与 task，避免重连时堆积
    private func teardown() {
        cancelConnectTimeout()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }
}

// MARK: - 握手回调

/// URLSessionWebSocketTask 不会回报握手阶段的失败
/// （TLS、HTTP Upgrade、认证），只有 delegate 能看到。
final class SessionDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: ((String?) -> Void)?
    var onError: ((Error) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?(protocol)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // 服务端主动关闭
        if closeCode != .normalClosure {
            onError?(NSError(
                domain: "ws", code: Int(closeCode.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "服务端关闭（code \(closeCode.rawValue)）"]
            ))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error { onError?(error) }
    }
}
