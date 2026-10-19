import Foundation

// MARK: - 常量

enum Api {
    static let host = "https://vicapi.vaillant.com.cn"
    static let appKey = "9109fb3ea6c04cf1be34c71ff82a51ec"
    static let appAuth = "Basic YXBwLXc6aW90MlExWDNY"
    // 官方 App 的 UA。威能按 UA 区分客户端，换掉可能被拒。
    static let userAgent = "VaillantPlus/230329005 CFNetwork/1485 Darwin/23.1.0"
}

struct ApiError: LocalizedError {
    let message: String
    var isTokenExpired: Bool = false
    var errorDescription: String? { message }
}

// MARK: - 设备

struct Device: Identifiable, Codable, Hashable {
    let id: String            // did
    let mac: String
    let productKey: String
    let name: String
    let model: String
    let online: Bool

    var subtitle: String {
        model.isEmpty ? id : "\(name) · \(model)"
    }
}

// MARK: - 凭据

struct Credentials: Codable {
    let username: String
    let password: String
}

// MARK: - 客户端

/// 威能中国区云 API 客户端。
///
/// 端点逆自 https://github.com/daxingplay/vaillant-plus-cn-api
/// （它被 https://github.com/daxingplay/home-assistant-vaillant-plus 使用）
final class APIClient: NSObject {
    private let session: URLSession

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        #if canImport(Darwin)
        // 移动端网络切换频繁，等连接恢复优于直接失败
        config.waitsForConnectivity = true
        #endif
        session = URLSession(configuration: config)
        super.init()
    }

    // MARK: 底层请求

    private func makeRequest(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        token: String? = nil,
        form: [String: String]? = nil,
        json: [String: Any]? = nil,
        basicAuth: String? = nil
    ) -> URLRequest {
        var components = URLComponents(string: "\(Api.host)/\(path)")!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(Api.appKey, forHTTPHeaderField: "appkey")
        request.setValue(Api.userAgent, forHTTPHeaderField: "User-Agent")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let basicAuth {
            request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        }
        if let form {
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            var parts: [String] = []
            for (k, v) in form {
                let encoded = v.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? v
                parts.append("\(k)=\(encoded)")
            }
            request.httpBody = parts.joined(separator: "&").data(using: .utf8)
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    /// 发请求并解析 JSON。威能所有响应都带 `code` 字段。
    @discardableResult
    private func send(
        _ request: URLRequest,
        requireCode200: Bool = true
    ) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApiError(message: "无响应")
        }

        var json: [String: Any] = [:]
        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        }

        // 威能用过期的 token 会返回 424 + code 9006
        let code = json["code"] as? Int
        if http.statusCode == 424 || http.statusCode == 403 || code == 9006 {
            throw ApiError(message: "登录已过期，请重新登录", isTokenExpired: true)
        }
        if http.statusCode >= 400 {
            throw ApiError(message: "服务器返回 \(http.statusCode)")
        }
        if requireCode200, let code, code != 200 {
            let msg = json["msg"] as? String ?? "错误码 \(code)"
            throw ApiError(message: msg)
        }
        return json
    }

    // MARK: 登录

    /// 密码换 token。token 由调用方保存，密码不落盘。
    func login(username: String, password: String) async throws -> String {
        let request = makeRequest(
            path: "auth/oauth/token",
            method: "POST",
            query: ["grant_type": "password"],
            form: [
                "appkey": Api.appKey,
                "scope": "server",
                "username": username,
                "password": password,
            ],
            basicAuth: Api.appAuth
        )

        let json = try await send(request)
        guard let token = json["access_token"] as? String else {
            throw ApiError(message: "登录失败：未返回 token")
        }
        return token
    }

    // MARK: 设备列表

    func devices(token: String) async throws -> [Device] {
        let request = makeRequest(
            path: "app/device/getBindList",
            query: ["appKey": Api.appKey, "version": "1.0"],
            token: token
        )
        let json = try await send(request)
        guard let groups = json["data"] as? [[String: Any]] else { return [] }

        return groups.flatMap { group -> [Device] in
            let list = group["allBindList"] as? [[String: Any]] ?? []
            return list.compactMap { d in
                guard let did = d["did"] as? String else { return nil }
                let model = (d["modelInfo"] as? [String: Any])?["model"] as? String ?? ""
                return Device(
                    id: did,
                    mac: d["mac"] as? String ?? "",
                    productKey: d["productKey"] as? String ?? "",
                    name: (d["productName"] as? String)
                        ?? (d["verboseName"] as? String)
                        ?? did,
                    model: model,
                    online: (d["isOnline"] as? Int) == 1
                )
            }
        }
    }

    // MARK: 控制

    /// 下发控制指令。attrs 的可用键见 `WritableAttr`。
    func control(device: Device, token: String, attrs: [String: Any]) async throws {
        let request = makeRequest(
            path: "app/device/control/\(device.id)",
            method: "POST",
            token: token,
            json: [
                "appKey": Api.appKey,
                "data": ["attrs": attrs],
                "version": "1.0",
            ]
        )
        _ = try await send(request)
    }
}

// MARK: - 可写属性

/// 云端接受的控制键，逆自集成源码。
enum WritableAttr {
    // 地暖
    /// 开关：true/false，或 1/0
    static let heatingEnable = "Heating_Enable"
    /// 目标室温
    static let setpointComfort = "Room_Temperature_Setpoint_Comfort"
    /// 模式：开机为 "Cruising"
    static let modeCH = "Mode_Setting_CH"

    // 生活热水
    /// 生活热水设定温度（集成的 set_temperature 用的就是这个键）
    static let dhwSetpoint = "DHW_setpoint"
    /// 热水开关。集成写的是 WarmStar_Tank_Loading_Enable，值为 1/0
    static let dhwEnable = "WarmStar_Tank_Loading_Enable"
}

/// 读取生活热水数据时的候选键，按优先级排列。
/// 与集成 water_heater.py 的 DHW_SETPOINT_ATTRS / DHW_ENABLE_ATTRS 一致。
enum ReadAttr {
    static let dhwSetpointKeys = [
        "Current_DHW_Setpoint", "DHW_readSetPoint", "DHW_setpoint",
    ]
    static let dhwEnableKeys = [
        "WarmStar_Tank_Loading_Enable", "Enabled_DHW", "DHW_switch",
    ]
    static let heatingEnableKeys = ["Heating_Enable", "Enabled_Heating"]

    /// 按优先级取第一个有值的键
    static func first(_ keys: [String], in attrs: [String: Any]) -> Any? {
        for key in keys where attrs[key] != nil { return attrs[key] }
        return nil
    }
}
