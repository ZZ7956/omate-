import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'export.dart';
import 'main.dart';
import 'settings.dart';

class Msg {
 final int id;
 final String role;
 final String content;
 final String ts;
 Msg(this.id, this.role, this.content, this.ts);
}

class Avatar extends StatelessWidget {
 final String? rel;
 final String name;
 final double size;
 const Avatar({super.key, this.rel, required this.name, this.size = 40});

 @override
 Widget build(BuildContext context) {
 Widget fallback() => CircleAvatar(
 radius: size / 2,
 child: Text(name.isEmpty ? '?' : name.substring(0, 1),
 style: TextStyle(fontSize: size * 0.45)),
 );
 if (rel == null || rel!.isEmpty) return fallback();
 final file = File('$avatarDir/${rel!.replaceFirst('rel://', '')}');
 return ClipOval(
 child: Image.file(file,
 width: size,
 height: size,
 fit: BoxFit.cover,
 cacheWidth: (size * 3).round(),
 errorBuilder: (_, __, ___) => fallback()),
 );
 }
}

class ChatStyle {
 final double fontSize;
 final Color userBubble, roleBubble, userText, roleText;
 final Color userItalic, userBold, roleItalic, roleBold;
 final String roleName, maskName;
 final String? roleAvatar, maskAvatar;

 ChatStyle({
 required this.fontSize,
 required this.userBubble,
 required this.roleBubble,
 required this.userText,
 required this.roleText,
 required this.userItalic,
 required this.userBold,
 required this.roleItalic,
 required this.roleBold,
 required this.roleName,
 required this.maskName,
 this.roleAvatar,
 this.maskAvatar,
 });

 factory ChatStyle.from(String? json) {
 Map d = {};
 try {
 final x = jsonDecode(json ?? '{}');
 if (x is Map) d = x;
 } catch (_) {}
 final role = d['role'] is Map ? d['role'] as Map : {};
 final mask = d['mask'] is Map ? d['mask'] as Map : {};

 Color col(String key, String custom, Color def, [dynamic opacity]) {
 final v = d[key];
 var c = (d[custom] == true && v is num) ? Color(v.toInt() & 0xFFFFFFFF) : def;
 if (opacity is num) {
 c = c.withAlpha((opacity.toDouble().clamp(0.0, 1.0) * 255).round());
 }
 return c;
 }

 final uText = col('user_text_color', 'use_custom_user_text_color', Colors.white);
 final rText = col('role_text_color', 'use_custom_role_text_color', Colors.white);
 String s(Map m, String k, String def) {
 final v = (m[k] ?? '').toString();
 return v.isEmpty ? def : v;
 }

 return ChatStyle(
 fontSize: d['font_size'] is num ? (d['font_size'] as num).toDouble() : 16,
 userBubble: col('user_bubble_color', 'use_custom_user_bubble_color',
 const Color(0xFF3E6B4B), d['user_bubble_opacity'] ?? 0.8),
 roleBubble: col('role_bubble_color', 'use_custom_role_bubble_color',
 const Color(0xFF2F3A40), d['role_bubble_opacity'] ?? 0.8),
 userText: uText,
 roleText: rText,
 userItalic: col('user_italic_text_color', 'use_custom_user_italic_text_color', uText),
 userBold: col('user_bold_text_color', 'use_custom_user_bold_text_color', uText),
 roleItalic: col('role_italic_text_color', 'use_custom_role_italic_text_color', rText),
 roleBold: col('role_bold_text_color', 'use_custom_role_bold_text_color', rText),
 roleName: s(role, 'name', '角色'),
 maskName: s(mask, 'name', '我'),
 roleAvatar: s(role, 'avatar', ''),
 maskAvatar: s(mask, 'avatar', ''),
 );
 }

