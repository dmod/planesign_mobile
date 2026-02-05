import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

BluetoothCharacteristic? findCharacteristicByUuid(
  List<BluetoothService> services,
  String uuid,
) {
  final needle = uuid.toLowerCase();
  for (final service in services) {
    for (final characteristic in service.characteristics) {
      final u128 = characteristic.uuid.str128.toLowerCase();
      final u16 = characteristic.uuid.str.toLowerCase();
      if (u128 == needle || u16 == needle) {
        return characteristic;
      }
    }
  }
  return null;
}

String decodeBleUtf8String(List<int> value) {
  var decoded = utf8.decode(value, allowMalformed: true);
  decoded = decoded.replaceAll('\x00', '').trim();
  return decoded;
}
