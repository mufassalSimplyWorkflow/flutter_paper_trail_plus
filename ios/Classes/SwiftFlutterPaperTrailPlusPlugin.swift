import Flutter
import UIKit
import PaperTrailLumberjack
import Network
import CocoaAsyncSocket

public class SwiftFlutterPaperTrailPlusPlugin: NSObject, FlutterPlugin {
    // Configuration
    private static var hostName: String?
    private static var programName: String?
    private static var machineName: String?
    private static var port: UInt?
    private static let maxRetryAttempts = 5
    private static let retryInterval: TimeInterval = 3.0
    
    // State
    private var isConnectionActive = false
    private var monitor: NWPathMonitor?
    private let monitorQueue = DispatchQueue(label: "io.flutter.plugins.papertrail.networkmonitor")
    private var logger: RMPaperTrailLogger?
    private var pendingLogs = [(message: String, level: DDLogLevel)]()
    private var isInitialized = false
    private var isReconnecting = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "flutter_paper_trail_plus", 
            binaryMessenger: registrar.messenger()
        )
        let instance = SwiftFlutterPaperTrailPlusPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initLogger":
            initLogger(call, result: result)
        case "setUserId":
            setUserId(call, result: result)
        case "log":
            logMessage(call, result: result)
        case "getStatus":
            getStatus(result: result)
        case "flush":
            flushPendingLogs(result: result)
        case "forceReconnect":
            forceReconnect(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Core Methods

    private func initLogger(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            let config = try validateConfig(call.arguments)
            
            SwiftFlutterPaperTrailPlusPlugin.hostName = config.hostName
            SwiftFlutterPaperTrailPlusPlugin.programName = config.programName
            SwiftFlutterPaperTrailPlusPlugin.machineName = config.machineName
            SwiftFlutterPaperTrailPlusPlugin.port = config.port
            
            initializeLogger()
            startNetworkMonitoring()
            isInitialized = true
            
            result("Logger initialized successfully")
        } catch {
            result(FlutterError.from(error))
        }
    }

    private func setUserId(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let params = call.arguments as? [String: Any],
              let userId = params["userId"] as? String else {
            result(FlutterError(
                code: "INVALID_ARGUMENTS",
                message: "userId is required and must be a string",
                details: nil
            ))
            return
        }
        
        guard let logger = self.logger else {
            result(FlutterError(
                code: "LOGGER_NOT_INITIALIZED",
                message: "Logger must be initialized first",
                details: nil
            ))
            return
        }
        
        let originalProgramName = SwiftFlutterPaperTrailPlusPlugin.programName ?? "app"
        logger.programName = "\(userId)-\(originalProgramName)"
        
        result("User ID set successfully")
    }

    private func logMessage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            let (message, level) = try validateLogParams(call.arguments)
            
            if isConnectionActive, isLoggerReady() {
                dispatchLog(message: message, level: level)
                result("Log sent successfully")
            } else {
                pendingLogs.append((message, level))
                attemptReconnect()
                result("Log queued (connection unavailable)")
            }
        } catch {
            result(FlutterError.from(error))
        }
    }

    // MARK: - Logger Management

    private func initializeLogger() {
        guard let hostName = SwiftFlutterPaperTrailPlusPlugin.hostName,
              let programName = SwiftFlutterPaperTrailPlusPlugin.programName,
              let machineName = SwiftFlutterPaperTrailPlusPlugin.machineName,
              let port = SwiftFlutterPaperTrailPlusPlugin.port else {
            return
        }

        if let existingLogger = logger {
            DDLog.remove(existingLogger)
        }

        let paperTrailLogger = RMPaperTrailLogger.sharedInstance()!
        paperTrailLogger.host = hostName
        paperTrailLogger.port = port
        paperTrailLogger.programName = programName
        paperTrailLogger.machineName = machineName
        
        if let socket = paperTrailLogger.value(forKey: "socket") as? GCDAsyncSocket {
            socket.isIPv4PreferredOverIPv6 = true
            socket.isIPv6Enabled = false
        }
        
        self.logger = paperTrailLogger
        DDLog.add(paperTrailLogger)
    }

    private func isLoggerReady() -> Bool {
        guard let logger = logger,
              let socket = logger.value(forKey: "socket") as? GCDAsyncSocket else {
            return false
        }
        return socket.isConnected
    }

    private func attemptReconnect() {
        guard !isReconnecting else { return }
        
        isReconnecting = true
        print("Attempting to reconnect logger...")
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.isReconnecting = false }
            
            for attempt in 1...SwiftFlutterPaperTrailPlusPlugin.maxRetryAttempts {
                self?.initializeLogger()
                
                if self?.isLoggerReady() == true {
                    print("Reconnected successfully after \(attempt) attempts")
                    self?.processPendingLogs()
                    return
                }
                
                print("Reconnect attempt \(attempt) failed")
                Thread.sleep(forTimeInterval: SwiftFlutterPaperTrailPlusPlugin.retryInterval)
            }
            
            print("Failed to reconnect after \(SwiftFlutterPaperTrailPlusPlugin.maxRetryAttempts) attempts")
        }
    }

    private func forceReconnect(result: @escaping FlutterResult) {
        initializeLogger()
        if isConnectionActive {
            processPendingLogs()
        }
        result("Reconnection attempted")
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        monitor = NWPathMonitor()
        monitor?.pathUpdateHandler = { [weak self] path in
            let newStatus = path.status == .satisfied
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if newStatus != self.isConnectionActive {
                    print("Network status changed: \(newStatus ? "Connected" : "Disconnected")")
                    self.isConnectionActive = newStatus
                    
                    if newStatus {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.initializeLogger()
                            self.processPendingLogs()
                        }
                    } else {
                        if let logger = self.logger {
                            DDLog.remove(logger)
                        }
                        self.logger = nil
                    }
                }
            }
        }
        monitor?.start(queue: monitorQueue)
    }

    // MARK: - Log Processing

    private func dispatchLog(message: String, level: DDLogLevel) {
        switch level {
        case .error: DDLogError(message)
        case .warning: DDLogWarn(message)
        case .info: DDLogInfo(message)
        case .debug: DDLogDebug(message)
        default: DDLogVerbose(message)
        }
    }

    private func processPendingLogs() {
        guard isConnectionActive, isLoggerReady(), !pendingLogs.isEmpty else {
            return
        }
        
        let logsToProcess = pendingLogs
        pendingLogs.removeAll()
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for log in logsToProcess {
                self?.dispatchLog(message: log.message, level: log.level)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func flushPendingLogs(result: @escaping FlutterResult) {
        processPendingLogs()
        result("Pending logs processed")
    }

    // MARK: - Status Reporting

    private func getStatus(result: @escaping FlutterResult) {
        let status: [String: Any] = [
            "initialized": isInitialized,
            "connected": isConnectionActive,
            "loggerReady": isConnectionActive && isLoggerReady(),
            "pendingLogs": pendingLogs.count,
            "hostName": SwiftFlutterPaperTrailPlusPlugin.hostName ?? "null",
            "port": SwiftFlutterPaperTrailPlusPlugin.port ?? 0
        ]
        result(status)
    }

    // MARK: - Validation

    private func validateConfig(_ arguments: Any?) throws -> (hostName: String, programName: String, machineName: String, port: UInt) {
        guard let params = arguments as? [String: Any] else {
            throw ValidationError.invalidArguments("Arguments must be a Map")
        }
        
        guard let hostName = params["hostName"] as? String, !hostName.isEmpty else {
            throw ValidationError.invalidArguments("hostName is required and must be a non-empty string")
        }
        
        guard let programName = params["programName"] as? String, !programName.isEmpty else {
            throw ValidationError.invalidArguments("programName is required and must be a non-empty string")
        }
        
        guard let machineName = params["machineName"] as? String, !machineName.isEmpty else {
            throw ValidationError.invalidArguments("machineName is required and must be a non-empty string")
        }
        
        guard let portValue = params["port"] else {
            throw ValidationError.invalidArguments("port is required")
        }
        
        let port: UInt?
        if let portString = portValue as? String {
            port = UInt(portString)
        } else if let portNumber = portValue as? Int {
            port = UInt(portNumber)
        } else {
            port = nil
        }
        
        guard let validPort = port else {
            throw ValidationError.invalidArguments("port must be a valid number (either string or integer)")
        }
        
        return (hostName, programName, machineName, validPort)
    }

    private func validateLogParams(_ arguments: Any?) throws -> (message: String, level: DDLogLevel) {
        guard let params = arguments as? [String: Any] else {
            throw ValidationError.invalidArguments("Arguments must be a Map")
        }
        
        guard let message = params["message"] as? String, !message.isEmpty else {
            throw ValidationError.invalidArguments("message is required and must be a non-empty string")
        }
        
        guard let logLevelString = params["logLevel"] as? String, !logLevelString.isEmpty else {
            throw ValidationError.invalidArguments("logLevel is required and must be a non-empty string")
        }
        
        return (message, ddLogLevel(from: logLevelString))
    }

    private func ddLogLevel(from string: String) -> DDLogLevel {
        switch string.lowercased() {
        case "error": return .error
        case "warning": return .warning
        case "info": return .info
        case "debug": return .debug
        case "verbose": return .verbose
        default: return .info
        }
    }

    deinit {
        monitor?.cancel()
        if let logger = logger {
            DDLog.remove(logger)
        }
    }
}

// MARK: - Error Handling

enum ValidationError: Error {
    case invalidArguments(String)
}

extension FlutterError {
    static func from(_ error: Error) -> FlutterError {
        if let validationError = error as? ValidationError {
            switch validationError {
            case .invalidArguments(let message):
                return FlutterError(
                    code: "INVALID_ARGUMENTS",
                    message: message,
                    details: nil
                )
            }
        }
        
        return FlutterError(
            code: "UNKNOWN_ERROR",
            message: error.localizedDescription,
            details: nil
        )
    }
}