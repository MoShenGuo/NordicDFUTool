import Foundation

/// 固件版本信息模型
/// 从服务器 API 返回的每个固件版本对应一个 FirmwareInfo
/// 包含版本号、下载地址、上传时间等关键信息
struct FirmwareInfo: Codable {
    let version: String       // 固件版本号，例如 "1.0.3"
    let firmwareUrl: String   // 固件包下载地址（.zip 格式，内含 .bin 镜像文件）
    let uploadTime: String    // 固件上传时间戳
}

/// 后台 API 响应结构
/// 服务器返回的 JSON 格式统一为 { code, info, data }
struct FirmwareListResponse: Codable {
    let code: Int             // 状态码，1 表示成功
    let info: String          // 状态信息描述
    let data: [FirmwareInfo]? // 固件列表数据（可能为 nil）
}

/// 固件服务（单例）
/// 负责两个核心功能：
/// 1. 从服务器查询可用的固件版本列表
/// 2. 下载固件包到本地沙盒（支持缓存机制）
///
/// OTA 升级流程中的作用：
/// 用户选择设备型号 → 查询固件列表 → 选择版本 → 下载固件包 → 交给 DFU Manager 执行升级
class FirmwareService {
    
    /// 单例实例
    static let shared = FirmwareService()
    
    /// 固件列表查询 API 基础地址
    private let baseURL = "https://hkapp.jointcorp.cloud/devicesp/testfirmware/app/list"
    
    private init() {}
    
    // MARK: - 固件缓存管理
    // 缓存机制说明：
    // 下载过的固件会保存在沙盒 Documents/FirmwareCache/ 目录下
    // 下次选择同一固件版本时，如果本地已有缓存，可跳过下载直接使用
    // 用户可以手动清理缓存，确保下次升级时重新下载最新的固件包
    
    /// 获取固件缓存目录的 URL
    /// 目录路径: Documents/FirmwareCache/
    /// 如果目录不存在会自动创建
    private var firmwareCacheDirectory: URL {
        // 获取 App 沙盒的 Documents 目录
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // 在 Documents 下创建专用的固件缓存子目录
        let cacheDir = documentsDir.appendingPathComponent("FirmwareCache")
        // 目录不存在时自动创建
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        return cacheDir
    }
    
