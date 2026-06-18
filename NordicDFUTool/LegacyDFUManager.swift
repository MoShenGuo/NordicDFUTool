import Foundation
import CoreBluetooth
import NordicDFU

/// 设备 OTA 框架类型（全局共享枚举）
enum OTAFrameworkType {
    case mcuManager   // 新版 SMP 协议 (iOSMcuManagerLibrary)
    case nordicDFU    // 旧版 Nordic DFU 协议 (iOSDFULibrary)
    case unknown      // 尚未检测
}

/// 旧版 OTA 升级管理器
/// 用于不支持 SMP 协议（McuManager）的设备
/// 流程：发送 0x47 指令 → 设备进入 DFU Bootloader → 扫描 DFU 设备 → Nordic DFU 升级

protocol LegacyDFUManagerDelegate: AnyObject {
    func legacyDFU(_ manager: LegacyDFUManager, didChangeState description: String)
    func legacyDFU(_ manager: LegacyDFUManager, didUpdateProgress progress: Int, speed: Double, part: Int, totalParts: Int)
    func legacyDFUDidComplete(_ manager: LegacyDFUManager)
    func legacyDFU(_ manager: LegacyDFUManager, didFailWithError error: String)
}

class LegacyDFUManager: NSObject {
    
    weak var delegate: LegacyDFUManagerDelegate?
    
    /// 0x47 指令：通知设备进入 DFU Bootloader 模式
    /// 格式：[0x47, 0, 0, ..., 0, CRC]
    /// CRC = 前15个字节的累加和（取低8位）
    private static var otaCommand: [UInt8] {
        var bytes: [UInt8] = [0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        // 最后一个字节 = 前15个字节的累加校验和
        var sum: UInt8 = 0
        for i in 0..<(bytes.count - 1) {
            sum = sum &+ bytes[i]
        }
        bytes[bytes.count - 1] = sum
        return bytes
    }
    
    /// SMP Service UUID（新版 McuManager 协议标识）
    static let smpServiceUUID = CBUUID(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")
    
    /// DFU 控制器
    private var dfuController: DFUServiceController?
    private var dfuPeripheral: CBPeripheral?
    private var isWaitingForDFU = false
    private var scanTimer: Timer?
    private var firmwareFileURL: URL?
    private var currentPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    // MARK: - 检测 SMP 支持
    
    /// 持有 checker 防止被 ARC 释放
    private static var activeChecker: SMPServiceChecker?
    
    /// 检查设备是否支持 SMP 协议
    static func checkSMPSupport(peripheral: CBPeripheral, completion: @escaping (Bool) -> Void) {
        let checker = SMPServiceChecker(peripheral: peripheral) { result in
            activeChecker = nil  // 检测完成后释放
            completion(result)
        }
        activeChecker = checker  // 强引用保持存活
        checker.start()
    }
    
    /// BLE Service/Characteristic UUID（旧版协议通信用）
    private static let serviceUUID = CBUUID(string: "FFF0")
    private static let sendCharUUID = CBUUID(string: "FFF6")
    
    // MARK: - 开始旧版 OTA
    
    func startLegacyOTA(peripheral: CBPeripheral,
                        firmwareURL: URL,
                        writeCharacteristic: CBCharacteristic?) {
        self.currentPeripheral = peripheral
        self.firmwareFileURL = firmwareURL
        self.writeCharacteristic = writeCharacteristic
        self.isWaitingForDFU = true
        self.dfuPeripheral = nil
        
        delegate?.legacyDFU(self, didChangeState: "正在发送 OTA 指令，设备将进入 DFU 模式...")
        
        // 如果没有传入写特征，尝试从 peripheral 的已发现服务中查找
        if writeCharacteristic == nil {
            if let char = findSendCharacteristic(from: peripheral) {
                self.writeCharacteristic = char
                sendOTACommand(to: peripheral, characteristic: char)
            } else {
                // 还没有发现服务，先发现服务再发送
                discoverAndSendOTA(peripheral: peripheral)
                return
            }
        } else {
            sendOTACommand(to: peripheral, characteristic: writeCharacteristic)
        }
        
        // 设备收到指令后会断开连接并重启进入 DFU Bootloader
        // 等待 3 秒后开始扫描 DFU 设备
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.startScanForDFUDevice()
        }
    }
    
    /// 从 peripheral 已发现的服务中查找 FFF0/FFF6 特征
    private func findSendCharacteristic(from peripheral: CBPeripheral) -> CBCharacteristic? {
        guard let services = peripheral.services else { return nil }
        for service in services {
            if service.uuid == LegacyDFUManager.serviceUUID {
                guard let chars = service.characteristics else { continue }
                for char in chars {
                    if char.uuid == LegacyDFUManager.sendCharUUID {
                        return char
                    }
                }
            }
        }
        return nil
    }
    
    /// 发现服务和特征后再发送 OTA 指令
    private func discoverAndSendOTA(peripheral: CBPeripheral) {
        delegate?.legacyDFU(self, didChangeState: "正在发现设备服务...")
        
        // 保存原始 delegate
        let originalDelegate = peripheral.delegate
        let discoverer = ServiceDiscoverer(peripheral: peripheral, serviceUUID: LegacyDFUManager.serviceUUID, charUUID: LegacyDFUManager.sendCharUUID) { [weak self] characteristic in
            // 恢复原始 delegate
            peripheral.delegate = originalDelegate
            
            guard let self = self else { return }
            if let char = characteristic {
                self.writeCharacteristic = char
                self.sendOTACommand(to: peripheral, characteristic: char)
                // 发送后等待 3 秒开始扫描
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.startScanForDFUDevice()
                }
            } else {
                self.delegate?.legacyDFU(self, didFailWithError: "未找到设备通信特征 (FFF0/FFF6)")
            }
        }
        discoverer.start()
    }
    
