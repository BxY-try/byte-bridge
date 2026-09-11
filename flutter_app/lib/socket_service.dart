import 'package:socket_io_client/socket_io_client.dart' as io;

class SocketService {
  io.Socket? _socket;

  void connect({
    required String ip,
    required int port,
    required void Function() onConnect,
    required void Function() onDisconnect,
    required void Function(dynamic error) onError,
  }) {
    _socket?.dispose();

    _socket = io.io(
      'http://$ip:$port',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .enableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(1000000) // Praktis unlimited selama app hidup
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .build(),
    );

    _socket!.onConnect((_) => onConnect());
    _socket!.onDisconnect((_) => onDisconnect());
    _socket!.onConnectError((err) => onError(err));
    _socket!.onError((err) => onError(err));
  }

  void sendKey(String key) {
    _socket?.emit('keypress', {'key': key});
  }

  void sendHotkey(List<String> keys) {
    _socket?.emit('hotkey', {'keys': keys});
  }

  void sendMouseMove(double dx, double dy) {
    _socket?.emit('mouse_move', {'dx': dx, 'dy': dy});
  }

  void sendMouseClick(String button) {
    _socket?.emit('mouse_click', {'button': button});
  }

  void sendTextInput(String text) {
    _socket?.emit('text_input', {'text': text});
  }

  bool get isConnected => _socket?.connected ?? false;

  void disconnect() {
    _socket?.disconnect();
  }

  void dispose() {
    _socket?.dispose();
  }
}
