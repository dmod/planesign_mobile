import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
// Requires url_launcher dependency (added in pubspec)
import 'package:url_launcher/url_launcher.dart';

import '../utils/snackbar.dart';
import '../utils/extra.dart';
import '../utils/utils.dart';

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

  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  Map<String, String> _characteristicValues = {};

  // Connection stability variables
  bool _autoReconnect = true;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _reconnectTimer;

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

    String decoded = utf8.decode(value, allowMalformed: true);

    // Remove any trailing NULLs and trim whitespace
    decoded = decoded.replaceAll('\x00', '').trim();

    debugPrint('[BLE] Update $key (${value.length} bytes) raw=$value utf8="$decoded"');

    if (mounted) {
      setState(() {
        _characteristicValues[key] = decoded;
      });
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

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _isConnectingSubscription.cancel();
    _reconnectTimer?.cancel();
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
    String tempValue = _characteristicValues[tempCharUUID] ?? 'No reading';
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
              tempValue,
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
        onTap: _connectionState == BluetoothConnectionState.connected ? _rebootDevice : null,
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
    // Format from PlaneSign BLE: "Connected|SSID|signal" or "Disconnected|None|0" or "Error|...|0"
    String wifiRaw = _characteristicValues[wifiStatusCharUUID] ?? '';

    String status = 'Unknown';
    String ssid = 'Not Connected';
    int signalStrength = 0;
    bool isConnected = false;
    bool isError = false;

    if (wifiRaw.isNotEmpty) {
      final parts = wifiRaw.split('|');
      if (parts.isNotEmpty) {
        status = parts[0];
        isConnected = status == 'Connected';
        isError = status == 'Error';

        if (parts.length > 1) {
          ssid = parts[1].isNotEmpty ? parts[1] : 'Unknown Network';
        }
        if (parts.length > 2) {
          signalStrength = int.tryParse(parts[2]) ?? 0;
        }
      }
    }

    // Determine icon and color based on connection status and signal strength
    IconData wifiIcon;
    Color wifiColor;
    String signalText;

    if (isError) {
      wifiIcon = Icons.wifi_off;
      wifiColor = Colors.orange;
      signalText = 'Error';
    } else if (!isConnected) {
      wifiIcon = Icons.wifi_off;
      wifiColor = Colors.red;
      signalText = 'Disconnected';
    } else if (signalStrength >= 70) {
      wifiIcon = Icons.wifi;
      wifiColor = Colors.green;
      signalText = 'Excellent';
    } else if (signalStrength >= 50) {
      wifiIcon = Icons.wifi;
      wifiColor = Colors.lightGreen;
      signalText = 'Good';
    } else if (signalStrength >= 30) {
      wifiIcon = Icons.wifi_2_bar;
      wifiColor = Colors.orange;
      signalText = 'Fair';
    } else {
      wifiIcon = Icons.wifi_1_bar;
      wifiColor = Colors.red;
      signalText = 'Weak';
    }

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
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: wifiColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(wifiIcon, size: 36, color: wifiColor),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Pi WiFi Connection',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isConnected ? ssid : status,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (isConnected) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: signalStrength / 100,
                          backgroundColor: Colors.grey[300],
                          valueColor: AlwaysStoppedAnimation<Color>(wifiColor),
                          minHeight: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '$signalText ($signalStrength%)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: wifiColor,
                      ),
                    ),
                  ],
                ),
              ],
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
          if (characteristic.uuid.str.toLowerCase() == wifiScanCharUUID.toLowerCase()) {
            final value = await characteristic.read();
            final decoded = utf8.decode(value, allowMalformed: true).trim();

            // Parse format: "SSID|signal|encrypted" per line
            final networks = <Map<String, String>>[];
            for (var line in decoded.split('\n')) {
              if (line.trim().isEmpty) continue;
              final parts = line.split('|');
              if (parts.isNotEmpty && parts[0].isNotEmpty) {
                networks.add({
                  'ssid': parts[0],
                  'signal': parts.length > 1 ? parts[1] : '0',
                  'encrypted': parts.length > 2 ? parts[2] : 'no',
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
      for (var service in _services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.str.toLowerCase() == wifiConfigCharUUID.toLowerCase()) {
            // Format: "SSID|PASSWORD" or "SSID|" for open networks
            final credentials = '$ssid|$password';
            await characteristic.write(utf8.encode(credentials));
            return true;
          }
        }
      }
      return false;
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
                buildWifiStatusCard(),
                buildWifiConfigButton(),
                buildTemperatureDisplay(),
                buildHostnameDisplay(),
                buildIpAddressDisplay(),
                buildOpenBrowserCard(),
                buildUptimeDisplay(),
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
    final signal = int.tryParse(signalStr.replaceAll(RegExp(r'[^0-9-]'), '')) ?? -100;
    // Signal is typically in dBm (negative) or percentage
    if (signal > 0) {
      // Percentage
      if (signal >= 70) return Icons.wifi;
      if (signal >= 40) return Icons.wifi_2_bar;
      return Icons.wifi_1_bar;
    } else {
      // dBm
      if (signal >= -50) return Icons.wifi;
      if (signal >= -70) return Icons.wifi_2_bar;
      return Icons.wifi_1_bar;
    }
  }

  Color _getSignalColor(String signalStr) {
    final signal = int.tryParse(signalStr.replaceAll(RegExp(r'[^0-9-]'), '')) ?? -100;
    if (signal > 0) {
      if (signal >= 70) return Colors.green;
      if (signal >= 40) return Colors.orange;
      return Colors.red;
    } else {
      if (signal >= -50) return Colors.green;
      if (signal >= -70) return Colors.orange;
      return Colors.red;
    }
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
