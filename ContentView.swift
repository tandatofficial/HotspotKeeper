import SwiftUI

struct ContentView: View {
    @StateObject private var engine = HotspotEngine.shared
    @State private var isOLEDMode: Bool = false
    @State private var showSettingsAlert: Bool = false

    var body: some View {
        ZStack {
            // Nền tối chuẩn OLED
            Color.black.ignoresSafeArea()

            if isOLEDMode {
                // MARK: - Chế độ Màn hình Đen (OLED Router Mode)
                OLEDClockView(uptime: engine.formattedUptime) {
                    isOLEDMode = false
                }
            } else {
                // MARK: - Giao diện chính
                VStack(spacing: 24) {
                    // Header
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iOS 15.4 • TROLLSTORE • iPHONE 11")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                            Text("HotspotKeeper")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                        }

                        Spacer()

                        Button(action: {
                            isOLEDMode = true
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 12))
                                Text("Màn hình đen")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(14)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    Spacer()

                    // MARK: - Nút Tròn Khổng Lồ Kích Hoạt Giữ Sóng
                    VStack(spacing: 16) {
                        Button(action: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                                engine.toggleKeepAlive()
                            }
                        }) {
                            ZStack {
                                // Vòng sáng bao quanh khi đang hoạt động
                                if engine.isActive {
                                    Circle()
                                        .stroke(Color(red: 0.18, green: 0.82, blue: 0.35).opacity(0.25), lineWidth: 16)
                                        .frame(width: 210, height: 210)
                                        .scaleEffect(engine.isActive ? 1.05 : 1.0)
                                        .animation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: engine.isActive)
                                }

                                Circle()
                                    .fill(
                                        engine.isActive
                                            ? LinearGradient(colors: [Color(red: 0.12, green: 0.65, blue: 0.28), Color(red: 0.08, green: 0.45, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                            : LinearGradient(colors: [Color(white: 0.18), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .frame(width: 180, height: 180)
                                    .shadow(color: engine.isActive ? Color.green.opacity(0.4) : Color.black.opacity(0.5), radius: 20)

                                VStack(spacing: 8) {
                                    Image(systemName: engine.isActive ? "wifi" : "wifi.slash")
                                        .font(.system(size: 46, weight: .semibold))
                                        .foregroundColor(.white)

                                    Text(engine.isActive ? "ĐANG GIỮ PHÁT" : "CHƯA BẬT")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(.white)

                                    if engine.isActive {
                                        Text(engine.formattedUptime)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(Color.white.opacity(0.9))
                                    }
                                }
                            }
                        }

                        Text(engine.statusMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(engine.isActive ? Color(red: 0.18, green: 0.82, blue: 0.35) : Color.gray)
                    }

                    Spacer()

                    // MARK: - Bảng Thông Số Giám Sát Thời Gian Thực
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            StatCard(icon: "clock.fill", title: "Thời gian giữ", value: engine.formattedUptime, color: .blue)
                            StatCard(icon: "paperplane.fill", title: "Gói mồi đã gửi", value: "\(engine.packetsSent) pkts", color: .green)
                        }

                        HStack(spacing: 12) {
                            StatCard(icon: "network", title: "Subnet Hotspot", value: "172.20.10.x", color: .purple)
                            StatCard(icon: "battery.100.bolt", title: "Pin iPhone", value: "\(engine.batteryLevel)% (\(engine.batteryState))", color: .orange)
                        }
                    }
                    .padding(.horizontal, 20)

                    // MARK: - Nút Mở Cài Đặt Điểm Truy Cập Cá Nhân
                    Button(action: openHotspotSettings) {
                        HStack {
                            Image(systemName: "personalhotspot")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Mở Cài đặt Điểm phát sóng iOS")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(Color(white: 0.15))
                        .cornerRadius(16)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private func openHotspotSettings() {
        if let url = URL(string: "App-Prefs:root=INTERNET_TETHERING"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Thẻ Thống Kê
struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(color)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(white: 0.10))
        .cornerRadius(14)
    }
}

// MARK: - Chế độ Màn hình Tối (OLED Mode)
struct OLEDClockView: View {
    let uptime: String
    let onWake: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                Image(systemName: "wifi")
                    .font(.system(size: 32))
                    .foregroundColor(Color.green.opacity(0.7))

                Text("ĐANG GIỮ PHÁT WI-FI 24/7")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.4))

                Text(uptime)
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.8))

                Spacer()

                Text("Chạm 2 lần vào màn hình để mở lại")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.2))
                    .padding(.bottom, 24)
            }
        }
        .onTapGesture(count: 2) {
            onWake()
        }
    }
}
