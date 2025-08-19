import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

const token = '7532281521:AAE3XEcfVB8ej_JeXpT3NsoLQ-SUSZmx_UM';
final apiUrl = 'https://api.telegram.org/bot$token/';
final int superAdminId = int.tryParse(Platform.environment['SUPER_ADMIN_ID'] ?? '') ?? 0;

void main() async {
  final db = initDb('nazorey.db');

  scheduleDailyReminder(db);

  await pollUpdates(db);
}

Database initDb(String path) {
  final db = sqlite3.open(path);
  db.execute('''
    CREATE TABLE IF NOT EXISTS users (  
      chat_id INTEGER PRIMARY KEY,
      username TEXT,
      last_read_date TEXT,
      read_count INTEGER DEFAULT 0,
      last_pray_date TEXT,
      pray_count INTEGER DEFAULT 0,
      is_admin INTEGER DEFAULT 0,
      subscribed INTEGER DEFAULT 1
    );
  ''');
  db.execute('''
    CREATE TABLE IF NOT EXISTS daily_stats (
      chat_id INTEGER,
      date TEXT,
      did_read INTEGER DEFAULT 0,
      did_pray INTEGER DEFAULT 0,
      PRIMARY KEY(chat_id, date)
    );
  ''');
  _ensureSchema(db);
  return db;
}

void _ensureSchema(Database db) {
  final cols = db.select('PRAGMA table_info(users);');
  final names = {for (final c in cols) c['name'] as String};
  if (!names.contains('last_pray_date')) {
    db.execute('ALTER TABLE users ADD COLUMN last_pray_date TEXT;');
  }
  if (!names.contains('pray_count')) {
    db.execute('ALTER TABLE users ADD COLUMN pray_count INTEGER DEFAULT 0;');
  }
  if (!names.contains('is_admin')) {
    db.execute('ALTER TABLE users ADD COLUMN is_admin INTEGER DEFAULT 0;');
  }
}

