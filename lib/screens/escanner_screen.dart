import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'offline_db.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:estacionamiento_qr/services/torneo_service.dart';

enum ScannerModo {
  estacionamiento,
  acreditacion,
}

class ScannerScreen extends StatefulWidget {
  final ScannerModo modo;
  final Map partido;
  final String jornadaId;

  const ScannerScreen({
    super.key,
    required this.modo,
    required this.partido,
    required this.jornadaId,
  });


  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}


class _ScannerScreenState extends State<ScannerScreen> {
  Map<String, dynamic>? datosPersona;
  String? nombreEmpresa;
  String? nombreFuncion;
  String? nombreArea;
  Map<String, dynamic>? jornadaActiva;
  String? equipoLocal;
  String? equipoVisitante;
  String? logoLocalUrl;
  String? logoVisitanteUrl;

  bool escaneando = false;
  bool procesando = false;
  bool qrInvalido = false;
  bool yaUsado = false;
  bool isOnline = true;

  String? qrResult;
  String? motivoRechazo;
  
  final TextEditingController _pulseraCtrl = TextEditingController();
  bool pulseraAsignada = false;

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  StreamSubscription<ResultadoJornadaActiva>? _jornadaSub;
  String? _jornadaId;
  bool _registroPermitido = true;
  String? _mensajeBloqueo;

  // ===== HID =====
  final TextEditingController _hidCtrl = TextEditingController();
  final FocusNode _hidFocus = FocusNode();
  Timer? _hidIdle;
  static const _hidIdleMs = 150;


@override
void initState() {
  super.initState();
  _initOffline();
  _jornadaId = widget.jornadaId;
  jornadaActiva = Map<String, dynamic>.from(widget.partido);
  equipoLocal = jornadaActiva?['equipo_local']?.toString();
  equipoVisitante = jornadaActiva?['equipo_visitante']?.toString();
  _cargarLogosEquipos();
  _jornadaSub = observarJornadaActiva().listen(
    _aplicarJornada,
    onError: (_) => _aplicarJornada(ResultadoJornadaActiva.error()),
  );

  Connectivity().checkConnectivity().then((results) {
    setState(() => isOnline = !results.contains(ConnectivityResult.none));
  });

  WidgetsBinding.instance.addPostFrameCallback((_) {
    iniciarEscaneo();
  });

  _connSub =
      Connectivity().onConnectivityChanged.listen((results) async {
    final online = !results.contains(ConnectivityResult.none);
    setState(() => isOnline = online);

    if (online) {
      await _syncVisitasPendientes();
    }
  });
}

Future<void> _initOffline() async {
  try {
    // 1️⃣ Borrar base vieja

    // 2️⃣ Descargar TODAS las visitas
    final ref = FirebaseDatabase.instance.ref('visitas');
    final snap = await ref.get();

    if (!snap.exists) return;

    final visitas = Map<String, dynamic>.from(snap.value as Map);

    // 3️⃣ Guardar local
    await OfflineDB.guardarVisitasOffline(visitas);
  } catch (e) {
    // No rompe la app
  }
}


  @override
  void dispose() {
    _jornadaSub?.cancel();
    _connSub?.cancel();
    _hidIdle?.cancel();
    _hidCtrl.dispose();
    _hidFocus.dispose();
    super.dispose();
  }

final Map<String, String> logosEquipos = {
  'america': 'america.png',
  'atlas': 'atlas.png',
  'chivas': 'chivas.png',
  'cruzazul': 'cruzazul.png',
  'juarez': 'juarez.png',
  'leon': 'leon.png',
  'mazatlan': 'mazatlan.png',
  'monterrey': 'monterrey.png',
  'necaxa': 'necaxa.png',
  'pachuca': 'pachuca.png',
  'puebla': 'puebla.png',
  'pumas': 'pumas.png',
  'queretaro': 'queretaro.png',
  'santos': 'santos.png',
  'tigres': 'tigres.png',
  'toluca': 'toluca.png',
  'tijuana': 'tijuana.png',
};



