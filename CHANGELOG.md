# Changelog · تاریخچه تغییرات

**EN** — Each script in this pool keeps its own changelog section below. When a script changes, bump its `VERSION` (following [Semantic Versioning](https://semver.org): MAJOR breaking · MINOR feature · PATCH fix) and add an entry at the top of that script's section — newest first.

<div dir="rtl">

**فا** — هر اسکریپت این مجموعه بخش تاریخچه مخصوص به خودش را دارد. با هر تغییر، مقدار `VERSION` داخل اسکریپت را طبق [نسخه‌بندی معنایی](https://semver.org) بالا ببرید (MAJOR تغییر ناسازگار · MINOR قابلیت جدید · PATCH رفع اشکال) و یک مورد جدید در بالای بخش همان اسکریپت اضافه کنید — جدیدترین بالا.

</div>

| Script · اسکریپت | Current · نسخه فعلی |
|---|---|
| [pro-plugin-manager.sh](pro-plugin-manager.sh) | 1.5.0 |
| [plugin-hunter.sh](plugin-hunter.sh) | 1.4.0 |
| [wp-core.sh](wp-core.sh) | 1.2.0 |
| [perm-patrol.sh](perm-patrol.sh) | 1.1.1 |
| [fix-roundcube.sh](fix-roundcube.sh) | 1.0.1 |
| [thing-to-link.sh](thing-to-link.sh) | 1.0.1 |

---

## pro-plugin-manager.sh

### 1.5.0 — 2026-07-12
**EN**
- Added Elementor Manager and updated the menu display.

<div dir="rtl">

**فا**
- افزودن مدیریت المنتور (Elementor Manager) و به‌روزرسانی نمایش منو.

</div>

### 1.4.0 — 2026-07-01
**EN**
- Added generic plugin management: install, update, repair, and rollback.
- Added optional activation prompt after managing a plugin.
- Removed the beta label from the Search & Replace menu option.

<div dir="rtl">

**فا**
- افزودن مدیریت عمومی افزونه‌ها: نصب، به‌روزرسانی، تعمیر و بازگردانی (rollback).
- افزودن پرسش اختیاری برای فعال‌سازی افزونه پس از مدیریت آن.
- حذف برچسب بتا از گزینه جستجو و جایگزینی در منو.

</div>

### 1.3.1 — 2026-06-29
**EN**
- Fixed formatting of the beta label on the Search & Replace menu option.

<div dir="rtl">

**فا**
- رفع اشکال قالب‌بندی برچسب بتا در گزینه جستجو و جایگزینی.

</div>

### 1.3.0 — 2026-06-28
**EN**
- Refactored Search & Replace: streamlined the MySQL fallback and removed the wp-cli dependency.
- Marked the Search & Replace menu option as beta.

<div dir="rtl">

**فا**
- بازنویسی جستجو و جایگزینی: ساده‌سازی مسیر جایگزین MySQL و حذف وابستگی به wp-cli.
- علامت‌گذاری گزینه جستجو و جایگزینی به‌عنوان بتا.

</div>

### 1.2.1 — 2026-06-28
**EN**
- Standardized the script header with website and contact info, and added a header printing function.

<div dir="rtl">

**فا**
- یکسان‌سازی هدر اسکریپت با اطلاعات وب‌سایت و تماس، و افزودن تابع چاپ هدر.

</div>

### 1.2.0 — 2026-06-28
**EN**
- Added database credential parsing from `wp-config.php` and a database Search & Replace feature.

<div dir="rtl">

**فا**
- افزودن خواندن اطلاعات اتصال دیتابیس از `wp-config.php` و قابلیت جستجو و جایگزینی در دیتابیس.

</div>

### 1.1.0 — 2026-06-28
**EN**
- Refactored the script structure, added feature stubs, and improved webroot resolution.

<div dir="rtl">

**فا**
- بازسازی ساختار اسکریپت، افزودن اسکلت قابلیت‌های آینده و بهبود تشخیص مسیر webroot.

</div>

### 1.0.0 — 2026-06-28
**EN**
- Initial release: menu-driven WordPress plugin operations.

<div dir="rtl">

**فا**
- انتشار اولیه: عملیات منو‌محور روی افزونه‌های وردپرس.

</div>

---

## plugin-hunter.sh

### 1.4.0 — 2026-07-12
**EN**
- Enhanced the site health check to verify full page rendering and detect critical errors.

<div dir="rtl">

**فا**
- بهبود بررسی سلامت سایت برای اطمینان از رندر کامل صفحه و تشخیص خطاهای بحرانی.

</div>

### 1.3.0 — 2026-07-07
**EN**
- Resolve the webroot from a domain name.

<div dir="rtl">

**فا**
- تشخیص مسیر webroot از روی نام دامنه.

</div>

### 1.2.1 — 2026-07-07
**EN**
- Fixed the automated check and the manual domain prompt.

<div dir="rtl">

**فا**
- رفع اشکال بررسی خودکار و پرسش دستی دامنه.

</div>

### 1.2.0 — 2026-06-30
**EN**
- Added a binary search strategy for faster fault isolation.

<div dir="rtl">

**فا**
- افزودن استراتژی جستجوی دودویی برای یافتن سریع‌تر افزونه خراب.

</div>

### 1.1.0 — 2026-06-30
**EN**
- Added a cancel option and enabled Phase 2.

<div dir="rtl">

**فا**
- افزودن گزینه لغو و فعال‌سازی فاز ۲.

</div>

### 1.0.1 — 2026-06-28
**EN**
- Standardized the script header with website and contact info, and added a header printing function.

<div dir="rtl">

**فا**
- یکسان‌سازی هدر اسکریپت با اطلاعات وب‌سایت و تماس، و افزودن تابع چاپ هدر.

</div>

### 1.0.0 — 2026-06-28
**EN**
- Initial release: scan a WordPress install for plugins and log results.

<div dir="rtl">

**فا**
- انتشار اولیه: پویش افزونه‌های یک نصب وردپرس و ثبت نتایج در لاگ.

</div>

---

## wp-core.sh

### 1.2.0 — 2026-07-12
**EN**
- Added new helper functions and improved the header descriptions.

<div dir="rtl">

**فا**
- افزودن توابع کمکی جدید و بهبود توضیحات هدر.

</div>

### 1.1.0 — 2026-06-30
**EN**
- Added a core rollback option and display of the current WordPress version in the menu.

<div dir="rtl">

**فا**
- افزودن گزینه بازگردانی هسته (rollback) و نمایش نسخه فعلی وردپرس در منو.

</div>

### 1.0.1 — 2026-06-28
**EN**
- Standardized the script header with website and contact info, and added a header printing function.

<div dir="rtl">

**فا**
- یکسان‌سازی هدر اسکریپت با اطلاعات وب‌سایت و تماس، و افزودن تابع چاپ هدر.

</div>

### 1.0.0 — 2026-06-28
**EN**
- Initial release: repair, update, or install WordPress core, or provision a fresh site.

<div dir="rtl">

**فا**
- انتشار اولیه: تعمیر، به‌روزرسانی یا نصب هسته وردپرس و راه‌اندازی سایت جدید.

</div>

---

## perm-patrol.sh

### 1.1.1 — 2026-07-12
**EN**
- Renamed from `fix-permissions.sh` to `perm-patrol.sh`.

<div dir="rtl">

**فا**
- تغییر نام از `fix-permissions.sh` به `perm-patrol.sh`.

</div>

### 1.1.0 — 2026-07-12
**EN**
- Added detailed descriptions and new features.

<div dir="rtl">

**فا**
- افزودن توضیحات کامل‌تر و قابلیت‌های جدید.

</div>

### 1.0.0 — 2026-07-12
**EN**
- Initial release (as `fix-permissions.sh`): reset ownership, fix file modes, and harden sensitive files in a panel user's home.

<div dir="rtl">

**فا**
- انتشار اولیه (با نام `fix-permissions.sh`): بازنشانی مالکیت، اصلاح دسترسی فایل‌ها و ایمن‌سازی فایل‌های حساس در هوم کاربر پنل.

</div>

---

## fix-roundcube.sh

### 1.0.1 — 2026-06-28
**EN**
- Standardized the script header with website and contact info, and added a header printing function.

<div dir="rtl">

**فا**
- یکسان‌سازی هدر اسکریپت با اطلاعات وب‌سایت و تماس، و افزودن تابع چاپ هدر.

</div>

### 1.0.0 — 2026-06-28
**EN**
- Initial release: repair and reconfigure Roundcube webmail.

<div dir="rtl">

**فا**
- انتشار اولیه: تعمیر و پیکربندی مجدد وب‌میل Roundcube.

</div>

---

## thing-to-link.sh

### 1.0.1 — 2026-06-28
**EN**
- Standardized the script header with website and contact info, and added a header printing function.

<div dir="rtl">

**فا**
- یکسان‌سازی هدر اسکریپت با اطلاعات وب‌سایت و تماس، و افزودن تابع چاپ هدر.

</div>

### 1.0.0 — 2026-06-28
**EN**
- Initial release: fetch a file or URL into the web root and make it accessible via link.

<div dir="rtl">

**فا**
- انتشار اولیه: دریافت فایل یا URL در ریشه وب و در دسترس قرار دادن آن از طریق لینک.

</div>
