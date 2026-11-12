import 'package:flutter/material.dart';
import 'package:estacionamiento_qr/services/torneo_service.dart';
import 'package:estacionamiento_qr/screens/escanner_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _consultando = false;
  String? _mensaje;

  Future<void> _entrar(ScannerModo modo) async {
    if (_consultando) return;

    setState(() {
      _consultando = true;
      _mensaje = null;
    });

    final resultado = await consultarJornadaActiva();
    if (!mounted) return;

    if (resultado.estado != EstadoJornadaActiva.unica ||
        resultado.jornada == null) {
      setState(() {
        _consultando = false;
        _mensaje = resultado.mensaje;
      });
      return;
    }

    final jornada = resultado.jornada!;
    setState(() => _consultando = false);

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ScannerScreen(
          modo: modo,
          partido: Map<String, dynamic>.from(jornada.datos),
          jornadaId: jornada.id,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F7D84),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),
            Image.network(
              'https://r2.thesportsdb.com/images/media/team/badge/g5bhfy1721108205.png',
              height: 130,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const Text(
                        'Selecciona el tipo de control',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _botonModo(
                              modo: ScannerModo.estacionamiento,
                              icono: Icons.local_parking,
                              texto: 'Estacionamiento',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _botonModo(
                              modo: ScannerModo.acreditacion,
                              icono: Icons.badge,
                              texto: 'Acreditaciones',
                            ),
                          ),
                        ],
                      ),
                      if (_consultando) ...[
                        const SizedBox(height: 28),
                        const CircularProgressIndicator(color: Colors.white),
                      ],
                      if (_mensaje != null) ...[
                        const SizedBox(height: 28),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            _mensaje!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _botonModo({
    required ScannerModo modo,
    required IconData icono,
    required String texto,
  }) {
    return OutlinedButton.icon(
      onPressed: _consultando ? null : () => _entrar(modo),
      icon: Icon(icono, color: Colors.black),
      label: Text(
        texto,
        style: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
      ),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        side: const BorderSide(color: Colors.black),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
      ),
    );
  }
}
