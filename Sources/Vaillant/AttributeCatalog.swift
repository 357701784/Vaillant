import SwiftUI

/// 一个传感器/数据点的展示定义。
struct AttributeSpec: Identifiable {
    let key: String          // 云端属性名
    let label: String        // 中文名
    let unit: String?
    let style: Style
    let group: Group
    /// 同义/镜像字段组。
    ///
    /// 威能的云会把同一个寄存器值复制到多个时段字段
    /// （今日/昨日/本月/今年 × 地暖/热水，8 个字段值全同）。
    /// 列出来是纯噪音 —— 只留一行，显示其中数值最大的那个。
    var mirrorKeys: [String] = []

    var id: String { key }

    enum Style {
        case temperature
        case pressure
        case duration          // 运行时长，原始单位是分钟
        case counter           // 累计值
        case percent
        case raw
        case status            // 亮/灭类状态
    }

    enum Group: String, CaseIterable, Identifiable {
        case temperature = "温度"
        case deviceState = "运行状态"
        case gas = "燃气消耗"
        case water = "用水"
        case fault = "故障与维护"
        case system = "系统"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .temperature: return "thermometer.medium"
            case .deviceState: return "gearshape.2"
            case .gas: return "flame"
            case .water: return "drop"
            case .fault: return "exclamationmark.triangle"
            case .system: return "info.circle"
            }
        }
    }
}

