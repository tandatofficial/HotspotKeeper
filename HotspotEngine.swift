import Foundation
import CoreFoundation
import AVFoundation
import UIKit
import Darwin

// MARK: - Dynamic Function Signatures for Private Frameworks

// 1. IOKit Power Management
typealias IOPMAssertionCreateWithNameFunc = @convention(c) (CFString, UInt32, CFString, UnsafeMutablePointer<UInt32>) -> Int32
typealias IOPMAssertionReleaseFunc = @convention(c) (UInt32) -> Int32

// 2. MobileWiFi Private Framework (Tự động bật và ép giữ sóng Hotspot)
typealias WiFiManagerClientCreateFunc = @convention(c) (OpaquePointer?, Int32) -> OpaquePointer?
typealias WiFiManagerClientGetMISStateFunc = @convention(c) (OpaquePointer) -> Int32
typealias WiFiManagerClientSetMISStateFunc = @convention(c) (OpaquePointer, Int32) -> Void
typealias WiFiManagerClientSetMISDiscoveryStateFunc = @convention(c) (OpaquePointer, Int32) -> Void
typealias WiFiManagerClientGetMISDiscoveryStateFunc = @convention(c) (OpaquePointer) -> Int32

class HotspotEngine: ObservableObject {
    static let shared = HotspotEngine()

    @Published var isActive: Bool = false
    @Published var uptimeSeconds: Int = 0
    @Published var packetsSent: Int = 0
    @Published var batteryLevel: Int = 100
    @Published var batteryState: String = "Đang sạc"
    @Published var statusMessage: String = "Sẵn sàng kích hoạt"
    @Published var isHardwareHotspotActive: Bool = false

    private var powerAssertionID1: UInt32 = 0
    private var powerAssertionID2: UInt32 = 0
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var pingTimer: Timer?
    private var discoveryTimer: Timer?
    private var networkHeartbeatTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var udpSocket: Int32 = -1

    // Function pointers
    private var pmaCreateFunc: IOPMAssertionCreateWithNameFunc?
    private var pmaReleaseFunc: IOPMAssertionReleaseFunc?
    private var wifiCreateFunc: WiFiManagerClientCreateFunc?
    private var wifiGetMISFunc: WiFiManagerClientGetMISStateFunc?
    private var wifiSetMISFunc: WiFiManagerClientSetMISStateFunc?
    private var wifiSetDiscFunc: WiFiManagerClientSetMISDiscoveryStateFunc?
    private var wifiGetDiscFunc: WiFiManagerClientGetMISDiscoveryStateFunc?

    private var wifiManager: OpaquePointer?

    init() {
        resolvePrivateSymbols()
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryInfo()
    }

    private func resolvePrivateSymbols() {
        // 1. IOKit
        if let handle = dlopen(nil, RTLD_NOW) {
            if let symCreate = dlsym(handle, "IOPMAssertionCreateWithName") {
                pmaCreateFunc = unsafeBitCast(symCreate, to: IOPMAssertionCreateWithNameFunc.self)
            }
            if let symRelease = dlsym(handle, "IOPMAssertionRelease") {
                pmaReleaseFunc = unsafeBitCast(symRelease, to: IOPMAssertionReleaseFunc.self)
            }
        }

        // 2. MobileWiFi Private Framework
        let mobileWiFiPaths = [
            "/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi",
            "/System/Library/Frameworks/MobileWiFi.framework/MobileWiFi"
        ]

        var wifiHandle: UnsafeMutableRawPointer? = nil
        for path in mobileWiFiPaths {
            wifiHandle = dlopen(path, RTLD_NOW)
            if wifiHandle != nil { break }
        }

        if let handle = wifiHandle {
            if let symCreate = dlsym(handle, "WiFiManagerClientCreate") {
                wifiCreateFunc = unsafeBitCast(symCreate, to: WiFiManagerClientCreateFunc.self)
            }
            if let symGetMIS = dlsym(handle, "WiFiManagerClientGetMISState") {
                wifiGetMISFunc = unsafeBitCast(symGetMIS, to: WiFiManagerClientGetMISStateFunc.self)
            }
            if let symSetMIS = dlsym(handle, "WiFiManagerClientSetMISState") {
                wifiSetMISFunc = unsafeBitCast(symSetMIS, to: WiFiManagerClientSetMISStateFunc.self)
            }
            if let symSetDisc = dlsym(handle, "WiFiManagerClientSetMISDiscoveryState") {
                wifiSetDiscFunc = unsafeBitCast(symSetDisc, to: WiFiManagerClientSetMISDiscoveryStateFunc.self)
            }
            if let symGetDisc = dlsym(handle, "WiFiManagerClientGetMISDiscoveryState") {
                wifiGetDiscFunc = unsafeBitCast(symGetDisc, to: WiFiManagerClientGetMISDiscoveryStateFunc.self)
            }
            print("[HotspotKeeper] Đã liên kết thành công MobileWiFi.framework")
        }
    }

