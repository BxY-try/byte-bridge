import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'discovery_service.dart';
import 'socket_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ByteBridgeApp());
}

class ByteBridgeApp extends StatelessWidget {
  const ByteBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ByteBridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        cardColor: const Color(0xFF1C2640),
      ),
      home: const HomeScreen(),
    );
  }
}

enum ConnState { discovering, connecting, connected, disconnected, failed }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SocketService _socketService = SocketService();
  ConnState _state = ConnState.discovering;
  String? _serverIp;
  int? _serverPort;
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    setState(() => _state = ConnState.discovering);
    final info = await discoverServer();
    if (info == null) {
      setState(() => _state = ConnState.failed);
      return;
    }
    _connectTo(info.ip, info.port);
  }

  void _connectTo(String ip, int port) {
    setState(() {
      _serverIp = ip;
      _serverPort = port;
      _state = ConnState.connecting;
    });

    _socketService.connect(
      ip: ip,
      port: port,
      onConnect: () {
        if (mounted) setState(() => _state = ConnState.connected);
      },
      onDisconnect: () {
        if (mounted) setState(() => _state = ConnState.disconnected);
      },
      onError: (_) {
        if (mounted) setState(() => _state = ConnState.disconnected);
      },
    );
  }

  Future<void> _showManualIpDialog() async {
    final controller = TextEditingController(text: _serverIp ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Input IP Server Manual'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '192.168.1.5',
            labelText: 'Alamat IP PC',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.datetime,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Hubungkan'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      _connectTo(result, 8080);
    }
  }

  void _sendKey(String key) {
    HapticFeedback.lightImpact();
    _socketService.sendKey(key);
  }

  void _sendHotkey(List<String> keys) {
    HapticFeedback.mediumImpact();
    _socketService.sendHotkey(keys);
  }

  @override
  void dispose() {
    _socketService.dispose();
    super.dispose();
  }

  String get _statusText {
    switch (_state) {
      case ConnState.discovering:
        return 'Mencari server di WiFi...';
      case ConnState.connecting:
        return 'Menghubungkan ke $_serverIp...';
      case ConnState.connected:
        return 'Terhubung ke $_serverIp';
      case ConnState.disconnected:
        return 'Terputus, menghubungkan ulang...';
      case ConnState.failed:
        return 'Server tidak ditemukan. Coba input IP manual.';
    }
  }

  Color get _statusColor {
    switch (_state) {
      case ConnState.connected:
        return Colors.greenAccent;
      case ConnState.failed:
        return Colors.redAccent;
      case ConnState.disconnected:
        return Colors.orangeAccent;
      default:
        return Colors.amberAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ByteBridge',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF131B2E),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _startDiscovery,
            tooltip: 'Cari ulang server',
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: _showManualIpDialog,
            tooltip: 'Input IP manual',
          ),
        ],
      ),
      body: Column(
        children: [
          // Connection Status Bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            color: _statusColor.withOpacity(0.12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.circle, size: 10, color: _statusColor),
                const SizedBox(width: 8),
                Text(
                  _statusText,
                  style: TextStyle(
                    color: _statusColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          // Active Tab Body
          Expanded(
            child: IndexedStack(
              index: _currentTabIndex,
              children: [
                _buildNumpadTab(),
                _buildMediaTab(),
                _buildNavTab(),
                _buildShortcutsTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (idx) {
          HapticFeedback.selectionClick();
          setState(() => _currentTabIndex = idx);
        },
        backgroundColor: const Color(0xFF131B2E),
        indicatorColor: Colors.indigo.withOpacity(0.4),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dialpad),
            label: 'Numpad',
          ),
          NavigationDestination(
            icon: Icon(Icons.music_note),
            label: 'Media',
          ),
          NavigationDestination(
            icon: Icon(Icons.navigation),
            label: 'Navigasi',
          ),
          NavigationDestination(
            icon: Icon(Icons.bolt),
            label: 'Pintasan',
          ),
        ],
      ),
    );
  }

  // ---------- TAB 1: NUMPAD ----------
  Widget _buildNumpadTab() {
    const rows = [
      ['esc', 'tab', 'backspace', '/'],
      ['7', '8', '9', '*'],
      ['4', '5', '6', '-'],
      ['1', '2', '3', '+'],
    ];

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          for (final row in rows)
            Expanded(
              child: Row(
                children: [
                  for (final key in row)
                    Expanded(child: _buildKeyButton(key)),
                ],
              ),
            ),
          // Bottom row: 0 (span 2), ., enter
          Expanded(
            child: Row(
              children: [
                Expanded(flex: 2, child: _buildKeyButton('0')),
                Expanded(child: _buildKeyButton('.')),
                Expanded(
                  child: _buildKeyButton(
                    'enter',
                    label: 'ENTER',
                    isAccent: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyButton(String key, {String? label, bool isAccent = false}) {
    final isBackspace = key == 'backspace';
    final isSpecial = ['esc', 'tab', '/', '*', '-', '+'].contains(key);

    return Padding(
      padding: const EdgeInsets.all(4),
      child: ElevatedButton(
        onPressed: () => _sendKey(key),
        style: ElevatedButton.styleFrom(
          backgroundColor: isAccent
              ? Colors.indigoAccent
              : (isSpecial ? const Color(0xFF182239) : const Color(0xFF1C2640)),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: EdgeInsets.zero,
        ),
        child: isBackspace
            ? const Icon(Icons.backspace_outlined, size: 22)
            : Text(
                label ?? key.toUpperCase(),
                style: TextStyle(
                  fontSize: isSpecial || isAccent ? 16 : 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
      ),
    );
  }

  // ---------- TAB 2: MEDIA ----------
  Widget _buildMediaTab() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Volume Card
            Card(
              color: const Color(0xFF131B2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('VOLUME PC', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCircleBtn(Icons.volume_down, 'volumedown'),
                        _buildCircleBtn(Icons.volume_off, 'volumemute'),
                        _buildCircleBtn(Icons.volume_up, 'volumeup'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            // Music Card
            Card(
              color: const Color(0xFF131B2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('KONTROL PEMUTAR MUSIK', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCircleBtn(Icons.skip_previous, 'prevtrack'),
                        _buildCircleBtn(Icons.play_arrow, 'playpause', isLarge: true),
                        _buildCircleBtn(Icons.skip_next, 'nexttrack'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCircleBtn(IconData icon, String key, {bool isLarge = false}) {
    return InkWell(
      onTap: () => _sendKey(key),
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: isLarge ? 72 : 56,
        height: isLarge ? 72 : 56,
        decoration: BoxDecoration(
          color: isLarge ? Colors.indigoAccent : const Color(0xFF1C2640),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: isLarge ? 36 : 26, color: Colors.white),
      ),
    );
  }

  // ---------- TAB 3: NAVIGATION ----------
  Widget _buildNavTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildNavActionBtn('F5 (Play)', () => _sendKey('f5')),
              _buildNavActionBtn('Shift+F5', () => _sendHotkey(['shift', 'f5'])),
              _buildNavActionBtn('ESC', () => _sendKey('esc')),
              _buildNavActionBtn('Space', () => _sendKey('space')),
            ],
          ),
          // D-Pad Grid
          Column(
            children: [
              _buildDpadBtn(Icons.arrow_drop_up, 'up'),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildDpadBtn(Icons.arrow_left, 'left'),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _sendKey('enter'),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: Colors.indigoAccent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Text(
                          'OK',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildDpadBtn(Icons.arrow_right, 'right'),
                ],
              ),
              const SizedBox(height: 8),
              _buildDpadBtn(Icons.arrow_drop_down, 'down'),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildNavActionBtn('Page Up', () => _sendKey('pageup')),
              _buildNavActionBtn('Page Down', () => _sendKey('pagedown')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDpadBtn(IconData icon, String key) {
    return InkWell(
      onTap: () => _sendKey(key),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 68,
        height: 68,
        decoration: BoxDecoration(
          color: const Color(0xFF1C2640),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(icon, size: 36, color: Colors.white),
      ),
    );
  }

  Widget _buildNavActionBtn(String label, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Color(0xFF2E3C5D)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Text(label),
    );
  }

  // ---------- TAB 4: SHORTCUTS ----------
  Widget _buildShortcutsTab() {
    final shortcuts = [
      {'label': 'Copy (Ctrl+C)', 'keys': ['ctrl', 'c']},
      {'label': 'Paste (Ctrl+V)', 'keys': ['ctrl', 'v']},
      {'label': 'Undo (Ctrl+Z)', 'keys': ['ctrl', 'z']},
      {'label': 'Redo (Ctrl+Y)', 'keys': ['ctrl', 'y']},
      {'label': 'Save (Ctrl+S)', 'keys': ['ctrl', 's']},
      {'label': 'Select All (Ctrl+A)', 'keys': ['ctrl', 'a']},
      {'label': 'Desktop (Win+D)', 'keys': ['win', 'd']},
      {'label': 'Switch (Alt+Tab)', 'keys': ['alt', 'tab']},
      {'label': 'Screenshot', 'keys': ['win', 'shift', 's']},
    ];

    return Padding(
      padding: const EdgeInsets.all(16),
      child: GridView.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.2,
        ),
        itemCount: shortcuts.length,
        itemBuilder: (context, idx) {
          final s = shortcuts[idx];
          return ElevatedButton(
            onPressed: () => _sendHotkey(s['keys'] as List<String>),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1C2640),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.all(8),
            ),
            child: Text(
              s['label'] as String,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
          );
        },
      ),
    );
  }
}