  // ================= ESCANEO =================

 void iniciarEscaneo() {
  setState(() {
    escaneando = false;
    qrResult = null;
    qrInvalido = false;
    yaUsado = false;
    procesando = false;
    _hidCtrl.clear();
  });

  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _hidFocus.requestFocus();
  });
}


  Future<void> _buscarOnline({required String qrTexto}) async {
    final uid = qrTexto.trim();
    final ref = FirebaseDatabase.instance.ref('visitas/$uid');

    try {
      setState(() {
        procesando = true;
        datosPersona = null;
        qrInvalido = false;
        yaUsado = false;
        motivoRechazo = null;
      });

      // ¿Ya usado local?
      if (await OfflineDB.yaUsadoLocal(uid)) {
        setState(() {
          qrInvalido = true;
          yaUsado = true;
          motivoRechazo = 'Este acceso ya fue utilizado';
          procesando = false;
        });
        return;
      }

      final snap = await ref.get();
      if (!snap.exists) {
        setState(() {
          qrInvalido = true;
          procesando = false;
        });
        return;
      }

      final data = Map<String, dynamic>.from(snap.value as Map);

// ⛔️ YA USADO EN FIREBASE
if (data['estatus'] == 'usado') {
  setState(() {
    qrInvalido = true;
    yaUsado = true;
    motivoRechazo = 'Este acceso ya fue utilizado';
    procesando = false;
  });
  return;
}

      if (!await _puedeRegistrar()) return;

      // Marcar uso LOCAL
await OfflineDB.marcarParkingUsado(uid, data: data);


      setState(() {
        datosPersona = data;
        qrInvalido = false;
        yaUsado = false;
        procesando = false;
      });
    } catch (e) {
      setState(() {
        qrInvalido = true;
        procesando = false;
      });
    }
  }

  Future<void> _buscarOffline({required String qrTexto}) async {
  if (!await _puedeRegistrar()) return;

  final uid = qrTexto.trim();

  // ¿Ya fue usado offline?
  if (await OfflineDB.parkingYaUsado(uid)) {
    setState(() {
      qrInvalido = true;
      yaUsado = true;
      motivoRechazo = 'Este acceso ya fue utilizado';
      procesando = false;
    });
    return;
  }

  // 🔎 BUSCAR VISITA GUARDADA
  final visita = await OfflineDB.buscarVisitaOffline(uid);

  if (visita == null) {
    setState(() {
      qrInvalido = true;
      motivoRechazo = 'QR no encontrado';
      procesando = false;
    });
    return;
  }

  if (!await _puedeRegistrar()) return;

  // Marcar como usado local
  await OfflineDB.marcarParkingUsado(uid, data: visita);

  setState(() {
    datosPersona = visita;
    qrInvalido = false;
    yaUsado = false;
    procesando = false;
  });
}


void _avisar(String mensaje) {
  if (!mounted || mensaje.isEmpty) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(mensaje)),
  );
}