    // MARK: - Bật / Tắt Khóa Giữ Sóng Hotspot
    func toggleKeepAlive() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        uptimeSeconds = 0
        packetsSent = 0
        statusMessage = "Đang ép bật và khóa giữ sóng Wi-Fi 24/7"

        // 1. Tự động ép bật phần cứng Hotspot qua MobileWiFi
        enableHardwareHotspot(enable: true)

        // 2. Khóa Power Management (IOKit) cấm CPU, Baseband và Wi-Fi đi ngủ
        acquirePowerAssertions()

        // 3. Chạy luồng âm thanh tĩnh nền (Silent Audio Background Session)
        startSilentAudioSession()

        // 4. Khởi tạo socket gửi packet mồi định kỳ vào dải mạng Hotspot (bridge100 / 172.20.10.x)
        setupUDPSocket()
        startNetworkKeepAlive()

        // 5. Bật Discovery Beacon Loop liên tục để máy tính không bao giờ mất sóng
        startDiscoveryLoop()

        // 6. Gửi Heartbeat mạng 4G định kỳ tránh nhà mạng ngắt kết nối rảnh (RRC idle)
        startCellularHeartbeat()

        // 7. Bật Background Task watchdog
        startBackgroundTaskWatchdog()

        // 8. Timer đếm giờ và cập nhật pin
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.uptimeSeconds += 1
            self.updateBatteryInfo()
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        statusMessage = "Đã dừng duy trì"

        // Hủy timers
        timer?.invalidate(); timer = nil
        pingTimer?.invalidate(); pingTimer = nil
        discoveryTimer?.invalidate(); discoveryTimer = nil
        networkHeartbeatTimer?.invalidate(); networkHeartbeatTimer = nil

        // Giải phóng IOKit Power Assertions
        releasePowerAssertions()

        // Dừng Audio
        audioPlayer?.stop()
        audioPlayer = nil

        // Đóng Socket
        if udpSocket >= 0 {
            close(udpSocket)
            udpSocket = -1
        }

