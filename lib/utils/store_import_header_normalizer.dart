class StoreImportHeaderNormalizer {
  const StoreImportHeaderNormalizer._();

  static String normalize(String raw) => raw
      .replaceAll('\uFEFF', '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ی', 'ي')
      .replaceAll('ک', 'ك')
      .replaceAll('ة', 'ه')
      .replaceAll(RegExp(r'[\s\-/]+'), '_')
      .replaceAll(RegExp(r'[^\w\u0600-\u06FF]'), '');

  static bool matchesAny(String normalizedValue, Iterable<String> aliases) =>
      aliases.any((alias) => normalize(alias) == normalizedValue);
}
