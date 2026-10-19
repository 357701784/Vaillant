import Foundation
import Combine

/// 威能云端实时通道。
///
/// 协议逆自 vaillant_plus_cn_api/websocket.py：
/// 1. `wss://vicapi.vaillant.com.cn/monitor/ws/app`，带 `Authorization: Bearer <token>`
/// 2. 连上后发 `{"type":"msg","productKey":..,"mac":..,"did":..}` 订阅
/// 3. 服务端推 `{"type":"2","did":..,"data":{...}}` —— 订阅后第一帧是全量属性
/// 4. 每 15 秒发 `{"type":"ping"}`，服务端回 `{"type":"pong"}` 或 `{"type":"3"}`
///
/// **为什么是短连接轮询而不是长连接**
///
/// 维持长连接在 iOS 上极不稳定：实测约 43 秒就被服务端断开
/// （code=53 Software caused connection abort）。但每次新建连接、订阅之后，
/// 服务端**立刻**推送全量属性帧（实测 157 个字段）。
///
/// 既然每次都能拿到全量快照，就没必要维持长连接 —— 改成「开一条连接、
/// 取一帧、断开」，按固定间隔轮询。这样没有心跳、没有掉线重连、
/// 也没有重连风暴，行为可预期。
@MainActor
final class MonitorClient: NSObject, ObservableObject {
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
    @Published private(set) var diagnostic: String?
    @Published private(set) var log: [String] = []

    private let client: APIClient
    private var device: Device?
    private var token: String?

    /// 轮询定时器
    private var pollTimer: Task<Void, Never>?
    /// 当前正在进行的抓取，防止并发
    private var inFlight = false
    /// 界面回到前台时立刻刷新一次
    private var wantConnection = false

    /// 轮询间隔。设备状态变化有分钟级延迟，10 秒足够且不浪费服务器资源。
    private let pollInterval: TimeInterval = 10
    /// 单次抓取超时
    private let fetchTimeout: TimeInterval = 12

    private var failureCount = 0

    init(client: APIClient = APIClient()) {
        self.client = client
        super.init()
    }

    // MARK: 日志

    private func log(_ text: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(ts)] \(text)")
        if log.count > 150 { log.removeFirst(log.count - 150) }
    }

    func clearLog() { log.removeAll() }

    // MARK: 生命周期

    func connect(device: Device, token: String) {
        disconnect()
        self.device = device
        self.token = token
        wantConnection = true
        failureCount = 0
        log("开始轮询，间隔 \(Int(pollInterval)) 秒")
        poll()
    }

    func disconnect() {
        wantConnection = false
        pollTimer?.cancel()
        pollTimer = nil
        state = .idle
        attrs.removeAll()
        lastUpdate = nil
    }

    /// token 过期时外部调用
    func invalidateToken() {
        wantConnection = false
        pollTimer?.cancel()
        pollTimer = nil
        state = .failed("登录已过期")
    }

    // MARK: 轮询

    private func poll() {
        pollTimer?.cancel()
        pollTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.fetchOnce()
                guard let self, !Task.isCancelled, self.wantConnection else { return }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    /// 开一条短连接，订阅，取一帧，断开
    private func fetchOnce() async {
        guard let device, let token, wantConnection, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        if attrs.isEmpty {
            state = failureCount > 0 ? .reconnecting(attempt: failureCount) : .connecting
        }

        var request = URLRequest(url: URL(string: "wss://vicapi.vaillant.com.cn/monitor/ws/app")!)
        request.timeoutInterval = fetchTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        // 订阅
        let message: [String: Any] = [
            "type": "msg",
            "productKey": device.productKey,
            "mac": device.mac,
            "did": device.id,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: payload, encoding: .utf8)
        else { return }

        // send 的回调与连接建立竞态，这里直接发，失败由下方取帧时暴露
        socket.send(.string(text)) { _ in }

        // 取帧：最多等 fetchTimeout 秒
        let deadline = Date().addingTimeInterval(fetchTimeout)
        while Date() < deadline {
            do {
                let received = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) in
                    socket.receive { result in
                        continuation.resume(with: result)
                    }
                }

                guard let data = asText(received),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if json["type"] as? String == "2",
                   let update = json["data"] as? [String: Any],
                   !update.isEmpty {
                    // 每帧都是全量，直接替换
                    attrs = update
                    lastUpdate = Date()
                    state = .live
                    diagnostic = nil
                    failureCount = 0
                    log("收到 \(update.count) 个字段")
                    return
                }
            } catch {
                break
            }
        }

        // 没拿到数据
        failureCount += 1
        if failureCount == 1 {
            log("第 1 次抓取未收到数据（code 57 多为握手未完成，稍后重试）")
        } else {
            log("第 \(failureCount) 次抓取失败")
        }
        if attrs.isEmpty {
            state = failureCount >= 5
                ? .failed("多次抓取失败，请检查网络")
                : .reconnecting(attempt: failureCount)
        }
    }

    private func asText(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let s): return s.data(using: .utf8)
        case .data(let d): return d
        @unknown default: return nil
        }
    }
}
