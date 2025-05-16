import Flutter
import UIKit
import PaperTrailLumberjack
import Network

public class SwiftFlutterPaperTrailPlusPlugin: NSObject, FlutterPlugin {
    // Configuration properties
    private static var programName: String?
    private static var hostName: String?
    private static var machineName: String?
    private static var port: UInt?
    private static let maxRetryAttempts = 3
    private static let retryInterval: TimeInterval = 2.0
    
    // State management
    private var isConnectionActive = false
    private var monitor: NWPathMonitor?
    private var queue = DispatchQueue(label: "com.papertrail.network.monitor")
    private var loggerInitialized = false
    private var logger: RMPaperTrailLogger?
    private var pendingLogs: [(message: String, level: DDLogLevel)] = []

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
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Public Methods

    private func initLogger(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let params = call.arguments as? [String: Any] else {
            return result(argumentError("Arguments must be a Map"))
        }
        
        // Validate required parameters
        guard let hostName = params["hostName"] as? String, !hostName.isEmpty else {
            return result(argumentError("hostName is required and must be a non-empty string"))
        }
        
        guard let programName = params["programName"] as? String, !programName.isEmpty else {
            return result(argumentError("programName is required and must be a non-empty string"))
        }
        
        guard let machineName = params["machineName"] as? String, !machineName.isEmpty else {
            return result(argumentError("machineName is required and must be a non-empty string"))
        }
        
        guard let portValue = params["port"] else {
            return result(argumentError("port is required"))
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
            return result(argumentError("port must be a valid number (either string or integer)"))
        }

        // Store configuration
        SwiftFlutterPaperTrailPlusPlugin.hostName = hostName
        SwiftFlutterPaperTrailPlusPlugin.programName = programName
        SwiftFlutterPaperTrailPlusPlugin.machineName = machineName
        SwiftFlutterPaperTrailPlusPlugin.port = validPort

        // Initialize logger and monitoring
        initializePaperTrailLogger()
        startNetworkMonitoring()
        
        result("Logger initialized successfully")
    }

    private func setUserId(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let params = call.arguments as? [String: Any] else {
            return result(argumentError("Arguments must be a Map"))
        }
        
        guard let userId = params["userId"] as? String, !userId.isEmpty else {
            return result(argumentError("userId is required and must be a non-empty string"))
        }
        
        guard let programName = SwiftFlutterPaperTrailPlusPlugin.programName else {
            return result(FlutterError(
                code: "LOGGER_NOT_INITIALIZED",
                message: "Logger must be initialized first",
                details: nil
            ))
        }
        
        guard let paperTrailLogger = logger else {
            return result(FlutterError(
                code: "LOGGER_NOT_AVAILABLE",
                message: "Logger instance not available",
                details: nil
            ))
        }

        paperTrailLogger.programName = "\(userId)--on--\(programName)"
        result("User ID set successfully")
    }

    private func logMessage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let params = call.arguments as? [String: Any] else {
            return result(argumentError("Arguments must be a Map"))
        }
        
        guard let message = params["message"] as? String, !message.isEmpty else {
            return result(argumentError("message is required and must be a non-empty string"))
        }
        
        guard let logLevelString = params["logLevel"] as? String, !logLevelString.isEmpty else {
            return result(argumentError("logLevel is required and must be a non-empty string"))
        }

        let logLevel = ddLogLevel(from: logLevelString)
        