 // 开启「全局样式」后，用设置页里的颜色和字号覆盖窗口自己的
 ChatStyle applyGlobal(AppSettings s, {bool force = false}) {
 if (!s.overrideStyle && !force) return this;
 return ChatStyle(
 fontSize: s.fontSize,
 userBubble: Color(s.userBubble),
 roleBubble: Color(s.roleBubble),
 userText: Color(s.userText),
 roleText: Color(s.roleText),
 userItalic: Color(s.userText),
 userBold: Color(s.userText),
 roleItalic: Color(s.roleText),
 roleBold: Color(s.roleText),
 roleName: roleName,
 maskName: maskName,
 roleAvatar: roleAvatar,
 maskAvatar: maskAvatar,
 );
 }
}

List<InlineSpan> buildSpans(String text, Color italic, Color bold) {
 final re = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*', dotAll: true);
 final out = <InlineSpan>[];
 var last = 0;
 for (final m in re.allMatches(text)) {
 if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
 if (m.group(1) != null) {
 out.add(TextSpan(
 text: m.group(1),
 style: TextStyle(fontWeight: FontWeight.bold, color: bold)));
 } else {
 out.add(TextSpan(
 text: m.group(2),
 style: TextStyle(fontStyle: FontStyle.italic, color: italic)));
 }
 last = m.end;
 }
 if (last < text.length) out.add(TextSpan(text: text.substring(last)));
 return out;
}

class ChatBackground extends StatelessWidget {
 final Widget child;
 const ChatBackground({super.key, required this.child});

 @override
 Widget build(BuildContext context) {
 return ListenableBuilder(
 listenable: settings,
 builder: (context, _) {
 final p = settings.bgImage;
 return Stack(children: [
 Positioned.fill(child: ColoredBox(color: Color(settings.pageColor))),
 if (p != null && File(p).existsSync())
 Positioned.fill(
 child: Opacity(
 opacity: settings.bgOpacity,
 child: Image.file(File(p),
 fit: BoxFit.cover,
 cacheWidth: 1080,
 errorBuilder: (_, __, ___) => const SizedBox()),
 ),
 ),
 Positioned.fill(child: child),
 ]);
 },
 );
 }
}

class BubbleView extends StatelessWidget {
 final Msg msg;
 final ChatStyle style;
 final bool highlight;
 final VoidCallback? onTap;
 final VoidCallback? onLongPress;
 const BubbleView({
 super.key,
 required this.msg,
 required this.style,
 this.highlight = false,
 this.onTap,
 this.onLongPress,
 });

 @override
 Widget build(BuildContext context) {
 final st = style;
 final isUser = msg.role == 'user';
 final bg = isUser ? st.userBubble : st.roleBubble;
 final tc = isUser ? st.userText : st.roleText;
 final name = isUser ? st.maskName : st.roleName;
 final av = isUser ? st.maskAvatar : st.roleAvatar;
 final time = msg.ts.length >= 16 ? msg.ts.substring(11, 16) : '';
 final fam = settings.fontFamily;

 final header = <Widget>[
 if (settings.showAvatar) Avatar(rel: av, name: name, size: 28),
 if (settings.showAvatar && settings.showName) const SizedBox(width: 6),
 if (settings.showName)
 Flexible(
 child: Text('$name $time',
 overflow: TextOverflow.ellipsis,
 style: const TextStyle(fontSize: 12, color: Colors.grey)),
 ),
 ];

 return GestureDetector(
 behavior: HitTestBehavior.translucent,
 onTap: onTap,
 onLongPress: onLongPress,
 child: Padding(
 padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
 child: Column(
 crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
 children: [
 if (header.isNotEmpty)
 Row(
 mainAxisAlignment:
 isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
 children: isUser ? header.reversed.toList() : header,
 ),
 if (header.isNotEmpty) const SizedBox(height: 4),
 ConstrainedBox(
 constraints:
 BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.84),
 child: Container(
 padding: const EdgeInsets.all(10),
 decoration: BoxDecoration(
 color: bg,
 borderRadius: BorderRadius.circular(settings.bubbleRadius),
 border: highlight ? Border.all(color: Colors.amber, width: 2) : null,
 ),
 child: Text.rich(TextSpan(
 style: TextStyle(
 color: tc, fontSize: st.fontSize, height: 1.5, fontFamily: fam),
 children: buildSpans(
 msg.content,
 isUser ? st.userItalic : st.roleItalic,
 isUser ? st.userBold : st.roleBold,
 ),
 )),
 ),
 ),
 ],
 ),
 ),
 );
 }
}