/// 全部可读属性。
///
/// 键名逐一取自 daxingplay/home-assistant-vaillant-plus 的 sensor.py，
/// 那些键能显示出来说明云端确实在推这些数据 —— 官方 App 只是没给你看。
enum Catalog {
    static let specs: [AttributeSpec] = [
        // 温度
        .init(key: "Flow_temperature", label: "出水温度", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "return_temperature", label: "回水温度", unit: "°C", style: .temperature, group: .temperature),
        // 实测这台 familyCONNECT 推的字段（部分传感器装在网关侧）
        .init(key: "DHW_temperature", label: "热水温度（实测）", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "CH_readSetPoint", label: "采暖读取设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Flow_Temperature_Setpoint", label: "出水设定温度", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "DHW_setpoint", label: "生活热水设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "DHW_readSetPoint", label: "生活热水读取设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Current_DHW_Setpoint", label: "当前生活热水设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Tank_temperature", label: "水箱温度", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Room_Temperature", label: "室温", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Outdoor_Temperature", label: "室外温度", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Lower_Limitation_of_CH_Setpoint", label: "采暖设定下限", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Upper_Limitation_of_CH_Setpoint", label: "采暖设定上限", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Lower_Limitation_of_DHW_Setpoint", label: "热水设定下限", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Upper_Limitation_of_DHW_Setpoint", label: "热水设定上限", unit: "°C", style: .temperature, group: .temperature),

        // 运行状态 —— 官方 App 基本不给你看
        .init(key: "burn_status", label: "燃烧器", unit: nil, style: .status, group: .deviceState),
        .init(key: "pump_status", label: "水泵", unit: nil, style: .status, group: .deviceState),
        .init(key: "fan_status", label: "风机", unit: nil, style: .status, group: .deviceState),
        .init(key: "fan_speed", label: "风速", unit: "rpm", style: .raw, group: .deviceState),
        .init(key: "ebus_status", label: "eBUS 总线", unit: nil, style: .status, group: .deviceState),
        .init(key: "modbus_status", label: "Modbus 总线", unit: nil, style: .status, group: .deviceState),
        .init(key: "water_pressure", label: "水压", unit: "bar", style: .pressure, group: .deviceState),
        .init(key: "Heating_Enable", label: "采暖使能", unit: nil, style: .status, group: .deviceState),
        .init(key: "Enabled_Heating", label: "采暖已启用", unit: nil, style: .status, group: .deviceState),
        .init(key: "Mode_Setting_CH", label: "采暖模式", unit: nil, style: .raw, group: .deviceState),
        .init(key: "Heating_System_Setting", label: "采暖系统设置", unit: nil, style: .raw, group: .deviceState),
        .init(key: "Heating_Curve", label: "采暖曲线", unit: nil, style: .raw, group: .deviceState),
        .init(key: "DHW_switch", label: "热水开关", unit: nil, style: .status, group: .deviceState),
        .init(key: "DHW_Function", label: "热水功能", unit: nil, style: .raw, group: .deviceState),

        // 燃气
        // 燃气消耗：8 个时段字段的值完全相同（实测 000080bf），
        // 且烧水几天都不变。合并成一行，取数值最大的那个。
        .init(key: "gas_ch_consumption_today",
              label: "燃气表读数",
              unit: nil, style: .counter, group: .gas,
              mirrorKeys: [
                "gas_ch_consumption_yesterday",
                "gas_ch_consumption_monthly",
                "gas_ch_consumption_yearly",
                "gas_dhw_consumption_today",
                "gas_dhw_consumption_yesterday",
                "gas_dhw_consumption_monthly",
                "gas_dhw_consumption_yearly",
              ]),
        .init(key: "gas_consumption", label: "燃气累计", unit: nil, style: .counter, group: .gas),
        // 注：gasDHWToday / gasCHToday 曾列在此处，但两者恒为 0、
        // HA 集成也未收录（集成里一个驼峰命名的字段都没有），
        // 与其余下划线命名的字段来源不同，已移除。
        .init(key: "Mode_Setting_DHW", label: "热水模式", unit: nil, style: .raw, group: .deviceState),
        .init(key: "CH_workTime", label: "采暖运行时长", unit: "分钟", style: .duration, group: .gas),
        .init(key: "CH_power", label: "采暖功率", unit: nil, style: .raw, group: .gas),
        .init(key: "CH_startTimes", label: "采暖启动次数", unit: "次", style: .counter, group: .gas),

        // 用水
        .init(key: "DHW_workTime", label: "热水运行时长", unit: "分钟", style: .duration, group: .water),
        .init(key: "DHW_power", label: "热水功率", unit: nil, style: .raw, group: .water),
        .init(key: "DHW_startTimes", label: "热水启动次数", unit: "次", style: .counter, group: .water),

        // 故障
        .init(key: "maintainence_remainTime", label: "距下次保养", unit: nil, style: .raw, group: .fault),
        .init(key: "Fault_List_1", label: "故障码 1", unit: nil, style: .raw, group: .fault),
        .init(key: "Fault_List_2", label: "故障码 2", unit: nil, style: .raw, group: .fault),
        .init(key: "Fault_List_3", label: "故障码 3", unit: nil, style: .raw, group: .fault),
        .init(key: "Fault_List_4", label: "故障码 4", unit: nil, style: .raw, group: .fault),
        .init(key: "Fault_List_5", label: "故障码 5", unit: nil, style: .raw, group: .fault),
        .init(key: "Gateway_Fault_List_1", label: "网关故障 1", unit: nil, style: .raw, group: .fault),
        .init(key: "Gateway_Fault_List_2", label: "网关故障 2", unit: nil, style: .raw, group: .fault),
        .init(key: "Gateway_Fault_List_3", label: "网关故障 3", unit: nil, style: .raw, group: .fault),
        .init(key: "Gateway_Fault_List_4", label: "网关故障 4", unit: nil, style: .raw, group: .fault),
        .init(key: "Gateway_Fault_List_5", label: "网关故障 5", unit: nil, style: .raw, group: .fault),

        // 系统
        .init(key: "WiFi_RSSI", label: "WiFi 信号", unit: "dBm", style: .raw, group: .system),
    ]

    /// 界面上没列出来、但云端推了的字段。
    /// 用于「原始数据」页，让你能发现官方 App 藏着什么。
    static func unknownKeys(in attrs: [String: Any]) -> [String] {
        let known = Set(specs.map(\.key))
        return attrs.keys.filter { !known.contains($0) }.sorted()
    }

    // MARK: 取值与格式化

    /// 传感器未接时威能返回的哨兵值。
    /// -50°C 是常见的「无此传感器」标记，0 则多表示该通道未启用。
    private static let sentinelTemps: Set<Double> = [-50, -51, -99, 127.5]

    /// 温度是否是无意义的哨兵值
    static func isSentinelTemperature(_ value: Double?) -> Bool {
        guard let value else { return true }
        return sentinelTemps.contains(value) || value <= -40 || value > 110
    }

    /// 温度取值：过滤哨兵值。
    /// DHW_temperature 这类字段实测出现过 127.5 —— 超出物理范围，视为无效。
    static func temperature(_ value: Any?) -> Double? {
        let n = number(value)
        return isSentinelTemperature(n) ? nil : n
    }

    /// 从原始属性里取数值。
    ///
    /// 实测云端的值有四种形态，都遇到过：
    ///   - `35`        JSON 数字
    ///   - `0`         JSON 数字
    ///   - `"000080bf"` 十六进制字符串（燃气消耗等累计量）
    ///   - `"42"`      十进制字符串
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            if let direct = Double(t) { return direct }
            // 十六进制：纯数字+字母、或有 0x 前缀
            if t.hasPrefix("0x") || t.hasPrefix("0X") {
                return UInt64(t.dropFirst(2), radix: 16).map { Double($0) }
            }
            if !t.isEmpty, t.allSatisfy({ $0.isHexDigit }) {
                return UInt64(t, radix: 16).map { Double($0) }
            }
            return nil
        default: return nil
        }
    }

    /// 判断"亮/灭"类状态是否开启。
    static func isOn(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as Int: return n != 0
        case let d as Double: return d != 0
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if ["1", "true", "on", "yes", "run", "burning"].contains(t) { return true }
            if ["0", "false", "off", "no", "stop", "standby"].contains(t) { return false }
            return nil
        default: return nil
        }
    }

    /// 故障码列表里"没有故障"的常见占位值。
    /// 65535 = 0xFFFF 是实测到的哨兵值，表示该位无故障。
    private static let noFaultValues: Set<String> = [
        "", "-", "--", "0", "0.0", "none", "null", "no fault", "ok",
        "65535", "0xffff", "65534", "4294967295",
    ]

    /// 哨兵值：表示"该字段无内容"，显示出来只会是噪音。
    /// 65535 (0xFFFF) 是威能设备的通用占位值 —— 故障码槽位为空、
    /// 保养时间未知等都用它。
    /// 取一组同义字段中数值最大的那个原始值。
    /// 用于「8 个时段字段其实是同一个值」的情况。
    static func mergedRaw(_ spec: AttributeSpec, in attrs: [String: Any]) -> Any? {
        guard !spec.mirrorKeys.isEmpty else { return attrs[spec.key] }
        var best: Any?
        var bestNumber = -Double.infinity
        for key in [spec.key] + spec.mirrorKeys {
            guard let value = attrs[key], let n = number(value) else { continue }
            if n > bestNumber {
                bestNumber = n
                best = value
            }
        }
        return best ?? attrs[spec.key]
    }

    static func isSentinel(_ value: Any?) -> Bool {
        guard let value else { return true }
        if let n = number(value) { return n == 65535 || n == 65534 }
        let text = String(describing: value).trimmingCharacters(in: .whitespaces).lowercased()
        return text == "0xffff" || text == "65535" || text == "-1"
    }

    static func isFault(_ spec: AttributeSpec, value: Any?) -> Bool? {
        guard spec.group == .fault, spec.key.hasPrefix("Fault") || spec.key.hasPrefix("Gateway_Fault") else {
            return nil
        }
        guard let value else { return nil }
        let text = String(describing: value).trimmingCharacters(in: .whitespaces)
        if noFaultValues.contains(text.lowercased()) { return false }
        // 有些设备把故障描述成 "F.xxx" / 数字
        return true
    }

    /// 把原始值格式化成显示文本。
    static func format(_ spec: AttributeSpec, value: Any?) -> String? {
        guard let value else { return nil }
        let raw = String(describing: value)

        switch spec.style {
        case .status:
            guard let on = isOn(value) else { return raw }
            return on ? "运行中" : "停止"

        case .duration:
            guard let n = number(value) else { return raw }
            let hours = Int(n) / 60, mins = Int(n) % 60
            if hours > 0 { return "\(hours) 小时 \(mins) 分" }
            return "\(mins) 分钟"

        case .temperature:
            // 温度单独走：过滤 -50 / 127.5 这类哨兵值
            guard let n = temperature(value) else { return nil }
            let text = String(format: "%.1f", n)
            if let unit = spec.unit { return "\(text) \(unit)" }
            return text

        case .pressure, .percent, .counter, .raw:
            guard let n = number(value) else { return raw }
            let text: String
            var suffix = spec.unit ?? ""

            if spec.group == .gas && isHexString(raw) {
                // 燃气读数是十六进制定点格式，低三位是小数：
                // "000080bf" = 32991 → 32.991
                //
                // 单位未经确认 —— 集成作者也是原样透传（名字里带 "raw"），
                // 官方文档也没写。所以不标单位，只标「读数」。
                text = String(format: "%.3f", n / 1000)
                suffix = suffix.isEmpty ? "读数" : suffix
            } else {
                switch spec.style {
                case .pressure: text = String(format: "%.2f", n)
                default:        text = n == n.rounded() ? String(Int(n)) : String(format: "%.2f", n)
                }
            }
            return suffix.isEmpty ? text : "\(text) \(suffix)"
        }
    }

    /// 原始值是否为十六进制字符串
    private static func isHexString(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, !t.hasPrefix("0x") else { return false }
        // 纯十进制数字不算
        if t.allSatisfy(\.isNumber) { return false }
        return t.allSatisfy(\.isHexDigit)
    }
}
