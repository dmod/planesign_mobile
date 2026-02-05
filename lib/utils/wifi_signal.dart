import 'package:flutter/material.dart';

class WifiStatusDisplay {
  final String status;
  final String ssid;
  final int signalStrength;
  final bool isConnected;
  final bool isError;
  final IconData icon;
  final Color color;
  final String signalText;

  const WifiStatusDisplay({
    required this.status,
    required this.ssid,
    required this.signalStrength,
    required this.isConnected,
    required this.isError,
    required this.icon,
    required this.color,
    required this.signalText,
  });
}

WifiStatusDisplay wifiStatusDisplayFromRaw(String wifiRaw) {
  // Format from PlaneSign BLE: "Connected|SSID|signal" or "Disconnected|None|0" or "Error|...|0"
  var status = 'Unknown';
  var ssid = 'Not Connected';
  var signalStrength = 0;
  var isConnected = false;
  var isError = false;

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

  return WifiStatusDisplay(
    status: status,
    ssid: ssid,
    signalStrength: signalStrength,
    isConnected: isConnected,
    isError: isError,
    icon: wifiIcon,
    color: wifiColor,
    signalText: signalText,
  );
}

int? parseSignalDbm(String signalStr) {
  // Accepts formats like "-55", "-55 dBm", "RSSI:-55".
  final cleaned = signalStr.trim();
  final match = RegExp(r'-\d{1,3}').firstMatch(cleaned);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}

int? parseSignalPercent(String signalStr) {
  // Accepts formats like "72", "72%".
  final cleaned = signalStr.trim();
  // If there's a negative number present, treat it as dBm instead.
  if (RegExp(r'-\d{1,3}').hasMatch(cleaned)) return null;
  final match = RegExp(r'\d{1,3}').firstMatch(cleaned);
  if (match == null) return null;
  final val = int.tryParse(match.group(0)!);
  if (val == null) return null;
  return val;
}

int signalQuality(String signalStr) {
  // Returns a 0..100 quality score for sorting and UI.
  // Prefer interpreting negative numbers as RSSI dBm.
  final dbm = parseSignalDbm(signalStr);
  if (dbm != null) {
    // Map dBm range [-100..-30] to [0..100]
    final clamped = dbm.clamp(-100, -30);
    final quality = ((clamped + 100) * 100 / 70).round();
    return quality.clamp(0, 100);
  }

  final percent = parseSignalPercent(signalStr);
  if (percent != null) return percent.clamp(0, 100);

  return 0;
}

IconData wifiSignalIcon(String signalStr) {
  final dbm = parseSignalDbm(signalStr);
  if (dbm != null) {
    if (dbm >= -60) return Icons.wifi;
    if (dbm >= -75) return Icons.wifi_2_bar;
    if (dbm >= -90) return Icons.wifi_1_bar;
    return Icons.wifi_off;
  }

  final percent = parseSignalPercent(signalStr) ?? 0;
  if (percent >= 70) return Icons.wifi;
  if (percent >= 40) return Icons.wifi_2_bar;
  if (percent >= 15) return Icons.wifi_1_bar;
  return Icons.wifi_off;
}

Color wifiSignalColor(String signalStr) {
  // Natural colors based on RSSI dBm: green (strong), amber (medium), red (weak)
  final dbm = parseSignalDbm(signalStr);
  if (dbm != null) {
    if (dbm >= -60) return Colors.green;
    if (dbm >= -75) return Colors.amber;
    return Colors.red;
  }

  // Fallback for percentage-based values
  final percent = parseSignalPercent(signalStr) ?? 0;
  if (percent >= 70) return Colors.green;
  if (percent >= 40) return Colors.amber;
  return Colors.red;
}
