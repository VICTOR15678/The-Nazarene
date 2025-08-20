import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

final String token = Platform.environment['BOT_TOKEN'] ?? '';
final apiUrl = 'https://api.telegram.org/bot$token/';
final int superAdminId = int.tryParse(Platform.environment['SUPER_ADMIN_ID'] ?? '') ?? 0;

void main() async {
  if (token.isEmpty) {
    stderr.writeln('Environment variable BOT_TOKEN is not set. Please set BOT_TOKEN and restart.');
    exit(1);
  }
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
  print('Начинаем опрос обновлений...');
  while (true) {
    final url = Uri.parse('${apiUrl}getUpdates?offset=$offset&timeout=20');
    try {
      print('Запрашиваем обновления с offset=$offset');
      final resp = await http.get(url).timeout(Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['ok'] == true) {
          final updates = data['result'] as List<dynamic>;
          print('Получено ${updates.length} обновлений');
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
            
            print('Обрабатываем сообщение от $chatId ($username): "$text"');

            await handleMessage(db, chatId, username, text);
          }
        } else {
          print('getUpdates вернул ok=false: ${resp.body}');
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
    await sendMessage(
      chatId,
      'Привет! Я бот "Назарей". Используй кнопки ниже, чтобы отметиться:\n' +
          '— читал\n— молился\n— читал и молился\n\n' +
          'Чтобы получать утренние напоминания в 6:00, используй /subscribe. ' +
          'Чтобы отписаться — /unsubscribe. Статистика — /status.\n' +
          'Все команды — /help. Если пропали кнопки, введи /menu или слово «кнопки».',
      replyMarkup: buildMainKeyboard(),
    );
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

  // показать клавиатуру по запросу
  if (text == '/menu' || text == 'кнопки' || text == 'кнопка' || text == 'меню') {
    await sendMessage(chatId, 'Выберите действие:', replyMarkup: buildMainKeyboard());
    return;
  }

  // /help | /commands | "команды" — показать все команды
  if (text == '/help' || text == '/commands' || text == 'команды') {
    print('Обработка команды /help для пользователя $chatId');
    final help = buildHelpMessage(db, chatId);
    print('Справка сгенерирована, отправляем сообщение');
    await sendMessage(chatId, help, replyMarkup: buildMainKeyboard());
    print('Сообщение отправлено');
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

  // /kick <id|@username> — кикнуть пользователя (для админов)
  if (text.startsWith('/kick')) {
    if (!isAdmin(db, chatId)) {
      await sendMessage(chatId, 'Недостаточно прав.');
      return;
    }
    final parts = text.split(RegExp('\\s+'));
    if (parts.length < 2) {
      await sendMessage(chatId, 'Использование: /kick <chat_id|@username>');
      return;
    }
    final target = parts[1];
    final targetId = parseTargetChatId(db, target);
    if (targetId == null) {
      await sendMessage(chatId, 'Пользователь не найден.');
      return;
    }
    if (isSuperAdmin(targetId)) {
      await sendMessage(chatId, 'Нельзя кикнуть супер-админа.');
      return;
    }
    db.execute('DELETE FROM users WHERE chat_id = ?;', [targetId]);
    db.execute('DELETE FROM daily_stats WHERE chat_id = ?;', [targetId]);
    await sendMessage(chatId, 'Пользователь $target удалён из бота.');
    return;
  }

  // /reset — полный сброс бота (только для супер-админа)
  if (text == '/reset') {
    if (!isSuperAdmin(chatId)) {
      await sendMessage(chatId, 'Команда доступна только супер-админу.');
      return;
    }
    db.execute('DELETE FROM users;');
    db.execute('DELETE FROM daily_stats;');
    await sendMessage(chatId, 'Бот полностью сброшен. Все данные удалены.');
    return;
  }

  if (text == '/status') {
    // Только личный статус (для всех)
    final today = todayString();
    final rows = db.select('SELECT last_read_date, last_pray_date, subscribed FROM users WHERE chat_id = ?;', [chatId]);
    if (rows.isNotEmpty) {
      final lastRead = rows.first['last_read_date'] as String? ?? 'не было';
      final lastPray = rows.first['last_pray_date'] as String? ?? 'не было';
      final subscribed = (rows.first['subscribed'] as int?) ?? 0;
      final readToday = lastRead == today ? '✅' : '❌';
      final prayToday = lastPray == today ? '✅' : '❌';
      final subMark = subscribed == 1 ? '✅' : '❌';
      final dayRow = db.select('SELECT COUNT(*) AS cnt FROM daily_stats WHERE chat_id = ? AND did_read = 1;', [chatId]);
      final dayNum = dayRow.isNotEmpty ? ((dayRow.first['cnt'] as int?) ?? 0) : 0;
      await sendMessage(chatId, 'Ваш статус на сегодня:\nПодписка: ' + subMark + '\nЧтение: ' + readToday + '\nМолитва: ' + prayToday + '\nдень ' + dayNum.toString());
    } else {
      await sendMessage(chatId, 'Пользователь не найден.');
    }
    return;
  }

  // /report — отчёт за сегодня (для админа)
  if (text == '/report') {
    if (!isAdmin(db, chatId)) {
      await sendMessage(chatId, 'Недостаточно прав.');
      return;
    }
    final date = todayString();
    final report = buildDailyReport(db, date);
    await sendMessage(chatId, report);
    return;
  }

  // команда /user удалена

  final readOnly = <String>{'прочитал', 'я прочитал', 'читал', 'я читал'};
  final prayOnly = <String>{'молился', 'я молился', 'помолился', 'я помолился'};
  final both = <String>{
    'прочитал и молился',
    'прочитал и помолился',
    'молился и прочитал',
    'помолился и прочитал',
    'читал и молился',
    'молился и читал'
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


  await sendMessage(chatId, 'Используйте кнопки: "читал", "молился", "читал и молился". \nТакже распознаю фразы с этими словами и команды /subscribe, /unsubscribe, /status, /menu.');
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

String buildHelpMessage(Database db, int chatId) {
  final isAdminUser = isAdmin(db, chatId);
  final isSuper = isSuperAdmin(chatId);
  final b = StringBuffer();
  b.writeln('Доступные команды:');
  b.writeln('');
  b.writeln('/start — запуск бота и показ ');
  b.writeln('/menu — показать кнопки');
  b.writeln('/status — ваш статус на сегодня и текущий день');
  b.writeln('/subscribe — включить утренние напоминания (06:00)');
  b.writeln('/unsubscribe — выключить напоминания');
  b.writeln('');
  if (isAdminUser) {
    b.writeln('Команды для админов:');
    b.writeln('/report — отчёт за сегодня');
    b.writeln('/admins — список администраторов');
    b.writeln('/kick <chat_id|@username> — удалить пользователя из бота');
    b.writeln('');
  }
  if (isSuper) {
    b.writeln('Команды для супер-админа:');
    b.writeln('/admin_add <chat_id|@username> — выдать права админа');
    b.writeln('/admin_remove <chat_id|@username> — снять права админа');
    b.writeln('/reset — полный сброс бота (удалить всех пользователей и данные)');
    b.writeln('');
  }
  return b.toString();
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

Future<void> sendMessage(int chatId, String text, {Map<String, dynamic>? replyMarkup}) async {
  print('Отправляем сообщение в чат $chatId: "${text.substring(0, text.length > 50 ? 50 : text.length)}..."');
  final params = <String, String>{
    'chat_id': chatId.toString(),
    'text': text,
  };
  if (replyMarkup != null) {
    params['reply_markup'] = jsonEncode(replyMarkup);
  }
  final uri = Uri.parse('${apiUrl}sendMessage');
  int attempt = 0;
  while (true) {
    try {
      print('Попытка отправки #${attempt + 1}');
      final resp = await http.post(uri, body: params);
      if (resp.statusCode == 200) {
        print('Сообщение успешно отправлено');
        break;
      }
      if (resp.statusCode == 429) {
        int retryAfterSec = 1;
        try {
          final body = jsonDecode(resp.body);
          final paramsObj = body is Map ? body['parameters'] : null;
          if (paramsObj is Map && paramsObj['retry_after'] is int) {
            retryAfterSec = paramsObj['retry_after'] as int;
          }
        } catch (_) {}
        print('Rate limit, ждём $retryAfterSec секунд');
        await Future.delayed(Duration(seconds: retryAfterSec));
        attempt++;
        if (attempt < 3) {
          continue;
        }
      } else if (resp.statusCode >= 500 && resp.statusCode < 600) {
        print('Серверная ошибка ${resp.statusCode}, повторяем');
        await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
        attempt++;
        if (attempt < 3) {
          continue;
        }
      }
      print('Ошибка sendMessage ${resp.statusCode}: ${resp.body}');
      break;
    } catch (e) {
      print('Ошибка sendMessage: $e');
      await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      attempt++;
      if (attempt >= 3) {
        break;
      }
    }
  }
}

Map<String, dynamic> buildMainKeyboard() {
  return {
    'keyboard': [
      [
        {'text': 'читал'},
        {'text': 'молился'},
      ],
      [
        {'text': 'читал и молился'},
      ],
    ],
    'resize_keyboard': true,
    'one_time_keyboard': false,
  };
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
          await sendMessage(
            chatId,
            'Напоминание: доброе утро! Не забудьте сегодня прочитать Библию и помолиться. Отметьтесь кнопками ниже.',
            replyMarkup: buildMainKeyboard(),
          );
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