        // Kết thúc Background task
        endBackgroundTask()
    }

    // MARK: - 1. MobileWiFi: Tự động Bật & Ép Giữ Trạng Thái Phát Sóng
    private func enableHardwareHotspot(enable: Bool) {
        guard let createFunc = wifiCreateFunc else {
            print("[HotspotKeeper] Không tìm thấy WiFiManagerClientCreate")
            return
        }

        if wifiManager == nil {
            wifiManager = createFunc(nil, 0)
        }

        guard let manager = wifiManager else {
            print("[HotspotKeeper] Không thể khởi tạo WiFiManagerRef")
            return
        }

        let state: Int32 = enable ? 1 : 0

        // Gạt công tắc phát Hotspot phần cứng
        if let setMIS = wifiSetMISFunc {
            setMIS(manager, state)
            print("[HotspotKeeper] Đã gọi WiFiManagerClientSetMISState(\(state))")
        }

        // Kích hoạt chế độ phát hiện liên tục (Broadcast Discovery State)
        if let setDisc = wifiSetDiscFunc {
            setDisc(manager, state)
            print("[HotspotKeeper] Đã gọi WiFiManagerClientSetMISDiscoveryState(\(state))")
        }

        DispatchQueue.main.async {
            self.isHardwareHotspotActive = enable
        }
    }

    private func startDiscoveryLoop() {
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, let manager = self.wifiManager, let setDisc = self.wifiSetDiscFunc else { return }
            setDisc(manager, 1)
        }
    }

    // MARK: - 2. IOKit Assertions: Chống Deep Sleep toàn diện
    private func acquirePowerAssertions() {
        guard let createFunc = pmaCreateFunc else { return }

        // Khóa 1: Cấm hệ thống ngủ sâu
        let reason1 = "HotspotKeeper System Sleep Lock" as CFString
        let type1 = "PreventSystemSleep" as CFString
        _ = createFunc(type1, 255, reason1, &powerAssertionID1)

        // Khóa 2: Cấm CPU nhàn rỗi tắt các tiến trình mạng
        let reason2 = "HotspotKeeper Idle Lock" as CFString
        let type2 = "PreventUserIdleSystemSleep" as CFString
        _ = createFunc(type2, 255, reason2, &powerAssertionID2)
    }

    private func releasePowerAssertions() {
        guard let releaseFunc = pmaReleaseFunc else { return }
        if powerAssertionID1 != 0 {
            _ = releaseFunc(powerAssertionID1)
            powerAssertionID1 = 0
        }
        if powerAssertionID2 != 0 {
            _ = releaseFunc(powerAssertionID2)
            powerAssertionID2 = 0
        }
    }

    // MARK: - 3. Silent Audio Background Loop
    private func startSilentAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let silentWavData = createSilentWavData()
            audioPlayer = try AVAudioPlayer(data: silentWavData)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 0.01
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("[HotspotKeeper] Lỗi khởi tạo Audio Session: \(error)")
        }
    }

    private func createSilentWavData() -> Data {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let durationSeconds: Int = 1
        let numSamples = sampleRate * Int32(durationSeconds)
        let subChunk2Size = numSamples * Int32(channels) * Int32(bitsPerSample / 8)
        let chunkSize = 36 + subChunk2Size

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: subChunk2Size.littleEndian) { Array($0) })
        data.append(Data(count: Int(subChunk2Size)))
        return data
    }

    // MARK: - 4. UDP Broadcast Keep-Alive
    private func setupUDPSocket() {
        udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpSocket >= 0 else { return }

        var broadcastEnable: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startNetworkKeepAlive() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.sendKeepAlivePacket()
        }
    }

    private func sendKeepAlivePacket() {
        guard udpSocket >= 0 else { return }

        let targets = ["172.20.10.15", "255.255.255.255", "172.20.10.2", "172.20.10.3"]
        let message = "HOTSPOT_ALIVE"
        let msgData = [UInt8](message.utf8)

        for ip in targets {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9999).bigEndian
            inet_pton(AF_INET, ip, &addr.sin_addr)

            let sent = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udpSocket, msgData, msgData.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent > 0 {
                DispatchQueue.main.async {
                    self.packetsSent += 1
                }
            }
        }
    }

    // MARK: - 5. Heartbeat 4G duy trì kết nối nhà mạng không bị nghẽn/ngủ
    private func startCellularHeartbeat() {
        networkHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
            guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    // MARK: - 6. Background Task Watchdog
    private func startBackgroundTaskWatchdog() {
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "HotspotKeepAliveTask") { [weak self] in
            self?.renewBackgroundTask()
        }
    }

    private func renewBackgroundTask() {
        endBackgroundTask()
        if isActive {
            startBackgroundTaskWatchdog()
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - 7. Battery Monitoring
    private func updateBatteryInfo() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? Int(level * 100) : 100

        switch UIDevice.current.batteryState {
        case .charging: batteryState = "Đang sạc"
        case .full: batteryState = "Đã đầy"
        case .unplugged: batteryState = "Dùng pin"
        default: batteryState = "Không rõ"
        }
    }

    var formattedUptime: String {
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        let seconds = uptimeSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
