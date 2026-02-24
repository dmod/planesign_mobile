import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// Requires url_launcher dependency (added in pubspec)
import 'package:url_launcher/url_launcher.dart';

import '../utils/snackbar.dart';
import '../utils/extra.dart';
import '../utils/utils.dart';
import '../utils/ble_utils.dart';
import '../utils/docker_status.dart';
import '../utils/wifi_signal.dart';
import '../utils/temperature.dart';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;

  const DeviceScreen({super.key, required this.device});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  static const String tempCharUUID = 'abbd155c-e9d1-4d9d-ae9e-6871b20880e4';
  static const String hostnameCharUUID = '7e60d076-d3fd-496c-8460-63a0454d94d9';
  static const String ipAddressCharUUID = 'fed6ced8-9ef1-4b7e-9f05-07963adde32b';
  static const String rebootCharUUID = '99945678-1234-5678-1234-56789abcdef2';
  static const String uptimeCharUUID = 'a77a6077-7302-486e-9087-853ac5899335';
  static const String wifiStatusCharUUID = 'f2a3b4c5-6d7e-8f90-a1b2-c3d4e5f6a7b8';
  static const String wifiScanCharUUID = '99945678-1234-5678-1234-56789abcdef3';
  static const String wifiConfigCharUUID = '99945678-1234-5678-1234-56789abcdef4';
  static const String dockerContainerControlCharUUID = '29352a73-3108-4ecc-9440-57b5a8a5c027';
  static const String planeSignVersionCharUUID = '8d1151e7-04b8-49e2-955a-daa50e1285e5';
  static const String dockerUpdateCheckCharUUID = 'a9cc9f79-aa76-4955-aeb5-85aa9299028e';
  static const String systemUpdateCharUUID = '32d1b76b-9532-44da-9a43-3b682b8be90c';
  static const String systemUpdateLogCharUUID = 'f63b67f9-b823-4f8f-a528-94e286cda73e';

  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  Map<String, String> _characteristicValues = {};

  // Connection stability variables
  bool _autoReconnect = true;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _reconnectTimer;

  bool _isDockerBusy = false;
  bool _isUpdateCheckBusy = false;
  bool _isUpdating = false;
  bool _showUpdateLog = false;

  String _updateLog = '';
  final ScrollController _updateLogScrollController = ScrollController();

  late StreamSubscription<BluetoothConnectionState> _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;

  // Key for programmatic control of refresh indicator (optional future use)
  final GlobalKey<RefreshIndicatorState> _refreshKey = GlobalKey<RefreshIndicatorState>();

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription = widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
        // Reset reconnection attempts on successful connection
        _reconnectAttempts = 0;
        _reconnectTimer?.cancel();

        _services = []; // must rediscover services
        try {
          _services = await widget.device.discoverServices();
          // Automatically read and subscribe to all characteristics
          for (var service in _services) {
            for (var characteristic in service.characteristics) {
              if (characteristic.properties.read) {
                try {
                  final value = await characteristic.read();
                  _updateCharacteristicValue(characteristic.uuid.str128, value);
                } catch (e) {
                  print('Error reading characteristic ${characteristic.uuid}: $e');
                }
              }
              if (characteristic.properties.notify || characteristic.properties.indicate) {
                try {
                  await characteristic.setNotifyValue(true);
                  characteristic.lastValueStream.listen((value) {
                    _updateCharacteristicValue(characteristic.uuid.str128, value);
                  });
                } catch (e) {
                  print('Error subscribing to characteristic ${characteristic.uuid}: $e');
                }
              }
            }
          }
        } catch (e) {
          Snackbar.show(ABC.c, prettyException("Discover Services Error:", e), success: false);
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        // Handle disconnection
        if (_autoReconnect && _reconnectAttempts < _maxReconnectAttempts) {
          _scheduleReconnect();
        } else if (_reconnectAttempts >= _maxReconnectAttempts) {
          Snackbar.show(ABC.c, "Max reconnection attempts ($_maxReconnectAttempts) reached. Please manually reconnect.",
              success: false);
        }
      }
      if (mounted) {
        setState(() {});
      }
    });

    _isConnectingSubscription = widget.device.isConnecting.listen((value) {
      if (mounted) {
        setState(() {});
      }
    });

    // Auto-connect when screen opens
    onConnectPressed();
  }

  void _updateCharacteristicValue(String uuid, List<int> value) {
    final key = uuid.toLowerCase();

    final decoded = decodeBleUtf8String(value);

    debugPrint('[BLE] Update $key (${value.length} bytes) raw=$value utf8="$decoded"');

    if (mounted) {
      setState(() {
        if (key == systemUpdateLogCharUUID) {
          _updateLog += decoded;
        } else {
          _characteristicValues[key] = decoded;
          // Auto-detect update completion via status notification
          if (key == systemUpdateCharUUID && _isUpdating) {
            if (decoded.startsWith('complete') || decoded.startsWith('failed') || decoded == 'idle') {
              _isUpdating = false;
            }
          }
        }
      });
      // Auto-scroll log view to bottom
      if (key == systemUpdateLogCharUUID && _updateLogScrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_updateLogScrollController.hasClients) {
            _updateLogScrollController.animateTo(
              _updateLogScrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
            );
          }
        });
      }
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    final delay = Duration(seconds: 2 * (_reconnectAttempts + 1)); // Exponential backoff

    _reconnectTimer = Timer(delay, () async {
      if (!mounted) return;

      _reconnectAttempts++;
      print('Reconnection attempt $_reconnectAttempts of $_maxReconnectAttempts');

      if (mounted) {
        Snackbar.show(ABC.c, "Reconnecting... (attempt $_reconnectAttempts/$_maxReconnectAttempts)", success: true);
      }

      try {
        await onConnectPressed();
      } catch (e) {
        print('Reconnection attempt failed: $e');
        if (_reconnectAttempts < _maxReconnectAttempts) {
          _scheduleReconnect();
        }
      }
    });
  }

  Future<void> _refreshDockerStatus() async {
    try {
      final ch = findCharacteristicByUuid(_services, dockerContainerControlCharUUID);
      if (ch == null) {
        Snackbar.show(ABC.c, 'Docker status characteristic not found', success: false);
        return;
      }
      final value = await ch.read();
      _updateCharacteristicValue(ch.uuid.str128, value);
    } catch (e) {
      Snackbar.show(ABC.c, prettyException('Docker Status Error:', e), success: false);
    }
  }

  Future<void> _checkForUpdate() async {
    if (_isUpdateCheckBusy) return;
    if (_connectionState != BluetoothConnectionState.connected) return;

    setState(() => _isUpdateCheckBusy = true);
    try {
      final ch = findCharacteristicByUuid(_services, dockerUpdateCheckCharUUID);
      if (ch == null) {
        Snackbar.show(ABC.c, 'Update check characteristic not found', success: false);
        return;
      }
      final value = await ch.read();
      _updateCharacteristicValue(ch.uuid.str128, value);
    } catch (e) {
      Snackbar.show(ABC.c, prettyException('Update Check Error:', e), success: false);
    } finally {
      if (mounted) setState(() => _isUpdateCheckBusy = false);
    }
  }

  Future<void> _sendDockerCommand(String command) async {
    if (_isDockerBusy) return;
    if (_connectionState != BluetoothConnectionState.connected) return;

    setState(() => _isDockerBusy = true);
    try {
      final ch = findCharacteristicByUuid(_services, dockerContainerControlCharUUID);
      if (ch == null) {
        Snackbar.show(ABC.c, 'Docker control characteristic not found', success: false);
        return;
      }

      await ch.write(utf8.encode(command));
      await _refreshDockerStatus();
    } catch (e) {
      Snackbar.show(ABC.c, prettyException('Docker Command Error:', e), success: false);
    } finally {
      if (mounted) setState(() => _isDockerBusy = false);
    }
  }

  Future<void> _triggerSystemUpdate() async {
    if (_isUpdating) return;
    if (_connectionState != BluetoothConnectionState.connected) return;

    // Confirmation dialog — the update script will reboot the device
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('System Update'),
        content: const Text(
          'This will download the latest software and reboot the device. '
          'The connection will be lost during the update.\n\n'
          'Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isUpdating = true;
      _showUpdateLog = true;
      _updateLog = '';
    });
    try {
      final ch = findCharacteristicByUuid(_services, systemUpdateCharUUID);
      if (ch == null) {
        Snackbar.show(ABC.c, 'Update characteristic not found', success: false);
        setState(() => _isUpdating = false);
        return;
      }
      await ch.write(utf8.encode('update'));
      Snackbar.show(ABC.c, 'Update started', success: true);
    } catch (e) {
      Snackbar.show(ABC.c, prettyException('Update Error:', e), success: false);
      setState(() => _isUpdating = false);
    }
  }

  Widget buildDockerContainerCard() {
    final statusRaw = (_characteristicValues[dockerContainerControlCharUUID] ?? '').trim();

    final versionRaw = (_characteristicValues[planeSignVersionCharUUID] ?? '').trim();
    final versionDisplay = versionRaw.isEmpty ? 'Unknown' : versionRaw;

    final dockerDisplay = dockerRuntimeDisplayFromRaw(statusRaw);

    final running = dockerDisplay.running;
    final hasValue = dockerDisplay.hasValue;
    final borderColor = dockerDisplay.borderColor;
    final icon = dockerDisplay.icon;
    final headline = dockerDisplay.headline;

    // Update check
    final updateRaw = (_characteristicValues[dockerUpdateCheckCharUUID] ?? '').trim();
    final updateDisplay = updateCheckDisplayFromRaw(updateRaw);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor.withValues(alpha: 0.6), width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: borderColor, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PlaneSignRuntime',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[700],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        headline,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh container status',
                  onPressed: _isDockerBusy ? null : _refreshDockerStatus,
                  icon: _isDockerBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Version: $versionDisplay',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            const SizedBox(height: 8),
            // Update check section
            Row(
              children: [
                Icon(updateDisplay.icon, color: updateDisplay.borderColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    updateDisplay.headline,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: updateDisplay.borderColor,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _isUpdateCheckBusy ? null : _checkForUpdate,
                  icon: _isUpdateCheckBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 18),
                  label: const Text('Check', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: (_isUpdating || _isDockerBusy) ? null : _triggerSystemUpdate,
                  icon: _isUpdating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update, size: 18),
                  label: Text(
                    _isUpdating ? 'Updating…' : 'Update',
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.indigo,
                  ),
                ),
              ],
            ),
            if (updateDisplay.localDigest.isNotEmpty || updateDisplay.remoteDigest.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: Text(
                  'Local: ${updateDisplay.localDigest}  Remote: ${updateDisplay.remoteDigest}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isDockerBusy || running) ? null : () => _sendDockerCommand('start'),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: (_isDockerBusy || !running) ? null : () => _sendDockerCommand('stop'),
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
            if (_showUpdateLog) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.grey[800],
                        border: Border(bottom: BorderSide(color: Colors.grey[700]!, width: 0.5)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.terminal, size: 14, color: Colors.grey[400]),
                          const SizedBox(width: 6),
                          Text(
                            'Update Output',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[400],
                            ),
                          ),
                          const Spacer(),
                          if (_updateLog.isNotEmpty && !_isUpdating)
                            InkWell(
                              onTap: () => setState(() {
                                _showUpdateLog = false;
                                _updateLog = '';
                              }),
                              child: Icon(Icons.close, size: 14, color: Colors.grey[500]),
                            ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        controller: _updateLogScrollController,
                        padding: const EdgeInsets.all(8),
                        child: SizedBox(
                          width: double.infinity,
                          child: SelectableText(
                            _updateLog.isEmpty ? 'Waiting for output...' : _updateLog,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.greenAccent,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _isConnectingSubscription.cancel();
    _reconnectTimer?.cancel();
    _updateLogScrollController.dispose();
    super.dispose();
  }

  Future onConnectPressed() async {
    try {
      // Cancel any pending reconnection attempts
      _reconnectTimer?.cancel();

      await widget.device.connectAndUpdateStream();

      // Request higher MTU for better data throughput (if supported)
      try {
        await widget.device.requestMtu(512);
      } catch (e) {
        // MTU request might not be supported on all platforms
        print('MTU request failed: $e');
      }
    } catch (e) {
      if (e is! FlutterBluePlusException || e.code != FbpErrorCode.connectionCanceled.index) {
        Snackbar.show(ABC.c, prettyException("Connect Error:", e), success: false);
      }
    }
  }

  // Unified pull-to-refresh handler: force a clean reconnect & resubscribe
  Future<void> _handlePullToRefresh() async {
    try {
      Snackbar.show(ABC.c, "Refreshing connection...", success: true);

      // Clear in-memory caches immediately for visual feedback
      setState(() {
        _services = [];
        _characteristicValues.clear();
        _reconnectAttempts = 0; // treat as fresh session
      });

      // If currently connected (or connecting), attempt a graceful disconnect first
      BluetoothConnectionState currentState = _connectionState;
      if (currentState == BluetoothConnectionState.connected) {
        try {
          await widget.device.disconnect(queue: false);
        } catch (_) {
          // Ignore disconnect errors
        }
      }

      // Give the stack a brief pause to settle before reconnect
      await Future.delayed(const Duration(milliseconds: 250));

      await onConnectPressed();

      // Allow listener (discoverServices, subscriptions) to complete
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Refresh Error:", e), success: false);
    }
  }

  Widget buildCharacteristicTile(BluetoothCharacteristic c) {
    String value = _characteristicValues[c.uuid.str128.toLowerCase()] ?? 'No value';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('0x${c.uuid.str.toUpperCase()}', style: TextStyle(fontWeight: FontWeight.w500)),
          SizedBox(height: 4),
          Text('Value: $value', style: TextStyle(color: Colors.grey[700])),
        ],
      ),
    );
  }

  Widget buildTemperatureDisplay() {
    final tempRaw = _characteristicValues[tempCharUUID] ?? 'No reading';
    final tempDisplay = formatRpiTemperature(tempRaw);
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.thermostat, size: 40, color: Colors.blue),
            SizedBox(width: 16),
            Text(
              tempDisplay,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildHostnameDisplay() {
    String hostname = _characteristicValues[hostnameCharUUID] ?? 'Unknown';
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.computer, size: 40, color: Colors.green),
            SizedBox(width: 16),
            Text(
              hostname,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildIpAddressDisplay() {
    String ipAddress = _characteristicValues[ipAddressCharUUID] ?? 'Unknown';
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.router, size: 40, color: Colors.teal),
            SizedBox(width: 16),
            Text(
              ipAddress,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildInfoCard() {
    final tempRaw = _characteristicValues[tempCharUUID] ?? 'No reading';
    final tempValue = formatRpiTemperature(tempRaw);
    final hostname = _characteristicValues[hostnameCharUUID] ?? 'Unknown';
    final ipAddress = _characteristicValues[ipAddressCharUUID] ?? 'Unknown';
    final uptimeRaw = _characteristicValues[uptimeCharUUID] ?? 'No reading';
    final uptimeDisplay = extractUptimeFromOutput(uptimeRaw);

    Widget row({required IconData icon, required Color color, required String label, required String value}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 10),
            SizedBox(
              width: 90,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[700],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Info',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            row(
              icon: Icons.thermostat,
              color: Colors.blue,
              label: 'Temp',
              value: tempValue,
            ),
            row(
              icon: Icons.computer,
              color: Colors.green,
              label: 'Hostname',
              value: hostname,
            ),
            row(
              icon: Icons.router,
              color: Colors.teal,
              label: 'IP Address',
              value: ipAddress,
            ),
            row(
              icon: Icons.access_time,
              color: Colors.purple,
              label: 'Uptime',
              value: uptimeDisplay,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rebootDevice() async {
    try {
      for (var service in _services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.str.toLowerCase() == rebootCharUUID.toLowerCase()) {
            await characteristic.write(utf8.encode('reboot'));
            Snackbar.show(ABC.c, "Reboot command sent", success: true);
            return;
          }
        }
      }
      Snackbar.show(ABC.c, "Reboot characteristic not found", success: false);
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Reboot Error:", e), success: false);
    }
  }

  Future<void> _confirmAndRebootDevice() async {
    if (_connectionState != BluetoothConnectionState.connected) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reboot device?'),
        content: const Text(
          'This will restart the PlaneSign device. You may need to reconnect after it comes back online.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reboot'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _rebootDevice();
    }
  }

  Future<void> _openHostInBrowser() async {
    final raw = _characteristicValues[ipAddressCharUUID];
    if (raw == null || raw.trim().isEmpty) {
      Snackbar.show(ABC.c, "IP address not available", success: false);
      return;
    }
    final ipAddress = raw.trim();
    final uri = Uri.tryParse('https://$ipAddress');
    if (uri == null) {
      Snackbar.show(ABC.c, "Malformed URL", success: false);
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        Snackbar.show(ABC.c, "Could not launch browser", success: false);
      }
    } catch (e) {
      Snackbar.show(ABC.c, prettyException("Launch Error:", e), success: false);
    }
  }

  Widget buildOpenBrowserCard() {
    final raw = _characteristicValues[ipAddressCharUUID];
    final hasIp = raw != null && raw.trim().isNotEmpty;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: hasIp ? Colors.indigo[50] : Colors.grey[200],
      child: InkWell(
        onTap: hasIp ? _openHostInBrowser : null,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.open_in_browser, size: 40, color: hasIp ? Colors.indigo : Colors.grey),
              const SizedBox(width: 16),
              Text(
                'Open Web Console',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: hasIp ? Colors.indigo : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildRebootButton() {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.red[100],
      child: InkWell(
        onTap: _connectionState == BluetoothConnectionState.connected ? _confirmAndRebootDevice : null,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.restart_alt, size: 40, color: Colors.red),
              SizedBox(width: 16),
              Text(
                'Reboot Device',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.red,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildUptimeDisplay() {
    String uptimeRaw = _characteristicValues[uptimeCharUUID] ?? 'No reading';
    String uptimeDisplay = extractUptimeFromOutput(uptimeRaw);

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.access_time, size: 40, color: Colors.purple),
            SizedBox(width: 16),
            Text(
              uptimeDisplay,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildWifiStatusCard() {
    final wifiRaw = _characteristicValues[wifiStatusCharUUID] ?? '';
    final wifiDisplay = wifiStatusDisplayFromRaw(wifiRaw);

    final status = wifiDisplay.status;
    final ssid = wifiDisplay.ssid;
    final signalStrength = wifiDisplay.signalStrength;
    final isConnected = wifiDisplay.isConnected;
    final wifiIcon = wifiDisplay.icon;
    final wifiColor = wifiDisplay.color;
    final signalText = wifiDisplay.signalText;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: wifiColor.withValues(alpha: 0.5), width: 2),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: LinearGradient(
            colors: [wifiColor.withValues(alpha: 0.1), wifiColor.withValues(alpha: 0.05)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: wifiColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(wifiIcon, size: 32, color: wifiColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pi WiFi Connection',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isConnected ? ssid : status,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _showWifiConfigDialog,
                    icon: Icon(Icons.wifi_find, size: 18, color: wifiColor),
                    label: const Text('Configure'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      side: BorderSide(color: wifiColor.withValues(alpha: 0.8)),
                      foregroundColor: wifiColor,
                      textStyle: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: (signalStrength.clamp(0, 100)) / 100,
                        backgroundColor: Colors.grey[300],
                        valueColor: AlwaysStoppedAnimation<Color>(wifiColor),
                        minHeight: 8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    isConnected ? '$signalText ($signalStrength%)' : 'Not connected',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isConnected ? wifiColor : Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<List<Map<String, String>>> _scanWifiNetworks() async {
    try {
      for (var service in _services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.str128.toLowerCase() == wifiScanCharUUID.toLowerCase() ||
              characteristic.uuid.str.toLowerCase() == wifiScanCharUUID.toLowerCase()) {
            final value = await characteristic.read();
            final decoded = utf8.decode(value, allowMalformed: true).trim();

            // Parse format: "SSID|signal|encrypted" per line
            final networks = <Map<String, String>>[];
            for (var line in decoded.split('\n')) {
              if (line.trim().isEmpty) continue;
              final parts = line.split('|');
              if (parts.isNotEmpty && parts[0].isNotEmpty) {
                networks.add({
                  'ssid': parts[0].trim(),
                  'signal': parts.length > 1 ? parts[1].trim() : '0',
                  'encrypted': parts.length > 2 ? parts[2].trim() : 'no',
                });
              }
            }
            return networks;
          }
        }
      }
      return [];
    } catch (e) {
      print('Error scanning WiFi: $e');
      return [];
    }
  }

  Future<bool> _configureWifi(String ssid, String password) async {
    try {
      BluetoothCharacteristic? wifiCh;
      for (var service in _services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.str128.toLowerCase() == wifiConfigCharUUID.toLowerCase() ||
              characteristic.uuid.str.toLowerCase() == wifiConfigCharUUID.toLowerCase()) {
            wifiCh = characteristic;
            break;
          }
        }
        if (wifiCh != null) break;
      }

      if (wifiCh == null) return false;

      final canWrite = wifiCh.properties.write;
      final canWriteNoResp = wifiCh.properties.writeWithoutResponse;
      if (!canWrite && !canWriteNoResp) {
        debugPrint('[WiFi] Config characteristic not writable: ${wifiCh.uuid}');
        return false;
      }

      // Format: "SSID|PASSWORD" or "SSID|" for open networks
      final credentials = '$ssid|$password';
      final bytes = utf8.encode(credentials);

      bool looksLikeGattUnlikely(Object e) {
        final s = e.toString();
        return s.contains('GATT_UNLIKELY') || s.contains('android-code: 14') || s.contains('androidCode: 14');
      }

      Future<void> doWrite(bool withoutResponse) async {
        debugPrint(
          '[WiFi] Writing config to ${wifiCh!.uuid} (ssid="$ssid", bytes=${bytes.length}, withoutResponse=$withoutResponse)',
        );
        await wifiCh.write(
          bytes,
          withoutResponse: withoutResponse,
          allowLongWrite: true,
        );
      }

      // Prefer writeWithoutResponse when available; some peripherals reject write-with-response.
      final preferredWithoutResponse = canWriteNoResp;
      final modesToTry = <bool>[];
      if (preferredWithoutResponse) {
        modesToTry.add(true);
        if (canWrite) modesToTry.add(false);
      } else {
        modesToTry.add(false);
        if (canWriteNoResp) modesToTry.add(true);
      }

      for (final mode in modesToTry) {
        try {
          await doWrite(mode);
          return true;
        } catch (e) {
          debugPrint('[WiFi] Write failed (withoutResponse=$mode): $e');
          if (looksLikeGattUnlikely(e)) {
            await Future.delayed(const Duration(milliseconds: 250));
            continue;
          }
          return false;
        }
      }

      // Final retry on preferred mode (common transient on Android)
      try {
        await Future.delayed(const Duration(milliseconds: 500));
        await doWrite(preferredWithoutResponse);
        return true;
      } catch (e) {
        debugPrint('[WiFi] Final retry failed: $e');
        return false;
      }
    } catch (e) {
      print('Error configuring WiFi: $e');
      return false;
    }
  }

  void _showWifiConfigDialog() {
    showDialog(
      context: context,
      builder: (context) => _WifiConfigDialog(
        onScan: _scanWifiNetworks,
        onConfigure: _configureWifi,
      ),
    );
  }

  Widget buildWifiConfigButton() {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.blue[50],
      child: InkWell(
        onTap: _connectionState == BluetoothConnectionState.connected ? _showWifiConfigDialog : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_find, size: 40, color: Colors.blue[700]),
              const SizedBox(width: 16),
              Text(
                'Configure WiFi',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue[700],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName),
      ),
      body: RefreshIndicator(
        key: _refreshKey,
        color: Theme.of(context).colorScheme.primary,
        onRefresh: _handlePullToRefresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: <Widget>[
              ListTile(
                title: Text(
                  'Status: ${_connectionState.toString().split('.')[1]}',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: _reconnectAttempts > 0
                    ? Text('Reconnection attempts: $_reconnectAttempts/$_maxReconnectAttempts')
                    : null,
                trailing: IconButton(
                  tooltip: 'Refresh / Reconnect',
                  icon: const Icon(Icons.sync),
                  onPressed: () {
                    _refreshKey.currentState?.show();
                    _handlePullToRefresh();
                  },
                ),
              ),

              // Manual reconnect button (also redundant with pull-to-refresh, but kept)
              if (_connectionState == BluetoothConnectionState.disconnected)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: InkWell(
                    onTap: () {
                      _reconnectAttempts = 0; // Reset counter for manual reconnect
                      onConnectPressed();
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.refresh, size: 40, color: Colors.blue),
                          SizedBox(width: 16),
                          Text(
                            'Reconnect',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_connectionState == BluetoothConnectionState.connected) ...[
                buildDockerContainerCard(),
                buildWifiStatusCard(),
                buildInfoCard(),
                buildOpenBrowserCard(),
                buildRebootButton(),
              ],
              const SizedBox(height: 32), // Ensure scroll area even if few widgets
            ],
          ),
        ),
      ),
    );
  }
}

// WiFi Configuration Dialog Widget
class _WifiConfigDialog extends StatefulWidget {
  final Future<List<Map<String, String>>> Function() onScan;
  final Future<bool> Function(String ssid, String password) onConfigure;

  const _WifiConfigDialog({
    required this.onScan,
    required this.onConfigure,
  });

  @override
  State<_WifiConfigDialog> createState() => _WifiConfigDialogState();
}

class _WifiConfigDialogState extends State<_WifiConfigDialog> {
  List<Map<String, String>> _networks = [];
  bool _isScanning = false;
  bool _isConfiguring = false;
  String? _selectedSsid;
  bool _selectedIsEncrypted = true;
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    setState(() {
      _isScanning = true;
      _networks = [];
    });

    final networks = await widget.onScan();

    // Sort strongest signal first
    networks.sort((a, b) {
      final qa = signalQuality(a['signal'] ?? '');
      final qb = signalQuality(b['signal'] ?? '');
      final bySignal = qb.compareTo(qa);
      if (bySignal != 0) return bySignal;
      return (a['ssid'] ?? '').compareTo(b['ssid'] ?? '');
    });

    if (mounted) {
      setState(() {
        _networks = networks;
        _isScanning = false;
      });
    }
  }

  Future<void> _configure() async {
    if (_selectedSsid == null) return;

    setState(() => _isConfiguring = true);

    final success = await widget.onConfigure(
      _selectedSsid!,
      _passwordController.text,
    );

    if (mounted) {
      setState(() => _isConfiguring = false);

      if (success) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('WiFi configured: $_selectedSsid'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to configure WiFi'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  IconData _getSignalIcon(String signalStr) {
    return wifiSignalIcon(signalStr);
  }

  Color _getSignalColor(String signalStr) {
    return wifiSignalColor(signalStr);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.wifi, color: Colors.blue),
          const SizedBox(width: 8),
          const Expanded(child: Text('Configure WiFi')),
          if (_isScanning)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startScan,
              tooltip: 'Rescan',
            ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isScanning && _networks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Scanning for networks...')),
              )
            else if (_networks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No networks found')),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _networks.length,
                  itemBuilder: (context, index) {
                    final network = _networks[index];
                    final ssid = network['ssid'] ?? '';
                    final signal = network['signal'] ?? '0';
                    final encrypted = network['encrypted']?.toLowerCase() != 'no';
                    final isSelected = _selectedSsid == ssid;

                    return ListTile(
                      leading: Icon(
                        _getSignalIcon(signal),
                        color: _getSignalColor(signal),
                      ),
                      title: Text(
                        ssid,
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        '${signal.contains('dBm') ? signal : '$signal dBm'} • ${encrypted ? 'Secured' : 'Open'}',
                      ),
                      trailing: encrypted ? const Icon(Icons.lock, size: 16) : const Icon(Icons.lock_open, size: 16),
                      selected: isSelected,
                      selectedTileColor: Colors.blue.withValues(alpha: 0.1),
                      onTap: () {
                        setState(() {
                          _selectedSsid = ssid;
                          _selectedIsEncrypted = encrypted;
                          _passwordController.clear();
                        });
                      },
                    );
                  },
                ),
              ),
            if (_selectedSsid != null) ...[
              const Divider(),
              Text(
                'Selected: $_selectedSsid',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              if (_selectedIsEncrypted)
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                  ),
                )
              else
                const Text(
                  'This is an open network (no password required)',
                  style: TextStyle(color: Colors.grey),
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedSsid != null && !_isConfiguring ? _configure : null,
          child: _isConfiguring
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }
}