void _aplicarJornada(ResultadoJornadaActiva resultado) {
  if (!mounted) return;

  if (resultado.estado == EstadoJornadaActiva.unica &&
      resultado.jornada != null) {
    final jornada = resultado.jornada!;
    final cambio = _jornadaId != null && _jornadaId != jornada.id;
    final estabaBloqueado = !_registroPermitido;
    final local = jornada.datos['equipo_local']?.toString();
    final visitante = jornada.datos['equipo_visitante']?.toString();
    final cambiaronEquipos =
        local != equipoLocal || visitante != equipoVisitante;

    setState(() {
      _registroPermitido = true;
      _mensajeBloqueo = null;
      _jornadaId = jornada.id;
      jornadaActiva = Map<String, dynamic>.from(jornada.datos);
      equipoLocal = local;
      equipoVisitante = visitante;
      if (cambiaronEquipos) {
        logoLocalUrl = null;
        logoVisitanteUrl = null;
      }
      if (cambio) {
        escaneando = false;
        procesando = false;
        datosPersona = null;
        qrResult = null;
        qrInvalido = false;
        yaUsado = false;
        motivoRechazo = null;
        pulseraAsignada = false;
        _pulseraCtrl.clear();
        _hidCtrl.clear();
      }
    });

    if (cambiaronEquipos || logoLocalUrl == null) {
      _cargarLogosEquipos();
    }
    if (cambio) {
      _avisar(
        'La jornada activa cambió. Los siguientes accesos corresponden a la jornada actual.',
      );
    } else if (estabaBloqueado) {
      _avisar('Jornada activa lista. Ya puedes escanear.');
    }
    if (cambio || estabaBloqueado) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _hidFocus.requestFocus();
      });
    }
    return;
  }

  setState(() {
    _registroPermitido = false;
    _mensajeBloqueo = resultado.mensaje;
    _jornadaId = null;
    escaneando = false;
    procesando = false;
    datosPersona = null;
    qrResult = null;
    qrInvalido = false;
    yaUsado = false;
    motivoRechazo = null;
    _hidCtrl.clear();
  });
}

/// Confirma, justo antes de registrar, que sigue habiendo una sola jornada
/// y que es la misma que está en pantalla. No escribe en `jornada_activa`.
Future<bool> _puedeRegistrar() async {
  final idEsperado = _jornadaId;
  if (!_registroPermitido || idEsperado == null) {
    if (mounted) {
      setState(() {
        procesando = false;
        escaneando = false;
      });
    }
    return false;
  }

  final actual = await consultarJornadaActiva();
  if (!mounted) return false;

  if (actual.estado == EstadoJornadaActiva.error) {
    _avisar(actual.mensaje);
    setState(() {
      procesando = false;
      escaneando = false;
      qrResult = null;
      datosPersona = null;
      qrInvalido = false;
      yaUsado = false;
    });
    return false;
  }

  final sigue = actual.estado == EstadoJornadaActiva.unica &&
      actual.jornada?.id == idEsperado;
  if (!sigue) {
    _aplicarJornada(actual);
    return false;
  }
  return _registroPermitido && _jornadaId == idEsperado;
}

   
   Future<String?> _obtenerNombreEmpresa(String empresaId) async {
  final snap = await FirebaseFirestore.instance
      .collection('empresas')
      .doc(empresaId)
      .get();

  if (!snap.exists) return null;
  return snap.data()!['nombre'];
}

Future<String?> _obtenerNombreArea(String areaId) async {
  final snap = await FirebaseFirestore.instance
      .collection('areas')
      .doc(areaId)
      .get();

  if (!snap.exists) return null;
  return snap.data()!['nombre'];
}

