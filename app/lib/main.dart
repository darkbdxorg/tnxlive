import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_gpl/return_code.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ---------------------------------------------------------------------------
// Foreground task (keeps the process alive with the screen off)
// ---------------------------------------------------------------------------
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LiveTaskHandler());
}

class LiveTaskHandler extends TaskHandler {
  DateTime? _started;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _started = timestamp;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final start = _started;
    if (start == null) return;
    final elapsed = timestamp.difference(start);
    FlutterForegroundTask.updateService(
      notificationTitle: 'TNxLive — LIVE cholche',
      notificationText: 'Duration: ${_fmtDuration(elapsed)} • Screen off thakleo stream cholbe',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

String _fmtDuration(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const TNxLiveApp());
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------
const _bg = Color(0xFF070709);
const _card = Color(0xFF121216);
const _card2 = Color(0xFF1A1A20);
const _red = Color(0xFFE50914);
const _txtDim = Color(0xFF9A9AA5);

class TNxLiveApp extends StatelessWidget {
  const TNxLiveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TNxLive',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
          surface: _card,
          primary: _red,
          onPrimary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: _bg,
          elevation: 0,
          titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _card2,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _red, width: 1.4)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          hintStyle: const TextStyle(color: _txtDim, fontSize: 13),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : _txtDim),
          trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? _red : _card2),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  // Playlist
  List<String> _videos = [];

  // Destinations
  bool _ytOn = true, _fbOn = false, _customOn = false;
  final _ytKey = TextEditingController();
  final _fbKey = TextEditingController();
  final _customUrl = TextEditingController();

  static const ytServer = 'rtmp://a.rtmp.youtube.com/live2/';
  static const fbServer = 'rtmp://live-api-s.facebook.com:443/rtmp/';

  // Settings
  String _quality = '720p';
  String _mode = 'reencode'; // reencode | copy

  // Streaming state
  bool _live = false;
  bool _starting = false;
  DateTime? _startedAt;
  Timer? _ticker;
  int? _sessionId;
  String _statBitrate = '—', _statFps = '—', _statSpeed = '—', _statSize = '—';

  final List<String> _logs = [];
  final _logScroll = ScrollController();
  late final AnimationController _pulse;

  static const _qualityMap = {
    '480p': (w: 854, h: 480, bitrate: '1200k', buf: '2400k'),
    '720p': (w: 1280, h: 720, bitrate: '2500k', buf: '5000k'),
    '1080p': (w: 1920, h: 1080, bitrate: '4500k', buf: '9000k'),
  };

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _initForegroundTask();
    _loadPrefs();
    for (final c in [_ytKey, _fbKey, _customUrl]) {
      c.addListener(_savePrefs);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulse.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // ---------- prefs ----------
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _videos = p.getStringList('videos') ?? [];
      _ytOn = p.getBool('yt_on') ?? true;
      _fbOn = p.getBool('fb_on') ?? false;
      _customOn = p.getBool('custom_on') ?? false;
      _ytKey.text = p.getString('yt_key') ?? '';
      _fbKey.text = p.getString('fb_key') ?? '';
      _customUrl.text = p.getString('custom_url') ?? '';
      _quality = p.getString('quality') ?? '720p';
      _mode = p.getString('mode') ?? 'reencode';
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('videos', _videos);
    await p.setBool('yt_on', _ytOn);
    await p.setBool('fb_on', _fbOn);
    await p.setBool('custom_on', _customOn);
    await p.setString('yt_key', _ytKey.text);
    await p.setString('fb_key', _fbKey.text);
    await p.setString('custom_url', _customUrl.text);
    await p.setString('quality', _quality);
    await p.setString('mode', _mode);
  }

  // ---------- foreground task ----------
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'tnxlive_stream',
        channelName: 'TNxLive Streaming',
        channelDescription: 'Live stream cholakalin notification',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _ensurePermissions() async {
    final np = await FlutterForegroundTask.checkNotificationPermission();
    if (np != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!ignoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  // ---------- logging ----------
  void _addLog(String line) {
    final clean = line.trim();
    if (clean.isEmpty) return;
    setState(() {
      _logs.add(clean);
      if (_logs.length > 100) _logs.removeRange(0, _logs.length - 100);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  // ---------- video picker ----------
  Future<void> _pickVideos() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.video, allowMultiple: true);
    if (res == null) return;
    final paths = res.files.map((f) => f.path).whereType<String>().where((p) => p.isNotEmpty).toList();
    if (paths.isEmpty) {
      _snack('Video file select holo na — abar try koro');
      return;
    }
    setState(() => _videos.addAll(paths));
    _savePrefs();
    _addLog('${paths.length} ta video playlist e add holo');
  }

  // ---------- destinations ----------
  List<({String name, String url})> _activeDestinations() {
    final list = <({String name, String url})>[];
    if (_ytOn && _ytKey.text.trim().isNotEmpty) {
      list.add((name: 'YouTube', url: '$ytServer${_ytKey.text.trim()}'));
    }
    if (_fbOn && _fbKey.text.trim().isNotEmpty) {
      list.add((name: 'Facebook', url: '$fbServer${_fbKey.text.trim()}'));
    }
    if (_customOn && _customUrl.text.trim().isNotEmpty) {
      list.add((name: 'Custom/TikTok', url: _customUrl.text.trim()));
    }
    return list;
  }

  int get _destCount => _activeDestinations().length;

  // ---------- streaming ----------
  String? _validate() {
    if (_videos.isEmpty) return 'Age playlist e ontoto 1 ta video add koro';
    if (!_ytOn && !_fbOn && !_customOn) return 'Ontoto 1 ta destination ON koro (YouTube / Facebook / Custom)';
    if (_ytOn && _ytKey.text.trim().isEmpty) return 'YouTube ON ache kintu Stream Key dewa hoy nai';
    if (_fbOn && _fbKey.text.trim().isEmpty) return 'Facebook ON ache kintu Stream Key dewa hoy nai';
    if (_customOn && _customUrl.text.trim().isEmpty) return 'Custom/TikTok ON ache kintu full RTMP URL dewa hoy nai';
    return null;
  }

  Future<String> _buildConcatFile() async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/tnxlive_playlist.txt');
    final buf = StringBuffer();
    for (final v in _videos) {
      buf.writeln("file '${v.replaceAll("'", r"'\''")}'");
    }
    await f.writeAsString(buf.toString());
    return f.path;
  }

  Future<void> _startLive() async {
    final err = _validate();
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() => _starting = true);
    await _ensurePermissions();
    await _savePrefs();

    final dests = _activeDestinations();
    final listPath = await _buildConcatFile();

    // Build FFmpeg arguments
    final args = <String>['-re', '-stream_loop', '-1', '-f', 'concat', '-safe', '0', '-i', listPath];
    if (_mode == 'copy') {
      args.addAll(['-c', 'copy']);
    } else {
      final q = _qualityMap[_quality]!;
      args.addAll([
        '-vf', 'scale=${q.w}:${q.h}:force_original_aspect_ratio=decrease,pad=${q.w}:${q.h}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency',
        '-b:v', q.bitrate, '-maxrate', q.bitrate, '-bufsize', q.buf,
        '-pix_fmt', 'yuv420p', '-g', '60',
        '-c:a', 'aac', '-b:a', '128k', '-ar', '44100',
      ]);
    }
    if (dests.length == 1) {
      args.addAll(['-f', 'flv', dests.first.url]);
    } else {
      final tee = dests.map((d) => '[f=flv:onfail=ignore]${d.url}').join('|');
      args.addAll(['-f', 'tee', tee]);
    }

    _addLog('Stream start hocche → ${dests.map((d) => d.name).join(', ')}');
    _addLog('Mode: ${_mode == 'copy' ? 'Copy (no re-encode)' : 'Re-encode $_quality'} • ${_videos.length} video loop');

    // Foreground service (process keep-alive + notification)
    if (!await FlutterForegroundTask.isRunningService) {
      final r = await FlutterForegroundTask.startService(
        serviceId: 888,
        serviceTypes: [ForegroundServiceTypes.mediaPlayback],
        notificationTitle: 'TNxLive — LIVE cholche',
        notificationText: 'Stream cholche • ${dests.map((d) => d.name).join(', ')}',
        callback: startCallback,
      );
      if (r is ServiceRequestFailure) _addLog('Foreground service warning: ${r.error}');
    }
    await WakelockPlus.enable();

    FFmpegKitConfig.setLogLevel(21); // AV_LOG_INFO-ish; keep logs useful
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (session) async {
        final rc = await session.getReturnCode();
        if (!mounted) return;
        if (ReturnCode.isCancel(rc)) {
          _addLog('Stream bondho kora hoyeche');
        } else if (ReturnCode.isSuccess(rc)) {
          _addLog('Stream shesh hoyeche');
        } else {
          final fail = await session.getFailStackTrace();
          _addLog('Stream error (code: $rc) ${fail ?? ''}');
          _snack('Stream theme geche — log dekho, key/net check koro');
        }
        await _cleanupAfterStop();
      },
      (log) => _addLog(log.getMessage()),
      (stats) {
        if (!mounted) return;
        setState(() {
          final br = stats.getBitrate();
          _statBitrate = br <= 0 ? '—' : (br >= 1000 ? '${(br / 1000).toStringAsFixed(2)} Mbps' : '${br.toStringAsFixed(0)} kbps');
          _statFps = stats.getVideoFps() <= 0 ? '—' : stats.getVideoFps().toStringAsFixed(0);
          _statSpeed = stats.getSpeed() <= 0 ? '—' : '${stats.getSpeed().toStringAsFixed(2)}x';
          final sz = stats.getSize();
          _statSize = sz <= 0 ? '—' : '${(sz / (1024 * 1024)).toStringAsFixed(1)} MB';
        });
      },
    );
    _sessionId = session.getSessionId();

    setState(() {
      _live = true;
      _starting = false;
      _startedAt = DateTime.now();
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _cleanupAfterStop() async {
    _ticker?.cancel();
    await WakelockPlus.disable();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    if (mounted) {
      setState(() {
        _live = false;
        _starting = false;
        _startedAt = null;
        _statBitrate = '—'; _statFps = '—'; _statSpeed = '—'; _statSize = '—';
      });
    }
  }

  Future<void> _stopLive() async {
    _addLog('Stream bondho kora hocche…');
    final id = _sessionId;
    if (id != null) {
      await FFmpegKit.cancel(id);
    } else {
      await FFmpegKit.cancel();
    }
    // complete callback also cleans up; do it here too in case it lags
    await _cleanupAfterStop();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: _red, behavior: SnackBarBehavior.floating),
    );
  }

  // ---------- UI ----------
  Widget _cardBox({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: padding,
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withValues(alpha: 0.06))),
      child: child,
    );
  }

  Widget _sectionTitle(String t, IconData icon) {
    return Row(children: [
      Icon(icon, size: 18, color: _red),
      const SizedBox(width: 8),
      Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
    ]);
  }

  Widget _destRow({
    required String title,
    required String serverHint,
    required bool on,
    required ValueChanged<bool> onChanged,
    required TextEditingController controller,
    required String hint,
    required String helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text(serverHint, style: const TextStyle(color: _txtDim, fontSize: 11)),
          ])),
          Switch(value: on, onChanged: _live ? null : onChanged),
        ]),
        if (on) ...[
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: !_live,
            obscureText: false,
            autocorrect: false,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(hintText: hint),
          ),
          const SizedBox(height: 6),
          Text(helper, style: const TextStyle(color: _txtDim, fontSize: 11.5, height: 1.35)),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: const BoxDecoration(color: _red, shape: BoxShape.circle)),
          const SizedBox(width: 9),
          const Text('TNxLive'),
        ]),
        actions: [
          IconButton(
            tooltip: 'Guide',
            icon: const Icon(Icons.menu_book_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GuidePage())),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          // ---- Status card ----
          _cardBox(
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, __) => Container(
                    width: 14, height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _live ? _red.withValues(alpha: 0.45 + 0.55 * _pulse.value) : const Color(0xFF3A3A42),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(_live ? 'LIVE' : 'OFFLINE',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 2, color: _live ? _red : _txtDim)),
              ]),
              const SizedBox(height: 6),
              Text(_live ? _fmtDuration(elapsed) : '00:00:00',
                  style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
              Text(_live ? '$_destCount destination e stream jacche' : 'Start korte niche sob set kore LIVE chap dao',
                  style: const TextStyle(color: _txtDim, fontSize: 12.5)),
              const SizedBox(height: 14),
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
                _stat('Bitrate', _statBitrate),
                _stat('FPS', _statFps),
                _stat('Speed', _statSpeed),
                _stat('Sent', _statSize),
              ]),
            ]),
          ),

          // ---- Playlist ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _sectionTitle('Playlist (Loop hobe)', Icons.playlist_play_rounded)),
                FilledButton.icon(
                  onPressed: _live ? null : _pickVideos,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Video Add'),
                  style: FilledButton.styleFrom(backgroundColor: _red, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9)),
                ),
              ]),
              const SizedBox(height: 8),
              if (_videos.isEmpty)
                const Text('Kono video nai. Video Add chap diye 1 ba ekadhik video select koro — segulai ek-er por ek loop hoye stream hobe.',
                    style: TextStyle(color: _txtDim, fontSize: 12.5, height: 1.4))
              else
                ..._videos.asMap().entries.map((e) => ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(radius: 15, backgroundColor: _card2, child: Text('${e.key + 1}', style: const TextStyle(fontSize: 12, color: Colors.white))),
                      title: Text(e.value.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: _txtDim)),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18, color: _txtDim),
                        onPressed: _live ? null : () { setState(() => _videos.removeAt(e.key)); _savePrefs(); },
                      ),
                    )),
            ]),
          ),

          // ---- Destinations ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _sectionTitle('Destinations', Icons.sensors_rounded),
              _destRow(
                title: 'YouTube',
                serverHint: ytServer,
                on: _ytOn,
                onChanged: (v) { setState(() => _ytOn = v); _savePrefs(); },
                controller: _ytKey,
                hint: 'YouTube Stream Key ekhane bosao',
                helper: 'YouTube Studio → Create → Go Live → Stream theke key paba. Guide screen e details ache.',
              ),
              _destRow(
                title: 'Facebook',
                serverHint: fbServer,
                on: _fbOn,
                onChanged: (v) { setState(() => _fbOn = v); _savePrefs(); },
                controller: _fbKey,
                hint: 'Facebook Stream Key ekhane bosao',
                helper: 'Page er Live dashboard theke "Persistent stream key" nao — tahole protibar notun key lagbe na.',
              ),
              _destRow(
                title: 'TikTok / Custom RTMP',
                serverHint: 'Full URL (server + key eksathe)',
                on: _customOn,
                onChanged: (v) { setState(() => _customOn = v); _savePrefs(); },
                controller: _customUrl,
                hint: 'rtmp://... full combined URL bosao',
                helper: 'TikTok prottek session e notun server URL + key dey eksathe — oi full URL tai ekhane paste koro. 1000+ followers lage.',
              ),
              const SizedBox(height: 12),
              const Row(children: [
                Icon(Icons.lock_outline, size: 14, color: _txtDim),
                SizedBox(width: 6),
                Expanded(child: Text('Stream key sudhu tomar phone ei save thake — kono server e jay na.', style: TextStyle(color: _txtDim, fontSize: 11.5))),
              ]),
            ]),
          ),

          // ---- Settings ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _sectionTitle('Stream Settings', Icons.tune_rounded),
              const SizedBox(height: 12),
              const Text('Quality', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                for (final q in ['480p', '720p', '1080p'])
                  ChoiceChip(
                    label: Text(q),
                    selected: _quality == q,
                    onSelected: _live ? null : (_) { setState(() => _quality = q); _savePrefs(); },
                    selectedColor: _red,
                    backgroundColor: _card2,
                    labelStyle: TextStyle(color: _quality == q ? Colors.white : _txtDim),
                    side: BorderSide.none,
                  ),
              ]),
              const SizedBox(height: 6),
              Text(
                _quality == '480p' ? '~1200 kbps — slow net er jonno bhalo' : _quality == '720p' ? '~2500 kbps — recommended, balance bhalo' : '~4500 kbps — fast net lage, phone gorom hote pare',
                style: const TextStyle(color: _txtDim, fontSize: 11.5),
              ),
              const SizedBox(height: 14),
              const Text('Mode', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: const Text('Re-encode (Recommended)'),
                  selected: _mode == 'reencode',
                  onSelected: _live ? null : (_) { setState(() => _mode = 'reencode'); _savePrefs(); },
                  selectedColor: _red, backgroundColor: _card2,
                  labelStyle: TextStyle(color: _mode == 'reencode' ? Colors.white : _txtDim),
                  side: BorderSide.none,
                ),
                ChoiceChip(
                  label: const Text('Copy / Fast'),
                  selected: _mode == 'copy',
                  onSelected: _live ? null : (_) { setState(() => _mode = 'copy'); _savePrefs(); },
                  selectedColor: _red, backgroundColor: _card2,
                  labelStyle: TextStyle(color: _mode == 'copy' ? Colors.white : _txtDim),
                  side: BorderSide.none,
                ),
              ]),
              const SizedBox(height: 6),
              const Text('Copy mode e re-encode hoy na bole CPU/battery kom lage, kintu video age thekei H.264 + AAC format e thakte hobe, na hole stream cholbe na.',
                  style: TextStyle(color: _txtDim, fontSize: 11.5, height: 1.35)),
            ]),
          ),

          // ---- Log ----
          _cardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _sectionTitle('Live Log', Icons.terminal_rounded)),
                TextButton.icon(
                  onPressed: () => setState(_logs.clear),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Clear'),
                  style: TextButton.styleFrom(foregroundColor: _txtDim),
                ),
              ]),
              const SizedBox(height: 8),
              Container(
                height: 170,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFF050507), borderRadius: BorderRadius.circular(12)),
                child: _logs.isEmpty
                    ? const Text('Stream start korle ekhane FFmpeg log dekhte paba…', style: TextStyle(color: _txtDim, fontSize: 11.5, fontFamily: 'monospace'))
                    : ListView.builder(
                        controller: _logScroll,
                        itemCount: _logs.length,
                        itemBuilder: (_, i) => Text(_logs[i], style: const TextStyle(color: Color(0xFFB7F0C0), fontSize: 10.5, fontFamily: 'monospace', height: 1.35)),
                      ),
              ),
            ]),
          ),
          const Text('Tip: LIVE chalakalin phone charger e lagiye rakho, ar app ta recent apps theke swipe kore fello na.',
              textAlign: TextAlign.center, style: TextStyle(color: _txtDim, fontSize: 11.5)),
          const SizedBox(height: 8),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
          child: SizedBox(
            height: 58,
            child: FilledButton.icon(
              onPressed: _starting ? null : (_live ? _stopLive : _startLive),
              icon: Icon(_live ? Icons.stop_circle_rounded : Icons.sensors_rounded, size: 24),
              label: Text(_starting ? 'START HOCCHE…' : _live ? 'STOP LIVE' : 'START LIVE',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              style: FilledButton.styleFrom(
                backgroundColor: _live ? const Color(0xFF3A3A42) : _red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(children: [
      Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: _txtDim, fontSize: 11)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Guide
// ---------------------------------------------------------------------------
class GuidePage extends StatelessWidget {
  const GuidePage({super.key});

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
      );

  Widget _p(String t) => Text(t, style: const TextStyle(color: Color(0xFFC9C9D2), fontSize: 13.5, height: 1.55));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guide — Key kothay paba')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 30),
        children: [
          _p('TNxLive diye tomar phone thekei ek ba ekadhik video loop kore YouTube, Facebook ar Custom RTMP (TikTok soho) te ek sathe live stream korte parba. Stream cholte phone ON, charger e lagano ar internet e thaka lagbe.'),
          _h('▶ YouTube Stream Key'),
          _p('1) Phone/PC browser e YouTube Studio kholo (studio.youtube.com)\n2) Upar theke Create → Go Live chap dao\n3) Left side e "Stream" select koro\n4) Niche "Stream Key" dekhte paba — Copy kore app er YouTube field e bosao\n\nNote: Channel e prothom bar live enable korte 24 ghonta lagte pare. Live age theke enable na thakle key diyeo stream jabe na. Ekbar newa persistent key bar bar use kora jay.'),
          _h('▶ Facebook Stream Key'),
          _p('1) Tomar Facebook Page theke Live / Create Live Video te jao\n2) "Use stream key" option select koro\n3) Settings e giye "Persistent stream key" ON koro — tahole key change hobe na\n4) Key copy kore app er Facebook field e bosao\n\nPersonal profile er key prottek live e change hoy, Page er persistent key tai bhalo.'),
          _h('▶ TikTok'),
          _p('TikTok sobcheye strict:\n• Live korte 1000+ followers + boyosh 18+ lage\n• TikTok kono permanent key dey na — prottek session e LIVE Studio / "Stream to PC" theke notun Server URL + Stream Key paba\n• Oi duita mile je full RTMP URL hoy (server URL + "/" + key) seta app er "TikTok / Custom RTMP" field e paste koro\n• Key purono hole kaj korbe na — live start er thik age notun key nio'),
          _h('⚠ Tips — stream jeno na kate'),
          _p('• LIVE chalakalin sob somoy charger lagiye rakho — encoding e battery khub druto jay\n• Prothom bar Start chaple battery optimization off korar permission chaibe — allow koro, na hole screen off hole system app bondho kore dite pare\n• App recent apps theke swipe kore fello na\n• Net slow hole 480p use koro; 1080p er jonno strong upload lage\n• WiFi hole sobcheye stable hoy'),
          _h('© Copyright Warning'),
          _p('Sudhu nijer banano / nijer rights ache emon video stream koro. Onner movie, gan, ba TV content loop kore stream dile YouTube/Facebook copyright strike dibe, channel o sash hote pare.'),
          _h('Limit — shotti kotha'),
          _p('Eta phone-only system: phone off, battery sesh ba net chole gele LIVE o theme jabe. Phone na thakleo cholbe emon true 24/7 chaile alada server/VPS lage — seta onno setup.'),
        ],
      ),
    );
  }
}