    /// 直接扫描 DFU 设备（设备已在 DFU 模式）
    func startScanDirectly(firmwareURL: URL) {
        self.firmwareFileURL = firmwareURL
        self.isWaitingForDFU = true
        self.dfuPeripheral = nil
        
        delegate?.legacyDFU(self, didChangeState: "正在扫描 DFU 设备...")
        startScanForDFUDevice()
    }
    
    func abort() {
        _ = dfuController?.abort()
        dfuController = nil
        stopScanTimer()
        isWaitingForDFU = false
        BLEManager.shared.stopScan()
        BLEManager.shared.onPeripheralDiscovered = nil
        BLEManager.shared.onConnected = nil
        BLEManager.shared.onDisconnected = nil
    }
    
    /// DFU 完成或失败后的清理
    private func cleanup() {
        dfuController = nil
        stopScanTimer()
        isWaitingForDFU = false
        dfuPeripheral = nil
        BLEManager.shared.stopScan()
        BLEManager.shared.onPeripheralDiscovered = nil
        BLEManager.shared.onConnected = nil
        BLEManager.shared.onDisconnected = nil
    }
    
    // MARK: - 发送 OTA 指令
    
    private func sendOTACommand(to peripheral: CBPeripheral, characteristic: CBCharacteristic?) {
        guard let char = characteristic else {
            delegate?.legacyDFU(self, didFailWithError: "未找到写入特征 (FFF6)")
            return
        }
        let data = Data(LegacyDFUManager.otaCommand)
        peripheral.writeValue(data, for: char, type: .withResponse)
        delegate?.legacyDFU(self, didChangeState: L10n.s("OTA 指令已发送，等待设备重启...", "OTA command sent, waiting for device restart..."))
    }
    
    // MARK: - 扫描 DFU 设备
    
