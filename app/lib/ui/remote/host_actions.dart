import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/hosts_state.dart';

enum HostAction {
  edit,
  delete;

  String label(L10n l10n) => switch (this) {
    edit => l10n.commonEdit,
    delete => l10n.commonDelete,
  };
}

Future<bool> runHostAction(BuildContext context, WidgetRef ref, PortalHostConfig host, HostAction action) async {
  if (!context.mounted) return false;
  final l10n = context.l10n;
  try {
    switch (action) {
      case HostAction.edit:
        final name = await showDialog<String>(
          context: context,
          builder: (_) => _HostNameDialog(name: host.name),
        );
        if (name != null && context.mounted) await ref.read(hostsProvider.notifier).rename(host.id, name);
        return false;
      case HostAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.portalDeleteHost),
            content: Text(l10n.portalDeleteHostConfirmation(host.name)),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(l10n.commonCancel)),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: TextButton.styleFrom(foregroundColor: Theme.of(dialogContext).colorScheme.error),
                child: Text(l10n.commonDelete),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return false;
        await ref.read(hostsProvider.notifier).remove(host.id);
        return true;
    }
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l10n.commonFailedTryAgain)));
    }
    return false;
  }
}

class _HostNameDialog extends StatefulWidget {
  const _HostNameDialog({required this.name});

  final String name;

  @override
  State<_HostNameDialog> createState() => _HostNameDialogState();
}

class _HostNameDialogState extends State<_HostNameDialog> {
  final _field = GlobalKey<FormFieldState<String>>();

  void _save() {
    final field = _field.currentState!;
    if (field.validate()) Navigator.of(context).pop(field.value!.trim());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.portalEditHost),
      content: TextFormField(
        key: _field,
        initialValue: widget.name,
        autofocus: true,
        decoration: InputDecoration(labelText: l10n.portalName),
        validator: (name) => (name ?? '').trim().isEmpty ? l10n.portalNameRequired : null,
        onFieldSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.commonCancel)),
        FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
      ],
    );
  }
}