class MessageList extends StatefulWidget {
 final List<Msg> msgs;
 final ChatStyle style;
 final int initialIndex;
 final int? highlightId;
 final String title;
 final Future<void> Function(Msg)? onDelete;
 const MessageList({
 super.key,
 required this.msgs,
 required this.style,
 this.initialIndex = 0,
 this.highlightId,
 this.title = '',
 this.onDelete,
 });

 @override
 State<MessageList> createState() => MessageListState();
}

class MessageListState extends State<MessageList> {
 late List<Msg> _msgs;
 final _ctrl = ItemScrollController();
 late ChatStyle _st;
 bool _selecting = false;
 int? _a;
 int? _b;

 @override
 void initState() {
 super.initState();
 _msgs = List.of(widget.msgs);
 _st = widget.style;
 }

 String _day(String ts) => ts.length >= 10 ? ts.substring(0, 10) : '';

 // ---------- 跳到某一天 ----------
 Future<void> pickDay() async {
 if (_msgs.isEmpty) return;
 final re = RegExp(r'^\d{4}-\d{2}-\d{2}$');
 final days = <String>{};
 for (final m in _msgs) {
 final d = _day(m.ts);
 if (re.hasMatch(d)) days.add(d);
 }
 if (days.isEmpty) return;
 final sorted = days.toList()..sort();
 final first = DateTime.parse(sorted.first);
 final last = DateTime.parse(sorted.last);
 String f(DateTime d) =>
 '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
 final picked = await showDatePicker(
 context: context,
 initialDate: last,
 firstDate: first,
 lastDate: last,
 selectableDayPredicate: (d) => days.contains(f(d)),
 helpText: '跳到哪一天（灰色的日子没有聊天）',
 );
 if (picked == null) return;
 final day = f(picked);
 final idx = _msgs.indexWhere((m) => m.ts.startsWith(day));
 if (idx >= 0) _ctrl.jumpTo(index: idx);
 }

 // ---------- 选择并导出 ----------
 void enterSelect() {
 setState(() {
 _selecting = true;
 _a = null;
 _b = null;
 });
 }

 List<int>? _range() {
 final a = _a;
 if (a == null) return null;
 final b = _b ?? a;
 return a <= b ? [a, b] : [b, a];
 }

 bool _inRange(int i) {
 final r = _range();
 return r != null && i >= r[0] && i <= r[1];
 }

 int _count() {
 final r = _range();
 return r == null ? 0 : r[1] - r[0] + 1;
 }

 List<Msg> _selected() {
 final r = _range();
 if (r == null) return [];
 return _msgs.sublist(r[0], r[1] + 1);
 }

 String _hint() {
 if (_a == null) return '点一条消息作为起点';
 if (_b == null) return '起点已选，再点一条设终点（或直接导出这一条）';
 return '已选 ${_count()} 条';
 }

 void _tapSelect(int i) {
 setState(() {
 if (_a == null || _b != null) {
 _a = i;
 _b = null;
 } else {
 _b = i;
 }
 });
 }

 Future<void> _doExport(bool image) async {
 final sel = _selected();
 if (sel.isEmpty) return;
 if (image) {
 await exportImages(context, sel, _st, widget.title);
 } else {
 await exportText(context, sel, _st, widget.title);
 }
 }

