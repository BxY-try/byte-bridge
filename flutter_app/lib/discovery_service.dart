import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Hasil discovery: alamat IP dan port server yang ketemu di jaringan.
class ServerInfo {
  final String ip;
  final int port;
  ServerInfo(this.ip, this.port);
}

const int kDiscoveryPort = 37020;
const String kServiceTag = "numkey-server";

/// Dengerin broadcast UDP dari server di jaringan lokal.
/// Return null kalau gak ketemu dalam batas waktu [timeout].
Future<ServerInfo?> discoverServer({
  Duration timeout = const Duration(seconds: 8),
}) async {
  RawDatagramSocket? socket;
  final completer = Completer<ServerInfo?>();

  try {
    socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      kDiscoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;

    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket!.receive();
      if (datagram == null) return;

      try {
        final msg = utf8.decode(datagram.data);
        final data = jsonDecode(msg) as Map<String, dynamic>;
        if (data['service'] == kServiceTag &&
            data['ip'] is String &&
            data['port'] is int) {
          if (!completer.isCompleted) {
            completer.complete(ServerInfo(data['ip'], data['port']));
          }
        }
      } catch (_) {
        // paket bukan dari server kita (format gak cocok), abaikan
      }
    });
  } catch (e) {
    if (!completer.isCompleted) completer.complete(null);
  }

  // timeout guard biar UI gak nunggu selamanya kalau server gak nyala
  Future.delayed(timeout, () {
    if (!completer.isCompleted) completer.complete(null);
  });

  final result = await completer.future;
  socket?.close();
  return result;
}