Future<String?> _obtenerNombreFuncion(String funcionId) async {
  final snap = await FirebaseFirestore.instance
      .collection('funciones')
      .doc(funcionId)
      .get();

  if (!snap.exists) return null;
  return snap.data()!['nombre'];
}

  Future<void> _buscarAcreditacion({required String qrTexto}) async {
  if (!await _puedeRegistrar()) return;

  final id = qrTexto.trim();

  try {
    setState(() {
      procesando = true;
      datosPersona = null;
      qrInvalido = false;
      yaUsado = false;
      motivoRechazo = null;
    });

    final ref =
    FirebaseFirestore.instance.collection('usersAccess').doc(id);


    final snap = await ref.get();

    if (!snap.exists) {
      setState(() {
        qrInvalido = true;
        motivoRechazo = 'QR no encontrado';
        procesando = false;
      });
      return;
    }

    final data = snap.data()!;

  // Resolver empresa y función
nombreEmpresa = null;
nombreFuncion = null;
nombreArea = null;

if (data['areaId'] != null) {
  nombreArea = await _obtenerNombreArea(data['areaId']);
}

if (data['empresaId'] != null) {
  nombreEmpresa = await _obtenerNombreEmpresa(data['empresaId']);
}

if (data['funcion'] != null) {
  nombreFuncion = await _obtenerNombreFuncion(data['funcion']);
}


 // ❌ Acceso rechazado
if (data['estatus'] == 'rechazado') {
  setState(() {
    qrInvalido = true;
    motivoRechazo = 'Acceso no aprobado';
    procesando = false;
  });
  return;
}
// 🟡 Ya canjeado (pulsera asignada)
if (data['estatus'] == 'canjeado') {
  setState(() {
    datosPersona = data;
    pulseraAsignada = true;
    yaUsado = true;
    procesando = false;
  });
  return;
}



 pulseraAsignada = data['codigoPulsera'] != null &&
    data['codigoPulsera'] != 'SIN_PULSERA_ASIGNADA';


    setState(() {
      datosPersona = data;
      procesando = false;
    });
  } catch (e) {
    setState(() {
      qrInvalido = true;
      motivoRechazo = 'Error al validar acreditación';
      procesando = false;
    });
  }
}

Future<void> _asignarPulsera() async {
  final codigo = _pulseraCtrl.text.trim();

  if (codigo.isEmpty) return;
  if (!await _puedeRegistrar()) return;

  try {
    setState(() => procesando = true);
    if (!await _puedeRegistrar()) return;

    final ref = FirebaseFirestore.instance
        .collection('usersAccess')
        .doc(qrResult);

    await ref.update({
      'codigoPulsera': codigo,
      'estatus': 'canjeado',
      'canjeadoAt': FieldValue.serverTimestamp(),
    });

    setState(() {
      datosPersona!['codigoPulsera'] = codigo;
      datosPersona!['estatus'] = 'canjeado';
      pulseraAsignada = true;
      procesando = false;
    });
  } catch (e) {
    setState(() => procesando = false);
  }
}
String normalizarEquipo(String equipo) {
  return equipo
      .toLowerCase()
      .replaceAll(RegExp(r'[áàäâ]'), 'a')
      .replaceAll(RegExp(r'[éèëê]'), 'e')
      .replaceAll(RegExp(r'[íìïî]'), 'i')
      .replaceAll(RegExp(r'[óòöô]'), 'o')
      .replaceAll(RegExp(r'[úùüû]'), 'u')
      .replaceAll(RegExp(r'[^a-z]'), '');
}

String? archivoEscudo(String equipo) {
  final key = normalizarEquipo(equipo);

  // Match exacto
  if (logosEquipos.containsKey(key)) {
    return logosEquipos[key];
  }

  return null;
}

Future<void> _cargarLogosEquipos() async {
  if (equipoLocal == null || equipoVisitante == null) return;

  final logoLocalFile = archivoEscudo(equipoLocal!);
  final logoVisitanteFile = archivoEscudo(equipoVisitante!);

  if (logoLocalFile == null || logoVisitanteFile == null) return;

  try {
    final storage = FirebaseStorage.instance;

    final localUrl = await storage.ref().child(logoLocalFile).getDownloadURL();
    final visitanteUrl = await storage.ref().child(logoVisitanteFile).getDownloadURL();

    if (!mounted) return;

    setState(() {
      logoLocalUrl = localUrl;
      logoVisitanteUrl = visitanteUrl;
    });
  } catch (e) {
    // Si falla, no rompemos la pantalla
  }
}