 // ---------- 长按菜单 ----------
 Future<void> _menu(Msg m) async {
 await showModalBottomSheet(
 context: context,
 builder: (ctx) => SafeArea(
 child: Column(mainAxisSize: MainAxisSize.min, children: [
 ListTile(
 leading: const Icon(Icons.copy),
 title: const Text('复制'),
 onTap: () async {
 await Clipboard.setData(ClipboardData(text: m.content));
 if (ctx.mounted) Navigator.pop(ctx);
 if (mounted) {
 ScaffoldMessenger.of(context)
 .showSnackBar(const SnackBar(content: Text('已复制')));
 }
 },
 ),
 ListTile(
 leading: const Icon(Icons.ios_share),
 title: const Text('从这条开始选择并导出'),
 onTap: () {
 Navigator.pop(ctx);
 setState(() {
 _selecting = true;
 _a = _msgs.indexOf(m);
 _b = null;
 });
 },
 ),
 if (widget.onDelete != null)
 ListTile(
 leading: const Icon(Icons.delete_outline),
 title: const Text('删除这条'),
 onTap: () async {
 Navigator.pop(ctx);
 final ok = await showDialog<bool>(
 context: context,
 builder: (c) => AlertDialog(
 title: const Text('确定删除这条消息？'),
 content: const Text('只删除 App 里的这一份，不影响你的原备份文件。'),
 actions: [
 TextButton(
 onPressed: () => Navigator.pop(c, false),
 child: const Text('取消')),
 TextButton(
 onPressed: () => Navigator.pop(c, true),
 child: const Text('删除')),
 ],
 ),
 );
 if (ok == true) {
 await widget.onDelete!(m);
 if (mounted) {
 setState(() {
 _msgs.remove(m);
 _a = null;
 _b = null;
 });
 }
 }
 },
 ),
 ]),
 ),
 );
 }

 Widget _item(int i) {
 final m = _msgs[i];
 final day = _day(m.ts);
 final newDay = i == 0 || day != _day(_msgs[i - 1].ts);
 Widget bubble = BubbleView(
 msg: m,
 style: _st,
 highlight: widget.highlightId != null && m.id == widget.highlightId,
 onTap: _selecting ? () => _tapSelect(i) : null,
 onLongPress: _selecting ? null : () => _menu(m),
 );
 if (_selecting) {
 bubble = Container(
 color: _inRange(i) ? Colors.blue.withAlpha(50) : null,
 child: bubble,
 );
 }
 return Column(children: [
 if (newDay && day.isNotEmpty)
 Padding(
 padding: const EdgeInsets.only(top: 14, bottom: 4),
 child: Container(
 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
 decoration: BoxDecoration(
 color: Colors.white12, borderRadius: BorderRadius.circular(10)),
 child: Text(day, style: const TextStyle(fontSize: 12, color: Colors.grey)),
 ),
 ),
 bubble,
 ]);
 }

 @override
 Widget build(BuildContext context) {
 return ListenableBuilder(
 listenable: settings,
 builder: (context, _) {
 _st = widget.style.applyGlobal(settings);
 if (_msgs.isEmpty) return const Center(child: Text('没有消息'));
 final start = widget.initialIndex.clamp(0, _msgs.length - 1).toInt();
 return Stack(children: [
 ScrollablePositionedList.builder(
 itemScrollController: _ctrl,
 initialScrollIndex: start,
 itemCount: _msgs.length,
 itemBuilder: (c, i) => _item(i),
 ),
 Positioned(
 right: 8,
 bottom: _selecting ? 76 : 16,
 child: Column(children: [
 FloatingActionButton.small(
 heroTag: null,
 onPressed: () => _ctrl.jumpTo(index: 0),
 child: const Icon(Icons.keyboard_double_arrow_up),
 ),
 const SizedBox(height: 8),
 FloatingActionButton.small(
 heroTag: null,
 onPressed: () => _ctrl.jumpTo(index: _msgs.length - 1),
 child: const Icon(Icons.keyboard_double_arrow_down),
 ),
 ]),
 ),
 if (_selecting)
 Positioned(
 left: 0,
 right: 0,
 bottom: 0,
 child: Material(
 color: const Color(0xFF1E1E1E),
 elevation: 8,
 child: SafeArea(
 top: false,
 child: Padding(
 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
 child: Row(children: [
 Expanded(
 child: Text(_hint(), style: const TextStyle(fontSize: 12))),
 TextButton(
 onPressed: _count() == 0 ? null : () => _doExport(false),
 child: const Text('文字'),
 ),
 TextButton(
 onPressed: _count() == 0 ? null : () => _doExport(true),
 child: const Text('图片'),
 ),
 TextButton(
 onPressed: () => setState(() {
 _selecting = false;
 _a = null;
 _b = null;
 }),
 child: const Text('取消'),
 ),
 ]),
 ),
 ),
 ),
 ),
 ]);
 },
 );
 }
}

