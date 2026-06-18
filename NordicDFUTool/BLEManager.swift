import Foundation
import CoreBluetooth

/// BLE 扫描和连接管理器（单例）
/// 负责整个 App 中蓝牙设备的扫描发现、连接管理、断开连接等操作
/// OTA 升级的前置步骤：必须先通过此管理器连接到目标 BLE 设备，才能进行后续的 DFU 固件升级
class BLEManager: NSObject {
    
    /// 单例实例，全局唯一的蓝牙管理器，所有页面共用同一个连接
    static let shared = BLEManager()
    
    /// 系统蓝牙中心管理器，用于扫描和连接 BLE 外设
    /// CBCentralManager 是 iOS CoreBluetooth 框架的核心类
    /// 创建时会自动触发系统蓝牙授权弹框（首次使用时）
    internal var centralManager: CBCentralManager!
    
    /// 已发现的所有外设列表（扫描过程中不断累加）
    private var discoveredPeripherals: [CBPeripheral] = []
    
    /// 当前已连接的外设（同一时间只维护一个连接）
    private var connectedPeripheral: CBPeripheral?
    
    // MARK: - 回调闭包（供外部 ViewController 监听蓝牙事件）
    
    /// 发现新外设时的回调，参数为当前已发现的全部外设列表
    var onPeripheralDiscovered: (([CBPeripheral]) -> Void)?
    
    /// 成功连接外设时的回调，参数为已连接的外设对象
    var onConnected: ((CBPeripheral) -> Void)?
    
    /// 外设断开连接时的回调，参数为断开的外设和可能的错误
    var onDisconnected: ((CBPeripheral, Error?) -> Void)?
    
    /// 蓝牙状态变化时的回调（如蓝牙开关、授权状态变化）
    var onBluetoothStateChanged: ((CBManagerState) -> Void)?
    
    /// 蓝牙是否已授权并处于开启状态，可以正常使用
    var isReady: Bool {
        return centralManager.state == .poweredOn
    }
    
    /// 蓝牙当前状态的中文描述，用于 UI 展示
    var stateDescription: String {
        switch centralManager.state {
        case .unknown: return "蓝牙状态未知"          // 刚初始化，还未确定状态
        case .resetting: return "蓝牙正在重置"        // 蓝牙模块正在重启
        case .unsupported: return "设备不支持蓝牙"    // 硬件不支持 BLE
        case .unauthorized: return "蓝牙未授权，请在设置中允许蓝牙访问"  // 用户拒绝了蓝牙权限
        case .poweredOff: return "蓝牙已关闭，请打开蓝牙"              // 用户关闭了蓝牙开关
        case .poweredOn: return "蓝牙已就绪"                          // 一切正常，可以扫描
        @unknown default: return "未知蓝牙状态"
        }
    }
    