    /// 开始扫描/查找 DFU 设备
    /// 策略：先查已连接的 DFU 设备（中断恢复场景），再广播扫描
    private func startScanForDFUDevice() {
        delegate?.legacyDFU(self, didChangeState: L10n.s("正在查找 DFU 设备...", "Looking for DFU device..."))
        
        // 策略1：先检查系统中是否已有连接的 DFU 设备（上次中断后设备可能还在连接状态）
        let dfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123") // Nordic DFU Service
        let connectedPeripherals = BLEManager.shared.centralManager.retrieveConnectedPeripherals(withServices: [dfuServiceUUID])
        
        if let dfuDevice = connectedPeripherals.first {
            NSLog("[LegacyDFU] 找到已连接的 DFU 设备: \(dfuDevice.name ?? "Unknown")")
            self.isWaitingForDFU = false
            self.dfuPeripheral = dfuDevice
            delegate?.legacyDFU(self, didChangeState: L10n.s("已找到 DFU 设备（已连接）: \(dfuDevice.name ?? "DFU")\n正在开始固件升级...", "Found DFU device (connected): \(dfuDevice.name ?? "DFU")\nStarting firmware upgrade..."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startDFUProcess()
            }
            return
        }
        
        // 策略2：广播扫描名称中包含 "DFU" 的设备
        delegate?.legacyDFU(self, didChangeState: L10n.s("正在扫描 DFU 设备...", "Scanning for DFU device..."))
        
        BLEManager.shared.onPeripheralDiscovered = { [weak self] peripherals in
            guard let self = self, self.isWaitingForDFU else { return }
            
            for peripheral in peripherals {
                guard let name = peripheral.name else { continue }
                if name.uppercased().contains("DFU") {
                    self.isWaitingForDFU = false
                    self.dfuPeripheral = peripheral
                    BLEManager.shared.stopScan()
                    self.stopScanTimer()
                    
                    DispatchQueue.main.async {
                        self.delegate?.legacyDFU(self, didChangeState: L10n.s("已找到 DFU 设备: \(name)\n正在开始固件升级...", "Found DFU device: \(name)\nStarting firmware upgrade..."))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.startDFUProcess()
                        }
                    }
                    return
                }
            }
        }
        
        BLEManager.shared.startScan()
        
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.isWaitingForDFU {
                self.isWaitingForDFU = false
                BLEManager.shared.stopScan()
                BLEManager.shared.onPeripheralDiscovered = nil
                self.delegate?.legacyDFU(self, didFailWithError: L10n.s("扫描超时，未找到 DFU 设备。请确认设备处于 DFU 模式。", "Scan timeout, DFU device not found. Make sure device is in DFU mode."))
            }
        }
    }
    
    private func stopScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }
    
    // MARK: - 执行 Nordic DFU
    
    private func startDFUProcess() {
        guard let dfuPeripheral = dfuPeripheral else {
            delegate?.legacyDFU(self, didFailWithError: "DFU 设备丢失")
            return
        }
        guard let firmwareURL = firmwareFileURL else {
            delegate?.legacyDFU(self, didFailWithError: "固件文件路径无效")
            return
        }
        
        do {
            let firmware = try DFUFirmware(urlToZipFile: firmwareURL)
            let initiator = DFUServiceInitiator()
            initiator.delegate = self
            initiator.progressDelegate = self
            initiator.logger = self
            initiator.packetReceiptNotificationParameter = 12
            dfuController = initiator.with(firmware: firmware).start(target: dfuPeripheral)
        } catch {
            delegate?.legacyDFU(self, didFailWithError: "固件解析失败: \(error.localizedDescription)")
        }
    }
}

// MARK: - SMPServiceChecker
/// 检查已连接设备是否有 SMP 服务（判断走新版还是旧版 OTA）
class SMPServiceChecker: NSObject, CBPeripheralDelegate {
    
    private let peripheral: CBPeripheral
    private let completion: (Bool) -> Void
    private var originalDelegate: CBPeripheralDelegate?
    private var timeoutTimer: Timer?
    
    init(peripheral: CBPeripheral, completion: @escaping (Bool) -> Void) {
        self.peripheral = peripheral
        self.completion = completion
        super.init()
    }
    