// ======================= 聊天页 / 话题页 =======================

class ChatPage extends StatefulWidget {
 final String chatId;
 final String title;
 final int? jumpToMsgId;
 const ChatPage({super.key, required this.chatId, required this.title, this.jumpToMsgId});
 @override
 State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
 final _listKey = GlobalKey<MessageListState>();
 List<Msg>? _msgs;
 ChatStyle? _style;
 int _start = 0;

 @override
 void initState() {
 super.initState();
 _load();
 }

 Future<void> _load() async {
 final db = appDb!;
 final c = await db.query('chats', where: 'id = ?', whereArgs: [widget.chatId]);
 final style = ChatStyle.from(c.isEmpty ? '{}' : c.first['data']?.toString());
 final rows = await db.rawQuery(
 'SELECT id, role, content, ts FROM messages WHERE chat_id = ? ORDER BY id',
 [widget.chatId]);
 final msgs = rows
 .map((r) => Msg(r['id'] as int, (r['role'] ?? '').toString(),
 (r['content'] ?? '').toString(), (r['ts'] ?? '').toString()))
 .toList();
 var start = msgs.length - 1;
 if (widget.jumpToMsgId != null) {
 final k = msgs.indexWhere((m) => m.id == widget.jumpToMsgId);
 if (k >= 0) start = k;
 }
 setState(() {
 _msgs = msgs;
 _style = style;
 _start = start < 0 ? 0 : start;
 });
 }

 @override
 Widget build(BuildContext context) {
 return Scaffold(
 appBar: AppBar(
 title: Text(widget.title.isEmpty ? '聊天' : widget.title,
 maxLines: 1, overflow: TextOverflow.ellipsis),
 actions: [
 IconButton(
 icon: const Icon(Icons.calendar_month),
 tooltip: '跳到某一天',
 onPressed: () => _listKey.currentState?.pickDay(),
 ),
 IconButton(
 icon: const Icon(Icons.history),
 tooltip: '话题',
 onPressed: _style == null
 ? null
 : () => Navigator.push(
 context,
 MaterialPageRoute(
 builder: (_) =>
 TopicsPage(chatId: widget.chatId, style: _style!)),
 ),
 ),
 PopupMenuButton<String>(
 onSelected: (v) {
 if (v == 'export') _listKey.currentState?.enterSelect();
 if (v == 'search') {
 Navigator.push(
 context, MaterialPageRoute(builder: (_) => const SearchPage()));
 }
 if (v == 'style') {
 Navigator.push(
 context, MaterialPageRoute(builder: (_) => const SettingsPage()));
 }
 },
 itemBuilder: (_) => const [
 PopupMenuItem(value: 'export', child: Text('选择并导出')),
 PopupMenuItem(value: 'search', child: Text('搜索')),
 PopupMenuItem(value: 'style', child: Text('外观设置')),
 ],
 ),
 ],
 ),
 body: _msgs == null
 ? const Center(child: CircularProgressIndicator())
 : ChatBackground(
 child: MessageList(
 key: _listKey,
 msgs: _msgs!,
 style: _style!,
 initialIndex: _start,
 highlightId: widget.jumpToMsgId,
 title: widget.title,
 onDelete: (m) async {
 await appDb!.delete('messages', where: 'id = ?', whereArgs: [m.id]);
 },
 ),
 ),
 );
 }
}