    /// 私有初始化方法，确保单例
    /// 创建 CBCentralManager 时会立即触发系统蓝牙授权弹框（如果是首次请求）
    /// delegate 设为 self，所有蓝牙事件通过 CBCentralManagerDelegate 回调处理
    /// queue 设为 nil 表示使用主线程队列处理回调
    private override init() {
        super.init()
        // 初始化蓝牙中心管理器，此时系统会检查蓝牙权限
        // 如果 App 从未请求过蓝牙权限，会弹出系统授权对话框
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    /// 当前蓝牙状态（只读）
    var state: CBManagerState {
        return centralManager.state
    }
    
    /// 当前已连接的外设（只读），供外部判断是否有设备在线
    var currentPeripheral: CBPeripheral? {
        return connectedPeripheral
    }
    
    /// 请求蓝牙权限（触发系统授权弹框）
    /// 实际上 CBCentralManager 在 init 时已经创建并触发了授权
    /// 此方法的作用是：如果蓝牙已经就绪，立即通知调用方
    /// 用于 MainViewController 启动时主动检查蓝牙状态
    func requestBluetoothAuthorization() {
        // 如果蓝牙已经开启，直接回调通知 UI 更新状态显示
        if centralManager.state == .poweredOn {
            onBluetoothStateChanged?(.poweredOn)
        }
    }
    
    /// 开始扫描 BLE 外设
    /// 扫描前会检查蓝牙是否处于 poweredOn 状态
    /// 扫描参数：不限制 ServiceUUID（扫描所有设备），不允许重复上报同一设备
    func startScan() {
        // 蓝牙未就绪时不扫描，并通知当前状态
        guard centralManager.state == .poweredOn else {
            onBluetoothStateChanged?(centralManager.state)
            return
        }
        // 清空之前的扫描结果，重新开始
        discoveredPeripherals.removeAll()
        // 开始扫描：withServices 为 nil 表示不过滤，发现所有广播的 BLE 设备
        // AllowDuplicates 为 false 表示同一设备只上报一次
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }
    
    /// 停止扫描
    /// 在连接设备前或超时后调用，避免持续扫描消耗电量
    func stopScan() {
        centralManager.stopScan()
    }
    
    /// 连接指定的 BLE 外设
    /// 连接前先停止扫描（苹果建议连接时不要同时扫描）
    /// 连接结果通过 CBCentralManagerDelegate 的 didConnect/didFailToConnect 回调
    /// - Parameter peripheral: 要连接的目标外设对象
    func connect(peripheral: CBPeripheral) {
        stopScan()  // 停止扫描，节省资源
        centralManager.connect(peripheral, options: nil)  // 发起连接请求
    }
    
    /// 断开当前已连接的外设
    /// 在切换设备或退出升级时调用
    /// 断开后通过 didDisconnectPeripheral 回调通知
    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)  // 请求系统断开连接
        }
        connectedPeripheral = nil  // 清空当前连接引用
    }
    
    /// 获取已发现的外设列表（供外部读取）
    func getDiscoveredPeripherals() -> [CBPeripheral] {
        return discoveredPeripherals
    }
    
    /// 扫描指定名称的设备（用于批量升级时按设备型号筛选）
    /// 会在指定超时时间内持续扫描，超时后返回所有匹配的设备
    /// - Parameters:
    ///   - name: 设备名称关键字（不区分大小写模糊匹配）
    ///   - timeout: 扫描超时时间，默认 10 秒
    ///   - completion: 超时后回调，返回匹配的外设数组
    func scanForDevices(withName name: String, timeout: TimeInterval = 10.0,
                        completion: @escaping ([CBPeripheral]) -> Void) {
        // 用于收集匹配的外设
        var matchedPeripherals: [CBPeripheral] = []
        
        // 开始扫描所有设备
        startScan()
        
        // 保存之前的发现回调，扫描结束后恢复
        let previousHandler = onPeripheralDiscovered
        
        // 临时替换发现回调：每次发现设备时，筛选名称匹配的设备
        onPeripheralDiscovered = { peripherals in
            matchedPeripherals = peripherals.filter { p in
                guard let pName = p.name else { return false }
                // 不区分大小写，判断设备名是否包含目标关键字
                return pName.lowercased().contains(name.lowercased())
            }
        }
        
        // 超时后停止扫描，恢复原回调，并返回匹配结果
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stopScan()                           // 停止扫描
            self?.onPeripheralDiscovered = previousHandler  // 恢复之前的回调
            completion(matchedPeripherals)             // 返回匹配的设备列表
        }
    }
}

// MARK: - CBCentralManagerDelegate（蓝牙中心管理器代理方法）
extension BLEManager: CBCentralManagerDelegate {
    
    /// 蓝牙状态更新回调
    /// 在蓝牙开关变化、权限变化时触发
    /// 这是蓝牙初始化后第一个被调用的代理方法
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // 将状态变化转发给外部监听者（如 MainViewController 更新 UI）
        onBluetoothStateChanged?(central.state)
    }
    
    /// 发现外设回调
    /// 每发现一个新的 BLE 广播设备时触发
    /// - Parameters:
    ///   - peripheral: 发现的外设对象
    ///   - advertisementData: 广播数据（包含设备名称、服务UUID等）
    ///   - RSSI: 信号强度（负值，越接近0信号越强）
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 过滤掉没有名称的设备（通常是不需要的未知设备）
        guard peripheral.name != nil else { return }
        
        // 去重：如果设备已在列表中（通过 UUID 判断），不重复添加
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
        // 通知外部：发现了新设备，更新设备列表 UI
        onPeripheralDiscovered?(discoveredPeripherals)
    }
    
    /// 连接成功回调
    /// BLE 连接建立成功后触发
    /// 此时可以开始与设备通信（发现服务、特征等）
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral  // 记录当前已连接的外设
        onConnected?(peripheral)          // 通知外部连接成功
    }
    
    /// 连接失败回调
    /// 连接请求失败时触发（如设备不在范围内、连接超时等）
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onDisconnected?(peripheral, error)  // 通知外部连接失败
    }
    
    /// 断开连接回调
    /// 设备主动或被动断开时触发
    /// 在 OTA 升级过程中，设备重启切换 slot 时也会触发断开
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // 如果断开的是当前已连接的设备，清空引用
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
        }
        // 通知外部设备已断开
        onDisconnected?(peripheral, error)
    }
}