Widget _vistaEquipos() {
  if (logoLocalUrl == null || logoVisitanteUrl == null) {
    return const SizedBox.shrink();
  }

  return Column(
    children: [
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.network(
            logoLocalUrl!,
            height: 108,
            width: 108,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const SizedBox(width: 68, height: 68),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'VS',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Image.network(
            logoVisitanteUrl!,
            height: 108,
            width: 108,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const SizedBox(width: 68, height: 68),
          ),
        ],
      ),
    ],
  );
}

  void detenerEscaneo() {
    setState(() {
      escaneando = false;
      qrResult = null;
      qrInvalido = false;
      yaUsado = false;
      procesando = false;
      _pulseraCtrl.clear();
      pulseraAsignada = false;
      nombreEmpresa = null;
     nombreFuncion = null;
     nombreArea = null;

    });
    _hidIdle?.cancel();
    _hidCtrl.clear();
  }

  void _onHidChanged(String s) {
    _hidIdle?.cancel();
    _hidIdle = Timer(const Duration(milliseconds: _hidIdleMs), () async {
      final valor = s.replaceAll(RegExp(r'\s+'), '').trim();
      if (valor.isEmpty || escaneando || !_registroPermitido) return;

      setState(() {
  escaneando = true;
  qrResult = valor;
  procesando = true;
});


      if (widget.modo == ScannerModo.estacionamiento) {
  await (isOnline
      ? _buscarOnline(qrTexto: valor)
      : _buscarOffline(qrTexto: valor));
} else {
  await _buscarAcreditacion(qrTexto: valor);
}

    });
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
  if (escaneando) {
    detenerEscaneo();
    return false;
  }
  return true;
},

 child: Scaffold(
  backgroundColor: const Color.fromARGB(255, 24, 205, 172),
  body: Stack(
    children: [
    // CONTENIDO NORMAL
escaneando ? _vistaResultado() : _vistaEscaneoInvisible(),

      // BOTÓN DE REGRESAR
      Positioned(
        top: 12,
        left: 12,
        child: SafeArea(
          child: IconButton(
            icon: const Icon(
              Icons.arrow_back,
              color: Colors.white,
              size: 28,
            ),
           onPressed: () {
  if (escaneando) {
    detenerEscaneo();
  } else {
    Navigator.pop(context);
  }
},

          ),
        ),
      ),
    ],
  ),
),

    );
  }

  Widget _vistaInicial() {
    return RawKeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKey: (event) {
        if (event is RawKeyDownEvent &&
            event.logicalKey.keyLabel.toLowerCase() == 'enter') {
          iniciarEscaneo();
        }
      },
      child: const Center(
        child: Text(
          'ESCANEAR',
          style: TextStyle(fontSize: 25, color: Colors.white),
        ),
      ),
    );
  }

String _etiquetaJornada() {
  final numero = jornadaActiva?['jornada'];
  final titulo = numero != null ? 'Jornada $numero' : (_jornadaId ?? '');
  final local = equipoLocal ?? '';
  final visitante = equipoVisitante ?? '';
  if (local.isEmpty || visitante.isEmpty) return titulo;
  if (titulo.isEmpty) return '$local vs $visitante';
  return '$titulo · $local vs $visitante';
}

