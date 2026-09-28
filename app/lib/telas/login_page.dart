import 'package:flutter/material.dart';
import '../servicos/app_controller.dart';

class LoginPage extends StatefulWidget {
  final AppController controller;
  const LoginPage({super.key, required this.controller});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController server;
  final senha = TextEditingController();
  bool ocultar = true;
  bool enviando = false;

  @override
  void initState() {
    super.initState();
    server = TextEditingController(text: widget.controller.api.baseUrl);
  }

  @override
  void dispose() {
    server.dispose();
    senha.dispose();
    super.dispose();
  }

  Future<void> entrar() async {
    if (enviando) return;
    if (server.text.trim().isEmpty || senha.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Informe o servidor e a senha.')));
      return;
    }
    setState(() => enviando = true);
    try {
      await widget.controller.login(server.text, senha.text);
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
                      controller: server,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Endereço do servidor',
                        hintText: 'http://192.168.0.10:8080',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
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
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: enviando
                          ? null
                          : () async {
                              await widget.controller.limparSessaoLocal();
                              if (!mounted) return;
                              server.text = widget.controller.api.baseUrl;
                              senha.clear();
                            },
                      icon: const Icon(Icons.refresh),
                      label: const Text('LIMPAR SESSÃO SALVA'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'No PC, use 127.0.0.1 se o backend estiver no mesmo computador. No celular, use o IP do PC ou a URL HTTPS do servidor.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.black54),
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
