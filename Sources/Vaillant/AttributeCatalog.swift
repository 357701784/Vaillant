import SwiftUI

/// 一个传感器/数据点的展示定义。
struct AttributeSpec: Identifiable {
    let key: String          // 云端属性名
    let label: String        // 中文名
    let unit: String?
    let style: Style
    let group: Group

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

    enum Group: String, CaseIterable {
        case temperature = "温度"
        case deviceState = "运行状态"
        case gas = "燃气消耗"
        case water = "用水"
        case fault = "故障与维护"
        case system = "系统"

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
        .init(key: "Flow_Temperature_Setpoint", label: "出水设定温度", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "DHW_setpoint", label: "生活热水设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "DHW_readSetPoint", label: "生活热水读取设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Current_DHW_Setpoint", label: "当前生活热水设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Tank_temperature", label: "水箱温度", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Room_Temperature", label: "室温", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Room_Temperature_Setpoint_Comfort", label: "舒适模式室温设定", unit: "°C", style: .temperature, group: .temperature),
        .init(key: "Room_Temperature_Setpoint_ECO", label: "ECO 模式室温设定", unit: "°C", style: .temperature, group: .temperature),
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

        // 燃气
        .init(key: "gas_ch_consumption_today", label: "采暖燃气（今日）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_ch_consumption_yesterday", label: "采暖燃气（昨日）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_ch_consumption_monthly", label: "采暖燃气（本月）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_ch_consumption_yearly", label: "采暖燃气（今年）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_dhw_consumption_today", label: "热水燃气（今日）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_dhw_consumption_yesterday", label: "热水燃气（昨日）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_dhw_consumption_monthly", label: "热水燃气（本月）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_dhw_consumption_yearly", label: "热水燃气（今年）", unit: nil, style: .counter, group: .gas),
        .init(key: "gas_consumption", label: "燃气累计", unit: nil, style: .counter, group: .gas),
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

    /// 从原始属性里取数值，兼容 Int / Double / String。
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
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
    private static let noFaultValues: Set<String> = [
        "", "-", "--", "0", "0.0", "none", "null", "no fault", "ok",
    ]

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

        case .temperature, .pressure, .percent, .counter, .raw:
            guard let n = number(value) else { return raw }
            let text: String
            switch spec.style {
            case .temperature: text = String(format: "%.1f", n)
            case .pressure:    text = String(format: "%.2f", n)
            default:           text = n == n.rounded() ? String(Int(n)) : String(format: "%.2f", n)
            }
            if let unit = spec.unit { return "\(text) \(unit)" }
            return text
        }
    }
}