        DispatchQueue.global(qos: .utility).async {
            self.processLog(message: message, logLevel: logLevel, result: result)
        }
    }

    private func getStatus(result: @escaping FlutterResult) {
        let status: [String: Any] = [
            "initialized": loggerInitialized,
            "connected": isConnectionActive,
            "hostName": SwiftFlutterPaperTrailPlusPlugin.hostName ?? "null",
            "programName": SwiftFlutterPaperTrailPlusPlugin.programName ?? "null",
            "pendingLogs": pendingLogs.count
        ]
        result(status)
    }

    // MARK: - Private Methods

    private func initializePaperTrailLogger() {
        guard let hostName = SwiftFlutterPaperTrailPlusPlugin.hostName,
              let programName = SwiftFlutterPaperTrailPlusPlugin.programName,
              let machineName = SwiftFlutterPaperTrailPlusPlugin.machineName,
              let port = SwiftFlutterPaperTrailPlusPlugin.port else {
            return
        }

        // Remove existing logger if any
        if let existingLogger = logger {
            DDLog.remove(existingLogger)
        }

        // Create new logger instance
        let paperTrailLogger = RMPaperTrailLogger.sharedInstance()!
        paperTrailLogger.host = hostName
        paperTrailLogger.port = port
        paperTrailLogger.programName = programName
        paperTrailLogger.machineName = machineName
        self.logger = paperTrailLogger

        DDLog.add(paperTrailLogger)
        isConnectionActive = true
        loggerInitialized = true
        
        // Process any pending logs
        processPendingLogs()
    }

    private func processLog(message: String, logLevel: DDLogLevel, result: @escaping FlutterResult) {
        var attempts = 0
        var success = false
        var lastError: Error?
        
        while attempts < SwiftFlutterPaperTrailPlusPlugin.maxRetryAttempts && !success {
            if !self.isConnectionActive || self.logger == nil {
                // Store log for later if we're offline
                if attempts == 0 {
                    self.pendingLogs.append((message, logLevel))
                }
                
                self.reconnectLogger()
                Thread.sleep(forTimeInterval: SwiftFlutterPaperTrailPlusPlugin.retryInterval)
                attempts += 1
                continue
            }
            
            // Attempt to log
            do {
                try self.attemptLog(message: message, logLevel: logLevel)
                success = true
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: SwiftFlutterPaperTrailPlusPlugin.retryInterval)
                attempts += 1
            }
        }
        
        DispatchQueue.main.async {
            if success {
                result("Log sent successfully")
            } else {
                let errorDetails = lastError?.localizedDescription ?? "Unknown error"
                result(FlutterError(
                    code: "LOG_FAILED",
                    message: "Failed to send log after \(SwiftFlutterPaperTrailPlusPlugin.maxRetryAttempts) attempts",
                    details: errorDetails
                ))
            }
        }
    }

    private func processPendingLogs() {
        guard isConnectionActive, let _ = logger, !pendingLogs.isEmpty else {
            return
        }
        
        let logsToProcess = pendingLogs
        pendingLogs.removeAll()
        
        for log in logsToProcess {
            processLog(message: log.message, logLevel: log.level, result: { _ in })
        }
    }

    private func attemptLog(message: String, logLevel: DDLogLevel) throws {
        guard let _ = logger else {
            throw NSError(domain: "LoggerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Logger not initialized"])
        }
        
        switch logLevel {
        case .error: DDLogError(message)
        case .warning: DDLogWarn(message)
        case .info: DDLogInfo(message)
        case .debug: DDLogDebug(message)
        default: DDLogVerbose(message)
        }
    }

    private func startNetworkMonitoring() {
        monitor = NWPathMonitor()
        monitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            
            let newStatus = path.status == .satisfied
            if newStatus != self.isConnectionActive {
                print("Network status changed: \(newStatus ? "Connected" : "Disconnected")")
                self.isConnectionActive = newStatus
                
                if newStatus {
                    // When connection returns, reinitialize the logger after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.initializePaperTrailLogger()
                    }
                }
            }
        }
        
        let queue = DispatchQueue(label: "com.papertrail.network.monitor")
        monitor?.start(queue: queue)
    }

    private func reconnectLogger() {
        print("Attempting to reconnect logger...")
        initializePaperTrailLogger()
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

    private func argumentError(_ message: String) -> FlutterError {
        return FlutterError(
            code: "INVALID_ARGUMENTS",
            message: message,
            details: nil
        )
    }

    deinit {
        monitor?.cancel()
        if let logger = logger {
            DDLog.remove(logger)
        }
    }
}