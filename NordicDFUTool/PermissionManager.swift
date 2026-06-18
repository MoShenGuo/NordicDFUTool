import UIKit
import CoreBluetooth
import Network

/// 权限管理工具
/// 统一处理蓝牙和网络权限检查，未授权时引导用户去设置
class PermissionManager {
    
    static let shared = PermissionManager()
    
    private let networkMonitor = NWPathMonitor()
    private var isNetworkAvailable: Bool = true
    
    private init() {
        // 监听网络状态
        networkMonitor.pathUpdateHandler = { [weak self] path in
            self?.isNetworkAvailable = (path.status == .satisfied)
        }
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
    
    // MARK: - 蓝牙检查
    
    /// 检查蓝牙是否可用，不可用时弹出引导弹框
    /// - Returns: true = 蓝牙可用，false = 不可用（已弹出提示）
    @discardableResult
    static func checkBluetooth(from vc: UIViewController) -> Bool {
        let state = BLEManager.shared.state
        
        switch state {
        case .poweredOn:
            return true
        case .poweredOff:
            showSettingsAlert(from: vc,
                             title: L10n.s("蓝牙已关闭", "Bluetooth Off"),
                             message: L10n.s("请在系统设置中打开蓝牙以使用设备升级功能。", "Please enable Bluetooth in Settings to use device upgrade."))
            return false
        case .unauthorized:
            showSettingsAlert(from: vc,
                             title: L10n.s("蓝牙未授权", "Bluetooth Unauthorized"),
                             message: L10n.s("本应用需要蓝牙权限来扫描和连接 BLE 设备。请在设置 → 隐私 → 蓝牙中允许访问。", "This app needs Bluetooth access to scan and connect BLE devices. Please allow in Settings → Privacy → Bluetooth."))
            return false
        case .unsupported:
            let alert = UIAlertController(
                title: L10n.s("不支持蓝牙", "Bluetooth Unsupported"),
                message: L10n.s("当前设备不支持蓝牙 BLE。", "This device doesn't support Bluetooth BLE."),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.confirm, style: .default))
            vc.present(alert, animated: true)
            return false
        default:
            return false
        }
    }
    
    // MARK: - 网络检查
    
    /// 检查网络是否可用，不可用时弹出引导弹框
    /// - Returns: true = 网络可用，false = 不可用（已弹出提示）
    @discardableResult
    static func checkNetwork(from vc: UIViewController) -> Bool {
        if PermissionManager.shared.isNetworkAvailable {
            return true
        }
        
        showSettingsAlert(from: vc,
                         title: L10n.s("网络不可用", "Network Unavailable"),
                         message: L10n.s("请检查网络连接。需要网络来查询和下载固件。\n请在系统设置中开启 Wi-Fi 或蜂窝数据。", "Network required for firmware query and download.\nPlease enable Wi-Fi or Cellular Data in Settings."))
        return false
    }
    
    /// 同时检查蓝牙和网络
    static func checkAll(from vc: UIViewController) -> Bool {
        let ble = checkBluetooth(from: vc)
        if !ble { return false }
        let net = checkNetwork(from: vc)
        return net
    }
    
    // MARK: - 引导去设置
    
    private static func showSettingsAlert(from vc: UIViewController, title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.s("去设置", "Go to Settings"), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: L10n.cancel, style: .cancel))
        vc.present(alert, animated: true)
    }
}
