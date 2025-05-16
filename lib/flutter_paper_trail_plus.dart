import 'dart:async';
import 'package:flutter/services.dart';

/// A Flutter plugin for integrating with PaperTrail log service.
class FlutterPaperTrailPlus {
  static const MethodChannel _channel =
      const MethodChannel('flutter_paper_trail_plus');

  /// Initializes the logger for sending logs to PaperTrail.
  ///
  /// Throws [PlatformException] if initialization fails.
  ///
  /// - [hostName]: The hostname of the PaperTrail server (e.g., 'logsX.papertrailapp.com')
  /// - [port]: The port number to connect to (typically between 1-65535)
  /// - [programName]: The name of the program or application
  /// - [machineName]: The name of the machine or device
  static Future<void> initLogger({
    required String hostName,
    required int port,
    required String programName,
    required String machineName,
  }) async {
    try {
      await _channel.invokeMethod('initLogger', {
        'hostName': hostName,
        'machineName': machineName,
        'programName': programName,
        'port': port.toString(), // Convert to string for consistency
      });
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to initialize logger: ${e.message}');
    }
  }

  /// Sets the user ID for the logs.
  ///
  /// Throws [PlatformException] if operation fails.
  ///
  /// - [userId]: The user ID to associate with the logs
  static Future<void> setUserId(String userId) async {
    try {
      await _channel.invokeMethod('setUserId', {'userId': userId});
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to set user ID: ${e.message}');
    }
  }

  /// Gets the current status of the logger.
  ///
  /// Returns a map containing:
  /// - initialized: bool
  /// - connected: bool
  /// - loggerReady: bool
  /// - pendingLogs: int
  /// - hostName: String
  /// - port: int
  ///
  /// Throws [PlatformException] if status retrieval fails.
  static Future<Map<String, dynamic>> getStatus() async {
    try {
      final status =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
      return _parseStatus(status ?? {});
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to get status: ${e.message}');
    }
  }

  /// Parses the status map from the platform channel
  static Map<String, dynamic> _parseStatus(Map<dynamic, dynamic> status) {
    return {
      'initialized': status['initialized'] as bool? ?? false,
      'connected': status['connected'] as bool? ?? false,
      'loggerReady': status['loggerReady'] as bool? ?? false,
      'pendingLogs': status['pendingLogs'] as int? ?? 0,
      'hostName': status['hostName'] as String? ?? '',
      'port': int.tryParse(status['port']?.toString() ?? '0') ?? 0,
    };
  }

  /// Flushes any pending logs that were queued while offline.
  ///
  /// Throws [PlatformException] if operation fails.
  static Future<void> flush() async {
    try {
      await _channel.invokeMethod('flush');
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to flush logs: ${e.message}');
    }
  }

  /// Logs an error message to PaperTrail.
  ///
  /// Throws [PaperTrailException] if logging fails after retries.
  ///
  /// - [message]: The error message to log
  static Future<void> logError(String message) async {
    return _log(message, 'error');
  }

  /// Logs a warning message to PaperTrail.
  ///
  /// Throws [PaperTrailException] if logging fails after retries.
  ///
  /// - [message]: The warning message to log
  static Future<void> logWarning(String message) async {
    return _log(message, 'warning');
  }

  /// Logs an informational message to PaperTrail.
  ///
  /// Throws [PaperTrailException] if logging fails after retries.
  ///
  /// - [message]: The information message to log
  static Future<void> logInfo(String message) async {
    return _log(message, 'info');
  }

  /// Logs a debug message to PaperTrail.
  ///
  /// Throws [PaperTrailException] if logging fails after retries.
  ///
  /// - [message]: The debug message to log
  static Future<void> logDebug(String message) async {
    return _log(message, 'debug');
  }

  /// Logs a verbose message to PaperTrail.
  ///
  /// Throws [PaperTrailException] if logging fails after retries.
  ///
  /// - [message]: The verbose message to log
  static Future<void> logVerbose(String message) async {
    return _log(message, 'verbose');
  }

  /// Internal method to log a message with a specific log level.
  static Future<void> _log(String message, String logLevel) async {
    try {
      await _channel.invokeMethod('log', {
        'message': message,
        'logLevel': logLevel,
      });
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to log message: ${e.message}');
    }
  }
}

/// Exception thrown when PaperTrail operations fail.
class PaperTrailException implements Exception {
  final String message;
  PaperTrailException(this.message);

  @override
  String toString() => 'PaperTrailException: $message';
}