Future<void> pollUpdates(Database db) async {
  int offset = 0;
  while (true) {
    final url = Uri.parse('${apiUrl}getUpdates?offset=$offset&timeout=20');
    try {
      final resp = await http.get(url).timeout(Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          final updates = data['result'] as List<dynamic>;
          for (var update in updates) {
            offset = update['update_id'] + 1;
            final message = update['message'];
            if (message == null) continue;
            final chatId = message['chat']['id'];
            final username = (message['from'] != null && message['from']['username'] != null)
                ? message['from']['username']
                : (message['from'] != null ? (message['from']['first_name'] ?? '') : '');
            final textRaw = message['text'] ?? '';
            final text = textRaw.toString().trim().toLowerCase();

            await handleMessage(db, chatId, username, text);
          }
        }
      } else {
        print('getUpdates error: ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      print('Ошибка pollUpdates: $e');
    }
    await Future.delayed(Duration(seconds: 1));
  }
}

Future<void> handleMessage(Database db, int chatId, String username, String text) async {
  registerUserIfNeeded(db, chatId, username);

  if (text == '/start') {
    await sendMessage(chatId, 'Привет! Я бот "Назарей". Отмечайся сообщениями "прочитал" или "молился", ' +
        'и я сохраню это. Чтобы получать утренние напоминания в 6:00, используй /subscribe. ' +
        'Чтобы отписаться — /unsubscribe. Статистика — /status.');
    return;
  }

  if (text == '/subscribe') {
    setSubscribed(db, chatId, true);
    await sendMessage(chatId, 'Вы подписаны на утренние напоминания в 6:00.');
    return;
  }
  if (text == '/unsubscribe') {
    setSubscribed(db, chatId, false);
    await sendMessage(chatId, 'Вы отписаны от утренних напоминаний.');
    return;
  }

  // /admins — список админов
  if (text == '/admins') {
    if (!isAdmin(db, chatId)) {
      await sendMessage(chatId, 'Недостаточно прав.');
      return;
    }
    final rows = db.select('SELECT chat_id, username FROM users WHERE is_admin = 1 ORDER BY chat_id;');
    if (rows.isEmpty) {
      await sendMessage(chatId, 'Админов нет.');
    } else {
      final list = rows.map((r) {
        final id = r['chat_id'];
        final u = r['username'] ?? '';
        return u != '' ? '$id (@$u)' : '$id';
      }).join('\n');
      await sendMessage(chatId, 'Админы:\n$list');
    }
    return;
  }

  // /admin_add <id|@username>
  if (text.startsWith('/admin_add')) {
    if (!isSuperAdmin(chatId)) {
      await sendMessage(chatId, 'Команда доступна только супер-админу.');
      return;
    }
    final parts = text.split(RegExp('\\s+'));
    if (parts.length < 2) {
      await sendMessage(chatId, 'Использование: /admin_add <chat_id|@username>');
      return;
    }
    final target = parts[1];
    final targetId = parseTargetChatId(db, target);
    if (targetId == null) {
      await sendMessage(chatId, 'Пользователь не найден.');
      return;
    }
    db.execute('UPDATE users SET is_admin = 1 WHERE chat_id = ?;', [targetId]);
    await sendMessage(chatId, 'Пользователь $target назначен админом.');
    return;
  }

  // /admin_remove <id|@username>
  if (text.startsWith('/admin_remove')) {
    if (!isSuperAdmin(chatId)) {
      await sendMessage(chatId, 'Команда доступна только супер-админу.');
      return;
    }
    final parts = text.split(RegExp('\\s+'));
    if (parts.length < 2) {
      await sendMessage(chatId, 'Использование: /admin_remove <chat_id|@username>');
      return;
    }
    final target = parts[1];
    final targetId = parseTargetChatId(db, target);
    if (targetId == null) {
      await sendMessage(chatId, 'Пользователь не найден.');
      return;
    }
    db.execute('UPDATE users SET is_admin = 0 WHERE chat_id = ?;', [targetId]);
    await sendMessage(chatId, 'Пользователь $target лишён прав админа.');
    return;
  }

  if (text == '/status') {
    // Только личный статус (для всех)
    final today = todayString();
    final rows = db.select('SELECT last_read_date, read_count, last_pray_date FROM users WHERE chat_id = ?;', [chatId]);
    if (rows.isNotEmpty) {
      final lastRead = rows.first['last_read_date'] as String? ?? 'не было';
      final readCnt = (rows.first['read_count'] as int?) ?? 0;
      final lastPray = rows.first['last_pray_date'] as String? ?? 'не было';
      final readToday = lastRead == today ? '✅' : '❌';
      final prayToday = lastPray == today ? '✅' : '❌';
      await sendMessage(chatId, 'Ваш статус на сегодня:\nЧтение: $readToday\nМолитва: $prayToday\nдень ' + readCnt.toString());
    } else {
      await sendMessage(chatId, 'Пользователь не найден.');
    }
    return;
  }

  // /report today | /report YYYY-MM-DD
  if (text.startsWith('/report')) {
    if (!isAdmin(db, chatId)) {
      await sendMessage(chatId, 'Недостаточно прав.');
      return;
    }
    final parts = text.split(RegExp('\\s+'));
    String date;
    if (parts.length == 1 || parts[1] == 'today') {
      date = todayString();
    } else {
      date = parts[1];
    }
    final report = buildDailyReport(db, date);
    await sendMessage(chatId, report);
    return;
  }

  // /report_all [@username|chat_id] — отчёт за все дни (для админа)
  if (text.startsWith('/report_all')) {
    if (!isAdmin(db, chatId)) {
      await sendMessage(chatId, 'Недостаточно прав.');
      return;
    }
    final parts = text.split(RegExp('\\s+'));
    int? targetId;
    if (parts.length >= 2) {
      targetId = parseTargetChatId(db, parts[1]);
      if (targetId == null) {
        await sendMessage(chatId, 'Пользователь не найден.');
        return;
      }
    }

    // Определяем диапазон дат: от минимальной даты в daily_stats до сегодняшней
    final minRow = db.select('SELECT MIN(date) AS min_date FROM daily_stats' + (targetId != null ? ' WHERE chat_id = ?' : '') + ';', targetId != null ? [targetId] : const []);
    if (minRow.isEmpty || minRow.first['min_date'] == null) {
      await sendMessage(chatId, targetId != null ? 'Нет данных по этому пользователю.' : 'Нет данных.');
      return;
    }
    final minDateStr = minRow.first['min_date'] as String;
    DateTime startDate;
    try {
      startDate = DateTime.parse(minDateStr);
    } catch (_) {
      await sendMessage(chatId, 'Ошибка формата даты в БД.');
      return;
    }
    final now = DateTime.now();
    final endDate = DateTime(now.year, now.month, now.day);

    // Собираем отчёты по каждой дате и отправляем чанками
    final List<String> chunks = [];
    StringBuffer current = StringBuffer();
    for (DateTime d = startDate; !d.isAfter(endDate); d = d.add(Duration(days: 1))) {
      final y = d.year.toString().padLeft(4, '0');
      final m = d.month.toString().padLeft(2, '0');
      final day = d.day.toString().padLeft(2, '0');
      final date = y + '-' + m + '-' + day;
      String report;
      if (targetId != null) {
        // Один пользователь на эту дату
        final row = db.select(
          'SELECT u.chat_id, u.username, u.subscribed, COALESCE(ds.did_read,0) AS did_read, COALESCE(ds.did_pray,0) AS did_pray '
          'FROM users u LEFT JOIN daily_stats ds ON ds.chat_id = u.chat_id AND ds.date = ? '
          'WHERE u.chat_id = ? LIMIT 1;',
          [date, targetId],
        );
        if (row.isEmpty) continue;
        final uname = (row.first['username'] as String?) ?? '';
        final id = row.first['chat_id'];
        final subscribed = (row.first['subscribed'] as int?) ?? 0;
        final subMark = subscribed == 1 ? '✅' : '❌';
        final readMark = (row.first['did_read'] as int) == 1 ? '✅' : '❌';
        final prayMark = (row.first['did_pray'] as int) == 1 ? '✅' : '❌';
        final dayRow = db.select(
          'SELECT COUNT(*) AS cnt FROM daily_stats WHERE chat_id = ? AND did_read = 1 AND date <= ?;',
          [id, date],
        );
        final dayNum = dayRow.isNotEmpty ? ((dayRow.first['cnt'] as int?) ?? 0) : 0;
        report = 'Отчёт за ' + date + ':\n\n' + 'день ' + dayNum.toString() + '\n' + 'подписка: ' + subMark + '\n' + (uname.isNotEmpty ? '@' + uname : id.toString()) + ' — чтение: ' + readMark + ', молитва: ' + prayMark + ';\n';
      } else {
        // Все подписанные пользователи на эту дату
        // Используем buildDailyReport и добавим подписку в метку прямо здесь
        final rows2 = db.select(
          'SELECT u.chat_id, u.username, u.subscribed, COALESCE(ds.did_read,0) AS did_read, COALESCE(ds.did_pray,0) AS did_pray '
          'FROM users u '
          'LEFT JOIN daily_stats ds ON ds.chat_id = u.chat_id AND ds.date = ? '
          'WHERE u.subscribed = 1 OR u.subscribed = 0 '
          'ORDER BY LOWER(COALESCE(u.username, "")) ASC, u.chat_id ASC;',
          [date],
        );
        if (rows2.isEmpty) {
          report = 'Нет данных за ' + date + '.';
        } else {
          final b = StringBuffer('Отчёт за ' + date + ':\n\n');
          for (final r2 in rows2) {
            final uname2 = (r2['username'] as String?) ?? '';
            final id2 = r2['chat_id'];
            final subscribed2 = (r2['subscribed'] as int?) ?? 0;
            final subMark2 = subscribed2 == 1 ? '✅' : '❌';
            final readMark2 = (r2['did_read'] as int) == 1 ? '✅' : '❌';
            final prayMark2 = (r2['did_pray'] as int) == 1 ? '✅' : '❌';
            final dayRow2 = db.select(
              'SELECT COUNT(*) AS cnt FROM daily_stats WHERE chat_id = ? AND did_read = 1 AND date <= ?;',
              [id2, date],
            );
            final dayNum2 = dayRow2.isNotEmpty ? ((dayRow2.first['cnt'] as int?) ?? 0) : 0;
            b.writeln('день ' + dayNum2.toString());
            b.writeln('подписка: ' + subMark2);
            b.writeln((uname2.isNotEmpty ? '@' + uname2 : id2.toString()) + ' — чтение: ' + readMark2 + ', молитва: ' + prayMark2 + ';');
            b.writeln('');
          }
          report = b.toString();
        }
      }

      if (current.length + report.length > 3500) {
        chunks.add(current.toString());
        current = StringBuffer();
      }
      current.write(report + '\n');
    }
    if (current.isNotEmpty) {
      chunks.add(current.toString());
    }

    for (final chunk in chunks) {
      await sendMessage(chatId, chunk.trim());
      await Future.delayed(Duration(milliseconds: 300));
    }
    return;
  }

  // команда /user удалена

  final readOnly = <String>{'прочитал', 'я прочитал'};
  final prayOnly = <String>{'молился', 'я молился', 'помолился', 'я помолился'};
  final both = <String>{
    'прочитал и молился',
    'прочитал и помолился',
    'молился и прочитал',
    'помолился и прочитал'
  };

  if (readOnly.contains(text)) {
    final updated = markRead(db, chatId);
    await sendMessage(chatId, updated
        ? 'Отметил чтение. Мир вам!'
        : 'Сегодня чтение уже было отмечено.');
    return;
  }
  if (prayOnly.contains(text)) {
    final updated = markPray(db, chatId);
    await sendMessage(chatId, updated
        ? 'Отметил молитву. Мир вам!'
        : 'Сегодня молитва уже была отмечена.');
    return;
  }
  if (both.contains(text)) {
    final updatedRead = markRead(db, chatId);
    final updatedPray = markPray(db, chatId);
    if (updatedRead && updatedPray) {
      await sendMessage(chatId, 'Отметил чтение и молитву. Мир вам!');
    } else if (updatedRead && !updatedPray) {
      await sendMessage(chatId, 'Отметил чтение. Молитва уже была отмечена сегодня.');
    } else if (!updatedRead && updatedPray) {
      await sendMessage(chatId, 'Отметил молитву. Чтение уже было отмечено сегодня.');
    } else {
      await sendMessage(chatId, 'Сегодня уже отмечены и чтение, и молитва.');
    }
    return;
  }

  // Мягкое распознавание: игнорируем пунктуацию и мелкие опечатки
  final normalized = text
      .replaceAll(RegExp(r'[^a-zA-Zа-яА-ЯёЁ0-9\s]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final mentionsRead = RegExp(r'(прочитал|прочит|читал)').hasMatch(normalized);
  final mentionsPray = RegExp(r'(молил|помолил)').hasMatch(normalized);

  if (mentionsRead && mentionsPray) {
    final updatedRead = markRead(db, chatId);
    final updatedPray = markPray(db, chatId);
    if (updatedRead && updatedPray) {
      await sendMessage(chatId, 'Отметил чтение и молитву. Мир вам!');
    } else if (updatedRead && !updatedPray) {
      await sendMessage(chatId, 'Отметил чтение. Молитва уже была отмечена сегодня.');
    } else if (!updatedRead && updatedPray) {
      await sendMessage(chatId, 'Отметил молитву. Чтение уже было отмечено сегодня.');
    } else {
      await sendMessage(chatId, 'Сегодня уже отмечены и чтение, и молитва.');
    }
    return;
  }
  if (mentionsRead) {
    final updated = markRead(db, chatId);
    await sendMessage(chatId, updated
        ? 'Отметил чтение. Мир вам!'
        : 'Сегодня чтение уже было отмечено.');
    return;
  }
  if (mentionsPray) {
    final updated = markPray(db, chatId);
    await sendMessage(chatId, updated
        ? 'Отметил молитву. Мир вам!'
        : 'Сегодня молитва уже была отмечена.');
    return;
  }

  if (text == 'привет') {
    await sendMessage(chatId, 'привет друг😃');
    return;
  }
  if (text == 'пока') {
    await sendMessage(chatId, 'пока друг😢');
    return;
  }


  await sendMessage(chatId, 'Я распознаю: "прочитал", "молился", фразы с этими словами, а также /subscribe, /unsubscribe, /status.');
}

bool isAdmin(Database db, int chatId) {
  if (isSuperAdmin(chatId)) return true;
  final rows = db.select('SELECT is_admin FROM users WHERE chat_id = ?;', [chatId]);
  if (rows.isEmpty) return false;
  final val = rows.first['is_admin'] as int? ?? 0;
  return val == 1;
}

bool isSuperAdmin(int chatId) {
  return superAdminId != 0 && chatId == superAdminId;
}

int? parseTargetChatId(Database db, String target) {
  if (target.startsWith('@')) {
    final uname = target.substring(1);
    final rows = db.select('SELECT chat_id FROM users WHERE LOWER(username) = LOWER(?) LIMIT 1;', [uname]);
    if (rows.isEmpty) return null;
    return rows.first['chat_id'] as int;
  }
  return int.tryParse(target);
}

String buildDailyReport(Database db, String date) {
  final rows = db.select(
    'SELECT u.chat_id, u.username, u.subscribed, COALESCE(ds.did_read,0) AS did_read, COALESCE(ds.did_pray,0) AS did_pray '
    'FROM users u '
    'LEFT JOIN daily_stats ds ON ds.chat_id = u.chat_id AND ds.date = ? '
    'ORDER BY LOWER(COALESCE(u.username, "")) ASC, u.chat_id ASC;',
    [date],
  );
  if (rows.isEmpty) return 'Нет данных за ' + date + '.';
  final buffer = StringBuffer('Отчёт за ' + date + ':\n\n');
  for (final r in rows) {
    final uname = (r['username'] as String?) ?? '';
    final id = r['chat_id'];
    final subMark = ((r['subscribed'] as int?) ?? 0) == 1 ? '✅' : '❌';
    final readMark = (r['did_read'] as int) == 1 ? '✅' : '❌';
    final prayMark = (r['did_pray'] as int) == 1 ? '✅' : '❌';
    final labelPlain = uname.isNotEmpty ? '@' + uname : id.toString();
    // Печатаем "день N" на отдельной строке перед пользователем.
    // N = количество дней с отметкой чтения до и включая указанную дату.
    final dayRow = db.select(
      'SELECT COUNT(*) AS cnt FROM daily_stats WHERE chat_id = ? AND did_read = 1 AND date <= ?;',
      [id, date],
    );
    final dayNum = dayRow.isNotEmpty ? ((dayRow.first['cnt'] as int?) ?? 0) : 0;
    buffer.writeln('день ' + dayNum.toString());
    buffer.writeln('подписка: ' + subMark);
    buffer.writeln(labelPlain + ' — чтение: ' + readMark + ', молитва: ' + prayMark + ';');
    buffer.writeln('');
  }
  return buffer.toString();
}

void registerUserIfNeeded(Database db, int chatId, String username) {
  final rows = db.select('SELECT 1 FROM users WHERE chat_id = ?;', [chatId]);
  if (rows.isEmpty) {
    final stmt = db.prepare('INSERT INTO users(chat_id, username, subscribed) VALUES(?, ?, 1);');
    stmt.execute([chatId, username]);
    stmt.dispose();
    print('Новый пользователь зарегистрирован: $chatId ($username)');
    if (isSuperAdmin(chatId)) {
      db.execute('UPDATE users SET is_admin = 1 WHERE chat_id = ?;', [chatId]);
    }
  } else {
    db.execute('UPDATE users SET username = ? WHERE chat_id = ?;', [username, chatId]);
    if (isSuperAdmin(chatId)) {
      db.execute('UPDATE users SET is_admin = 1 WHERE chat_id = ?;', [chatId]);
    }
  }
}

bool markRead(Database db, int chatId) {
  final today = todayString();
  final rows = db.select('SELECT last_read_date FROM users WHERE chat_id = ?;', [chatId]);
  if (rows.isEmpty) return false;
  final last = rows.first['last_read_date'] as String?;
  if (last == today) {
    print('Пользователь $chatId уже отмечал чтение сегодня.');
    return false;
  }
  final stmt = db.prepare('UPDATE users SET last_read_date = ?, read_count = COALESCE(read_count,0) + 1 WHERE chat_id = ?;');
  stmt.execute([today, chatId]);
  stmt.dispose();
  print('Пользователь $chatId отметил прочтение: $today');
  db.execute('INSERT OR IGNORE INTO daily_stats(chat_id, date, did_read, did_pray) VALUES(?, ?, 0, 0);', [chatId, today]);
  db.execute('UPDATE daily_stats SET did_read = 1 WHERE chat_id = ? AND date = ?;', [chatId, today]);
  return true;
}

bool markPray(Database db, int chatId) {
  final today = todayString();
  final rows = db.select('SELECT last_pray_date FROM users WHERE chat_id = ?;', [chatId]);
  if (rows.isEmpty) return false;
  final last = rows.first['last_pray_date'] as String?;
  if (last == today) {
    print('Пользователь $chatId уже отмечал молитву сегодня.');
    return false;
  }
  final stmt = db.prepare('UPDATE users SET last_pray_date = ?, pray_count = COALESCE(pray_count,0) + 1 WHERE chat_id = ?;');
  stmt.execute([today, chatId]);
  stmt.dispose();
  print('Пользователь $chatId отметил молитву: $today');
  db.execute('INSERT OR IGNORE INTO daily_stats(chat_id, date, did_read, did_pray) VALUES(?, ?, 0, 0);', [chatId, today]);
  db.execute('UPDATE daily_stats SET did_pray = 1 WHERE chat_id = ? AND date = ?;', [chatId, today]);
  return true;
}

void setSubscribed(Database db, int chatId, bool sub) {
  db.execute('UPDATE users SET subscribed = ? WHERE chat_id = ?;', [sub ? 1 : 0, chatId]);
}

Future<void> sendMessage(int chatId, String text) async {
  final uri = Uri.parse('${apiUrl}sendMessage').replace(queryParameters: {
    'chat_id': chatId.toString(),
    'text': text,
    'parse_mode': 'HTML'
  });
  try {
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      print('Ошибка sendMessage ${resp.statusCode}: ${resp.body}');
    }
  } catch (e) {
    print('Ошибка sendMessage: $e');
  }
}

Future<void> scheduleDailyReminder(Database db) async {
  while (true) {
    final now = DateTime.now();
    DateTime next = DateTime(now.year, now.month, now.day, 6, 0, 0);
    if (!next.isAfter(now)) {
      next = next.add(Duration(days: 1));
    }
    final wait = next.difference(now);
    print('Ожидание следующего напоминания: ${wait.inHours} ч ${wait.inMinutes % 60} мин');
    await Future.delayed(wait);

    try {
      final rows = db.select('SELECT chat_id FROM users WHERE subscribed = 1;');
      if (rows.isEmpty) {
        print('Нет подписанных пользователей для напоминания.');
      } else {
        for (final row in rows) {
          final chatId = row['chat_id'] as int;
          await sendMessage(chatId, 'Напоминание: доброе утро! Не забудьте сегодня прочитать Библию и помолиться. Отметьтесь сообщением "прочитал" или "молился".');
          await Future.delayed(Duration(milliseconds: 200));
        }
        print('Напоминания отправлены: ${rows.length}');
      }
    } catch (e) {
      print('Ошибка при отправке напоминаний: $e');
    }
  }
}

String todayString() {
  final d = DateTime.now();
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}