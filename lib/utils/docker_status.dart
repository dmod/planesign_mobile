import 'package:flutter/material.dart';

class DockerRuntimeDisplay {
  final bool running;
  final bool hasValue;
  final Color borderColor;
  final IconData icon;
  final String headline;

  const DockerRuntimeDisplay({
    required this.running,
    required this.hasValue,
    required this.borderColor,
    required this.icon,
    required this.headline,
  });
}

DockerRuntimeDisplay dockerRuntimeDisplayFromRaw(String statusRaw) {
  final trimmed = statusRaw.trim();
  final normalized = trimmed.toLowerCase();

  final running = normalized.contains('running=true') || normalized.contains('status=running');
  final hasValue = trimmed.isNotEmpty;

  Color borderColor;
  IconData icon;
  String headline;

  if (!hasValue) {
    borderColor = Colors.grey;
    icon = Icons.help_outline;
    headline = 'Unknown';
  } else if (normalized.contains('docker not found') ||
      normalized.contains('status unavailable') ||
      normalized.startsWith('error:')) {
    borderColor = Colors.orange;
    icon = Icons.warning_amber;
    headline = 'Unavailable';
  } else if (running) {
    borderColor = Colors.green;
    icon = Icons.check_circle;
    headline = 'Running';
  } else {
    borderColor = Colors.red;
    icon = Icons.cancel;
    headline = 'Stopped';
  }

  return DockerRuntimeDisplay(
    running: running,
    hasValue: hasValue,
    borderColor: borderColor,
    icon: icon,
    headline: headline,
  );
}
