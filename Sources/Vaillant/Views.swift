import SwiftUI
import UIKit

// MARK: - 卡片与行

struct Card<Content: View>: View {
    let title: String?
    let systemImage: String?
    let content: Content

    init(_ title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// 一行「标签 — 值」。值按类型着色，故障值高亮。
struct DataRow: View {
    let spec: AttributeSpec
    let value: Any?

    private var formatted: String? { Catalog.format(spec, value: value) }

    private var isFault: Bool { Catalog.isFault(spec, value: value) == true }

    var body: some View {
        HStack {
            Text(spec.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let formatted {
                Text(formatted)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(isFault ? Color.red : Color.primary)
            } else {
                Text("—")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 登录

struct LoginView: View {
    @EnvironmentObject var store: AppStore

    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @FocusState private var field: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("威能热水器")
                    .font(.title2.weight(.semibold))
                Text("直接连接威能云，显示官方 App 不给你看的运行数据")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 32)

            VStack(spacing: 12) {
                TextField("手机号 / 账号", text: $username)
                    .textContentType(.username)
                    .keyboardType(.phonePad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
                    .modifier(PaddedField())

                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .focused($field, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await signIn() } }
                    .modifier(PaddedField())
            }
            .padding(.horizontal, 32)

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
            }

            Button {
                Task { await signIn() }
            } label: {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text("登录")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .disabled(busy || username.isEmpty || password.isEmpty)

            Spacer()

            Text("账号密码仅用于向威能云换取 token，不会保存在本 App 之外的任何地方")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func signIn() async {
        busy = true
        field = nil
        await store.signIn(username: username, password: password)
        busy = false
    }
}

private struct PaddedField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 设备选择

struct DeviceListView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        List(store.devices) { device in
            Button {
                store.select(device)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(device.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !device.online {
                        Text("离线")
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle("选择设备")
    }
}

// MARK: - 状态条

struct ConnectionBanner: View {
    let state: MonitorClient.State
    let lastUpdate: Date?
    let diagnostic: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicator)
                    .frame(width: 7, height: 7)
                Text(message)
                    .font(.caption)
                Spacer()
                if case .failed = state {
                    Button("重试", action: onRetry)
                        .font(.caption.weight(.semibold))
                } else if let lastUpdate {
                    Text(lastUpdate, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // 连不上时把服务端原话显示出来，省去反复猜测
            if let diagnostic, state != .live {
                Text(diagnostic)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(indicator.opacity(0.12))
    }

    private var indicator: Color {
        switch state {
        case .live: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var message: String {
        switch state {
        case .live:
            // 超过 3 分钟没更新，多半是设备离线了
            if let lastUpdate, Date().timeIntervalSince(lastUpdate) > 180 { return "设备可能已离线" }
            return "实时连接正常"
        case .connecting: return "连接中…"
        case .reconnecting(let n): return "重连中（第 \(n) 次）"
        case .failed(let m): return m
        case .idle: return "未连接"
        }
    }
}

// MARK: - 温度调节卡（地暖 / 生活热水共用）

/// 设定温度调节器。地暖和生活热水的结构一样，只是字段、范围和开关键不同。
struct SetpointCard: View {
    @EnvironmentObject var store: AppStore

    let title: String
    let icon: String
    let setpointKeys: [String]
    let enableKeys: [String]
    /// 下发设定温度用的键
    let writeSetpointKey: String
    /// 下发开关用的键；nil 表示不提供开关
    let writeEnableKey: String?
    /// 开关旁的文字，说明控制什么
    let switchLabel: String
    let fallbackMin: Double
    let fallbackMax: Double
    let step: Double
    let attrs: [String: Any]

    /// 上下限优先用设备上报的值。硬编码的范围来自集成源码的兜底常量，
    /// 未必符合本机 —— 超出真实上限会让云端返回 500。
    private var minTemp: Double {
        ReadAttr.firstNumber([ReadAttr.dhwLowerLimitKey], in: attrs) ?? fallbackMin
    }
    private var maxTemp: Double {
        ReadAttr.firstNumber([ReadAttr.dhwUpperLimitKey], in: attrs) ?? fallbackMax
    }

    private var setpoint: Double? {
        ReadAttr.first(setpointKeys, in: attrs).flatMap { Catalog.number($0) }
    }
    private var enabled: Bool? {
        ReadAttr.first(enableKeys, in: attrs).flatMap { Catalog.isOn($0) }
    }
    /// 界面显示的值。
    ///
    /// 直接用 setpoint —— 它来自 monitor.attrs，而乐观更新是同步写入的，
    /// 所以连按多次时每次都能看到最新的累计值。
    private var displayValue: Double? { setpoint }

    /// 该通道是否真的可用（网关会推 0 表示未启用）
    private var available: Bool { (setpoint ?? 0) > 0 }

    /// 该通道是否用采暖曲线控制（地暖）
    private var curveControlled: Bool { writeSetpointKey == WritableAttr.setpointComfort }

    /// 温度调节的前置条件。
    ///
    /// 不要求通道开启 —— 实测关闭状态下也能改温度（用户确认过），
    /// 之前的 500 是写错了字段，不是前置校验。
    ///
    /// 发送期间也必须能继续按，否则连按 5 次只会生效 1 次。
    private var canAdjust: Bool { available }

    var body: some View {
        Card(title, systemImage: icon) {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("目标温度")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(displayValue.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 42, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("°C")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    step("−", delta: -step)
                    step("+", delta: step)

                    if let key = writeEnableKey {
                        Spacer(minLength: 8)
                        // 原生 Toggle：滑动圆钮直接表达开/关，
                        // 旁边的文字说明这个开关控制什么。
                        Toggle(isOn: Binding(
                            get: { enabled ?? false },
                            set: { newValue in
                                store.send([key: newValue ? 1 : 0])
                            }
                        )) {
                            Text(switchLabel)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle((enabled ?? false) ? Color.orange : Color.secondary)
                        }
                        .toggleStyle(.switch)
                        .fixedSize()
                        // 不因温度指令在飞行中而禁用 —— 开关和温度是
                        // 两个独立属性，队列能同时容纳（key 不同不冲突）。
                    }
                }

                if !available {
                    // 这类机型的地暖不是「室温设定」控制，而是靠采暖曲线调节。
                    // 室温设定恒为 0，不该显示成一个看起来能调的数字。
                    VStack(alignment: .leading, spacing: 4) {
                        Text(curveControlled
                             ? "该机型用采暖曲线控制，无室温设定值"
                             : "云端未返回该通道的设定值")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if curveControlled, let curve = Catalog.number(attrs["Heating_Curve"]) {
                            Text("当前采暖曲线：\(String(format: "%.2f", curve))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func step(_ title: String, delta: Double) -> some View {
        let usable = canAdjust
            && (displayValue.map { $0 + delta >= minTemp && $0 + delta <= maxTemp } ?? false)

        return Button {
            // 累加逻辑放在 store 层：基准值取自同步更新的 attrs，
            // 连按多次才能逐次累加（用 View 的 @State 会丢按压）。
            store.stepTemperature(
                key: writeSetpointKey,
                readKeys: setpointKeys,
                delta: delta,
                min: minTemp,
                max: maxTemp
            )
        } label: {
            Text(title)
                .font(.title2.weight(.medium))
                .frame(width: 52, height: 46)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(usable ? 1 : 0.35)
    }
}

// MARK: - 首屏温度对比

/// 出水/回水温度对比条 —— 官方 App 不显示这两个数，
/// 但它们才是判断热水器工况的关键（温差大 = 水箱不够热或流量不足）。
struct TemperatureCompareCard: View {
    let flow: Double?
    let ret: Double?

    private var delta: Double? {
        guard let flow, let ret else { return nil }
        return flow - ret
    }

    var body: some View {
        Card("出水 / 回水", systemImage: "thermometer.transmission") {
            VStack(spacing: 14) {
                HStack(alignment: .bottom, spacing: 20) {
                    reading("出水", value: flow, color: .orange)
                    reading("回水", value: ret, color: .blue)
                    Spacer()
                    if let delta {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(delta, format: .number.precision(.fractionLength(1)))
                                .font(.title2.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .foregroundStyle(deltaColor(delta))
                            Text("温差")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let flow, let ret {
                    bar(flow: flow, ret: ret)
                }
            }
        }
    }

    private func reading(_ label: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                Text(value, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(color)
            } else {
                Text("—")
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 两条相对长度按当前读数归一化的横条
    private func bar(flow: Double, ret: Double) -> some View {
        let peak = max(flow, ret, 1)
        return VStack(spacing: 5) {
            track(value: flow, peak: peak, color: .orange)
            track(value: ret, peak: peak, color: .blue)
        }
    }

    private func track(value: Double, peak: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(6, geo.size.width * (value / peak)))
            }
        }
        .frame(height: 7)
    }

    /// 温差过大通常意味着水箱水量不足或流量偏低
    private func deltaColor(_ d: Double) -> Color {
        if d > 25 { return .red }
        if d > 18 { return .orange }
        return .primary
    }
}

// MARK: - 分组数据

struct AttributeGroupView: View {
    let group: AttributeSpec.Group
    let attrs: [String: Any]

    /// 该组里云端实际有值的项，哨兵值（65535 等）不算。
    private var items: [AttributeSpec] {
        Catalog.specs.filter { spec in
            guard spec.group == group else { return false }
            guard let value = attrs[spec.key] else { return false }
            // 65535 = 0xFFFF 是「无内容」占位值，显示出来只是噪音
            return !Catalog.isSentinel(value)
        }
    }

    /// 故障组里真的有故障的项
    private var activeFaults: [AttributeSpec] {
        items.filter { Catalog.isFault($0, value: attrs[$0.key]) == true }
    }

    /// 故障组里不是故障码的项（如保养剩余时间）
    private var otherItems: [AttributeSpec] {
        items.filter { Catalog.isFault($0, value: attrs[$0.key]) == nil }
    }

    var body: some View {
        // 故障组即使没有故障也显示 —— 让用户知道确实在监控，
        // 而不是怀疑这个功能没工作
        if !items.isEmpty || group == .fault {
            Card(group.rawValue, systemImage: group.icon) {
                VStack(spacing: 0) {
                    if group == .fault {
                        if activeFaults.isEmpty {
                            // 故障码槽位全是 0xFFFF —— 明确说「无故障」，
                            // 而不是让用户对着 11 行 65535 猜
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("无故障")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            if !otherItems.isEmpty { Divider() }
                        } else {
                            ForEach(Array(activeFaults.enumerated()), id: \.element.id) { index, spec in
                                DataRow(spec: spec, value: attrs[spec.key])
                                if index < activeFaults.count - 1 { Divider() }
                            }
                            if !otherItems.isEmpty { Divider() }
                        }
                        ForEach(Array(otherItems.enumerated()), id: \.element.id) { index, spec in
                            DataRow(spec: spec, value: attrs[spec.key])
                            if index < otherItems.count - 1 { Divider() }
                        }
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, spec in
                            DataRow(spec: spec, value: attrs[spec.key])
                            if index < items.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 原始数据

/// 云端推了、但目录里没定义的字段。
/// 用来发现官方 App 还有什么藏着不给看。
struct RawDataView: View {
    let attrs: [String: Any]

    private var pairs: [(String, String)] {
        attrs.keys.sorted().map { ($0, String(describing: attrs[$0] ?? "—")) }
    }

    var body: some View {
        Card("全部原始数据（\(attrs.count) 项）", systemImage: "curlybraces") {
            VStack(spacing: 0) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.0)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(pair.1)
                            .font(.subheadline.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    if index < pairs.count - 1 { Divider() }
                }
            }
            .textSelection(.enabled)
        }
    }
}

// MARK: - 调试日志

struct DebugLogView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Card("构建信息", systemImage: "info.circle") {
                        Text("版本 \(BuildInfo.version)")
                            .font(.footnote.monospaced())
                        Text("构建于 \(BuildInfo.timestamp)")
                            .font(.footnote.monospaced())
                        Text("设备 \(store.device?.id ?? "未选择")")
                            .font(.footnote.monospaced())
                        Text("mac \(store.device?.mac ?? "-")")
                            .font(.footnote.monospaced())
                    }

                    Card("连接事件（\(store.monitor.log.count) 条）", systemImage: "list.bullet.rectangle") {
                        if store.monitor.log.isEmpty {
                            Text("暂无记录")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(store.monitor.log.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(line.contains("❌") ? .red : .primary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清空") { store.monitor.clearLog() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = store.monitor.log.joined(separator: "\n")
                        } label: {
                            Label("复制全部日志", systemImage: "doc.on.doc")
                        }
                        Button {
                            store.monitor.clearLog()
                            store.reconnect()
                        } label: {
                            Label("清空并重新连接", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

enum BuildInfo {
    static let version = "3.1-ws-delegate"
    /// CI 会用实际构建时间戳覆盖
    static let timestamp = Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String ?? "未注入"
}

// MARK: - 主界面

// MARK: - 共用框架

/// 两页共用的外壳：导航栈 + 连接状态条 + 错误提示 + 工具栏。
/// 两页共用的内容区：状态条 + 滚动内容 + 错误提示。
/// 导航栈和工具栏由各页自己声明（工具栏项的类型和页面绑定更顺）。
struct MonitorScaffold<Content: View>: View {
    @EnvironmentObject var store: AppStore

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var attrs: [String: Any] { store.monitor.attrs }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ConnectionBanner(
                    state: store.monitor.state,
                    lastUpdate: store.monitor.lastUpdate,
                    diagnostic: store.monitor.diagnostic
                ) {
                    store.reconnect()
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if attrs.isEmpty {
                    ContentUnavailableView(
                        "等待数据",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("正在等待设备上报属性")
                    )
                    .padding(.top, 60)
                } else {
                    content
                }
            }
            .padding(16)
        }
        .overlay(alignment: .bottom) { ErrorToast() }
        .background(Color(.systemGroupedBackground))
    }
}

/// 控制失败提示条。指令常被云端静默忽略，没有提示用户会以为按钮坏了。
struct ErrorToast: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let error = store.errorMessage {
            VStack {
                Spacer()
                Text(error)
                    .font(.footnote)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            store.errorMessage = nil
                        }
                    }
            }
            .animation(.easeInOut, value: store.errorMessage)
        }
    }
}

// MARK: - 首页

/// 首页：只放控制类卡片 —— 生活热水、地暖、出水/回水。
struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAccount = false

    private var attrs: [String: Any] { store.monitor.attrs }

    var body: some View {
        NavigationStack {
            MonitorScaffold {
                SetpointCard(
                title: "生活热水",
                icon: "drop.fill",
                setpointKeys: ReadAttr.dhwSetpointKeys,
                enableKeys: ReadAttr.dhwEnableKeys,
                writeSetpointKey: WritableAttr.dhwSetpoint,
                writeEnableKey: WritableAttr.dhwEnable,
                switchLabel: "热水",
                fallbackMin: 35, fallbackMax: 65,
                // 集成用 PRECISION_HALVES，支持 0.5 度步进
                step: 0.5,
                attrs: attrs
            )
            SetpointCard(
                title: "地暖",
                icon: "thermometer.medium",
                setpointKeys: [WritableAttr.setpointComfort],
                enableKeys: ReadAttr.heatingEnableKeys,
                writeSetpointKey: WritableAttr.setpointComfort,
                writeEnableKey: WritableAttr.heatingEnable,
                switchLabel: "采暖",
                fallbackMin: 10, fallbackMax: 30,
                step: 0.5,
                attrs: attrs
            )
                TemperatureCompareCard(
                    flow: Catalog.temperature(attrs["Flow_temperature"]),
                    ret: Catalog.temperature(attrs["return_temperature"])
                )
            }
            .navigationTitle(store.device?.name ?? "威能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAccount = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.reconnect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showAccount) {
            AccountView()
        }
    }
}

// MARK: - 数据页

/// 数据页：其余的设备读数分组展示。
struct DataView: View {
    @EnvironmentObject var store: AppStore
    @State private var showRaw = false
    @State private var showDebug = false

    private var attrs: [String: Any] { store.monitor.attrs }

    /// 原始数据的纯文本形式，用于一键复制
    private var rawPlainText: String {
        attrs.keys.sorted()
            .map { "\($0) = \(String(describing: attrs[$0] ?? "—"))" }
            .joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            MonitorScaffold {
                ForEach(AttributeSpec.Group.allCases) { group in
                    AttributeGroupView(group: group, attrs: attrs)
                }
            }
            .navigationTitle("数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDebug = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.reconnect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showRaw = true
                    } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                }
            }
        }
        .sheet(isPresented: $showDebug) {
            DebugLogView()
        }
        .sheet(isPresented: $showRaw) {
            NavigationStack {
                ScrollView {
                    RawDataView(attrs: attrs).padding(16)
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("原始数据")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = rawPlainText
                        } label: {
                            Label("复制全部", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }
}

struct AccountView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    LabeledContent("账号", value: store.username ?? "—")
                    LabeledContent("设备 ID", value: store.device?.id ?? "—")
                    if let model = store.device?.model, !model.isEmpty {
                        LabeledContent("型号", value: model)
                    }
                }
                Section {
                    Button("退出登录", role: .destructive) {
                        store.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
