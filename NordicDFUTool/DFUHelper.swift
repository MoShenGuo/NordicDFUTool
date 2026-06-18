import Foundation
import CoreBluetooth

// DFUHelper 是旧项目参考代码，需要同时安装 Zip pod 才能编译
// 新的旧版 DFU 逻辑已在 LegacyDFUManager.swift 中实现
#if canImport(Zip)
import NordicDFU
import Zip

@objc public protocol DFUHelperDelegate: AnyObject {
    @objc func dfuDidChangeState(_ stateDescription: String, completed: Bool)
    @objc func dfuDidUpdateProgress(_ progress: Int, speed: Double, part: Int, totalParts: Int)
    @objc func dfuDidFailWithError(_ message: String)
}

@objc public class DFUHelper: NSObject, @unchecked Sendable {
    
    @objc public weak var delegate: DFUHelperDelegate?
    
    private var dfuController: DFUServiceController?
    
    /// 开始DFU升级
    @objc public func startDFU(centralManager: CBCentralManager, peripheral: CBPeripheral, outerZipPath: String, needUnzip: Bool) {
        
        var firmwareURL: URL
        
        if needUnzip {
            guard let url = extractFirmwareZip(from: outerZipPath) else {
                delegate?.dfuDidFailWithError("解压固件包失败，未找到firmware.zip")
                return
            }
            firmwareURL = url
        } else {
            firmwareURL = URL(fileURLWithPath: outerZipPath)
        }
        
        do {
            let firmware = try DFUFirmware(urlToZipFile: firmwareURL)
            let initiator = DFUServiceInitiator()
            initiator.delegate = self
            initiator.progressDelegate = self
            initiator.logger = self
            initiator.packetReceiptNotificationParameter = 12
            dfuController = initiator.with(firmware: firmware).start(target: peripheral)
        } catch {
            delegate?.dfuDidFailWithError("固件文件解析失败: \(error.localizedDescription)")
        }
    }
    
    @objc public func abortDFU() {
        _ = dfuController?.abort()
        dfuController = nil
    }
    
    private func extractFirmwareZip(from outerZipPath: String) -> URL? {
        let outerZipURL = URL(fileURLWithPath: outerZipPath)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ota_firmware_\(UUID().uuidString)")
        do {
            try Zip.unzipFile(outerZipURL, destination: tempDir, overwrite: true, password: nil)
        } catch {
            return nil
        }
        return findFirmwareZip(in: tempDir)
    }
    
    private func findFirmwareZip(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased() == "firmware.zip" {
                return fileURL
            }
        }
        return nil
    }
}

extension DFUHelper: DFUServiceDelegate {
    public func dfuStateDidChange(to state: DFUState) {
        var description = ""
        var completed = false
        switch state {
        case .connecting: description = "正在连接DFU设备..."
        case .starting: description = "正在启动DFU..."
        case .enablingDfuMode: description = "正在启用DFU模式..."
        case .uploading: description = "正在传输固件..."
        case .validating: description = "正在验证固件..."
        case .disconnecting: description = "正在断开连接..."
        case .completed: description = "✅ 升级完成！"; completed = true
        case .aborted: description = "升级已取消"
        @unknown default: description = ""
        }
        DispatchQueue.main.async { self.delegate?.dfuDidChangeState(description, completed: completed) }
    }
    
    public func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        DispatchQueue.main.async { self.delegate?.dfuDidFailWithError(message) }
    }
}

extension DFUHelper: DFUProgressDelegate {
    public func dfuProgressDidChange(for part: Int, outOf totalParts: Int, to progress: Int, currentSpeedBytesPerSecond: Double, avgSpeedBytesPerSecond: Double) {
        DispatchQueue.main.async { self.delegate?.dfuDidUpdateProgress(progress, speed: currentSpeedBytesPerSecond, part: part, totalParts: totalParts) }
    }
}

extension DFUHelper: LoggerDelegate {
    public func logWith(_ level: LogLevel, message: String) {
        NSLog("[DFU] \(message)")
    }
}

#endif
