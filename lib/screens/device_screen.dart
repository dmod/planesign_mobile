import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../utils/snackbar.dart';
import '../utils/extra.dart';

class DeviceScreen extends StatefulWidget {
  final BluetoothDevice device;

  const DeviceScreen({super.key, required this.device});

  @override
  State<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<DeviceScreen> {
  static const String TEMP_CHARACTERISTIC_UUID =
      'abbd155c-e9d1-4d9d-ae9e-6871b20880e4';
  static const String HOSTNAME_CHARACTERISTIC_UUID =
      '7e60d076-d3fd-496c-8460-63a0454d94d9';
  static const String REBOOT_CHARACTERISTIC_UUID =
      '99945678-1234-5678-1234-56789abcdef2';
  static const String VERSION_CHARACTERISTIC_UUID =
      '2d037cd2-c565-4d61-af60-be26ffb7209c';

  BluetoothConnectionState _connectionState =
      BluetoothConnectionState.disconnected;
  List<BluetoothService> _services = [];
  bool _isDiscoveringServices = false;
  bool _isConnecting = false;
  Map<String, String> _characteristicValues = {};

  late StreamSubscription<BluetoothConnectionState>
      _connectionStateSubscription;
  late StreamSubscription<bool> _isConnectingSubscription;

  @override
  void initState() {
    super.initState();

    _connectionStateSubscription =
        widget.device.connectionState.listen((state) async {
      _connectionState = state;
      if (state == BluetoothConnectionState.connected) {
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
                  print(
                      'Error reading characteristic ${characteristic.uuid}: $e');
                }
              }
              if (characteristic.properties.notify ||
                  characteristic.properties.indicate) {
                try {
                  await characteristic.setNotifyValue(true);
                  characteristic.lastValueStream.listen((value) {
                    _updateCharacteristicValue(characteristic.uuid.str, value);
                  });
                } catch (e) {
                  print(
                      'Error subscribing to characteristic ${characteristic.uuid}: $e');
                }
              }
            }
          }
        } catch (e) {
          Snackbar.show(ABC.c, prettyException("Discover Services Error:", e),
              success: false);
        }
        if (mounted) {
          setState(() {
            _isDiscoveringServices = false;
          });
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

  @override
  void dispose() {
    _connectionStateSubscription.cancel();
    _isConnectingSubscription.cancel();
    super.dispose();
  }

  Future onConnectPressed() async {
    try {
      await widget.device.connectAndUpdateStream();
    } catch (e) {
      if (e is! FlutterBluePlusException ||
          e.code != FbpErrorCode.connectionCanceled.index) {
        Snackbar.show(ABC.c, prettyException("Connect Error:", e),
            success: false);
      }
    }
  }

  Widget buildServiceTile(BluetoothService service) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.all(16),
          color: Colors.grey[200],
          child: Text(
            'Service: 0x${service.uuid.str.toUpperCase()}',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ...service.characteristics
            .map((c) => buildCharacteristicTile(c))
            .toList(),
        Divider(),
      ],
    );
  }

  Widget buildCharacteristicTile(BluetoothCharacteristic c) {
    String value = _characteristicValues[c.uuid.str] ?? 'No value';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('0x${c.uuid.str.toUpperCase()}',
              style: TextStyle(fontWeight: FontWeight.w500)),
          SizedBox(height: 4),
          Text('Value: $value', style: TextStyle(color: Colors.grey[700])),
        ],
      ),
    );
  }

  Widget buildTemperatureDisplay() {
    String tempValue =
        _characteristicValues[TEMP_CHARACTERISTIC_UUID] ?? 'No reading';
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
    String hostname =
        _characteristicValues[HOSTNAME_CHARACTERISTIC_UUID] ?? 'Unknown';
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

  Widget buildVersionDisplay() {
    String hostname =
        _characteristicValues[HOSTNAME_CHARACTERISTIC_UUID] ?? 'Unknown';
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
          if (characteristic.uuid.str.toLowerCase() ==
              REBOOT_CHARACTERISTIC_UUID.toLowerCase()) {
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
        onTap: _connectionState == BluetoothConnectionState.connected
            ? _rebootDevice
            : null,
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
            ),
            if (_connectionState == BluetoothConnectionState.connected) ...[
              buildTemperatureDisplay(),
              buildHostnameDisplay(),
              buildRebootButton(),
            ],
            if (_isDiscoveringServices)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20.0),
                  child: CircularProgressIndicator(),
                ),
              ),
            ..._services.map(buildServiceTile).toList(),
          ],
        ),
      ),
    );
  }
}
