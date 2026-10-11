// Omate 聊天记录阅读器 v1
// 功能：导入 zip、角色列表、窗口列表、聊天界面（气泡/头像/名字/日期分隔）、
//       话题（历史版本）、全局搜索并定位、长按复制/删除。
// 删除只改 App 自己的数据，不动原 zip。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:sqflite/sqflite.dart';

Database? appDb;
late String avatarDir;

Future<String> _dbPath() async => '${await getDatabasesPath()}/omate_reader.db';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final docs = await getApplicationDocumentsDirectory();
  avatarDir = '${docs.path}/avatars';
  Directory(avatarDir).createSync(recursive: true);
  final p = await _dbPath();
  if (await File(p).exists()) {
    try {
      appDb = await openDatabase(p);
    } catch (_) {}
  }
  runApp(const ReaderApp());
}

class ReaderApp extends StatelessWidget {
  const ReaderApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Omate 阅读器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
      ),
      home: const HomePage(),
    );
  }
}

// ======================= 导入 =======================

Future<void> importZip(String zipPath, void Function(String) say) async {
  final tmp = await getTemporaryDirectory();
  final srcPath = '${tmp.path}/src_omate_chat.db';

  say('读取 zip 目录…');
  final input = InputFileStream(zipPath);
  final archive = ZipDecoder().decodeBuffer(input);

  ArchiveFile? dbFile;
  final hist = <ArchiveFile>[];
  var avatarCount = 0;
  for (final f in archive) {
    if (!f.isFile) continue;
    final name = f.name.replaceAll('\\', '/');
    final parts = name.split('/');
    final base = parts.last;
    if (base == 'omate_chat.db') {
      dbFile = f;
    } else if (base.startsWith('avatar_')) {
      final o = OutputFileStream('$avatarDir/$base');
      f.writeContent(o);
      o.close();
      avatarCount++;
      if (avatarCount % 10 == 0) say('复制头像 $avatarCount …');
    } else if (parts.contains('chats') &&
        parts.contains('history') &&
        base.endsWith('.json')) {
      hist.add(f);
    }
  }
  if (dbFile == null) throw Exception('zip 里没找到 omate_chat.db');

  say('解出数据库（较大，请耐心等待）…');
  final srcFile = File(srcPath);
  if (await srcFile.exists()) await srcFile.delete();
  final so = OutputFileStream(srcPath);
  dbFile.writeContent(so);
  so.close();

  final src = await openDatabase(srcPath, readOnly: true);
  final dbPath = await _dbPath();
  await appDb?.close();
  appDb = null;
  await deleteDatabase(dbPath);
  final db = await openDatabase(dbPath, version: 1, onCreate: (db, v) async {
    await db.execute(
        'CREATE TABLE roles(id TEXT PRIMARY KEY, name TEXT, description TEXT, avatar TEXT, system_prompt TEXT)');
    await db.execute(
        'CREATE TABLE chats(id TEXT PRIMARY KEY, title TEXT, role_id TEXT, created_at TEXT, updated_at TEXT, data TEXT)');
    await db.execute(
        'CREATE TABLE messages(id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id TEXT, role TEXT, content TEXT, ts TEXT)');
    await db.execute(
        'CREATE TABLE topics(id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id TEXT, saved_at INTEGER, title TEXT, msg_count INTEGER)');
    await db.execute(
        'CREATE TABLE topic_messages(id INTEGER PRIMARY KEY AUTOINCREMENT, topic_id INTEGER, role TEXT, content TEXT, ts TEXT)');
  });

  // 窗口 + 角色
  say('导入角色和窗口…');
  final chatRows = await src.query('chats');
  final chatIds = <String>{};
  await db.transaction((txn) async {
    final b = txn.batch();
    for (final r in chatRows) {
      final id = r['id'].toString();
      Map data = {};
      try {
        final x = jsonDecode((r['data'] ?? '{}').toString());
        if (x is Map) data = x;
      } catch (_) {}
      String? roleId;
      final role = data['role'];
      if (role is Map && (role['id'] ?? '').toString().isNotEmpty) {
        roleId = role['id'].toString();
        b.insert(
            'roles',
            {
              'id': roleId,
              'name': (role['name'] ?? '').toString(),
              'description': (role['description'] ?? '').toString(),
              'avatar': (role['avatar'] ?? '').toString(),
              'system_prompt': (role['system_prompt'] ?? '').toString(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      b.insert('chats', {
        'id': id,
        'title': (r['title'] ?? '').toString(),
        'role_id': roleId,
        'created_at': (r['created_at'] ?? '').toString(),
        'updated_at': (r['updated_at'] ?? '').toString(),
        'data': jsonEncode(data),
      });
      chatIds.add(id);
    }
    await b.commit(noResult: true);
  });

  // 消息（跳过 is_deleted=1）
  var offset = 0;
  const page = 2000;
  while (true) {
    final rows = await src.rawQuery(
        'SELECT chat_id, role, content, timestamp FROM messages '
        'WHERE COALESCE(is_deleted,0)=0 ORDER BY chat_id, timestamp, id '
        'LIMIT $page OFFSET $offset');
    if (rows.isEmpty) break;
    await db.transaction((txn) async {
      final b = txn.batch();
      for (final r in rows) {
        b.insert('messages', {
          'chat_id': r['chat_id'].toString(),
          'role': (r['role'] ?? '').toString(),
          'content': (r['content'] ?? '').toString(),
          'ts': (r['timestamp'] ?? '').toString(),
        });
      }
      await b.commit(noResult: true);
    });
    offset += rows.length;
    say('导入消息 $offset …');
  }
  await db.execute('CREATE INDEX idx_m_chat ON messages(chat_id, id)');

  // 话题（history 里的 JSON）
  say('导入话题…');
  var done = 0;
  for (final f in hist) {
    done++;
    final parts = f.name.replaceAll('\\', '/').split('/');
    final ci = parts.indexOf('chats');
    if (ci < 0 || parts.length <= ci + 1) continue;
    final chatId = parts[ci + 1];
    Map j;
    try {
      final x = jsonDecode(utf8.decode(f.content as List<int>, allowMalformed: true));
      if (x is! Map) continue;
      j = x;
    } catch (_) {
      continue;
    }
    final msgs = (j['messages'] is List) ? j['messages'] as List : [];
    final m = RegExp(r'\d{10,}').firstMatch(parts.last);
    final savedAt = int.tryParse('${j['id']}') ??
        (m != null ? int.tryParse(m.group(0)!) : null) ??
        0;
    final title = (j['title'] ?? '').toString();
    await db.transaction((txn) async {
      if (!chatIds.contains(chatId)) {
        await txn.insert('chats', {
          'id': chatId,
          'title': title.isEmpty ? '（未归属窗口）' : title,
          'role_id': null,
          'created_at': '',
          'updated_at': DateTime.fromMillisecondsSinceEpoch(savedAt).toIso8601String(),
          'data': '{}',
        });
        chatIds.add(chatId);
      }
      final tid = await txn.insert('topics', {
        'chat_id': chatId,
        'saved_at': savedAt,
        'title': title,
        'msg_count': msgs.length,
      });
      final b = txn.batch();
      for (final mm in msgs) {
        if (mm is! Map) continue;
        b.insert('topic_messages', {
          'topic_id': tid,
          'role': (mm['role'] ?? '').toString(),
          'content': (mm['content'] ?? '').toString(),
          'ts': (mm['timestamp'] ?? '').toString(),
        });
      }
      await b.commit(noResult: true);
    });
    if (done % 10 == 0) say('导入话题 $done / ${hist.length} …');
  }
  await db.execute('CREATE INDEX idx_tm_topic ON topic_messages(topic_id, id)');
  await db.execute('CREATE INDEX idx_t_chat ON topics(chat_id)');

  await src.close();
  try {
    await File(srcPath).delete();
  } catch (_) {}
  appDb = db;
  say('完成');
}

// ======================= 公共组件 =======================

class Avatar extends StatelessWidget {
  final String? rel;
  final String name;
  final double size;
  const Avatar({super.key, this.rel, required this.name, this.size = 40});

  @override
  Widget build(BuildContext context) {
    Widget fallback() => CircleAvatar(
          radius: size / 2,
          child: Text(name.isEmpty ? '?' : name.substring(0, 1),
              style: TextStyle(fontSize: size * 0.45)),
        );
    if (rel == null || rel!.isEmpty) return fallback();
    final file = File('$avatarDir/${rel!.replaceFirst('rel://', '')}');
    return ClipOval(
      child: Image.file(file,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * 3).round(),
          errorBuilder: (_, __, ___) => fallback()),
    );
  }
}

class Msg {
  final int id;
  final String role;
  final String content;
  final String ts;
  Msg(this.id, this.role, this.content, this.ts);
}

class ChatStyle {
  final double fontSize;
  final Color userBubble, roleBubble, userText, roleText;
  final Color userItalic, userBold, roleItalic, roleBold;
  final String roleName, maskName;
  final String? roleAvatar, maskAvatar;

  ChatStyle({
    required this.fontSize,
    required this.userBubble,
    required this.roleBubble,
    required this.userText,
    required this.roleText,
    required this.userItalic,
    required this.userBold,
    required this.roleItalic,
    required this.roleBold,
    required this.roleName,
    required this.maskName,
    this.roleAvatar,
    this.maskAvatar,
  });

  factory ChatStyle.from(String? json) {
    Map d = {};
    try {
      final x = jsonDecode(json ?? '{}');
      if (x is Map) d = x;
    } catch (_) {}
    final role = d['role'] is Map ? d['role'] as Map : {};
    final mask = d['mask'] is Map ? d['mask'] as Map : {};

    Color col(String key, String custom, Color def, [dynamic opacity]) {
      final v = d[key];
      var c = (d[custom] == true && v is num) ? Color(v.toInt() & 0xFFFFFFFF) : def;
      if (opacity is num) {
        c = c.withAlpha((opacity.toDouble().clamp(0.0, 1.0) * 255).round());
      }
      return c;
    }

    final uText = col('user_text_color', 'use_custom_user_text_color', Colors.white);
    final rText = col('role_text_color', 'use_custom_role_text_color', Colors.white);
    String s(Map m, String k, String def) {
      final v = (m[k] ?? '').toString();
      return v.isEmpty ? def : v;
    }

    return ChatStyle(
      fontSize: d['font_size'] is num ? (d['font_size'] as num).toDouble() : 16,
      userBubble: col('user_bubble_color', 'use_custom_user_bubble_color',
          const Color(0xFF3E6B4B), d['user_bubble_opacity'] ?? 0.8),
      roleBubble: col('role_bubble_color', 'use_custom_role_bubble_color',
          const Color(0xFF2F3A40), d['role_bubble_opacity'] ?? 0.8),
      userText: uText,
      roleText: rText,
      userItalic: col('user_italic_text_color', 'use_custom_user_italic_text_color', uText),
      userBold: col('user_bold_text_color', 'use_custom_user_bold_text_color', uText),
      roleItalic: col('role_italic_text_color', 'use_custom_role_italic_text_color', rText),
      roleBold: col('role_bold_text_color', 'use_custom_role_bold_text_color', rText),
      roleName: s(role, 'name', '角色'),
      maskName: s(mask, 'name', '我'),
      roleAvatar: s(role, 'avatar', ''),
      maskAvatar: s(mask, 'avatar', ''),
    );
  }
}

List<InlineSpan> _spans(String text, Color italic, Color bold) {
  final re = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*', dotAll: true);
  final out = <InlineSpan>[];
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
    if (m.group(1) != null) {
      out.add(TextSpan(
          text: m.group(1),
          style: TextStyle(fontWeight: FontWeight.bold, color: bold)));
    } else {
      out.add(TextSpan(
          text: m.group(2),
          style: TextStyle(fontStyle: FontStyle.italic, color: italic)));
    }
    last = m.end;
  }
  if (last < text.length) out.add(TextSpan(text: text.substring(last)));
  return out;
}

class MessageList extends StatefulWidget {
  final List<Msg> msgs;
  final ChatStyle style;
  final int initialIndex;
  final int? highlightId;
  final Future<void> Function(Msg)? onDelete;
  const MessageList({
    super.key,
    required this.msgs,
    required this.style,
    this.initialIndex = 0,
    this.highlightId,
    this.onDelete,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  late List<Msg> _msgs;
  final _ctrl = ItemScrollController();

  @override
  void initState() {
    super.initState();
    _msgs = List.of(widget.msgs);
  }

  String _day(String ts) => ts.length >= 10 ? ts.substring(0, 10) : '';

  Future<void> _menu(Msg m) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('复制'),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: m.content));
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已复制')));
              }
            },
          ),
          if (widget.onDelete != null)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除这条'),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('确定删除这条消息？'),
                    content: const Text('只删除 App 里的这一份，不影响你的原备份文件。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('取消')),
                      TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('删除')),
                    ],
                  ),
                );
                if (ok == true) {
                  await widget.onDelete!(m);
                  if (mounted) setState(() => _msgs.remove(m));
                }
              },
            ),
        ]),
      ),
    );
  }

  Widget _bubble(Msg m) {
    final st = widget.style;
    final isUser = m.role == 'user';
    final bg = isUser ? st.userBubble : st.roleBubble;
    final tc = isUser ? st.userText : st.roleText;
    final name = isUser ? st.maskName : st.roleName;
    final av = isUser ? st.maskAvatar : st.roleAvatar;
    final time = m.ts.length >= 16 ? m.ts.substring(11, 16) : '';
    final hl = widget.highlightId != null && m.id == widget.highlightId;

    final header = <Widget>[
      Avatar(rel: av, name: name, size: 28),
      const SizedBox(width: 6),
      Flexible(
        child: Text('$name  $time',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: isUser ? header.reversed.toList() : header,
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onLongPress: () => _menu(m),
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.84),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(14),
                  border: hl ? Border.all(color: Colors.amber, width: 2) : null,
                ),
                child: Text.rich(TextSpan(
                  style: TextStyle(color: tc, fontSize: st.fontSize, height: 1.5),
                  children: _spans(
                    m.content,
                    isUser ? st.userItalic : st.roleItalic,
                    isUser ? st.userBold : st.roleBold,
                  ),
                )),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(int i) {
    final m = _msgs[i];
    final day = _day(m.ts);
    final newDay = i == 0 || day != _day(_msgs[i - 1].ts);
    return Column(children: [
      if (newDay && day.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            decoration: BoxDecoration(
                color: Colors.white12, borderRadius: BorderRadius.circular(10)),
            child: Text(day, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ),
      _bubble(m),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (_msgs.isEmpty) return const Center(child: Text('没有消息'));
    final start = widget.initialIndex.clamp(0, _msgs.length - 1).toInt();
    return Stack(children: [
      ScrollablePositionedList.builder(
        itemScrollController: _ctrl,
        initialScrollIndex: start,
        itemCount: _msgs.length,
        itemBuilder: (c, i) => _item(i),
      ),
      Positioned(
        right: 8,
        bottom: 16,
        child: Column(children: [
          FloatingActionButton.small(
            heroTag: null,
            onPressed: () => _ctrl.jumpTo(index: 0),
            child: const Icon(Icons.keyboard_double_arrow_up),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: null,
            onPressed: () => _ctrl.jumpTo(index: _msgs.length - 1),
            child: const Icon(Icons.keyboard_double_arrow_down),
          ),
        ]),
      ),
    ]);
  }
}

// ======================= 页面 =======================

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Map<String, Object?>> _roles = [];
  int _orphans = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = appDb;
    if (db == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final roles = await db.rawQuery(
          'SELECT r.id, r.name, r.avatar, COUNT(c.id) AS n, MAX(c.updated_at) AS u '
          'FROM roles r LEFT JOIN chats c ON c.role_id = r.id '
          'GROUP BY r.id ORDER BY u DESC');
      final o = await db
          .rawQuery('SELECT COUNT(*) AS n FROM chats WHERE role_id IS NULL');
      setState(() {
        _roles = roles;
        _orphans = (o.first['n'] as int?) ?? 0;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _import() async {
    if (appDb != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('重新导入？'),
          content: const Text('会清空 App 里现有的数据（包括你在 App 里删掉的记录），再重新导入。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('继续')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final picked = await FilePicker.platform.pickFiles(type: FileType.any);
    if (picked == null || picked.files.single.path == null) return;
    if (!mounted) return;

    final msg = ValueNotifier<String>('准备中…');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('正在导入'),
          content: ValueListenableBuilder<String>(
            valueListenable: msg,
            builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(v),
              const SizedBox(height: 8),
              const Text('请不要退出 App', style: TextStyle(color: Colors.grey)),
            ]),
          ),
        ),
      ),
    );
    String? error;
    try {
      await importZip(picked.files.single.path!, (s) => msg.value = s);
    } catch (e, st) {
      error = '$e\n$st';
    }
    if (!mounted) return;
    Navigator.pop(context);
    if (error != null) {
      showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('导入出错'),
          content: SingleChildScrollView(child: SelectableText(error!)),
        ),
      );
    }
    setState(() => _loading = true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('角色'),
        actions: [
          if (appDb != null)
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const SearchPage())),
            ),
          IconButton(icon: const Icon(Icons.file_open), onPressed: _import),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : appDb == null
              ? Center(
                  child: FilledButton.icon(
                    onPressed: _import,
                    icon: const Icon(Icons.file_open),
                    label: const Text('导入 Omate 备份 (zip)'),
                  ),
                )
              : ListView(
                  children: [
                    for (final r in _roles)
                      ListTile(
                        leading: Avatar(
                            rel: r['avatar']?.toString(),
                            name: (r['name'] ?? '').toString(),
                            size: 44),
                        title: Text((r['name'] ?? '').toString().isEmpty
                            ? '（无名角色）'
                            : r['name'].toString()),
                        subtitle: Text('${r['n']} 个窗口'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => WindowsPage(
                                roleId: r['id'].toString(),
                                roleName: (r['name'] ?? '').toString()),
                          ),
                        ),
                      ),
                    if (_orphans > 0)
                      ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.help_outline)),
                        title: const Text('未归属'),
                        subtitle: Text('$_orphans 个窗口（只在备份的话题里找到）'),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  const WindowsPage(roleId: null, roleName: '未归属')),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class WindowsPage extends StatefulWidget {
  final String? roleId;
  final String roleName;
  const WindowsPage({super.key, required this.roleId, required this.roleName});
  @override
  State<WindowsPage> createState() => _WindowsPageState();
}