Widget _vistaEscaneoInvisible() {
  if (!_registroPermitido) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          _mensajeBloqueo ??
              'No hay una jornada activa. No se pueden registrar accesos.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  return GestureDetector(
    onTap: () => _hidFocus.requestFocus(),
    behavior: HitTestBehavior.opaque,
    child: Stack(
      children: [
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _vistaEquipos(),
              const SizedBox(height: 22),
              Text(
                _etiquetaJornada(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'ESCANEAR',
                style: TextStyle(
                  fontSize: 25,
                  color: Colors.white,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        Opacity(
          opacity: 0,
          child: TextField(
            controller: _hidCtrl,
            focusNode: _hidFocus,
            autofocus: true,
            keyboardType: TextInputType.none,
            onChanged: _onHidChanged,
          ),
        ),
      ],
    ),
  );
}


Widget _vistaResultado() {
  return SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Center(
        child: procesando
            ? const CircularProgressIndicator()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    qrInvalido || yaUsado
                        ? Icons.cancel
                        : Icons.check_circle,
                    color: qrInvalido || yaUsado
                        ? Colors.red
                        : Colors.green,
                    size: 60,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    qrInvalido
                        ? 'QR NO VÁLIDO'
                        : yaUsado
                            ? 'ACCESO YA UTILIZADO'
                            : 'ACCESO PERMITIDO',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (!qrInvalido && !yaUsado) _vistaEquipos(),

                  const SizedBox(height: 20),

     if (datosPersona != null) ...[
  if (widget.modo == ScannerModo.estacionamiento) ...[
    // ================= ESTACIONAMIENTO =================

    Text(
      datosPersona!['nombre'] ?? '—',
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      textAlign: TextAlign.center,
    ),
    const SizedBox(height: 10),

    Text(
      'Modelo: ${datosPersona!['carroModelo'] ?? '—'}',
      style: const TextStyle(fontSize: 20, color: Colors.white),
    ),
    const SizedBox(height: 6),

    Text(
      'Placas: ${datosPersona!['placas'] ?? '—'}',
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    ),
    const SizedBox(height: 6),

    Text(
      'Color: ${datosPersona!['color'] ?? '—'}',
      style: const TextStyle(fontSize: 18, color: Colors.white),
    ),
  ] else ...[
    // ================= ACREDITACIÓN =================

    Text(
      '${datosPersona!['nombre'] ?? ''} ${datosPersona!['apellidoPaterno'] ?? ''} ${datosPersona!['apellidoMaterno'] ?? ''}',
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      textAlign: TextAlign.center,
    ),

    const SizedBox(height: 8),

    Text(
      'Área: ${nombreArea ?? '—'}',
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    const SizedBox(height: 6),

    Text(
      'Empresa: ${nombreEmpresa ?? '—'}',
      style: const TextStyle(fontSize: 18, color: Colors.white),
    ),
    Text(
      'Función: ${nombreFuncion ?? '—'}',
      style: const TextStyle(fontSize: 18, color: Colors.white),
    ),

    const SizedBox(height: 20),

    if (!pulseraAsignada) ...[
      SizedBox(
        width: 240,
        child: TextField(
          controller: _pulseraCtrl,
          decoration: const InputDecoration(
            labelText: 'Código de pulsera',
            filled: true,
            fillColor: Colors.white,
          ),
        ),
      ),
      const SizedBox(height: 12),
      ElevatedButton(
        onPressed: procesando ? null : _asignarPulsera,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(
              horizontal: 24, vertical: 12),
        ),
        child: const Text(
          'Asignar pulsera',
          style: TextStyle(color: Colors.white),
        ),
      ),
    ] else ...[
      Text(
        'Pulsera asignada: ${datosPersona!['codigoPulsera']}',
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.green,
          fontSize: 18,
        ),
      ),
    ],
  ],
],


                  const SizedBox(height: 24),

                  ElevatedButton(
                    onPressed: detenerEscaneo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 32, vertical: 14),
                    ),
                    child: const Text(
                      'Volver a escanear',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
      ),
    ),
  );
}
Future<void> _syncVisitasPendientes() async {
  if (!isOnline) return;

  final pendientes =
      await OfflineDB.obtenerVisitasPasadasPendientes();

  if (pendientes.isEmpty) return;

  for (final p in pendientes) {
    final uid = p['id'];
    final data = Map<String, dynamic>.from(p['data']);

    try {
      // 1️⃣ Marcar visita como usada
      await FirebaseDatabase.instance
          .ref('visitas/$uid')
          .update({'estatus': 'usado'});

      // 2️⃣ Crear visita pasada
      await FirebaseDatabase.instance
          .ref('visitas_pasadas/$uid')
          .set({
        ...data,
        'estatus': 'usado',
        'usadoAt': ServerValue.timestamp,
        'offline': true,
      });

      // 3️⃣ Limpiar local
      await OfflineDB.eliminarVisitaPasadaPendiente(uid);
    } catch (e) {
      // Si falla, se reintentará luego
    }
  }
}

}

