import 'package:flutter/material.dart';
import '../servicos/app_controller.dart';

class LoginPage extends StatefulWidget {
  final AppController controller;
  const LoginPage({super.key, required this.controller});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final senha = TextEditingController();
  bool ocultar = true;
  bool enviando = false;

  @override
  void dispose() {
    senha.dispose();
    super.dispose();
  }

  Future<void> entrar() async {
    if (enviando) return;
    if (senha.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Informe a senha.')));
      return;
    }
    setState(() => enviando = true);
    try {
      await widget.controller.login(senha.text);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                widget.controller.erroGlobal ?? 'Não foi possível entrar.')),
      );
    } finally {
      if (mounted) setState(() => enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    Image.asset('assets/logo.png', height: 120),
                    const SizedBox(height: 18),
                    Text('Ao Ponto Bot',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text('Painel de pedidos e atendimento',
                        style: TextStyle(color: Colors.black54)),
                    const SizedBox(height: 26),
                    if (widget.controller.erroGlobal != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          widget.controller.erroGlobal!,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: senha,
                      obscureText: ocultar,
                      onSubmitted: (_) => entrar(),
                      decoration: InputDecoration(
                        labelText: 'Senha administrativa',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => ocultar = !ocultar),
                          icon: Icon(ocultar
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: enviando ? null : entrar,
                        icon: enviando
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.login),
                        label: const Text('ENTRAR'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
