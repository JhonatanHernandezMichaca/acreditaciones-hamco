import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class OfflineDB {
  static const _dbName = 'acreditaciones.db';
  static const _dbVersion = 3;

  static const tablaAcreditaciones = 'acreditaciones_pdf';
  static const tablaUsosPendientes = 'usos_pendientes';
  static const tablaParking = 'parking_usos';
  static const tablaVisitasPasadasPendientes = 'visitas_pasadas_pendientes';

  static Database? _db;

static Future<void> resetDB() async {
  final path = join(await getDatabasesPath(), _dbName);
  await deleteDatabase(path);
  _db = null;
}

  // ===== PRECARGA DE VISITAS (ESTACIONAMIENTO OFFLINE) =====
static Future<void> guardarVisitasOffline(
    Map<String, dynamic> visitas) async {
  final db = await instance;
  final batch = db.batch();

  visitas.forEach((id, raw) {
    final data = Map<String, dynamic>.from(raw);

    batch.insert(
      tablaParking,
      {
        'id': id,
        'usado_local': 0,
        'carroModelo': data['carroModelo'],
        'placas': data['placas'],
        'color': data['color'],
        'nombre': data['nombre'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  });

  await batch.commit(noResult: true);
}


  static Future<Database> get instance async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), _dbName);

    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, v) async {
        
        // ===== ACREDITACIONES (NO TOCAR) =====
        await db.execute('''
          CREATE TABLE $tablaAcreditaciones(
            id TEXT PRIMARY KEY,
            nombre TEXT,
            apellidoPaterno TEXT,
            apellidoMaterno TEXT,
            funcion TEXT,
            medio TEXT,
            zona TEXT,
            equipo_local TEXT,
            equipo_visitante TEXT,
            fecha TEXT,
            hora TEXT,
            jornada INTEGER,
            nombreConcat TEXT,
            usado_local INTEGER DEFAULT 0,
            usadoEn_local INTEGER
          );
        ''');

        await db.execute('''
          CREATE TABLE $tablaUsosPendientes(
            id TEXT PRIMARY KEY,
            payload TEXT
          );
        ''');

        // ===== ESTACIONAMIENTO OFFLINE =====
        await db.execute('''
          CREATE TABLE $tablaParking(
            id TEXT PRIMARY KEY,
            usado_local INTEGER DEFAULT 0,
            usadoEn_local INTEGER,
            carroModelo TEXT,
            placas TEXT,
            color TEXT,
            nombre TEXT
          );
        ''');
        // ===== VISITAS PASADAS (PENDIENTES DE SYNC) =====
await db.execute('''
  CREATE TABLE $tablaVisitasPasadasPendientes(
    id TEXT PRIMARY KEY,
    payload TEXT,
    usadoEn_local INTEGER
  );
''');

      },
      onUpgrade: (db, oldVersion, newVersion) async {
  if (oldVersion < 3) {
    // Tabla nueva para visitas pasadas pendientes
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tablaVisitasPasadasPendientes(
        id TEXT PRIMARY KEY,
        payload TEXT,
        usadoEn_local INTEGER
      );
    ''');
  }
},

    );

    return _db!;
  }

  // =========================================================
  // =================== ESTACIONAMIENTO =====================
  // =========================================================

  static Future<bool> parkingYaUsado(String id) async {
    final db = await instance;
    final r = await db.query(
      tablaParking,
      columns: ['usado_local'],
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );

    if (r.isEmpty) return false;
    return (r.first['usado_local'] ?? 0) == 1;
  }

  static Future<void> marcarParkingUsado(
    String id, {
    Map<String, dynamic>? data,
    
  }) async {
    final db = await instance;
    final ts = DateTime.now().millisecondsSinceEpoch;

    await db.insert(
      tablaParking,
      {
        'id': id,
        'usado_local': 1,
        'usadoEn_local': ts,
        'carroModelo': data?['carroModelo'],
        'placas': data?['placas'],
        'color': data?['color'],
        'nombre': data?['nombre'],
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (data != null) {
  await guardarVisitaPasadaPendiente(id, {
    ...data,
    'estatus': 'usado',
    'origen': 'estacionamiento',
  });
}

  }

  static Future<Map<String, dynamic>?> getParkingLocal(String id) async {
    
    final db = await instance;
    final r = await db.query(
      tablaParking,
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );

    return r.isEmpty ? null : r.first;
  }

  static Future<Map<String, dynamic>?> buscarVisitaOffline(String id) async {
  final db = await instance;

  final r = await db.query(
    tablaParking,
    where: 'id=?',
    whereArgs: [id],
    limit: 1,
  );

  return r.isEmpty ? null : r.first;
}


  // =========================================================
  // =================== ACREDITACIONES ======================
  // ======= (SE DEJAN EXACTAMENTE IGUAL) ====================
  // =========================================================

  static Future<void> upsertAcreditaciones(Map<String, dynamic> map) async {
    final db = await instance;
    final batch = db.batch();

    map.forEach((id, raw) {
      final data = Map<String, dynamic>.from(raw);
      final partido = Map<String, dynamic>.from(data['partido']);

      final nombreConcat = (data['nombre'].toString() +
              data['apellidoPaterno'].toString() +
              data['apellidoMaterno'].toString())
          .replaceAll(' ', '')
          .toLowerCase();

      batch.insert(
        tablaAcreditaciones,
        {
          'id': id,
          'nombre': data['nombre'] ?? '',
          'apellidoPaterno': data['apellidoPaterno'] ?? '',
          'apellidoMaterno': data['apellidoMaterno'] ?? '',
          'funcion': data['funcion'] ?? '',
          'medio': data['medio'] ?? '',
          'zona': data['zona'] ?? '',
          'equipo_local': partido['equipo_local'] ?? '',
          'equipo_visitante': partido['equipo_visitante'] ?? '',
          'fecha': partido['fecha'] ?? '',
          'hora': partido['hora'] ?? '',
          'jornada': partido['jornada'] ?? 0,
          'nombreConcat': nombreConcat,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    await batch.commit(noResult: true);
  }

  static Future<void> marcarUsadoLocal(String id) async {
    final db = await instance;
    final ts = DateTime.now().millisecondsSinceEpoch;

    await db.update(
      tablaAcreditaciones,
      {'usado_local': 1, 'usadoEn_local': ts},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  static Future<bool> yaUsadoLocal(String id) async {
    final db = await instance;
    final r = await db.query(
      tablaAcreditaciones,
      columns: ['usado_local'],
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );

    if (r.isEmpty) return false;
    return (r.first['usado_local'] ?? 0) == 1;
  }
  static Future<void> guardarVisitaPasadaPendiente(
  String id,
  Map<String, dynamic> data,
) async {
  final db = await instance;
  final ts = DateTime.now().millisecondsSinceEpoch;

  await db.insert(
    tablaVisitasPasadasPendientes,
    {
      'id': id,
      'payload': jsonEncode(data),
      'usadoEn_local': ts,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}
static Future<List<Map<String, dynamic>>> obtenerVisitasPasadasPendientes() async {
  final db = await instance;

  final r = await db.query(tablaVisitasPasadasPendientes);

  return r.map((e) {
    return {
      'id': e['id'],
      'data': jsonDecode(e['payload'] as String),
      'usadoEn_local': e['usadoEn_local'],
    };
  }).toList();
}
static Future<void> eliminarVisitaPasadaPendiente(String id) async {
  final db = await instance;

  await db.delete(
    tablaVisitasPasadasPendientes,
    where: 'id=?',
    whereArgs: [id],
  );
}

}