class TopicsPage extends StatefulWidget {
 final String chatId;
 final ChatStyle style;
 const TopicsPage({super.key, required this.chatId, required this.style});
 @override
 State<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<TopicsPage> {
 List<Map<String, Object?>> _rows = [];
 bool _loading = true;

 @override
 void initState() {
 super.initState();
 _load();
 }

 Future<void> _load() async {
 final r = await appDb!.query('topics',
 where: 'chat_id = ?', whereArgs: [widget.chatId], orderBy: 'saved_at DESC');
 if (!mounted) return;
 setState(() {
 _rows = r;
 _loading = false;
 });
 }

 Future<void> _del(Map<String, Object?> r) async {
 final ok = await showDialog<bool>(
 context: context,
 builder: (c) => AlertDialog(
 title: const Text('删除这个话题？'),
 content: const Text('话题里的所有消息都会从 App 里删除，不影响你的原备份文件。'),
 actions: [
 TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
 TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除')),
 ],
 ),
 );
 if (ok != true) return;
 final id = r['id'] as int;
 await appDb!.delete('topic_messages', where: 'topic_id = ?', whereArgs: [id]);
 await appDb!.delete('topics', where: 'id = ?', whereArgs: [id]);
 _load();
 }

 @override
 Widget build(BuildContext context) {
 return Scaffold(
 appBar: AppBar(title: const Text('话题（历史版本）')),
 body: _loading
 ? const Center(child: CircularProgressIndicator())
 : _rows.isEmpty
 ? const Center(child: Text('这个窗口没有历史话题'))
 : Column(children: [
 const Padding(
 padding: EdgeInsets.all(8),
 child: Text('长按话题可以删除', style: TextStyle(color: Colors.grey)),
 ),
 Expanded(
 child: ListView.separated(
 itemCount: _rows.length,
 separatorBuilder: (_, __) => const Divider(height: 1),
 itemBuilder: (c, i) {
 final r = _rows[i];
 final t = DateTime.fromMillisecondsSinceEpoch(
 (r['saved_at'] as int?) ?? 0);
 final title = (r['title'] ?? '').toString();
 String two(int x) => x.toString().padLeft(2, '0');
 return ListTile(
 title: Text(title.isEmpty ? '（无标题）' : title),
 subtitle: Text(
 '${r['msg_count']} 条 · 保存于 ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}'),
 onLongPress: () => _del(r),
 onTap: () async {
 await Navigator.push(
 context,
 MaterialPageRoute(
 builder: (_) => TopicPage(
 topicId: r['id'] as int,
 title: title,
 style: widget.style),
 ),
 );
 _load();
 },
 );
 },
 ),
 ),
 ]),
 );
 }
}

class TopicPage extends StatefulWidget {
 final int topicId;
 final String title;
 final ChatStyle style;
 const TopicPage({super.key, required this.topicId, required this.title, required this.style});
 @override
 State<TopicPage> createState() => _TopicPageState();
}

class _TopicPageState extends State<TopicPage> {
 final _listKey = GlobalKey<MessageListState>();
 List<Msg>? _msgs;

 @override
 void initState() {
 super.initState();
 appDb!
 .rawQuery(
 'SELECT id, role, content, ts FROM topic_messages WHERE topic_id = ? ORDER BY id',
 [widget.topicId])
 .then((rows) => setState(() {
 _msgs = rows
 .map((r) => Msg(r['id'] as int, (r['role'] ?? '').toString(),
 (r['content'] ?? '').toString(), (r['ts'] ?? '').toString()))
 .toList();
 }));
 }

 @override
 Widget build(BuildContext context) {
 return Scaffold(
 appBar: AppBar(
 title: Text(widget.title.isEmpty ? '话题' : widget.title,
 maxLines: 1, overflow: TextOverflow.ellipsis),
 actions: [
 IconButton(
 icon: const Icon(Icons.calendar_month),
 tooltip: '跳到某一天',
 onPressed: () => _listKey.currentState?.pickDay(),
 ),
 PopupMenuButton<String>(
 onSelected: (v) {
 if (v == 'export') _listKey.currentState?.enterSelect();
 },
 itemBuilder: (_) => const [
 PopupMenuItem(value: 'export', child: Text('选择并导出')),
 ],
 ),
 ],
 ),
 body: _msgs == null
 ? const Center(child: CircularProgressIndicator())
 : ChatBackground(
 child: MessageList(
 key: _listKey,
 msgs: _msgs!,
 style: widget.style,
 initialIndex: 0,
 title: widget.title,
 onDelete: (m) async {
 final db = appDb!;
 await db.delete('topic_messages', where: 'id = ?', whereArgs: [m.id]);
 await db.rawUpdate(
 'UPDATE topics SET msg_count = (SELECT COUNT(*) FROM topic_messages WHERE topic_id = ?) WHERE id = ?',
 [widget.topicId, widget.topicId]);
 },
 ),
 ),
 );
 }
}
