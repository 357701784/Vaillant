import SwiftUI

@main
struct VaillantApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        switch store.phase {
        case .signedOut:
            LoginView()

        case .loadingDevices:
            ProgressView("正在读取设备…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))

        case .ready:
            // 多设备时先给选择页，单设备时直接进主界面
            if store.devices.count > 1 {
                NavigationStack { DeviceListView() }
            } else {
                DashboardView()
            }
        }
    }
}
