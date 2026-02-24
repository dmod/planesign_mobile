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

class UpdateCheckDisplay {
  final bool updateAvailable;
  final bool checkFailed;
  final String headline;
  final String localDigest;
  final String remoteDigest;
  final Color borderColor;
  final IconData icon;

  const UpdateCheckDisplay({
    required this.updateAvailable,
    required this.checkFailed,
    required this.headline,
    required this.localDigest,
    required this.remoteDigest,
    required this.borderColor,
    required this.icon,
  });
}

UpdateCheckDisplay updateCheckDisplayFromRaw(String raw) {
  final trimmed = raw.trim();
  final normalized = trimmed.toLowerCase();

  if (trimmed.isEmpty) {
    return const UpdateCheckDisplay(
      updateAvailable: false,
      checkFailed: false,
      headline: 'Not checked',
      localDigest: '',
      remoteDigest: '',
      borderColor: Colors.grey,
      icon: Icons.help_outline,
    );
  }

  // Parse pipe-delimited fields: "status|local=xxx|remote=yyy"
  String localDigest = '';
  String remoteDigest = '';
  final parts = trimmed.split('|');
  for (final part in parts) {
    if (part.startsWith('local=')) {
      localDigest = part.substring(6);
    } else if (part.startsWith('remote=')) {
      remoteDigest = part.substring(7);
    }
  }

  if (normalized.startsWith('update-available')) {
    return UpdateCheckDisplay(
      updateAvailable: true,
      checkFailed: false,
      headline: 'Update Available',
      localDigest: localDigest,
      remoteDigest: remoteDigest,
      borderColor: Colors.blue,
      icon: Icons.system_update,
    );
  } else if (normalized.startsWith('up-to-date')) {
    return UpdateCheckDisplay(
      updateAvailable: false,
      checkFailed: false,
      headline: 'Up to Date',
      localDigest: localDigest,
      remoteDigest: remoteDigest,
      borderColor: Colors.green,
      icon: Icons.check_circle_outline,
    );
  } else {
    // "check failed: ..." or unexpected format
    return UpdateCheckDisplay(
      updateAvailable: false,
      checkFailed: true,
      headline: trimmed,
      localDigest: localDigest,
      remoteDigest: remoteDigest,
      borderColor: Colors.orange,
      icon: Icons.warning_amber,
    );
  }
}
