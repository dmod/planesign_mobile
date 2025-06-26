import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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
  static const String TEMP_CHARACTERISTIC_UUID = 'abbd155c-e9d1-4d9d-ae9e-6871b20880e4';
  static const String HOSTNAME_CHARACTERISTIC_UUID = '7e60d076-d3fd-496c-8460-63a0454d94d9';
  static const String REBOOT_CHARACTERISTIC_UUID = '99945678-1234-5678-1234-56789abcdef2';
  static const String UPTIME_CHARACTERISTIC_UUID = 'a77a6077-7302-486e-9087-853ac5899335';

  BluetoothConnectionState _connectionState = BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  bool _isDiscoveringServices = false;
  bool _isConnecting = false;
  Map<String, String> _characteristicValues = {};

  // Connection stability variables
  bool _autoReconnect = true;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  Timer? _reconnectTimer;

  late StreamSubscription<BluetoothConnectionState> _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;

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
        if (mounted) {
          setState(() {
            _isDiscoveringServices = true;
          });
        }
        try {
          _services = await widget.device.discoverServices();
          // Automatically read and subscribe to all characteristics
          for (var service in _services) {
            for (var characteristic in service.characteristics) {
              if (characteristic.properties.read) {
                try {
                  final value = await characteristic.read();
                  _updateCharacteristicValue(characteristic.uuid.str, value);
                } catch (e) {
                  print('Error reading characteristic ${characteristic.uuid}: $e');
                }
              }
              if (characteristic.properties.notify || characteristic.properties.indicate) {
                try {
                  await characteristic.setNotifyValue(true);
                  characteristic.lastValueStream.listen((value) {
                    _updateCharacteristicValue(characteristic.uuid.str, value);
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
        if (mounted) {
          setState(() {
            _isDiscoveringServices = false;
          });
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
      _isConnecting = value;
      if (mounted) {
        setState(() {});
      }
    });

    // Auto-connect when screen opens
    onConnectPressed();
  }

  void _updateCharacteristicValue(String uuid, List<int> value) {
    if (mounted) {
      setState(() {
        try {
          _characteristicValues[uuid] = String.fromCharCodes(value);
        } catch (e) {
          _characteristicValues[uuid] = value.toString();
        }
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

  Widget buildCharacteristicTile(BluetoothCharacteristic c) {
    String value = _characteristicValues[c.uuid.str] ?? 'No value';
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
    String tempValue = _characteristicValues[TEMP_CHARACTERISTIC_UUID] ?? 'No reading';
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
    String hostname = _characteristicValues[HOSTNAME_CHARACTERISTIC_UUID] ?? 'Unknown';
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

  Future<void> _rebootDevice() async {
    try {
      for (var service in _services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.str.toLowerCase() == REBOOT_CHARACTERISTIC_UUID.toLowerCase()) {
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
    String uptimeRaw = _characteristicValues[UPTIME_CHARACTERISTIC_UUID] ?? 'No reading';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.platformName),
      ),
      body: SingleChildScrollView(
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
            ),
            // Auto-reconnect toggle
            SwitchListTile(
              title: Text('Auto Reconnect'),
              subtitle: Text('Automatically reconnect when connection is lost'),
              value: _autoReconnect,
              onChanged: (value) {
                setState(() {
                  _autoReconnect = value;
                  if (!value) {
                    _reconnectTimer?.cancel();
                  }
                });
              },
            ),
            // Manual reconnect button
            if (_connectionState == BluetoothConnectionState.disconnected)
              Card(
                margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: InkWell(
                  onTap: () {
                    _reconnectAttempts = 0; // Reset counter for manual reconnect
                    onConnectPressed();
                  },
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
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
              buildTemperatureDisplay(),
              buildHostnameDisplay(),
              buildUptimeDisplay(),
              buildRebootButton(),
            ],
          ],
        ),
      ),
    );
  }
}
