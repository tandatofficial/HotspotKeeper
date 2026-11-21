import Foundation
import AVFoundation
import UIKit

// MARK: - C / IOKit Private Declarations for Power Management
// Trong TrollStore (có entitlement platform-application và no-sandbox),
// ta có thể gọi trực tiếp IOPMAssertionCreateWithName để cấm kernel powerd tắt CPU/Wi-Fi.
typealias IOPMAssertionID = UInt32
typealias IOReturn = Int32

@_silgen_name("IOPMAssertionCreateWithName")
func IOPMAssertionCreateWithName(
    _ assertionType: CFString,
    _ assertionLevel: UInt32,
    _ assertionName: CFString,
    _ assertionID: UnsafeMutablePointer<IOPMAssertionID>
) -> IOReturn

@_silgen_name("IOPMAssertionRelease")
func IOPMAssertionRelease(_ assertionID: IOPMAssertionID) -> IOReturn

// MARK: - Hotspot Engine
class HotspotEngine: ObservableObject {
    static let shared = HotspotEngine()

    @Published var isActive: Bool = false
    @Published var uptimeSeconds: Int = 0
    @Published var packetsSent: Int = 0
    @Published var connectedClients: Int = 0
    @Published var batteryLevel: Int = 100
    @Published var batteryState: String = "Đang sạc"
    @Published var statusMessage: String = "Sẵn sàng kích hoạt"

    private var powerAssertionID: IOPMAssertionID = 0
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var pingTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var udpSocket: Int32 = -1

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryInfo()
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
        statusMessage = "Đang duy trì điểm phát sóng 24/7"

        // 1. Khóa Power Management (IOKit) cấm CPU và Wi-Fi đi ngủ
        acquirePowerAssertion()

        // 2. Chạy luồng âm thanh tĩnh nền (Silent Audio Background Session)
        startSilentAudioSession()

        // 3. Khởi tạo socket gửi packet mồi định kỳ vào dải mạng Hotspot (bridge100 / 172.20.10.x)
        setupUDPSocket()
        startNetworkKeepAlive()

        // 4. Bật Background Task watchdog
        startBackgroundTaskWatchdog()

        // 5. Timer đếm giờ và cập nhật pin
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

        // Hủy timer
        timer?.invalidate()
        timer = nil
        pingTimer?.invalidate()
        pingTimer = nil

        // Giải phóng IOKit Power Assertion
        releasePowerAssertion()

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

    // MARK: - 1. IOKit Assertion: Chống Deep Sleep
    private func acquirePowerAssertion() {
        let reason = "HotspotKeeper 24/7 Keep-Alive" as CFString
        let type = "PreventSystemSleep" as CFString
        let result = IOPMAssertionCreateWithName(type, 255, reason, &powerAssertionID)
        if result == 0 {
            print("[HotspotKeeper] Đã khóa thành công IOKit PreventSystemSleep (ID: \(powerAssertionID))")
        } else {
            print("[HotspotKeeper] Không thể lấy IOKit Assertion, mã lỗi: \(result)")
        }
    }

    private func releasePowerAssertion() {
        if powerAssertionID != 0 {
            _ = IOPMAssertionRelease(powerAssertionID)
            print("[HotspotKeeper] Đã giải phóng IOKit Assertion ID: \(powerAssertionID)")
            powerAssertionID = 0
        }
    }

    // MARK: - 2. Silent Audio Background Loop
    private func startSilentAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Tạo buffer âm thanh tĩnh 1 giây (pure silence) hoàn toàn trong RAM (không cần file mp3 ngoài)
            let silentWavData = createSilentWavData()
            audioPlayer = try AVAudioPlayer(data: silentWavData)
            audioPlayer?.numberOfLoops = -1 // Lặp vô hạn
            audioPlayer?.volume = 0.01 // Âm lượng cực nhỏ (không phát ra tiếng động)
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            print("[HotspotKeeper] Đã khởi chạy Silent Audio Background Loop")
        } catch {
            print("[HotspotKeeper] Lỗi khởi tạo Audio Session: \(error)")
        }
    }

    // Hàm tạo file WAV 16-bit PCM rỗng trong bộ nhớ RAM
    private func createSilentWavData() -> Data {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let durationSeconds: Int = 1
        let numSamples = sampleRate * Int32(durationSeconds)
        let subChunk2Size = numSamples * Int32(channels) * Int32(bitsPerSample / 8)
        let chunkSize = 36 + subChunk2Size

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt subchunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = channels * (bitsPerSample / 8)
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        // data subchunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: subChunk2Size.littleEndian) { Array($0) })
        // Silent PCM samples (zeros)
        data.append(Data(count: Int(subChunk2Size)))
        return data
    }

    // MARK: - 3. Network Keep-Alive Socket (bridge100 Subnet Ping)
    private func setupUDPSocket() {
        udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        guard udpSocket >= 0 else { return }

        var broadcastEnable: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startNetworkKeepAlive() {
        // Gửi gói tin mồi định kỳ mỗi 5 giây
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.sendKeepAlivePacket()
        }
    }

    private func sendKeepAlivePacket() {
        guard udpSocket >= 0 else { return }

        // Subnet mặc định của iOS Personal Hotspot là 172.20.10.x
        // Broadcast IP là 172.20.10.15:9999
        let targets = ["172.20.10.15", "255.255.255.255"]
        let message = "HOTSPOT_KEEPALIVE"
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

    // MARK: - 4. Background Task Watchdog
    private func startBackgroundTaskWatchdog() {
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "HotspotKeepAliveTask") { [weak self] in
            // Khi hệ thống yêu cầu kết thúc, tự động tạo chu kỳ task mới
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

    // MARK: - 5. Battery Monitoring
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

    // Format thời gian đã giữ sóng
    var formattedUptime: String {
        let hours = uptimeSeconds / 3600
        let minutes = (uptimeSeconds % 3600) / 60
        let seconds = uptimeSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
