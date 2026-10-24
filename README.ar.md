[English](README.en.md) | [Français](README.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Italiano](README.it.md) | [Português](README.pt.md) | [Nederlands](README.nl.md) | [Русский](README.ru.md) | [中文](README.zh.md) | **العربية**

<div dir="rtl">

# ToutWAF Backup - الملفات التنفيذية (الفرع `toutwaf-backup`)

يحتوي هذا الفرع على **ملفات تنفيذية موقَّعة** فقط من ToutWAF Backup (خادم وعميل النسخ الاحتياطي في ملف تنفيذي واحد `toutwaf-backup`) ومثبّتاتها. لا توجد شيفرة مصدرية هنا. تتحدث المثبّتات وسطر الأوامر عشر لغات؛ وقد كُتبت الترجمات بواسطة آلة ولم يراجعها ناطقون أصليون.

## الإصدار المتاح

| الإصدار | القناة | البناء | تاريخ النشر |
|---|---|---|---|
| `0.1.1` | dev | `0270440dc7e0` | 2026-10-24 |

## التثبيت

ضع **العميل** على كل جهاز تريد حمايته؛ ويجب أن يعمل **الخادم** على **جهاز مختلف** عن ToutWAF (النسخة المخزَّنة على الجهاز الذي تحميه لا تنجو من فقدانه: يرفض المثبّت دور الخادم بجوار ToutWAF).

```sh
# Linux: client
curl -fsSL https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup/install.sh | sudo bash -s -- --role client
# Linux: server (on a dedicated machine)
curl -fsSL https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup/install.sh | sudo bash -s -- --role server --datastore main=/srv/backups/main --start
```

```powershell
# Windows: client (read the script before running it)
irm https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup/install.ps1 -OutFile install.ps1
.\install.ps1 -Role client
```

مرآة إذا تعذّر الوصول إلى المضيف الأول: `https://raw.githubusercontent.com/qu3ntin01/toutwaf/toutwaf-backup` (اختر بـ `--base-url` أو `TOUTWAF_BACKUP_BASE_URL`).

لغة المثبّت: `--lang fr` (أو `--es` و`--de` ...؛ وعلى Windows `-Lang fr`)، وإلا فلغة نظامك في طرفية UTF-8.

## التحقق من إصدار

يسرد `releases/<الإصدار>/SHA256SUMS` قيم SHA-256 للأرشيفات؛ و`SHA256SUMS.sig` هو توقيع Ed25519 (base64) لذلك الملف. المفتاح العام هو `release.pub` (نفسه لمنتج ToutWAF: `ebd2a20ce5a5650f`). تتحقق المثبّتات من التوقيع ثم من التجزئة قبل تثبيت أي شيء.

```sh
V=0.1.1
cd releases/$V
base64 -d SHA256SUMS.sig > sig.bin
( printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; base64 -d ../../release.pub ) > pub.der
openssl pkeyutl -verify -pubin -inkey pub.der -keyform DER -rawin -in SHA256SUMS -sigfile sig.bin
sha256sum -c SHA256SUMS
```

## المحتويات

`install.sh` و`install.ps1` و`channel.json` (مؤشر «أحدث إصدار») و`release.pub` و`CHANGELOG.md` و`LICENSE` و`releases/<الإصدار>/`.

</div>
