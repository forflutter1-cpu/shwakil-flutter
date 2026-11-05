# Shwakil - Flutter App

نظام بطاقات الدفع المسبق - تطبيق Flutter متعدد المنصات (Windows / macOS / Linux / Android / iOS / Web)

## متطلبات التشغيل

- Flutter SDK 3.x+
- Dart 3.x+
- Backend: Laravel (راجع `../backend/`)

## تشغيل التطبيق

```powershell
cd flutter
flutter pub get
```

### Android / iOS
```powershell
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000/api --dart-define=API_CLIENT_KEY=your-key
```

### Web (Chrome)
```powershell
flutter run -d chrome --dart-define=API_BASE_URL=http://127.0.0.1:8000/api --dart-define=API_CLIENT_KEY=your-key
```

### Desktop (Windows)
```powershell
flutter run -d windows --dart-define=API_BASE_URL=http://127.0.0.1:8000/api --dart-define=API_CLIENT_KEY=your-key
```

To build a distributable Windows release:
```powershell
flutter build windows --release --dart-define=API_BASE_URL=https://shwakil.alkmal.com/api --dart-define=API_CLIENT_KEY=your-key
```

Copy the complete `build/windows/x64/runner/Release/` directory when sharing the app; it includes the executable and required runtime files. Windows desktop uses the persistent navigation sidebar on wide windows. Camera scanning, NFC, Bluetooth thermal printing, and native push notifications remain available only on platforms that provide those device services.

## هيكل المشروع

```
lib/
├── main.dart              # نقطة الدخول
├── screens/               # 50 شاشة
├── services/              # 26+ service للتواصل مع API
├── widgets/               # مكونات UI مشتركة
├── models/                # نماذج البيانات
├── utils/                 # أدوات مساعدة والثيم
└── localization/          # دعم تعدد اللغات
```

## الشاشات الرئيسية

- **المصادقة**: تسجيل دخول، تسجيل، OTP، نسيت كلمة المرور
- **البطاقات**: إنشاء بطاقة، مسح بطاقة، طلبات طباعة، مخزون
- **المحفظة**: رصيد، تحويل سريع، طلبات شحن/سحب
- **الأدمن**: لوحة تحكم كاملة لإدارة النظام
