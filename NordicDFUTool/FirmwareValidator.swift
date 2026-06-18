import Foundation
import ZIPFoundation
import iOSMcuManagerLibrary
import NordicDFU

/// 固件包验证结果
enum FirmwareValidationResult {
    case validMcuManager    // 有效的 McuManager (SMP) 固件包
    case validNordicDFU     // 有效的旧版 Nordic DFU 固件包
    case invalid(String)    // 无效，附带原因描述
}

/// 固件包校验工具
/// 在升级前深度检查固件包格式是否正确
struct FirmwareValidator {
    
    /// 校验固件文件（深度验证）
    static func validate(fileURL: URL) -> FirmwareValidationResult {
        let ext = fileURL.pathExtension.lowercased()
        
        // 必须是 .zip 文件
        guard ext == "zip" else {
            return .invalid(L10n.firmwareNotZip)
        }
        
        // 检查文件是否存在且可读
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            return .invalid(L10n.firmwareCorrupt)
        }
        
        // 尝试用 McuMgrPackage 解析（新版 SMP 格式）
        if let _ = try? McuMgrPackage(from: fileURL) {
            return .validMcuManager
        }
        
        // 尝试用 NordicDFU 的 DFUFirmware 解析（旧版格式）
        do {
            let _ = try DFUFirmware(urlToZipFile: fileURL)
            return .validNordicDFU
        } catch let error as DFUStreamZipError {
            // 根据 DFUStreamZipError 给出具体错误信息
            switch error {
            case .noManifest:
                break // 继续往下检查是否为其他格式
            case .invalidManifest:
                return .invalid(L10n.s(
                    "固件包 manifest.json 格式无效",
                    "Invalid manifest.json in firmware package"))
            case .fileNotFound:
                return .invalid(L10n.s(
                    "manifest.json 中指定的文件在 ZIP 包中不存在",
                    "File specified in manifest.json not found in ZIP"))
            case .typeNotFound:
                return .invalid(L10n.s(
                    "manifest.json 中未找到指定类型的固件",
                    "Specified firmware type not found in manifest.json"))
            }
        } catch {
            // 其他解析错误
        }
        
        // 两种格式都解析失败，手动检查 ZIP 内容给出提示
        guard let archive = Archive(url: fileURL, accessMode: .read) else {
            return .invalid(L10n.firmwareCorrupt)
        }
        
        var fileList: [String] = []
        for entry in archive {
            fileList.append(entry.path.lowercased())
        }
        
        let hasBin = fileList.contains { $0.hasSuffix(".bin") }
        let hasDat = fileList.contains { $0.hasSuffix(".dat") }
        let hasManifest = fileList.contains { $0.hasSuffix("manifest.json") }
        
        if !hasBin && !hasManifest {
            return .invalid(L10n.s(
                "ZIP 包中未找到固件文件 (.bin) 或 manifest.json\n\n包含文件: \(fileList.prefix(5).joined(separator: ", "))",
                "No firmware file (.bin) or manifest.json found in ZIP\n\nContains: \(fileList.prefix(5).joined(separator: ", "))"))
        }
        
        if hasBin && !hasDat && !hasManifest {
            return .invalid(L10n.s(
                "ZIP 包中有 .bin 文件但缺少 .dat 初始化包或 manifest.json\n请使用 nrfutil 工具重新打包",
                "ZIP contains .bin but missing .dat init packet or manifest.json\nPlease repackage using nrfutil"))
        }
        
        return .invalid(L10n.s(
            "固件包格式不被支持。\n支持格式:\n• McuManager: 含 manifest.json\n• Nordic DFU: 含 .dat + .bin",
            "Unsupported firmware format.\nSupported:\n• McuManager: contains manifest.json\n• Nordic DFU: contains .dat + .bin"))
    }
}