class _WindowsPageState extends State<WindowsPage> {
  List<Map<String, Object?>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final where = widget.roleId == null ? 'c.role_id IS NULL' : 'c.role_id = ?';
    final rows = await appDb!.rawQuery(
        'SELECT c.id, c.title, c.updated_at, '
        '(SELECT COUNT(*) FROM messages WHERE chat_id = c.id) AS n, '
        '(SELECT COUNT(*) FROM topics WHERE chat_id = c.id) AS t '
        'FROM chats c WHERE $where ORDER BY c.updated_at DESC',
        widget.roleId == null ? [] : [widget.roleId]);
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.roleName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (c, i) {
                final r = _rows[i];
                final u = (r['updated_at'] ?? '').toString();
                final title = (r['title'] ?? '').toString();
                return ListTile(
                  title: Text(title.isEmpty ? '（无标题）' : title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${r['n']} 条 · ${r['t']} 个话题 · 最近 ${u.length >= 10 ? u.substring(0, 10) : '-'}'),
                  onTap: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              ChatPage(chatId: r['id'].toString(), title: title)),
                    );
                    _load();
                  },
                );
              },
            ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final String chatId;
  final String title;
  final int? jumpToMsgId;
  const ChatPage({super.key, required this.chatId, required this.title, this.jumpToMsgId});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  List<Msg>? _msgs;
  ChatStyle? _style;
  int _start = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = appDb!;
    final c = await db.query('chats', where: 'id = ?', whereArgs: [widget.chatId]);
    final style = ChatStyle.from(c.isEmpty ? '{}' : c.first['data']?.toString());
    final rows = await db.rawQuery(
        'SELECT id, role, content, ts FROM messages WHERE chat_id = ? ORDER BY id',
        [widget.chatId]);
    final msgs = rows
        .map((r) => Msg(r['id'] as int, (r['role'] ?? '').toString(),
            (r['content'] ?? '').toString(), (r['ts'] ?? '').toString()))
        .toList();
    var start = msgs.length - 1;
    if (widget.jumpToMsgId != null) {
      final k = msgs.indexWhere((m) => m.id == widget.jumpToMsgId);
      if (k >= 0) start = k;
    }
    setState(() {
      _msgs = msgs;
      _style = style;
      _start = start < 0 ? 0 : start;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? '聊天' : widget.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '话题',
            onPressed: _style == null
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              TopicsPage(chatId: widget.chatId, style: _style!)),
                    ),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const SearchPage())),
          ),
        ],
      ),
      body: _msgs == null
          ? const Center(child: CircularProgressIndicator())
          : MessageList(
              msgs: _msgs!,
              style: _style!,
              initialIndex: _start,
              highlightId: widget.jumpToMsgId,
              onDelete: (m) async {
                await appDb!.delete('messages', where: 'id = ?', whereArgs: [m.id]);
              },
            ),
    );
  }
}

