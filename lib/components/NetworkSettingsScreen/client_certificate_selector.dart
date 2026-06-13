import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';

class ClientCertificateSelector extends ConsumerStatefulWidget {
  const ClientCertificateSelector({super.key});

  @override
  ConsumerState<ClientCertificateSelector> createState() => _ClientCertificateSelector();
}

class _ClientCertificateSelector extends ConsumerState<ClientCertificateSelector> {
  Future<void> _importCertificate() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ["p12", "pfx"],
      withData: true,
    );

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    final fileName = file.name;

    if (bytes == null || bytes.isEmpty) {
      if (!context.mounted) return;
      GlobalSnackbar.message((_) => "Failed to read certificate file");
      return;
    }

    final password = await _promptForPassword();
    if (password == null || !context.mounted) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final certDir = Directory(path_helper.join(dir.path, "certificates"));
      if (!certDir.existsSync()) {
        certDir.createSync(recursive: true);
      }

      final user = GetIt.instance<FinampUserHelper>().currentUser;
      if (user == null) {
        GlobalSnackbar.message((_) => "No user logged in");
        return;
      }

      final destPath = path_helper.join(certDir.path, "${user.id}.p12");
      await File(destPath).writeAsBytes(bytes);

      user.update(
        newClientCertificatePath: destPath,
        newClientCertificatePassword: password,
        newClientCertificateName: fileName,
      );

      if (!context.mounted) return;
      GlobalSnackbar.message((_) => "Certificate imported");
    } catch (e) {
      if (!context.mounted) return;
      GlobalSnackbar.error(e);
    }
  }

  Future<String?> _promptForPassword() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Certificate Password"),
        content: TextField(
          controller: controller,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "Password",
            hintText: "Enter the .p12 file password",
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text("Import"),
          ),
        ],
      ),
    );
  }

  Future<void> _removeCertificate() async {
    final user = GetIt.instance<FinampUserHelper>().currentUser;
    if (user == null) return;

    final path = user.clientCertificatePath;
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    }

    user.update(
      newClientCertificatePath: null,
      newClientCertificatePassword: null,
      newClientCertificateName: null,
    );

    if (!context.mounted) return;
    GlobalSnackbar.message((_) => "Certificate removed");
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(FinampUserHelper.finampCurrentUserProvider).valueOrNull;
    final certName = user?.clientCertificateName;
    final hasCert = certName != null;

    return ListTile(
      leading: Icon(hasCert ? Icons.lock : Icons.lock_open),
      title: const Text("Client Certificate"),
      subtitle: Text(
        hasCert ? certName : "No client certificate configured",
        style: TextTheme.of(context).bodySmall,
      ),
      trailing: hasCert
          ? IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _removeCertificate,
              tooltip: "Remove certificate",
            )
          : null,
      onTap: hasCert ? null : _importCertificate,
    );
  }
}