    func start() {
        originalDelegate = peripheral.delegate
        peripheral.delegate = self
        
        // 只搜索 SMP Service UUID
        peripheral.discoverServices([LegacyDFUManager.smpServiceUUID])
        
        // 5 秒超时
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.finish(supportsSMP: false)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        timeoutTimer?.invalidate()
        
        if let services = peripheral.services {
            let hasSMP = services.contains { $0.uuid == LegacyDFUManager.smpServiceUUID }
            finish(supportsSMP: hasSMP)
        } else {
            finish(supportsSMP: false)
        }
    }
    
    private func finish(supportsSMP: Bool) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        peripheral.delegate = originalDelegate
        DispatchQueue.main.async {
            self.completion(supportsSMP)
        }
    }
}


// MARK: - DFUServiceDelegate

extension LegacyDFUManager: DFUServiceDelegate {
    
    func dfuStateDidChange(to state: DFUState) {
        var description = ""
        switch state {
        case .connecting: description = "正在连接 DFU 设备..."
        case .starting: description = "正在启动 DFU..."
        case .enablingDfuMode: description = "正在启用 DFU 模式..."
        case .uploading: description = "正在传输固件..."
        case .validating: description = "正在验证固件..."
        case .disconnecting: description = "正在断开连接..."
        case .completed:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cleanup()
                self.delegate?.legacyDFUDidComplete(self)
            }
            return
        case .aborted: description = L10n.upgradeCancelled
        @unknown default: description = ""
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.legacyDFU(self, didChangeState: description)
        }
    }
    
    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cleanup()
            self.delegate?.legacyDFU(self, didFailWithError: message)
        }
    }
}

// MARK: - DFUProgressDelegate

extension LegacyDFUManager: DFUProgressDelegate {
    
    func dfuProgressDidChange(for part: Int, outOf totalParts: Int,
                              to progress: Int,
                              currentSpeedBytesPerSecond: Double,
                              avgSpeedBytesPerSecond: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.legacyDFU(self, didUpdateProgress: progress, speed: currentSpeedBytesPerSecond, part: part, totalParts: totalParts)
        }
    }
}

// MARK: - LoggerDelegate

extension LegacyDFUManager: LoggerDelegate {
    
    func logWith(_ level: LogLevel, message: String) {
        NSLog("[LegacyDFU] \(message)")
    }
}


// MARK: - ServiceDiscoverer
/// 辅助类：发现指定 Service 和 Characteristic
/// 用于在发送 OTA 指令前确保已找到 FFF0 服务下的 FFF6 特征
class ServiceDiscoverer: NSObject, CBPeripheralDelegate {
    
    private let peripheral: CBPeripheral
    private let serviceUUID: CBUUID
    private let charUUID: CBUUID
    private let completion: (CBCharacteristic?) -> Void
    private var timeoutTimer: Timer?
    
    /// 静态持有防止被 ARC 释放
    private static var activeDiscoverer: ServiceDiscoverer?
    
    init(peripheral: CBPeripheral, serviceUUID: CBUUID, charUUID: CBUUID, completion: @escaping (CBCharacteristic?) -> Void) {
        self.peripheral = peripheral
        self.serviceUUID = serviceUUID
        self.charUUID = charUUID
        self.completion = completion
        super.init()
    }
    
    func start() {
        ServiceDiscoverer.activeDiscoverer = self
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
        
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.finish(characteristic: nil)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            finish(characteristic: nil)
            return
        }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([charUUID], for: service)
            return
        }
        finish(characteristic: nil)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else {
            finish(characteristic: nil)
            return
        }
        for char in chars where char.uuid == charUUID {
            finish(characteristic: char)
            return
        }
        finish(characteristic: nil)
    }
    
    private func finish(characteristic: CBCharacteristic?) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        ServiceDiscoverer.activeDiscoverer = nil
        DispatchQueue.main.async {
            self.completion(characteristic)
        }
    }
}