class TopicsPage extends StatefulWidget {
  final String chatId;
  final ChatStyle style;
  const TopicsPage({super.key, required this.chatId, required this.style});
  @override
  State<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<TopicsPage> {
  List<Map<String, Object?>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    appDb!
        .query('topics',
            where: 'chat_id = ?', whereArgs: [widget.chatId], orderBy: 'saved_at DESC')
        .then((r) => setState(() {
              _rows = r;
              _loading = false;
            }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('话题（历史版本）')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _rows.isEmpty
              ? const Center(child: Text('这个窗口没有历史话题'))
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    final r = _rows[i];
                    final t = DateTime.fromMillisecondsSinceEpoch(
                        (r['saved_at'] as int?) ?? 0);
                    final title = (r['title'] ?? '').toString();
                    String two(int x) => x.toString().padLeft(2, '0');
                    return ListTile(
                      title: Text(title.isEmpty ? '（无标题）' : title),
                      subtitle: Text(
                          '${r['msg_count']} 条 · 保存于 ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}'),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => TopicPage(
                              topicId: r['id'] as int, title: title, style: widget.style),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

class TopicPage extends StatefulWidget {
  final int topicId;
  final String title;
  final ChatStyle style;
  const TopicPage({super.key, required this.topicId, required this.title, required this.style});
  @override
  State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> {
  List<Msg>? _msgs;

  @override
  void initState() {
    super.initState();
    appDb!
        .rawQuery(
            'SELECT id, role, content, ts FROM topic_messages WHERE topic_id = ? ORDER BY id',
            [widget.topicId])
        .then((rows) => setState(() {
              _msgs = rows
                  .map((r) => Msg(r['id'] as int, (r['role'] ?? '').toString(),
                      (r['content'] ?? '').toString(), (r['ts'] ?? '').toString()))
                  .toList();
            }));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.title.isEmpty ? '话题' : widget.title,
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _msgs == null
          ? const Center(child: CircularProgressIndicator())
          : MessageList(msgs: _msgs!, style: widget.style, initialIndex: 0),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _c = TextEditingController();
  List<Map<String, Object?>> _rows = [];
  bool _busy = false;
  bool _searched = false;
  String _kw = '';

  Future<void> _go() async {
    final k = _c.text.trim();
    if (k.isEmpty) return;
    setState(() {
      _busy = true;
      _kw = k;
    });
    final esc = k.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
    final rows = await appDb!.rawQuery(
        'SELECT m.id AS mid, m.chat_id, m.content, m.ts, c.title, r.name AS rname '
        'FROM messages m JOIN chats c ON c.id = m.chat_id '
        'LEFT JOIN roles r ON r.id = c.role_id '
        "WHERE m.content LIKE ? ESCAPE '\\' ORDER BY m.id DESC LIMIT 300",
        ['%$esc%']);
    setState(() {
      _rows = rows;
      _busy = false;
      _searched = true;
    });
  }

  String _snippet(String content) {
    final flat = content.replaceAll('\n', ' ');
    final i = flat.toLowerCase().indexOf(_kw.toLowerCase());
    if (i < 0) return flat.length > 60 ? '${flat.substring(0, 60)}…' : flat;
    final a = (i - 20).clamp(0, flat.length).toInt();
    final b = (i + _kw.length + 40).clamp(0, flat.length).toInt();
    return '${a > 0 ? '…' : ''}${flat.substring(a, b)}${b < flat.length ? '…' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _c,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _go(),
          decoration: const InputDecoration(hintText: '搜索全部聊天记录', border: InputBorder.none),
        ),
        actions: [IconButton(icon: const Icon(Icons.search), onPressed: _go)],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : !_searched
              ? const Center(child: Text('输入关键词，回车搜索'))
              : _rows.isEmpty
                  ? const Center(child: Text('没有找到'))
                  : Column(children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                            '找到 ${_rows.length} 条${_rows.length >= 300 ? '（最多显示 300 条）' : ''}',
                            style: const TextStyle(color: Colors.grey)),
                      ),
                      Expanded(
                        child: ListView.separated(
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (c, i) {
                            final r = _rows[i];
                            final ts = (r['ts'] ?? '').toString();
                            return ListTile(
                              title: Text(_snippet((r['content'] ?? '').toString()),
                                  maxLines: 3, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  '${r['rname'] ?? '未归属'} · ${(r['title'] ?? '').toString()} · ${ts.length >= 10 ? ts.substring(0, 10) : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatPage(
                                    chatId: r['chat_id'].toString(),
                                    title: (r['title'] ?? '').toString(),
                                    jumpToMsgId: r['mid'] as int,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ]),
    );
  }
}

