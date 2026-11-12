import 'package:firebase_database/firebase_database.dart';

final _db = FirebaseDatabase.instance.ref();

/// Devuelve lista de años disponibles
Future<List<String>> obtenerAniosDisponibles() async {
  final snap = await _db.child('partidos').get();
  if (!snap.exists) return [];

  final map = Map<String, dynamic>.from(snap.value as Map);
  return map.keys.map((e) => e.toString()).toList();
}

/// Devuelve modalidades para un año
Future<List<String>> obtenerModalidades(String anio) async {
  final snap = await _db.child('partidos/$anio').get();
  if (!snap.exists) return [];

  final map = Map<String, dynamic>.from(snap.value as Map);
  return map.keys.map((e) => e.toString()).toList();
}

/// Devuelve jornadas/partidos
Future<List<Map>> obtenerPartidos(String anio, String modalidad) async {
  final snap = await _db.child('partidos/$anio/$modalidad').get();
  if (!snap.exists) return [];

  final map = Map<String, dynamic>.from(snap.value as Map);

  return map.values
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

/// Resultado de leer `jornada_activa` sin modificar ese nodo.
enum EstadoJornadaActiva { unica, ninguna, varias, error }

class JornadaActiva {
  final String id;
  final Map<String, dynamic> datos;

  const JornadaActiva({required this.id, required this.datos});
}

class ResultadoJornadaActiva {
  final EstadoJornadaActiva estado;
  final JornadaActiva? jornada;
  final List<String> ids;
  final String mensaje;

  const ResultadoJornadaActiva._({
    required this.estado,
    this.mensaje = '',
    this.jornada,
    this.ids = const [],
  });

  factory ResultadoJornadaActiva.unica(JornadaActiva jornada) {
    return ResultadoJornadaActiva._(
      estado: EstadoJornadaActiva.unica,
      jornada: jornada,
    );
  }

  factory ResultadoJornadaActiva.ninguna() {
    return const ResultadoJornadaActiva._(
      estado: EstadoJornadaActiva.ninguna,
      mensaje:
          'No hay una jornada activa. No se pueden registrar accesos.',
    );
  }

  factory ResultadoJornadaActiva.varias(List<String> ids) {
    return ResultadoJornadaActiva._(
      estado: EstadoJornadaActiva.varias,
      ids: ids,
      mensaje:
          'Hay varias jornadas activas (${ids.join(', ')}). '
          'No se registrarán accesos hasta que quede una sola.',
    );
  }

  factory ResultadoJornadaActiva.error() {
    return const ResultadoJornadaActiva._(
      estado: EstadoJornadaActiva.error,
      mensaje: 'No fue posible consultar la jornada.',
    );
  }
}

/// Lee `jornada_activa` y acepta solo el nodo cuyo campo `activo` es true.
/// No escribe en la base de datos.
ResultadoJornadaActiva interpretarJornadaActiva(Object value) {
  if (value is! Map) return ResultadoJornadaActiva.error();

  final data = Map<Object?, Object?>.from(value);
  final activas = <JornadaActiva>[];

  for (final entry in data.entries) {
    final nodo = entry.value;
    if (nodo is! Map) continue;

    final datos = Map<String, dynamic>.from(nodo);
    if (datos['activo'] != true) continue;

    activas.add(
      JornadaActiva(id: entry.key.toString(), datos: datos),
    );
  }

  if (activas.isEmpty) return ResultadoJornadaActiva.ninguna();
  if (activas.length > 1) {
    return ResultadoJornadaActiva.varias(
      activas.map((jornada) => jornada.id).toList(),
    );
  }
  return ResultadoJornadaActiva.unica(activas.first);
}

Future<ResultadoJornadaActiva> consultarJornadaActiva() async {
  try {
    final snap = await _db.child('jornada_activa').get();
    if (!snap.exists || snap.value == null) {
      return ResultadoJornadaActiva.ninguna();
    }
    return interpretarJornadaActiva(snap.value as Object);
  } catch (_) {
    return ResultadoJornadaActiva.error();
  }
}

/// Escucha cambios de la jornada activa. Solo lectura.
Stream<ResultadoJornadaActiva> observarJornadaActiva() {
  return _db.child('jornada_activa').onValue.map((event) {
    try {
      final value = event.snapshot.value;
      if (!event.snapshot.exists || value == null) {
        return ResultadoJornadaActiva.ninguna();
      }
      return interpretarJornadaActiva(value);
    } catch (_) {
      return ResultadoJornadaActiva.error();
    }
  });
}
