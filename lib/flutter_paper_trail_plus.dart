import 'dart:async';
import 'package:flutter/services.dart';

class FlutterPaperTrailPlus {
  static const MethodChannel _channel =
      MethodChannel('flutter_paper_trail_plus');

  /// Initializes the PaperTrail logger
  static Future<void> initLogger({
    required String hostName,
    required int port,
    required String programName,
    required String machineName,
  }) async {
    try {
      await _channel.invokeMethod('initLogger', {
        'hostName': hostName,
        'port': port.toString(),
        'programName': programName,
        'machineName': machineName,
      });
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to initialize logger: ${e.message}');
    }
  }

  /// Sets the user ID for log tagging
  static Future<void> setUserId(String userId) async {
    try {
      await _channel.invokeMethod('setUserId', {'userId': userId});
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to set user ID: ${e.message}');
    }
  }

  /// Gets the current logger status
  static Future<PaperTrailStatus> getStatus() async {
    try {
      final status = await _channel.invokeMethod<Map>('getStatus');
      return PaperTrailStatus.fromMap(Map<String, dynamic>.from(status ?? {}));
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to get status: ${e.message}');
    }
  }

  /// Forces a reconnection attempt
  static Future<void> forceReconnect() async {
    try {
      await _channel.invokeMethod('forceReconnect');
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to reconnect: ${e.message}');
    }
  }

  /// Flushes pending logs
  static Future<void> flush() async {
    try {
      await _channel.invokeMethod('flush');
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to flush logs: ${e.message}');
    }
  }

  // Logging methods
  static Future<void> logError(String message) => _log(message, 'error');
  static Future<void> logWarning(String message) => _log(message, 'warning');
  static Future<void> logInfo(String message) => _log(message, 'info');
  static Future<void> logDebug(String message) => _log(message, 'debug');
  static Future<void> logVerbose(String message) => _log(message, 'verbose');

  static Future<void> _log(String message, String level) async {
    try {
      await _channel.invokeMethod('log', {
        'message': message,
        'logLevel': level,
      });
    } on PlatformException catch (e) {
      throw PaperTrailException('Failed to log message: ${e.message}');
    }
  }
}

class PaperTrailStatus {
  final bool initialized;
  final bool connected;
  final bool loggerReady;
  final int pendingLogs;
  final String hostName;
  final int port;

  PaperTrailStatus({
    required this.initialized,
    required this.connected,
    required this.loggerReady,
    required this.pendingLogs,
    required this.hostName,
    required this.port,
  });

  factory PaperTrailStatus.fromMap(Map<String, dynamic> map) {
    return PaperTrailStatus(
      initialized: map['initialized'] as bool? ?? false,
      connected: map['connected'] as bool? ?? false,
      loggerReady: map['loggerReady'] as bool? ?? false,
      pendingLogs: map['pendingLogs'] as int? ?? 0,
      hostName: map['hostName'] as String? ?? '',
      port: int.tryParse(map['port']?.toString() ?? '0') ?? 0,
    );
  }

  @override
  String toString() {
    return 'PaperTrailStatus(initialized: $initialized, connected: $connected, '
        'loggerReady: $loggerReady, pendingLogs: $pendingLogs, '
        'hostName: $hostName, port: $port)';
  }
}

class PaperTrailException implements Exception {
  final String message;
  PaperTrailException(this.message);

  @override
  String toString() => 'PaperTrailException: $message';
}
