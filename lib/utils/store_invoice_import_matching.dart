class StoreInvoiceImportMatching {
  const StoreInvoiceImportMatching._();

  static bool hasDuplicateInvoice({
    required List<Map<String, dynamic>> existingInvoices,
    required String type,
    required String invoiceNumber,
    required String Function(String) normalize,
  }) {
    final key = normalize(invoiceNumber);
    if (key.isEmpty) return false;
    return existingInvoices.any(
      (invoice) =>
          invoice['type']?.toString() == type &&
          normalize(invoice['invoiceNumber']?.toString() ?? '') == key,
    );
  }

  static Map<String, dynamic>? resolveUnit({
    required List<Map<String, dynamic>> units,
    required String Function(String) normalize,
    String clientRef = '',
    String name = '',
  }) {
    final hasHint = clientRef.trim().isNotEmpty || name.trim().isNotEmpty;
    if (hasHint) {
      for (final unit in units) {
        if ((clientRef.trim().isNotEmpty &&
                unit['clientRef']?.toString() == clientRef) ||
            (name.trim().isNotEmpty &&
                (normalize(unit['name']?.toString() ?? '') == normalize(name) ||
                    normalize(unit['code']?.toString() ?? '') ==
                        normalize(name)))) {
          return unit;
        }
      }
      return null;
    }

    for (final unit in units) {
      if (unit['isBase'] == true) return unit;
    }
    return units.isEmpty ? null : units.first;
  }
}
