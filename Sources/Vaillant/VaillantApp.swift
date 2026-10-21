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
            // 多设备时先选一个，选完才进主界面
            if store.device == nil {
                NavigationStack { DeviceListView() }
            } else {
                TabView {
                    HomeView()
                        .tabItem { Label("首页", systemImage: "house.fill") }

                    DataView()
                        .tabItem { Label("数据", systemImage: "chart.bar.xaxis") }
                }
            }
        }
    }
}