    /// 检查某个固件是否已经缓存到本地
    /// 通过 URL 的最后路径分量（文件名）来判断缓存文件是否存在
    /// - Parameter urlString: 固件下载 URL
    /// - Returns: 如果缓存存在，返回本地文件 URL；否则返回 nil
    func getCachedFirmware(for urlString: String) -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        // 用 URL 的文件名作为缓存文件名（如 "firmware_v1.0.3.zip"）
        let fileName = url.lastPathComponent
        let cachedURL = firmwareCacheDirectory.appendingPathComponent(fileName)
        // 判断文件是否存在
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        return nil
    }
    
    /// 清理所有沙盒中的固件缓存文件
    /// 清理后下次升级时会重新从服务器下载最新固件
    /// - Returns: 元组 (是否成功, 释放的空间大小/字节)
    func clearFirmwareCache() -> (success: Bool, freedSize: Int64) {
        let cacheDir = firmwareCacheDirectory
        var freedSize: Int64 = 0
        
        do {
            // 遍历缓存目录中所有文件
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])
            for file in files {
                // 累计文件大小
                let attrs = try file.resourceValues(forKeys: [.fileSizeKey])
                freedSize += Int64(attrs.fileSize ?? 0)
                // 删除文件
                try FileManager.default.removeItem(at: file)
            }
            return (true, freedSize)
        } catch {
            return (false, 0)
        }
    }
    
    /// 获取当前缓存总大小（字节）
    /// 用于在 UI 上显示缓存占用空间
    func getCacheSize() -> Int64 {
        let cacheDir = firmwareCacheDirectory
        var totalSize: Int64 = 0
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])
            for file in files {
                let attrs = try file.resourceValues(forKeys: [.fileSizeKey])
                totalSize += Int64(attrs.fileSize ?? 0)
            }
        } catch {}
        
        return totalSize
    }
    
    /// 获取缓存目录中所有固件文件的 URL 列表
    /// 用于在 UI 上显示缓存的固件数量
    func getCachedFirmwareFiles() -> [URL] {
        let cacheDir = firmwareCacheDirectory
        do {
            return try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
        } catch {
            return []
        }
    }
    
    // MARK: - 网络请求
    
    /// 从服务器查询指定设备型号的固件版本列表
    /// API 地址: baseURL?deviceName=xxx
    /// - Parameters:
    ///   - deviceName: 设备型号名称（如 "2602"）
    ///   - completion: 回调，成功返回 [FirmwareInfo]，失败返回 Error
    func fetchFirmwareList(deviceName: String, completion: @escaping (Result<[FirmwareInfo], Error>) -> Void) {
        // 构建请求 URL，添加 deviceName 查询参数
        guard var components = URLComponents(string: baseURL) else {
            completion(.failure(FirmwareError.invalidURL))
            return
        }
        
        components.queryItems = [
            URLQueryItem(name: "deviceName", value: deviceName)
        ]
        
        guard let url = components.url else {
            completion(.failure(FirmwareError.invalidURL))
            return
        }
        
        // 创建 GET 请求，超时30秒
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        // 发起网络请求
        URLSession.shared.dataTask(with: request) { data, response, error in
            // 网络错误处理（如断网、超时）
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            // 检查是否收到数据
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(FirmwareError.noData))
                }
                return
            }
            
            do {
                // 解析 JSON 响应
                let response = try JSONDecoder().decode(FirmwareListResponse.self, from: data)
                // code == 1 表示服务端返回成功
                if response.code == 1, let firmwares = response.data {
                    DispatchQueue.main.async {
                        completion(.success(firmwares))
                    }
                } else {
                    // 服务端返回了错误信息
                    DispatchQueue.main.async {
                        completion(.failure(FirmwareError.serverError(response.info)))
                    }
                }
            } catch {
                // JSON 解析失败
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()  // 启动请求任务
    }
    
    /// 下载固件文件到本地沙盒
    /// 支持缓存跳过：如果本地已有该固件的缓存，直接返回缓存路径，不重复下载
    /// 下载后文件保存在 Documents/FirmwareCache/ 目录下
    ///
    /// - Parameters:
    ///   - urlString: 固件包的下载 URL
    ///   - skipIfCached: 是否跳过已缓存的文件（默认 true）
    ///   - progress: 下载进度回调（0.0 ~ 1.0）
    ///   - completion: 下载完成回调，成功返回本地文件 URL，失败返回 Error
    func downloadFirmware(from urlString: String, skipIfCached: Bool = true,
                          progress: @escaping (Double) -> Void,
                          completion: @escaping (Result<URL, Error>) -> Void) {
        // 先检查本地缓存：如果已有该固件，直接返回缓存路径（跳过下载）
        if skipIfCached, let cachedURL = getCachedFirmware(for: urlString) {
            DispatchQueue.main.async {
                progress(1.0)              // 进度直接设为100%
                completion(.success(cachedURL))  // 返回缓存文件路径
            }
            return
        }
        
        // 验证 URL 有效性
        guard let url = URL(string: urlString) else {
            completion(.failure(FirmwareError.invalidURL))
            return
        }
        
        // 创建下载任务
        // 使用 downloadTask 而不是 dataTask，因为固件文件可能较大
        // downloadTask 会先下载到系统临时目录，完成后再移动到目标位置
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            // 下载出错处理
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            // 确保临时文件存在
            guard let tempURL = tempURL, let self = self else {
                DispatchQueue.main.async {
                    completion(.failure(FirmwareError.noData))
                }
                return
            }
            
            // 将临时文件移动到固件缓存目录，以 URL 文件名作为保存名
            let fileName = url.lastPathComponent
            let destinationURL = self.firmwareCacheDirectory.appendingPathComponent(fileName)
            
            do {
                // 如果目标位置已存在同名文件（可能是旧版缓存），先删除
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                // 将临时文件移动到缓存目录（比 copy 更高效，不会占用双倍空间）
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                DispatchQueue.main.async {
                    completion(.success(destinationURL))  // 返回保存后的文件路径
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
        
        // 监听下载进度
        // 通过 KVO 观察 task.progress.fractionCompleted 属性变化
        let observation = task.progress.observe(\.fractionCompleted) { progressObj, _ in
            DispatchQueue.main.async {
                progress(progressObj.fractionCompleted)  // 回调当前下载进度
            }
        }
        
        // 使用 associated object 保持 observation 的强引用
        // 防止 observation 被释放导致无法接收进度更新
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
        
        // 启动下载任务
        task.resume()
    }
}

// MARK: - 错误定义
/// 固件服务相关的错误类型枚举
enum FirmwareError: LocalizedError {
    case invalidURL           // URL 格式无效
    case noData               // 服务器未返回数据
    case serverError(String)  // 服务端返回错误信息
    case deviceNotFound       // 未找到匹配的 BLE 设备
    case downloadFailed       // 固件下载失败
    
    /// 错误的本地化描述（显示给用户）
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的URL"
        case .noData: return "未收到数据"
        case .serverError(let msg): return "服务器错误: \(msg)"
        case .deviceNotFound: return "未找到匹配设备"
        case .downloadFailed: return "下载失败"
        }
    }
}
