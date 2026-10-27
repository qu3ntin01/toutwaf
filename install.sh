#!/usr/bin/env bash
# ToutWAF installer for Linux x86_64 or arm64 with systemd: Red Hat family (Alma, Rocky, RHEL, CentOS Stream, Oracle, Fedora), Amazon Linux 2023, Debian family
# (Debian 11+, Ubuntu 20.04+, Mint, ...; arm64 with a 64-bit OS, e.g. Raspberry Pi OS 64-bit, emulation-tested only), SUSE (Leap 15.6+/16, Tumbleweed, SLES), Arch family. Full list + status: docs/install/platforms.md
# (generated from deploy/platforms.json). The system is checked BEFORE anything is changed: --check-compat, --skip-os-check.
#
#   curl -fsSL https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/main/install.sh | sudo bash
#       -> interactive menu (reads the keyboard from /dev/tty, so it works when piped)
#   curl -fsSL <url> | sudo bash -s -- --install --yes --public-host example.com
#       -> unattended "direct" install (see --help for every option)
#
# What it does (idempotent: re-run to upgrade, existing configuration is never overwritten):
#   * installs toutwaf-dp (data plane) and/or toutwaf-cp + toutwafctl (control plane) from a signed release
#     verifying SHA-256 and the Ed25519 signature (built-in trust anchor)
#   * creates the unprivileged `toutwaf` system user and one installation home, /var/toutwaf by default (bin/ conf/ data/ logs/; --home DIR);
#     an installation made before this layout keeps /etc/toutwaf, /var/lib/toutwaf, /var/log/toutwaf and is never moved
#   * installs hardened systemd units (NoNewPrivileges, ProtectSystem=strict, seccomp SystemCallFilter, ...)
#   * grants CAP_NET_BIND_SERVICE (ambient + setcap) so ports 80/443 work without root
#   * opens the firewall by default when firewalld or ufw is active (80/443 + console port; --console-from, --no-firewall), labels files for SELinux, installs logrotate + sysctl tuning
#   * prepares the panel (`toutwaf-cp bootstrap`) and prints the panel links, the one-time setup link and the ports to open
#   * upgrades with automatic rollback when the new version fails its health check
#
# A node reached through a WireGuard tunnel to the main ToutWAF is NOT installed with this script by hand: the console (VPN > Add a WAF node) serves
# a node installer (node-install.sh / node-install.ps1) that sets the tunnel up, then runs THIS script with `--component dp --cp-url <control plane in
# the tunnel> --enroll-token <one-time token> --no-firewall` (it opens the ports itself, according to the traffic mode). See docs/vpn/noeuds-waf.md.
set -Eeuo pipefail
IFS=$'\n\t'
umask 022      # files we create must not inherit a permissive/odd caller umask (secrets are chmod-ed explicitly)

INSTALLER_VERSION="2"
REPO="${TOUTWAF_REPO:-qu3ntin01/toutwaf}"                  # public binaries-only repository (see deploy/RELEASE-LAYOUT.md)
DEFAULT_CHANNEL="dev"                                   # the copy of this script published on the dev branch has: DEFAULT_CHANNEL="dev"
VERSION="${TOUTWAF_VERSION:-latest}"
COMPONENT="${TOUTWAF_COMPONENT:-all}"          # dp | cp | all
# Layout: one installation HOME (default /var/toutwaf) holding bin/ conf/ data/ logs/. An existing installation keeps its own paths
# (the legacy /usr/local/bin + /etc/toutwaf + /var/lib/toutwaf + /var/log/toutwaf, or any HOME chosen earlier): see resolve_layout.
HOME_DIR="${TOUTWAF_HOME:-}"; HOME_EXPLICIT=0; [ -z "$HOME_DIR" ] || HOME_EXPLICIT=1
BIN_EXPLICIT=0; [ -z "${TOUTWAF_BIN_DIR:-}" ] || BIN_EXPLICIT=1
LAYOUT=""; LAYOUT_NOTE=""                       # home | existing
BIN_DIR="${TOUTWAF_BIN_DIR:-/usr/local/bin}"
CONF_DIR="/etc/toutwaf"
DATA_DIR="/var/lib/toutwaf"
LOG_DIR="/var/log/toutwaf"
SVC_USER="toutwaf"
DESTDIR="${DESTDIR:-}"                          # staging root (packaging / tests): no system changes at all
BASE_URL="${TOUTWAF_BASE_URL:-}"                # mirror, default: the project's own GitLab, GitHub as a fallback
# Where releases are read: the project's own GitLab first (public project, raw files), the GitHub copy of the same signed channel when it is unreachable.
# Release archives stay verified by the signature key of this installer, whichever source served them. TOUTWAF_REPO (another GitHub repository) disables both.
SRC_PRIMARY="${TOUTWAF_SRC_PRIMARY:-https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw}"; SRC_FALLBACK="https://raw.githubusercontent.com/$REPO"; SRC_ROOT=""
if [ -n "${TOUTWAF_REPO:-}" ]; then SRC_PRIMARY="$SRC_FALLBACK"; SRC_FALLBACK=""; fi
CP_BIN="${TOUTWAF_CP_BIN:-}"                    # override of the toutwaf-cp used for `bootstrap` (tests)
TARBALL=""                                      # local tarball instead of download
CP_URL=""; NODE_TOKEN=""; ENROLL_TOKEN=""; NODE_GROUP=""; CP_CA=""
CLOUD_URL=""; CLOUD_PINS=""; CLOUD_CA=""; CLOUD_ENROL_TOKEN=""   # ToutWAF Cloud: the node connects OUTBOUND to the hosted control plane (toutwaf-cloudlink)
CLOUDLINK_PORT=9544
CP_PORT=9443; HTTP_PORT=80; HTTPS_PORT=443; PUBLIC_HOST=""; CHANNEL="${TOUTWAF_CHANNEL:-}"
OPEN_FW=""                                      # "" = default: open what is needed when firewalld / ufw is active; 1 = same, explicit; 0 = never touch the firewall
CONSOLE_FROM=""                                 # restrict the console port to this address / CIDR ("" = reachable from anywhere)
# The firewall MODULE (ToutWAF manages this machine's nftables rules) is NOT the system-firewall option above (OPEN_FW opens the ports ToutWAF needs
# in firewalld / ufw). "" = not decided (asked in the interactive mode, default NO); 1 = switch the module on at the end of the installation
# (no rule is applied: every change goes through the trial with automatic rollback in the console); 0 = explicitly not.
FW_MODULE=""; case "${TOUTWAF_WITH_FIREWALL:-}" in 1|yes|true|on) FW_MODULE=1;; 0|no|false|off) FW_MODULE=0;; esac
# The ToutWAF Backup client (the program that backs this machine up to a ToutWAF Backup server, see docs/backup/toutwaf-backup.md): installed only on request,
# from the release channel of that product, after the Ed25519 signature of its SHA256SUMS and the SHA-256 of the archive have been verified. The public
# key is the release key of the publisher (the one the products of this repository are signed with), built in as the default; another key can be given with
# --backup-client-pubkey, TOUTWAF_BACKUP_PUBKEY or $CONF_DIR/backup-release.pub. The client comes from the `toutwaf-backup` branch of the public repository.
BACKUP_CLIENT=""; case "${TOUTWAF_WITH_BACKUP_CLIENT:-}" in 1|yes|true|on) BACKUP_CLIENT=1;; esac
BACKUP_CLIENT_BASE="${TOUTWAF_BACKUP_BASE_URL:-https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw/toutwaf-backup}"
BACKUP_CLIENT_PUBKEY="${TOUTWAF_BACKUP_PUBKEY:-V7tJBQsSrIsDTGIqlFhJZ8q4t/Fc8iNvg/cKkfRDATA=}"; BACKUP_CLIENT_VERSION=""; BACKUP_CLIENT_RESULT=""
# Telemetry to the publisher space is ON by default and can be switched off in one click in the console ("zero telemetry"). --no-telemetry or
# TOUTWAF_TELEMETRY=0 installs with zero telemetry from the first start (written to the control-plane configuration; the console shows it).
NO_TELEMETRY=0; case "$(printf '%s' "${TOUTWAF_TELEMETRY:-}" | tr 'A-Z' 'a-z')" in 0|false|off|no|none|zero) NO_TELEMETRY=1;; esac
# The database (--db): empty = ask in the interactive mode; SQLite (unchanged behaviour) otherwise. See the db-setup block.
DB_ENGINE="${TOUTWAF_DB:-}"; DB_DSN="${TOUTWAF_DB_DSN:-}"; DB_DSN_FILE="${TOUTWAF_DB_DSN_FILE:-}"; DB_LOCAL=""; case "${TOUTWAF_DB_INSTALL_LOCAL:-}" in 1|yes|true|on) DB_LOCAL=1;; esac
DB_HOST=""; DB_PORT=""; DB_NAME="toutwaf"; DB_USER="toutwaf"; DB_PASSWORD_FILE="${TOUTWAF_DB_PASSWORD_FILE:-}"; DB_TLS_MODE=""; DB_CA=""
DB_ADMIN_DSN_FILE=""; DB_BACKUP_TIMER=1; DB_SERVER_LOCAL=0; DB_RESULT=""; DB_SECRET_WRITTEN=0; DB_ASKED=0; DB_SCHEMA_LINE=""; DB_BACKUP_SCHEDULED=0
OPEN_CP_PORT=0; NO_SELINUX=0; NO_SYSCTL=0; NO_START=0; NO_ENABLE=0; FORCE=0; DRY_RUN=0; ASSUME_YES=0
QUIET=0; NO_COLOR_FLAG=0; ACCEPT_DEFAULTS=0
CHECK_COMPAT=0                                  # --check-compat: print the compatibility verdict, change nothing (exit 0 compatible, 3 not)
# The extras of a release (deploy/RELEASE-LAYOUT.md, "Extras"): the host agent for Windows and the antivirus programs, a second asset next to the archive of the platform.
# --no-extras (or TOUTWAF_NO_EXTRAS=1) leaves them out; --extras FILE (repeatable, or TOUTWAF_EXTRAS=FILE:FILE) installs them from local files (offline).
NO_EXTRAS=0; case "${TOUTWAF_NO_EXTRAS:-}" in 1|yes|true|on) NO_EXTRAS=1;; esac
EXTRAS_LOCAL="${TOUTWAF_EXTRAS:-}"; EXTRAS_DIR=""; EXTRAS_RESULT=""; EXTRAS_COUNT=0; EXTRAS_VERSION=""; EXTRAS_BUILD=""; SIG_OK_FOR=""
ACTION=""; PURGE=0; LANG_CODE="${TOUTWAF_LANG:-}"; NARGS=$#

# ------------------------------------------------------------------------------------------------ message catalog
# 10 languages (en fr es de it pt nl ru zh ar). Generated: edit deploy/tools/gen-installer-i18n.py, not these lines.
read_catalog() { cat <<'TW_CATALOG'
# BEGIN CATALOG (generated by tools/gen-installer-i18n.py)
en|tagline|Web application & API protection
fr|tagline|Protection des applications web et des API
es|tagline|Protección de aplicaciones web y API
de|tagline|Schutz für Webanwendungen und APIs
it|tagline|Protezione di applicazioni web e API
pt|tagline|Proteção de aplicações web e APIs
nl|tagline|Bescherming van webapplicaties en API's
ru|tagline|Защита веб-приложений и API
zh|tagline|Web 应用与 API 防护
ar|tagline|حماية تطبيقات الويب وواجهات API
en|menu_title|What would you like to do?
fr|menu_title|Que souhaitez-vous faire ?
es|menu_title|¿Qué desea hacer?
de|menu_title|Was möchten Sie tun?
it|menu_title|Cosa vuoi fare?
pt|menu_title|O que deseja fazer?
nl|menu_title|Wat wilt u doen?
ru|menu_title|Что вы хотите сделать?
zh|menu_title|请选择要执行的操作
ar|menu_title|ماذا تريد أن تفعل؟
en|opt_install|Install (control plane + data plane + console)
fr|opt_install|Installer (plan de contrôle + plan de données + console)
es|opt_install|Instalar (plano de control + plano de datos + consola)
de|opt_install|Installieren (Control Plane + Data Plane + Konsole)
it|opt_install|Installa (control plane + data plane + console)
pt|opt_install|Instalar (plano de controlo + plano de dados + consola)
nl|opt_install|Installeren (control plane + data plane + console)
ru|opt_install|Установить (control plane + data plane + консоль)
zh|opt_install|安装（控制平面 + 数据平面 + 控制台）
ar|opt_install|تثبيت (مستوى التحكم + مستوى البيانات + لوحة التحكم)
en|opt_install_d|Everything on this machine: web console, policy store and reverse proxy / WAF.
fr|opt_install_d|Tout sur cette machine : console web, base de politiques et reverse proxy / WAF.
es|opt_install_d|Todo en esta máquina: consola web, almacén de políticas y proxy inverso / WAF.
de|opt_install_d|Alles auf diesem Rechner: Web-Konsole, Richtlinienspeicher und Reverse-Proxy / WAF.
it|opt_install_d|Tutto su questa macchina: console web, archivio delle policy e reverse proxy / WAF.
pt|opt_install_d|Tudo nesta máquina: consola web, repositório de políticas e proxy reverso / WAF.
nl|opt_install_d|Alles op deze machine: webconsole, beleidsopslag en reverse proxy / WAF.
ru|opt_install_d|Всё на этой машине: веб-консоль, хранилище политик и reverse proxy / WAF.
zh|opt_install_d|在本机安装全部组件：Web 控制台、策略库和反向代理 / WAF。
ar|opt_install_d|كل شيء على هذا الجهاز: لوحة الويب ومخزن السياسات والوكيل العكسي / WAF.
en|opt_cp|Install the control plane only
fr|opt_cp|Installer le plan de contrôle seul
es|opt_cp|Instalar solo el plano de control
de|opt_cp|Nur die Control Plane installieren
it|opt_cp|Installa solo il control plane
pt|opt_cp|Instalar apenas o plano de controlo
nl|opt_cp|Alleen de control plane installeren
ru|opt_cp|Установить только control plane
zh|opt_cp|仅安装控制平面
ar|opt_cp|تثبيت مستوى التحكم فقط
en|opt_cp_d|Web console, API and policy store. Data planes (nodes) join it later.
fr|opt_cp_d|Console web, API et base de politiques. Les plans de données (nœuds) la rejoignent ensuite.
es|opt_cp_d|Consola web, API y almacén de políticas. Los planos de datos (nodos) se unen después.
de|opt_cp_d|Web-Konsole, API und Richtlinienspeicher. Data Planes (Knoten) treten später bei.
it|opt_cp_d|Console web, API e archivio delle policy. I data plane (nodi) si uniscono dopo.
pt|opt_cp_d|Console web, API e repositório de políticas. Os planos de dados (nós) aderem depois.
nl|opt_cp_d|Webconsole, API en beleidsopslag. Data planes (nodes) sluiten later aan.
ru|opt_cp_d|Веб-консоль, API и хранилище политик. Data plane (узлы) подключаются позже.
zh|opt_cp_d|Web 控制台、API 与策略库。数据平面（节点）稍后加入。
ar|opt_cp_d|لوحة الويب وواجهة API ومخزن السياسات. تنضم مستويات البيانات (العقد) لاحقا.
en|opt_dp|Install a data plane only
fr|opt_dp|Installer un plan de données seul
es|opt_dp|Instalar solo un plano de datos
de|opt_dp|Nur eine Data Plane installieren
it|opt_dp|Installa solo un data plane
pt|opt_dp|Instalar apenas um plano de dados
nl|opt_dp|Alleen een data plane installeren
ru|opt_dp|Установить только data plane
zh|opt_dp|仅安装数据平面
ar|opt_dp|تثبيت مستوى بيانات فقط
en|opt_dp_d|Reverse proxy / WAF node that joins an existing control plane (asks for its URL and an enrolment token).
fr|opt_dp_d|Nœud reverse proxy / WAF qui rejoint un plan de contrôle existant (demande son URL et un jeton d'enrôlement).
es|opt_dp_d|Nodo de proxy inverso / WAF que se une a un plano de control existente (pide su URL y un token de alta).
de|opt_dp_d|Reverse-Proxy- / WAF-Knoten, der einer bestehenden Control Plane beitritt (fragt URL und Registrierungstoken ab).
it|opt_dp_d|Nodo reverse proxy / WAF che si unisce a un control plane esistente (chiede URL e token di registrazione).
pt|opt_dp_d|Nó de proxy reverso / WAF que se junta a um plano de controlo existente (pede a URL e um token de inscrição).
nl|opt_dp_d|Reverse-proxy- / WAF-node die zich bij een bestaande control plane voegt (vraagt om URL en inschrijftoken).
ru|opt_dp_d|Узел reverse proxy / WAF, подключаемый к существующему control plane (запросит URL и токен регистрации).
zh|opt_dp_d|加入现有控制平面的反向代理 / WAF 节点（需要其 URL 和注册令牌）。
ar|opt_dp_d|عقدة وكيل عكسي / WAF تنضم إلى مستوى تحكم قائم (تطلب عنوانه ورمز التسجيل).
en|opt_update|Update
fr|opt_update|Mettre à jour
es|opt_update|Actualizar
de|opt_update|Aktualisieren
it|opt_update|Aggiorna
pt|opt_update|Atualizar
nl|opt_update|Bijwerken
ru|opt_update|Обновить
zh|opt_update|更新
ar|opt_update|تحديث
en|opt_update_d|Download a newer release, verify it (SHA-256 / sigstore), back up, keep configuration and data, roll back on failure.
fr|opt_update_d|Télécharge une version plus récente, la vérifie (SHA-256 / sigstore), sauvegarde, conserve configuration et données, annule en cas d'échec.
es|opt_update_d|Descarga una versión más reciente, la verifica (SHA-256 / sigstore), hace copia, conserva configuración y datos y revierte si falla.
de|opt_update_d|Lädt eine neuere Version, prüft sie (SHA-256 / sigstore), sichert, behält Konfiguration und Daten und macht bei Fehlern rückgängig.
it|opt_update_d|Scarica una versione più recente, la verifica (SHA-256 / sigstore), esegue il backup, conserva configurazione e dati, ripristina in caso di errore.
pt|opt_update_d|Transfere uma versão mais recente, verifica-a (SHA-256 / sigstore), faz uma cópia de segurança, mantém configuração e dados e reverte em caso de falha.
nl|opt_update_d|Downloadt een nieuwere versie, controleert (SHA-256 / sigstore), maakt een back-up, behoudt configuratie en data en draait terug bij mislukking.
ru|opt_update_d|Скачивает новую версию, проверяет (SHA-256 / sigstore), делает резервную копию, сохраняет настройки и данные, при сбое откатывает.
zh|opt_update_d|下载新版本，校验（SHA-256 / sigstore），先备份，保留配置和数据，失败时回滚。
ar|opt_update_d|ينزل إصدارا أحدث ويتحقق منه (SHA-256 / sigstore) وينشئ نسخة احتياطية ويحتفظ بالإعدادات والبيانات ويتراجع عند الفشل.
en|opt_uninstall|Uninstall
fr|opt_uninstall|Désinstaller
es|opt_uninstall|Desinstalar
de|opt_uninstall|Deinstallieren
it|opt_uninstall|Disinstalla
pt|opt_uninstall|Desinstalar
nl|opt_uninstall|Verwijderen
ru|opt_uninstall|Удалить
zh|opt_uninstall|卸载
ar|opt_uninstall|إزالة التثبيت
en|opt_uninstall_d|Remove ToutWAF; you choose whether to keep or delete configuration, data and logs.
fr|opt_uninstall_d|Supprime ToutWAF ; vous choisissez de conserver ou de supprimer configuration, données et journaux.
es|opt_uninstall_d|Elimina ToutWAF; usted elige conservar o borrar configuración, datos y registros.
de|opt_uninstall_d|Entfernt ToutWAF; Sie wählen, ob Konfiguration, Daten und Logs behalten oder gelöscht werden.
it|opt_uninstall_d|Rimuove ToutWAF; scegli se mantenere o eliminare configurazione, dati e log.
pt|opt_uninstall_d|Remove o ToutWAF; escolhe se mantém ou apaga a configuração, os dados e os logs.
nl|opt_uninstall_d|Verwijdert ToutWAF; u kiest of configuratie, data en logs bewaard of gewist worden.
ru|opt_uninstall_d|Удаляет ToutWAF; вы выбираете, сохранить или удалить настройки, данные и журналы.
zh|opt_uninstall_d|移除 ToutWAF；可选择保留或删除配置、数据和日志。
ar|opt_uninstall_d|يزيل ToutWAF؛ تختار الاحتفاظ بالإعدادات والبيانات والسجلات أو حذفها.
en|opt_status|Status and health check
fr|opt_status|État et vérification de santé
es|opt_status|Estado y comprobación de salud
de|opt_status|Status und Gesundheitsprüfung
it|opt_status|Stato e controllo di integrità
pt|opt_status|Estado e verificação de integridade
nl|opt_status|Status en gezondheidscontrole
ru|opt_status|Состояние и проверка работоспособности
zh|opt_status|状态与健康检查
ar|opt_status|الحالة وفحص السلامة
en|opt_status_d|Installed versions, services, listening ports and health endpoints.
fr|opt_status_d|Versions installées, services, ports en écoute et points de santé.
es|opt_status_d|Versiones instaladas, servicios, puertos en escucha y endpoints de salud.
de|opt_status_d|Installierte Versionen, Dienste, lauschende Ports und Health-Endpunkte.
it|opt_status_d|Versioni installate, servizi, porte in ascolto ed endpoint di salute.
pt|opt_status_d|Versões instaladas, serviços, portas em escuta e endpoints de saúde.
nl|opt_status_d|Geïnstalleerde versies, services, luisterpoorten en health-endpoints.
ru|opt_status_d|Установленные версии, службы, слушающие порты и health-эндпоинты.
zh|opt_status_d|已安装版本、服务、监听端口和健康检查端点。
ar|opt_status_d|الإصدارات المثبتة والخدمات والمنافذ المفتوحة ونقاط فحص السلامة.
en|opt_links|Show the panel links again
fr|opt_links|Afficher à nouveau les liens du panneau
es|opt_links|Mostrar de nuevo los enlaces del panel
de|opt_links|Panel-Links erneut anzeigen
it|opt_links|Mostra di nuovo i link del pannello
pt|opt_links|Mostrar novamente as ligações do painel
nl|opt_links|Paneellinks opnieuw tonen
ru|opt_links|Показать ссылки на панель ещё раз
zh|opt_links|再次显示面板链接
ar|opt_links|عرض روابط اللوحة مرة أخرى
en|opt_links_d|Panel URLs, one-time setup link and the firewall ports to open.
fr|opt_links_d|URL du panneau, lien d'installation à usage unique et ports à ouvrir dans le pare-feu.
es|opt_links_d|URL del panel, enlace de configuración de un solo uso y puertos a abrir en el cortafuegos.
de|opt_links_d|Panel-URLs, einmaliger Einrichtungslink und die in der Firewall zu öffnenden Ports.
it|opt_links_d|URL del pannello, link di configurazione monouso e porte da aprire nel firewall.
pt|opt_links_d|URLs do painel, ligação de configuração de utilização única e portas a abrir na firewall.
nl|opt_links_d|Paneel-URL's, eenmalige installatielink en de in de firewall te openen poorten.
ru|opt_links_d|Адреса панели, одноразовая ссылка настройки и порты для открытия в брандмауэре.
zh|opt_links_d|面板地址、一次性设置链接以及需要在防火墙放行的端口。
ar|opt_links_d|عناوين اللوحة ورابط الإعداد لمرة واحدة والمنافذ المطلوب فتحها في جدار الحماية.
en|opt_quit|Quit
fr|opt_quit|Quitter
es|opt_quit|Salir
de|opt_quit|Beenden
it|opt_quit|Esci
pt|opt_quit|Sair
nl|opt_quit|Afsluiten
ru|opt_quit|Выйти
zh|opt_quit|退出
ar|opt_quit|خروج
en|choice|Your choice
fr|choice|Votre choix
es|choice|Su elección
de|choice|Ihre Wahl
it|choice|La tua scelta
pt|choice|A sua escolha
nl|choice|Uw keuze
ru|choice|Ваш выбор
zh|choice|您的选择
ar|choice|اختيارك
en|invalid_choice|Invalid choice.
fr|invalid_choice|Choix invalide.
es|invalid_choice|Elección no válida.
de|invalid_choice|Ungültige Auswahl.
it|invalid_choice|Scelta non valida.
pt|invalid_choice|Escolha inválida.
nl|invalid_choice|Ongeldige keuze.
ru|invalid_choice|Неверный выбор.
zh|invalid_choice|无效的选择。
ar|invalid_choice|اختيار غير صالح.
en|state_installed|Installed: %s
fr|state_installed|Installé : %s
es|state_installed|Instalado: %s
de|state_installed|Installiert: %s
it|state_installed|Installato: %s
pt|state_installed|Instalado: %s
nl|state_installed|Geïnstalleerd: %s
ru|state_installed|Установлено: %s
zh|state_installed|已安装：%s
ar|state_installed|المثبت: %s
en|state_none|ToutWAF is not installed on this machine.
fr|state_none|ToutWAF n'est pas installé sur cette machine.
es|state_none|ToutWAF no está instalado en esta máquina.
de|state_none|ToutWAF ist auf diesem Rechner nicht installiert.
it|state_none|ToutWAF non è installato su questa macchina.
pt|state_none|O ToutWAF não está instalado nesta máquina.
nl|state_none|ToutWAF is niet geïnstalleerd op deze machine.
ru|state_none|ToutWAF не установлен на этой машине.
zh|state_none|本机尚未安装 ToutWAF。
ar|state_none|ToutWAF غير مثبت على هذا الجهاز.
en|cfg_title|Installation options (Enter = default)
fr|cfg_title|Options d'installation (Entrée = valeur par défaut)
es|cfg_title|Opciones de instalación (Intro = valor por defecto)
de|cfg_title|Installationsoptionen (Eingabe = Standard)
it|cfg_title|Opzioni di installazione (Invio = predefinito)
pt|cfg_title|Opções de instalação (Enter = padrão)
nl|cfg_title|Installatie-opties (Enter = standaard)
ru|cfg_title|Параметры установки (Enter = по умолчанию)
zh|cfg_title|安装选项（回车 = 默认值）
ar|cfg_title|خيارات التثبيت (Enter = الافتراضي)
en|q_cp_url|Control plane URL (e.g. https://cp.example.com:9444)
fr|q_cp_url|URL du plan de contrôle (ex. https://cp.example.com:9444)
es|q_cp_url|URL del plano de control (p. ej. https://cp.example.com:9444)
de|q_cp_url|URL der Control Plane (z. B. https://cp.example.com:9444)
it|q_cp_url|URL del control plane (es. https://cp.example.com:9444)
pt|q_cp_url|URL do plano de controlo (ex. https://cp.example.com:9444)
nl|q_cp_url|URL van de control plane (bv. https://cp.example.com:9444)
ru|q_cp_url|URL control plane (напр. https://cp.example.com:9444)
zh|q_cp_url|控制平面 URL（例如 https://cp.example.com:9444）
ar|q_cp_url|عنوان مستوى التحكم (مثال https://cp.example.com:9444)
en|q_token|Enrolment token (console: Nodes > Add node)
fr|q_token|Jeton d'enrôlement (console : Nœuds > Ajouter un nœud)
es|q_token|Token de alta (consola: Nodos > Agregar nodo)
de|q_token|Registrierungstoken (Konsole: Knoten > Knoten hinzufügen)
it|q_token|Token di registrazione (console: Nodi > Aggiungi nodo)
pt|q_token|Token de inscrição (consola: Nós > Adicionar nó)
nl|q_token|Inschrijftoken (console: Nodes > Node toevoegen)
ru|q_token|Токен регистрации (консоль: Узлы > Добавить узел)
zh|q_token|注册令牌（控制台：节点 > 添加节点）
ar|q_token|رمز التسجيل (لوحة التحكم: العقد > إضافة عقدة)
en|q_cp_ca|Control plane CA / certificate PEM file (empty = system trust store)
fr|q_cp_ca|Fichier PEM de la CA / du certificat du plan de contrôle (vide = magasin système)
es|q_cp_ca|Archivo PEM de la CA / certificado del plano de control (vacío = almacén del sistema)
de|q_cp_ca|PEM-Datei der CA / des Zertifikats der Control Plane (leer = Systemspeicher)
it|q_cp_ca|File PEM della CA / certificato del control plane (vuoto = archivio di sistema)
pt|q_cp_ca|Ficheiro PEM da CA / certificado do plano de controlo (vazio = repositório do sistema)
nl|q_cp_ca|PEM-bestand van de CA / het certificaat van de control plane (leeg = systeemopslag)
ru|q_cp_ca|PEM-файл CA / сертификата control plane (пусто = системное хранилище)
zh|q_cp_ca|控制平面 CA / 证书 PEM 文件（留空 = 系统信任库）
ar|q_cp_ca|ملف PEM لشهادة / مرجع مستوى التحكم (فارغ = مخزن النظام)
en|q_cp_port|Console port
fr|q_cp_port|Port de la console
es|q_cp_port|Puerto de la consola
de|q_cp_port|Konsolen-Port
it|q_cp_port|Porta della console
pt|q_cp_port|Porta da consola
nl|q_cp_port|Consolepoort
ru|q_cp_port|Порт консоли
zh|q_cp_port|控制台端口
ar|q_cp_port|منفذ لوحة التحكم
en|q_http_port|HTTP port
fr|q_http_port|Port HTTP
es|q_http_port|Puerto HTTP
de|q_http_port|HTTP-Port
it|q_http_port|Porta HTTP
pt|q_http_port|Porta HTTP
nl|q_http_port|HTTP-poort
ru|q_http_port|Порт HTTP
zh|q_http_port|HTTP 端口
ar|q_http_port|منفذ HTTP
en|q_https_port|HTTPS port
fr|q_https_port|Port HTTPS
es|q_https_port|Puerto HTTPS
de|q_https_port|HTTPS-Port
it|q_https_port|Porta HTTPS
pt|q_https_port|Porta HTTPS
nl|q_https_port|HTTPS-poort
ru|q_https_port|Порт HTTPS
zh|q_https_port|HTTPS 端口
ar|q_https_port|منفذ HTTPS
en|q_public_host|Public host name or IP address (empty = auto-detect)
fr|q_public_host|Nom d'hôte ou adresse IP publique (vide = détection auto)
es|q_public_host|Nombre de host o IP pública (vacío = detección automática)
de|q_public_host|Öffentlicher Hostname oder IP-Adresse (leer = automatisch)
it|q_public_host|Nome host o indirizzo IP pubblico (vuoto = rilevamento automatico)
pt|q_public_host|Nome de host ou IP público (vazio = deteção automática)
nl|q_public_host|Publieke hostnaam of IP-adres (leeg = automatisch)
ru|q_public_host|Публичное имя хоста или IP (пусто = автоопределение)
zh|q_public_host|公网主机名或 IP 地址（留空 = 自动检测）
ar|q_public_host|اسم المضيف أو عنوان IP العام (فارغ = اكتشاف تلقائي)
en|q_firewall|Open the firewall automatically (firewalld / ufw)?
fr|q_firewall|Ouvrir automatiquement le pare-feu (firewalld / ufw) ?
es|q_firewall|¿Abrir el cortafuegos automáticamente (firewalld / ufw)?
de|q_firewall|Firewall automatisch öffnen (firewalld / ufw)?
it|q_firewall|Aprire automaticamente il firewall (firewalld / ufw)?
pt|q_firewall|Abrir a firewall automaticamente (firewalld / ufw)?
nl|q_firewall|Firewall automatisch openen (firewalld / ufw)?
ru|q_firewall|Автоматически открыть порты в брандмауэре (firewalld / ufw)?
zh|q_firewall|是否自动放行防火墙端口（firewalld / ufw）？
ar|q_firewall|فتح جدار الحماية تلقائيا (firewalld / ufw)؟
en|q_boot|Start the services at boot?
fr|q_boot|Démarrer les services au démarrage ?
es|q_boot|¿Iniciar los servicios al arrancar?
de|q_boot|Dienste beim Systemstart starten?
it|q_boot|Avviare i servizi all'avvio?
pt|q_boot|Iniciar os serviços no arranque?
nl|q_boot|Services bij het opstarten starten?
ru|q_boot|Запускать службы при загрузке?
zh|q_boot|是否开机自动启动服务？
ar|q_boot|تشغيل الخدمات عند الإقلاع؟
en|q_channel|Release channel (stable / dev)
fr|q_channel|Canal de publication (stable / dev)
es|q_channel|Canal de versiones (stable / dev)
de|q_channel|Release-Kanal (stable / dev)
it|q_channel|Canale di rilascio (stable / dev)
pt|q_channel|Canal de lançamento (stable / dev)
nl|q_channel|Releasekanaal (stable / dev)
ru|q_channel|Канал релизов (stable / dev)
zh|q_channel|发布通道（stable / dev）
ar|q_channel|قناة الإصدارات (stable / dev)
en|q_bindir|Install directory
fr|q_bindir|Répertoire d'installation
es|q_bindir|Directorio de instalación
de|q_bindir|Installationsverzeichnis
it|q_bindir|Directory di installazione
pt|q_bindir|Diretório de instalação
nl|q_bindir|Installatiemap
ru|q_bindir|Каталог установки
zh|q_bindir|安装目录
ar|q_bindir|مجلد التثبيت
en|q_confirm|Proceed with the installation?
fr|q_confirm|Lancer l'installation ?
es|q_confirm|¿Continuar con la instalación?
de|q_confirm|Installation starten?
it|q_confirm|Procedere con l'installazione?
pt|q_confirm|Prosseguir com a instalação?
nl|q_confirm|Doorgaan met de installatie?
ru|q_confirm|Начать установку?
zh|q_confirm|开始安装？
ar|q_confirm|المتابعة في التثبيت؟
en|q_purge|Also delete configuration, data and logs? (No = keep them)
fr|q_purge|Supprimer aussi configuration, données et journaux ? (Non = les conserver)
es|q_purge|¿Borrar también configuración, datos y registros? (No = conservarlos)
de|q_purge|Auch Konfiguration, Daten und Logs löschen? (Nein = behalten)
it|q_purge|Eliminare anche configurazione, dati e log? (No = conservali)
pt|q_purge|Apagar também configuração, dados e logs? (Não = manter)
nl|q_purge|Ook configuratie, data en logs wissen? (Nee = bewaren)
ru|q_purge|Удалить также настройки, данные и журналы? (Нет = сохранить)
zh|q_purge|同时删除配置、数据和日志？（否 = 保留）
ar|q_purge|حذف الإعدادات والبيانات والسجلات أيضا؟ (لا = الاحتفاظ بها)
en|q_confirm_un|Really uninstall ToutWAF?
fr|q_confirm_un|Désinstaller vraiment ToutWAF ?
es|q_confirm_un|¿Desinstalar ToutWAF de verdad?
de|q_confirm_un|ToutWAF wirklich deinstallieren?
it|q_confirm_un|Disinstallare davvero ToutWAF?
pt|q_confirm_un|Desinstalar mesmo o ToutWAF?
nl|q_confirm_un|ToutWAF echt verwijderen?
ru|q_confirm_un|Действительно удалить ToutWAF?
zh|q_confirm_un|确定要卸载 ToutWAF 吗？
ar|q_confirm_un|هل تريد فعلا إزالة ToutWAF؟
en|aborted|Aborted.
fr|aborted|Abandon.
es|aborted|Cancelado.
de|aborted|Abgebrochen.
it|aborted|Annullato.
pt|aborted|Cancelado.
nl|aborted|Afgebroken.
ru|aborted|Отменено.
zh|aborted|已取消。
ar|aborted|تم الإلغاء.
en|root_required|Run as root (sudo bash install.sh).
fr|root_required|Exécutez en root (sudo bash install.sh).
es|root_required|Ejecute como root (sudo bash install.sh).
de|root_required|Als root ausführen (sudo bash install.sh).
it|root_required|Eseguire come root (sudo bash install.sh).
pt|root_required|Execute como root (sudo bash install.sh).
nl|root_required|Voer uit als root (sudo bash install.sh).
ru|root_required|Запустите от root (sudo bash install.sh).
zh|root_required|请以 root 身份运行（sudo bash install.sh）。
ar|root_required|شغّل السكربت بصلاحيات root (sudo bash install.sh).
en|s_prereq|Installing prerequisites
fr|s_prereq|Installation des prérequis
es|s_prereq|Instalando requisitos previos
de|s_prereq|Voraussetzungen installieren
it|s_prereq|Installazione dei prerequisiti
pt|s_prereq|A instalar pré-requisitos
nl|s_prereq|Vereisten installeren
ru|s_prereq|Установка зависимостей
zh|s_prereq|安装依赖项
ar|s_prereq|تثبيت المتطلبات
en|s_fetch|Downloading ToutWAF %s (%s)
fr|s_fetch|Téléchargement de ToutWAF %s (%s)
es|s_fetch|Descargando ToutWAF %s (%s)
de|s_fetch|ToutWAF %s (%s) wird heruntergeladen
it|s_fetch|Download di ToutWAF %s (%s)
pt|s_fetch|A transferir o ToutWAF %s (%s)
nl|s_fetch|ToutWAF %s (%s) downloaden
ru|s_fetch|Загрузка ToutWAF %s (%s)
zh|s_fetch|正在下载 ToutWAF %s（%s）
ar|s_fetch|تنزيل ToutWAF %s (%s)
en|s_sha|SHA-256 verified
fr|s_sha|SHA-256 vérifié
es|s_sha|SHA-256 verificado
de|s_sha|SHA-256 geprüft
it|s_sha|SHA-256 verificato
pt|s_sha|SHA-256 verificado
nl|s_sha|SHA-256 gecontroleerd
ru|s_sha|SHA-256 проверен
zh|s_sha|SHA-256 校验通过
ar|s_sha|تم التحقق من SHA-256
en|s_sig|cosign signature verified
fr|s_sig|Signature cosign vérifiée
es|s_sig|Firma cosign verificada
de|s_sig|cosign-Signatur geprüft
it|s_sig|Firma cosign verificata
pt|s_sig|Assinatura cosign verificada
nl|s_sig|cosign-handtekening gecontroleerd
ru|s_sig|Подпись cosign проверена
zh|s_sig|cosign 签名校验通过
ar|s_sig|تم التحقق من توقيع cosign
en|w_nocosign|cosign not installed: signature not verified (checksum only)
fr|w_nocosign|cosign absent : signature non vérifiée (somme de contrôle uniquement)
es|w_nocosign|cosign no instalado: firma sin verificar (solo suma de control)
de|w_nocosign|cosign fehlt: Signatur nicht geprüft (nur Prüfsumme)
it|w_nocosign|cosign non installato: firma non verificata (solo checksum)
pt|w_nocosign|cosign não instalado: assinatura não verificada (apenas checksum)
nl|w_nocosign|cosign niet geïnstalleerd: handtekening niet gecontroleerd (alleen checksum)
ru|w_nocosign|cosign не установлен: подпись не проверена (только контрольная сумма)
zh|w_nocosign|未安装 cosign：未校验签名（仅校验和）
ar|w_nocosign|cosign غير مثبت: لم يتم التحقق من التوقيع (المجموع الاختباري فقط)
en|s_user|Creating the service account and directories
fr|s_user|Création du compte de service et des répertoires
es|s_user|Creando la cuenta de servicio y los directorios
de|s_user|Dienstkonto und Verzeichnisse anlegen
it|s_user|Creazione dell'account di servizio e delle directory
pt|s_user|A criar a conta de serviço e os diretórios
nl|s_user|Serviceaccount en mappen aanmaken
ru|s_user|Создание служебной учётной записи и каталогов
zh|s_user|创建服务账户和目录
ar|s_user|إنشاء حساب الخدمة والمجلدات
en|s_bin|Installing binaries
fr|s_bin|Installation des binaires
es|s_bin|Instalando binarios
de|s_bin|Programme installieren
it|s_bin|Installazione dei binari
pt|s_bin|A instalar binários
nl|s_bin|Binaries installeren
ru|s_bin|Установка исполняемых файлов
zh|s_bin|安装程序文件
ar|s_bin|تثبيت الملفات التنفيذية
en|s_cfg|Writing configuration (existing files are kept)
fr|s_cfg|Écriture de la configuration (les fichiers existants sont conservés)
es|s_cfg|Escribiendo la configuración (se conservan los archivos existentes)
de|s_cfg|Konfiguration schreiben (vorhandene Dateien bleiben)
it|s_cfg|Scrittura della configurazione (i file esistenti sono mantenuti)
pt|s_cfg|A gravar a configuração (os ficheiros existentes são mantidos)
nl|s_cfg|Configuratie schrijven (bestaande bestanden blijven)
ru|s_cfg|Запись настроек (существующие файлы сохраняются)
zh|s_cfg|写入配置（保留已有文件）
ar|s_cfg|كتابة الإعدادات (تبقى الملفات الموجودة)
en|s_units|Installing systemd units and system tuning
fr|s_units|Installation des unités systemd et réglages système
es|s_units|Instalando unidades systemd y ajustes del sistema
de|s_units|systemd-Units und Systemoptimierung installieren
it|s_units|Installazione delle unit systemd e ottimizzazioni di sistema
pt|s_units|A instalar unidades systemd e ajustes do sistema
nl|s_units|systemd-units en systeemtuning installeren
ru|s_units|Установка юнитов systemd и настройка системы
zh|s_units|安装 systemd 单元与系统调优
ar|s_units|تثبيت وحدات systemd وضبط النظام
en|s_selinux|Configuring SELinux
fr|s_selinux|Configuration de SELinux
es|s_selinux|Configurando SELinux
de|s_selinux|SELinux konfigurieren
it|s_selinux|Configurazione di SELinux
pt|s_selinux|A configurar o SELinux
nl|s_selinux|SELinux configureren
ru|s_selinux|Настройка SELinux
zh|s_selinux|配置 SELinux
ar|s_selinux|إعداد SELinux
en|q_console_from|Only allow this network to reach the console (CIDR such as 203.0.113.0/24, empty = anyone)
fr|q_console_from|N'autoriser que ce réseau à joindre la console (CIDR, ex. 203.0.113.0/24 ; vide = tout le monde)
es|q_console_from|Permitir solo esta red hacia la consola (CIDR, p. ej. 203.0.113.0/24; vacío = cualquiera)
de|q_console_from|Konsole nur für dieses Netz freigeben (CIDR, z. B. 203.0.113.0/24; leer = alle)
it|q_console_from|Consenti alla console solo questa rete (CIDR, es. 203.0.113.0/24; vuoto = chiunque)
pt|q_console_from|Permitir apenas esta rede na consola (CIDR, ex. 203.0.113.0/24; vazio = qualquer um)
nl|q_console_from|Console alleen voor dit netwerk openen (CIDR, bv. 203.0.113.0/24; leeg = iedereen)
ru|q_console_from|Разрешить доступ к консоли только из этой сети (CIDR, напр. 203.0.113.0/24; пусто = всем)
zh|q_console_from|仅允许该网络访问控制台（CIDR，如 203.0.113.0/24；留空 = 任何人）
ar|q_console_from|السماح لهذه الشبكة فقط بالوصول إلى لوحة التحكم (CIDR مثل 203.0.113.0/24؛ فارغ = الجميع)
en|q_console_from_bad|Not an address or CIDR (0.0.0.0/0 is the same as empty): the console port stays open to everyone.
fr|q_console_from_bad|Ni adresse ni CIDR valide (0.0.0.0/0 revient à vide) : le port de la console reste ouvert à tous.
es|q_console_from_bad|No es una dirección ni un CIDR (0.0.0.0/0 equivale a vacío): el puerto de la consola queda abierto a todos.
de|q_console_from_bad|Keine Adresse und kein CIDR (0.0.0.0/0 entspricht leer): der Konsolenport bleibt für alle offen.
it|q_console_from_bad|Non è un indirizzo né un CIDR (0.0.0.0/0 equivale a vuoto): la porta della console resta aperta a tutti.
pt|q_console_from_bad|Não é um endereço nem um CIDR (0.0.0.0/0 equivale a vazio): a porta da consola fica aberta a todos.
nl|q_console_from_bad|Geen adres of CIDR (0.0.0.0/0 is hetzelfde als leeg): de consolepoort blijft voor iedereen open.
ru|q_console_from_bad|Не адрес и не CIDR (0.0.0.0/0 равно пустому): порт консоли остаётся открытым для всех.
zh|q_console_from_bad|不是有效的地址或 CIDR（0.0.0.0/0 等同于留空）：控制台端口对所有人开放。
ar|q_console_from_bad|ليس عنوانا ولا CIDR صالحا (0.0.0.0/0 يعادل فارغا): يبقى منفذ لوحة التحكم مفتوحا للجميع.
en|fw_console_note|The console (port %s) holds the administration login: opening it to the whole Internet is convenient but exposed.
fr|fw_console_note|La console (port %s) porte la connexion d'administration : l'ouvrir à tout Internet est pratique mais exposé.
es|fw_console_note|La consola (puerto %s) contiene el acceso de administración: abrirla a todo Internet es cómodo pero expuesto.
de|fw_console_note|Die Konsole (Port %s) enthält die Admin-Anmeldung: sie für das ganze Internet zu öffnen ist bequem, aber exponiert.
it|fw_console_note|La console (porta %s) ospita l'accesso amministrativo: aprirla a tutta Internet è comodo ma esposto.
pt|fw_console_note|A consola (porta %s) contém o início de sessão de administração: abri-la a toda a Internet é cómodo, mas exposto.
nl|fw_console_note|De console (poort %s) bevat de beheerlogin: openen voor heel internet is handig maar blootgesteld.
ru|fw_console_note|Консоль (порт %s) содержит вход администратора: открывать её всему Интернету удобно, но небезопасно.
zh|fw_console_note|控制台（端口 %s）承载管理员登录：向整个互联网开放虽然方便，但存在暴露风险。
ar|fw_console_note|لوحة التحكم (المنفذ %s) تحوي تسجيل دخول الإدارة: فتحها لكل الإنترنت مريح لكنه معرّض للخطر.
en|fw_console_open|Console port %s is open to everyone: restrict it with --console-from CIDR or in the console (Settings > Firewall)
fr|fw_console_open|Le port %s de la console est ouvert à tous : restreignez-le avec --console-from CIDR ou dans la console (Réglages > Pare-feu)
es|fw_console_open|El puerto %s de la consola está abierto a todos: restrínjalo con --console-from CIDR o en la consola (Ajustes > Cortafuegos)
de|fw_console_open|Konsolenport %s ist für alle offen: mit --console-from CIDR oder in der Konsole (Einstellungen > Firewall) einschränken
it|fw_console_open|La porta %s della console è aperta a tutti: limitala con --console-from CIDR o nella console (Impostazioni > Firewall)
pt|fw_console_open|A porta %s da consola está aberta a todos: restrinja com --console-from CIDR ou na consola (Definições > Firewall)
nl|fw_console_open|Consolepoort %s staat open voor iedereen: beperk met --console-from CIDR of in de console (Instellingen > Firewall)
ru|fw_console_open|Порт консоли %s открыт для всех: ограничьте его через --console-from CIDR или в консоли (Настройки > Брандмауэр)
zh|fw_console_open|控制台端口 %s 对所有人开放：请用 --console-from CIDR 或在控制台（设置 > 防火墙）中限制
ar|fw_console_open|منفذ لوحة التحكم %s مفتوح للجميع: قيّده بـ --console-from CIDR أو من اللوحة (الإعدادات > جدار الحماية)
en|fw_console_from|Console port %s is only open to %s
fr|fw_console_from|Le port %s de la console n'est ouvert qu'à %s
es|fw_console_from|El puerto %s de la consola solo está abierto a %s
de|fw_console_from|Konsolenport %s ist nur für %s offen
it|fw_console_from|La porta %s della console è aperta solo a %s
pt|fw_console_from|A porta %s da consola está aberta apenas a %s
nl|fw_console_from|Consolepoort %s staat alleen open voor %s
ru|fw_console_from|Порт консоли %s открыт только для %s
zh|fw_console_from|控制台端口 %s 仅对 %s 开放
ar|fw_console_from|منفذ لوحة التحكم %s مفتوح فقط لـ %s
en|fw_none|No active firewall (firewalld / ufw / nftables / iptables) found: nothing filters the traffic, no port to open
fr|fw_none|Aucun pare-feu actif (firewalld / ufw / nftables / iptables) : rien ne filtre le trafic, aucun port à ouvrir
es|fw_none|No hay cortafuegos activo (firewalld / ufw / nftables / iptables): nada filtra el tráfico, no hay puertos que abrir
de|fw_none|Keine aktive Firewall (firewalld / ufw / nftables / iptables) gefunden: nichts filtert den Verkehr, keine Ports zu öffnen
it|fw_none|Nessun firewall attivo (firewalld / ufw / nftables / iptables): nulla filtra il traffico, nessuna porta da aprire
pt|fw_none|Nenhuma firewall ativa (firewalld / ufw / nftables / iptables): nada filtra o tráfego, nenhuma porta a abrir
nl|fw_none|Geen actieve firewall (firewalld / ufw / nftables / iptables) gevonden: niets filtert het verkeer, geen poorten te openen
ru|fw_none|Активный брандмауэр (firewalld / ufw / nftables / iptables) не найден: трафик не фильтруется, открывать порты не нужно
zh|fw_none|未发现活动的防火墙（firewalld / ufw / nftables / iptables）：流量未被过滤，无需放行端口
ar|fw_none|لم يُعثر على جدار حماية نشط (firewalld / ufw / nftables / iptables): لا شيء يرشح الحركة ولا منافذ لفتحها
en|fw_manual|The %s firewall is not modified by the installer: run these commands yourself
fr|fw_manual|Le pare-feu %s n'est pas modifié par l'installeur : exécutez vous-même ces commandes
es|fw_manual|El cortafuegos %s no lo modifica el instalador: ejecute usted estos comandos
de|fw_manual|Die Firewall %s wird vom Installer nicht verändert: führen Sie diese Befehle selbst aus
it|fw_manual|Il firewall %s non viene modificato dall'installer: esegui tu questi comandi
pt|fw_manual|A firewall %s não é modificada pelo instalador: execute estes comandos por si
nl|fw_manual|De firewall %s wordt niet door de installer gewijzigd: voer deze commando's zelf uit
ru|fw_manual|Брандмауэр %s установщик не изменяет: выполните эти команды сами
zh|fw_manual|安装程序不会修改 %s 防火墙：请自行执行以下命令
ar|fw_manual|لا يعدّل المثبّت جدار الحماية %s: نفّذ هذه الأوامر بنفسك
en|fw_failed|The firewall could not be configured: %s
fr|fw_failed|Le pare-feu n'a pas pu être configuré : %s
es|fw_failed|No se pudo configurar el cortafuegos: %s
de|fw_failed|Die Firewall konnte nicht konfiguriert werden: %s
it|fw_failed|Impossibile configurare il firewall: %s
pt|fw_failed|Não foi possível configurar a firewall: %s
nl|fw_failed|De firewall kon niet worden geconfigureerd: %s
ru|fw_failed|Не удалось настроить брандмауэр: %s
zh|fw_failed|无法配置防火墙：%s
ar|fw_failed|تعذر إعداد جدار الحماية: %s
en|home_fresh|New installation: everything goes under %s (bin, conf, data, logs)
fr|home_fresh|Nouvelle installation : tout est placé sous %s (bin, conf, data, logs)
es|home_fresh|Instalación nueva: todo va bajo %s (bin, conf, data, logs)
de|home_fresh|Neuinstallation: alles liegt unter %s (bin, conf, data, logs)
it|home_fresh|Nuova installazione: tutto sotto %s (bin, conf, data, logs)
pt|home_fresh|Nova instalação: tudo fica em %s (bin, conf, data, logs)
nl|home_fresh|Nieuwe installatie: alles komt onder %s (bin, conf, data, logs)
ru|home_fresh|Новая установка: всё размещается в %s (bin, conf, data, logs)
zh|home_fresh|全新安装：所有内容位于 %s（bin、conf、data、logs）
ar|home_fresh|تثبيت جديد: كل شيء تحت %s (bin وconf وdata وlogs)
en|home_legacy|Existing installation detected: its paths are kept (bin %s, conf %s, data %s). Nothing is moved; use --home DIR for the new layout.
fr|home_legacy|Installation existante détectée : ses chemins sont conservés (bin %s, conf %s, data %s). Rien n'est déplacé ; utilisez --home DIR pour la nouvelle disposition.
es|home_legacy|Instalación existente detectada: se mantienen sus rutas (bin %s, conf %s, data %s). No se mueve nada; use --home DIR para la nueva disposición.
de|home_legacy|Bestehende Installation erkannt: ihre Pfade bleiben (bin %s, conf %s, data %s). Nichts wird verschoben; --home DIR für das neue Layout.
it|home_legacy|Installazione esistente rilevata: i suoi percorsi restano (bin %s, conf %s, data %s). Nulla viene spostato; usa --home DIR per il nuovo layout.
pt|home_legacy|Instalação existente detetada: os caminhos são mantidos (bin %s, conf %s, data %s). Nada é movido; use --home DIR para o novo layout.
nl|home_legacy|Bestaande installatie gevonden: de paden blijven (bin %s, conf %s, data %s). Er wordt niets verplaatst; gebruik --home DIR voor de nieuwe indeling.
ru|home_legacy|Обнаружена существующая установка: её пути сохраняются (bin %s, conf %s, data %s). Ничего не переносится; для новой схемы используйте --home DIR.
zh|home_legacy|检测到现有安装：沿用其路径（bin %s、conf %s、data %s）。不会移动任何内容；使用 --home DIR 采用新布局。
ar|home_legacy|تم اكتشاف تثبيت قائم: تبقى مساراته (bin %s وconf %s وdata %s). لا يُنقل شيء؛ استخدم --home DIR للتخطيط الجديد.
en|home_explicit_legacy|--home %s was given while an installation exists in %s: its data is NOT moved
fr|home_explicit_legacy|--home %s a été donné alors qu'une installation existe dans %s : ses données ne sont PAS déplacées
es|home_explicit_legacy|Se indicó --home %s mientras existe una instalación en %s: sus datos NO se mueven
de|home_explicit_legacy|--home %s wurde angegeben, obwohl in %s eine Installation existiert: deren Daten werden NICHT verschoben
it|home_explicit_legacy|--home %s indicato mentre esiste un'installazione in %s: i suoi dati NON vengono spostati
pt|home_explicit_legacy|--home %s foi informado enquanto existe uma instalação em %s: os dados dela NÃO são movidos
nl|home_explicit_legacy|--home %s opgegeven terwijl er een installatie bestaat in %s: de data wordt NIET verplaatst
ru|home_explicit_legacy|--home %s указан при существующей установке в %s: её данные НЕ переносятся
zh|home_explicit_legacy|已指定 --home %s，但 %s 中已有安装：其数据不会被移动
ar|home_explicit_legacy|تم تحديد --home %s بينما يوجد تثبيت في %s: بياناته لا تُنقل
en|home_bad|--home must be an absolute path (letters, digits, . _ - + /), not / and not under /proc /sys /dev: %s
fr|home_bad|--home doit être un chemin absolu (lettres, chiffres, . _ - + /), ni / ni sous /proc /sys /dev : %s
es|home_bad|--home debe ser una ruta absoluta (letras, dígitos, . _ - + /), no / ni bajo /proc /sys /dev: %s
de|home_bad|--home muss ein absoluter Pfad sein (Buchstaben, Ziffern, . _ - + /), nicht / und nicht unter /proc /sys /dev: %s
it|home_bad|--home deve essere un percorso assoluto (lettere, cifre, . _ - + /), non / né sotto /proc /sys /dev: %s
pt|home_bad|--home deve ser um caminho absoluto (letras, dígitos, . _ - + /), não / nem sob /proc /sys /dev: %s
nl|home_bad|--home moet een absoluut pad zijn (letters, cijfers, . _ - + /), niet / en niet onder /proc /sys /dev: %s
ru|home_bad|--home должен быть абсолютным путём (буквы, цифры, . _ - + /), не / и не в /proc /sys /dev: %s
zh|home_bad|--home 必须是绝对路径（字母、数字、. _ - + /），不能是 / 也不能位于 /proc /sys /dev 下：%s
ar|home_bad|يجب أن يكون --home مسارا مطلقا (حروف وأرقام . _ - + /) وليس / ولا تحت /proc /sys /dev: %s
en|home_noexec|%s is on a noexec mount: the binaries could not run from there, choose another --home
fr|home_noexec|%s est sur un montage noexec : les binaires n'y pourraient pas s'exécuter, choisissez un autre --home
es|home_noexec|%s está en un montaje noexec: los binarios no podrían ejecutarse allí, elija otro --home
de|home_noexec|%s liegt auf einem noexec-Mount: die Programme könnten dort nicht laufen, wählen Sie ein anderes --home
it|home_noexec|%s si trova su un mount noexec: i binari non potrebbero girarvi, scegli un altro --home
pt|home_noexec|%s está numa montagem noexec: os binários não poderiam executar ali, escolha outro --home
nl|home_noexec|%s staat op een noexec-mount: de programma's kunnen daar niet draaien, kies een ander --home
ru|home_noexec|%s находится на noexec-разделе: бинарные файлы там не запустятся, выберите другой --home
zh|home_noexec|%s 位于 noexec 挂载上：二进制文件无法在此运行，请选择其他 --home
ar|home_noexec|%s على نقطة تركيب noexec: لا يمكن تشغيل الملفات التنفيذية هناك، اختر --home آخر
en|s_fw|Configuring the firewall
fr|s_fw|Configuration du pare-feu
es|s_fw|Configurando el cortafuegos
de|s_fw|Firewall konfigurieren
it|s_fw|Configurazione del firewall
pt|s_fw|A configurar a firewall
nl|s_fw|Firewall configureren
ru|s_fw|Настройка брандмауэра
zh|s_fw|配置防火墙
ar|s_fw|إعداد جدار الحماية
en|s_boot|Preparing the panel (administrator account, secure panel path)
fr|s_boot|Préparation du panneau (compte administrateur, chemin sécurisé)
es|s_boot|Preparando el panel (cuenta de administrador, ruta segura)
de|s_boot|Panel vorbereiten (Administratorkonto, sicherer Pfad)
it|s_boot|Preparazione del pannello (account amministratore, percorso sicuro)
pt|s_boot|A preparar o painel (conta de administrador, caminho seguro)
nl|s_boot|Paneel voorbereiden (beheerdersaccount, beveiligd pad)
ru|s_boot|Подготовка панели (учётная запись администратора, защищённый путь)
zh|s_boot|准备面板（管理员账户、安全路径）
ar|s_boot|تجهيز اللوحة (حساب المسؤول والمسار الآمن)
en|s_start|Starting the services
fr|s_start|Démarrage des services
es|s_start|Iniciando los servicios
de|s_start|Dienste starten
it|s_start|Avvio dei servizi
pt|s_start|A iniciar os serviços
nl|s_start|Services starten
ru|s_start|Запуск служб
zh|s_start|启动服务
ar|s_start|بدء الخدمات
en|s_health|Waiting for the services to become healthy
fr|s_health|Attente de la disponibilité des services
es|s_health|Esperando a que los servicios estén sanos
de|s_health|Warten auf gesunde Dienste
it|s_health|Attesa dei servizi in salute
pt|s_health|A aguardar que os serviços fiquem saudáveis
nl|s_health|Wachten tot de services gezond zijn
ru|s_health|Ожидание готовности служб
zh|s_health|等待服务就绪
ar|s_health|انتظار جاهزية الخدمات
en|s_backup|Backing up configuration and data
fr|s_backup|Sauvegarde de la configuration et des données
es|s_backup|Copia de seguridad de configuración y datos
de|s_backup|Konfiguration und Daten sichern
it|s_backup|Backup di configurazione e dati
pt|s_backup|Cópia de segurança de configuração e dados
nl|s_backup|Back-up van configuratie en data
ru|s_backup|Резервное копирование настроек и данных
zh|s_backup|备份配置与数据
ar|s_backup|نسخ احتياطي للإعدادات والبيانات
en|w_rollback|The new version is not healthy: rolling back to the previous one
fr|w_rollback|La nouvelle version n'est pas saine : retour à la précédente
es|w_rollback|La nueva versión no está sana: volviendo a la anterior
de|w_rollback|Die neue Version arbeitet nicht fehlerfrei: Rückkehr zur vorherigen
it|w_rollback|La nuova versione non funziona correttamente: ritorno alla precedente
pt|w_rollback|A nova versão não está saudável: a voltar à anterior
nl|w_rollback|De nieuwe versie is niet gezond: terugdraaien naar de vorige
ru|w_rollback|Новая версия не работает: откат к предыдущей
zh|w_rollback|新版本运行异常：正在回滚到上一版本
ar|w_rollback|الإصدار الجديد غير سليم: جار التراجع إلى السابق
en|up_to_date|Already up to date (%s)
fr|up_to_date|Déjà à jour (%s)
es|up_to_date|Ya está actualizado (%s)
de|up_to_date|Bereits aktuell (%s)
it|up_to_date|Già aggiornato (%s)
pt|up_to_date|Já está atualizado (%s)
nl|up_to_date|Al bijgewerkt (%s)
ru|up_to_date|Уже актуально (%s)
zh|up_to_date|已是最新版本（%s）
ar|up_to_date|محدّث بالفعل (%s)
en|not_installed|ToutWAF is not installed: nothing to update.
fr|not_installed|ToutWAF n'est pas installé : rien à mettre à jour.
es|not_installed|ToutWAF no está instalado: nada que actualizar.
de|not_installed|ToutWAF ist nicht installiert: nichts zu aktualisieren.
it|not_installed|ToutWAF non è installato: niente da aggiornare.
pt|not_installed|O ToutWAF não está instalado: nada a atualizar.
nl|not_installed|ToutWAF is niet geïnstalleerd: niets bij te werken.
ru|not_installed|ToutWAF не установлен: обновлять нечего.
zh|not_installed|尚未安装 ToutWAF：无需更新。
ar|not_installed|ToutWAF غير مثبت: لا شيء للتحديث.
en|st_channel|Channel: %s
fr|st_channel|Canal : %s
es|st_channel|Canal: %s
de|st_channel|Kanal: %s
it|st_channel|Canale: %s
pt|st_channel|Canal: %s
nl|st_channel|Kanaal: %s
ru|st_channel|Канал: %s
zh|st_channel|通道：%s
ar|st_channel|القناة: %s
en|st_latest|Latest available: %s
fr|st_latest|Dernière version disponible : %s
es|st_latest|Última versión disponible: %s
de|st_latest|Neueste verfügbare Version: %s
it|st_latest|Ultima versione disponibile: %s
pt|st_latest|Última versão disponível: %s
nl|st_latest|Laatst beschikbare versie: %s
ru|st_latest|Последняя доступная версия: %s
zh|st_latest|最新可用版本：%s
ar|st_latest|أحدث إصدار متاح: %s
en|st_newer|update available: run with --update
fr|st_newer|mise à jour disponible : lancez avec --update
es|st_newer|actualización disponible: ejecute con --update
de|st_newer|Update verfügbar: mit --update ausführen
it|st_newer|aggiornamento disponibile: esegui con --update
pt|st_newer|atualização disponível: execute com --update
nl|st_newer|update beschikbaar: voer uit met --update
ru|st_newer|доступно обновление: запустите с --update
zh|st_newer|有可用更新：请使用 --update 运行
ar|st_newer|تحديث متاح: شغّل مع --update
en|e_yanked|Version %s was withdrawn (yanked) and must not be installed. Run --update for the current release, or --force to override.
fr|e_yanked|La version %s a été retirée (yanked) et ne doit pas être installée. Lancez --update pour la version courante, ou --force pour passer outre.
es|e_yanked|La versión %s fue retirada (yanked) y no debe instalarse. Ejecute --update para la versión actual, o --force para ignorarlo.
de|e_yanked|Version %s wurde zurückgezogen (yanked) und darf nicht installiert werden. Mit --update die aktuelle Version holen, oder --force zum Übergehen.
it|e_yanked|La versione %s è stata ritirata (yanked) e non va installata. Esegui --update per la versione corrente, o --force per forzare.
pt|e_yanked|A versão %s foi retirada (yanked) e não deve ser instalada. Execute --update para a versão atual, ou --force para ignorar.
nl|e_yanked|Versie %s is ingetrokken (yanked) en mag niet worden geïnstalleerd. Gebruik --update voor de huidige versie, of --force om te negeren.
ru|e_yanked|Версия %s отозвана (yanked) и не должна устанавливаться. Запустите --update для актуальной версии или --force, чтобы обойти.
zh|e_yanked|版本 %s 已被撤回（yanked），不应安装。请运行 --update 获取当前版本，或使用 --force 强制。
ar|e_yanked|تم سحب الإصدار %s (yanked) ولا يجب تثبيته. شغّل --update للإصدار الحالي أو --force للتجاوز.
en|e_nover|No version is published on the %s channel yet, so there is nothing to install. ToutWAF was not installed or modified. To install from the %s channel instead, run the installer again with --channel %s.
fr|e_nover|Aucune version n'est encore publiée sur le canal %s : il n'y a rien à installer. ToutWAF n'a été ni installé ni modifié. Pour installer depuis le canal %s, relancez l'installeur avec --channel %s.
es|e_nover|Todavía no hay ninguna versión publicada en el canal %s, así que no hay nada que instalar. ToutWAF no se ha instalado ni modificado. Para instalar desde el canal %s, vuelva a ejecutar el instalador con --channel %s.
de|e_nover|Auf dem Kanal %s ist noch keine Version veröffentlicht, es gibt also nichts zu installieren. ToutWAF wurde weder installiert noch verändert. Um vom Kanal %s zu installieren, starten Sie das Installationsprogramm erneut mit --channel %s.
it|e_nover|Sul canale %s non è ancora pubblicata nessuna versione, quindi non c'è nulla da installare. ToutWAF non è stato installato né modificato. Per installare dal canale %s, rilancia l'installer con --channel %s.
pt|e_nover|Ainda não há nenhuma versão publicada no canal %s, por isso não há nada para instalar. O ToutWAF não foi instalado nem alterado. Para instalar a partir do canal %s, execute o instalador de novo com --channel %s.
nl|e_nover|Op het kanaal %s is nog geen versie gepubliceerd, dus er valt niets te installeren. ToutWAF is niet geïnstalleerd of gewijzigd. Om vanaf het kanaal %s te installeren, start u het installatieprogramma opnieuw met --channel %s.
ru|e_nover|В канале %s пока не опубликовано ни одной версии, устанавливать нечего. ToutWAF не установлен и не изменён. Чтобы установить из канала %s, запустите установщик снова с --channel %s.
zh|e_nover|%s 通道尚未发布任何版本，因此没有可安装的内容。未安装或更改 ToutWAF。若要改从 %s 通道安装，请使用 --channel %s 重新运行安装程序。
ar|e_nover|لم يُنشر أي إصدار على القناة %s بعد، لذلك لا يوجد ما يمكن تثبيته. لم يتم تثبيت ToutWAF أو تغييره. للتثبيت من القناة %s شغّل المثبّت مجددًا مع --channel %s.
en|e_installer_old|This installer is too old for this release (needs version %s): download it again from the channel URL.
fr|e_installer_old|Cet installeur est trop ancien pour cette version (version %s requise) : retéléchargez-le depuis l'URL du canal.
es|e_installer_old|Este instalador es demasiado antiguo para esta versión (requiere la versión %s): descárguelo de nuevo desde la URL del canal.
de|e_installer_old|Dieses Installationsprogramm ist für diese Version zu alt (benötigt Version %s): erneut von der Kanal-URL laden.
it|e_installer_old|Questo installer è troppo vecchio per questa versione (richiede la versione %s): scaricalo di nuovo dall'URL del canale.
pt|e_installer_old|Este instalador é demasiado antigo para esta versão (requer a versão %s): transfira-o novamente a partir do URL do canal.
nl|e_installer_old|Dit installatieprogramma is te oud voor deze versie (vereist versie %s): download het opnieuw van de kanaal-URL.
ru|e_installer_old|Этот установщик слишком старый для этого релиза (нужна версия %s): скачайте его заново по URL канала.
zh|e_installer_old|此安装程序对该版本而言太旧（需要版本 %s）：请从通道 URL 重新下载。
ar|e_installer_old|هذا المثبّت قديم جدًا لهذا الإصدار (يتطلب الإصدار %s): نزّله من جديد من عنوان القناة.
en|up_rebuilt|Same version, new build: installed %s, available %s. Updating.
fr|up_rebuilt|Même version, nouvelle compilation : installée %s, disponible %s. Mise à jour en cours.
es|up_rebuilt|Misma versión, nueva compilación: instalada %s, disponible %s. Actualizando.
de|up_rebuilt|Gleiche Version, neuer Build: installiert %s, verfügbar %s. Aktualisierung läuft.
it|up_rebuilt|Stessa versione, nuova build: installata %s, disponibile %s. Aggiornamento in corso.
pt|up_rebuilt|Mesma versão, nova compilação: instalada %s, disponível %s. A atualizar.
nl|up_rebuilt|Zelfde versie, nieuwe build: geïnstalleerd %s, beschikbaar %s. Bezig met bijwerken.
ru|up_rebuilt|Та же версия, новая сборка: установлена %s, доступна %s. Выполняется обновление.
zh|up_rebuilt|版本相同，有新构建：已安装 %s，可用 %s。正在更新。
ar|up_rebuilt|الإصدار نفسه وبناء جديد: المثبّت %s، المتاح %s. جارٍ التحديث.
en|st_newbuild|same version, new build available: run again with %s
fr|st_newbuild|même version, nouvelle compilation disponible : relancez avec %s
es|st_newbuild|misma versión, nueva compilación disponible: ejecute de nuevo con %s
de|st_newbuild|gleiche Version, neuer Build verfügbar: erneut mit %s ausführen
it|st_newbuild|stessa versione, nuova build disponibile: esegui di nuovo con %s
pt|st_newbuild|mesma versão, nova compilação disponível: execute novamente com %s
nl|st_newbuild|zelfde versie, nieuwe build beschikbaar: voer opnieuw uit met %s
ru|st_newbuild|та же версия, доступна новая сборка: запустите снова с %s
zh|st_newbuild|版本相同，有新构建：请使用 %s 再次运行
ar|st_newbuild|الإصدار نفسه وبناء جديد متاح: شغّل مجددًا مع %s
en|st_nochannel|Latest available: nothing published on this channel yet
fr|st_nochannel|Dernière version disponible : rien n'est encore publié sur ce canal
es|st_nochannel|Última versión disponible: todavía no hay nada publicado en este canal
de|st_nochannel|Neueste verfügbare Version: in diesem Kanal ist noch nichts veröffentlicht
it|st_nochannel|Ultima versione disponibile: su questo canale non è ancora stato pubblicato nulla
pt|st_nochannel|Última versão disponível: ainda não há nada publicado neste canal
nl|st_nochannel|Laatst beschikbare versie: in dit kanaal is nog niets gepubliceerd
ru|st_nochannel|Последняя доступная версия: в этом канале пока ничего не опубликовано
zh|st_nochannel|最新可用版本：此渠道尚未发布任何内容
ar|st_nochannel|أحدث إصدار متاح: لم يُنشر شيء في هذه القناة بعد
en|w_mirror|The public mirror served files that do not agree with each other (%s): it is probably still refreshing after a publication. Reading the channel again, once.
fr|w_mirror|Le miroir public a servi des fichiers qui ne concordent pas (%s) : il est probablement encore en cours de mise à jour après une publication. Nouvelle lecture du canal, une seule fois.
es|w_mirror|El espejo público ha servido archivos que no concuerdan entre sí (%s): probablemente aún se está actualizando tras una publicación. Se lee el canal de nuevo, una sola vez.
de|w_mirror|Der öffentliche Spiegel hat Dateien geliefert, die nicht zusammenpassen (%s): vermutlich wird er nach einer Veröffentlichung noch aktualisiert. Der Kanal wird einmal neu gelesen.
it|w_mirror|Il mirror pubblico ha servito file che non concordano tra loro (%s): probabilmente si sta ancora aggiornando dopo una pubblicazione. Rileggo il canale, una sola volta.
pt|w_mirror|O espelho público serviu ficheiros que não concordam entre si (%s): provavelmente ainda está a atualizar após uma publicação. A ler o canal de novo, uma única vez.
nl|w_mirror|De openbare mirror leverde bestanden die niet bij elkaar passen (%s): hij wordt waarschijnlijk nog bijgewerkt na een publicatie. Het kanaal wordt één keer opnieuw gelezen.
ru|w_mirror|Публичное зеркало отдало файлы, которые не согласуются между собой (%s): вероятно, оно ещё обновляется после публикации. Канал будет прочитан заново один раз.
zh|w_mirror|公共镜像提供的文件彼此不一致（%s）：很可能是发布后仍在刷新。将重新读取一次渠道。
ar|w_mirror|قدّمت المرآة العامة ملفات غير متسقة فيما بينها (%s): ربما ما زالت تُحدَّث بعد النشر. ستُعاد قراءة القناة مرة واحدة.
en|e_mismatch|checksum mismatch for %s (%s): the downloaded file does not match the checksum that was published, so nothing was installed or changed. Right after a publication the public mirror can serve the previous files for a few minutes: wait five minutes and run the installer again. If it happens again, do not install: the publication is damaged.
fr|e_mismatch|somme de contrôle incorrecte pour %s (%s) : le fichier téléchargé ne correspond pas à la somme publiée, donc rien n'a été installé ni modifié. Juste après une publication, le miroir public peut servir les anciens fichiers pendant quelques minutes : attendez cinq minutes et relancez l'installeur. Si cela se reproduit, n'installez pas : la publication est endommagée.
es|e_mismatch|suma de comprobación incorrecta para %s (%s): el archivo descargado no coincide con la suma publicada, por lo que no se ha instalado ni modificado nada. Justo después de una publicación, el espejo público puede servir los archivos anteriores durante unos minutos: espere cinco minutos y vuelva a ejecutar el instalador. Si se repite, no instale: la publicación está dañada.
de|e_mismatch|Prüfsumme stimmt nicht für %s (%s): Die heruntergeladene Datei passt nicht zur veröffentlichten Prüfsumme, daher wurde nichts installiert oder geändert. Direkt nach einer Veröffentlichung kann der öffentliche Spiegel einige Minuten lang die vorherigen Dateien liefern: Warten Sie fünf Minuten und starten Sie das Installationsprogramm erneut. Tritt es erneut auf, installieren Sie nicht: Die Veröffentlichung ist beschädigt.
it|e_mismatch|checksum non corrispondente per %s (%s): il file scaricato non corrisponde al checksum pubblicato, quindi non è stato installato né modificato nulla. Subito dopo una pubblicazione il mirror pubblico può servire per qualche minuto i file precedenti: attendi cinque minuti e rilancia l'installer. Se si ripete, non installare: la pubblicazione è danneggiata.
pt|e_mismatch|soma de verificação incorreta para %s (%s): o ficheiro transferido não corresponde à soma publicada, por isso nada foi instalado nem alterado. Logo após uma publicação, o espelho público pode servir os ficheiros anteriores durante alguns minutos: aguarde cinco minutos e execute o instalador de novo. Se se repetir, não instale: a publicação está danificada.
nl|e_mismatch|checksum klopt niet voor %s (%s): het gedownloade bestand komt niet overeen met de gepubliceerde checksum, dus er is niets geïnstalleerd of gewijzigd. Direct na een publicatie kan de openbare mirror enkele minuten de vorige bestanden aanbieden: wacht vijf minuten en start het installatieprogramma opnieuw. Gebeurt het opnieuw, installeer dan niet: de publicatie is beschadigd.
ru|e_mismatch|контрольная сумма не совпадает для %s (%s): загруженный файл не соответствует опубликованной сумме, поэтому ничего не установлено и не изменено. Сразу после публикации публичное зеркало может несколько минут отдавать прежние файлы: подождите пять минут и запустите установщик снова. Если ошибка повторится, не устанавливайте: публикация повреждена.
zh|e_mismatch|%s 的校验和不匹配（%s）：下载的文件与已发布的校验和不一致，因此未安装或更改任何内容。发布后的几分钟内，公共镜像可能仍提供旧文件：请等待五分钟后重新运行安装程序。若再次出现，请勿安装：该发布已损坏。
ar|e_mismatch|مجموع التحقق غير مطابق لـ %s (%s): الملف الذي نُزِّل لا يطابق المجموع المنشور، لذلك لم يُثبَّت أو يُغيَّر أي شيء. بعد النشر مباشرة قد تقدّم المرآة العامة الملفات السابقة لبضع دقائق: انتظر خمس دقائق وشغّل المثبّت مجددًا. إن تكرر ذلك فلا تثبّت: النشر تالف.
en|e_downgrade|The latest release %s of channel %s is older than the installed %s: use --force to downgrade.
fr|e_downgrade|La dernière version %s du canal %s est plus ancienne que la version installée %s : utilisez --force pour rétrograder.
es|e_downgrade|La última versión %s del canal %s es anterior a la instalada %s: use --force para degradar.
de|e_downgrade|Die neueste Version %s des Kanals %s ist älter als die installierte %s: --force zum Downgrade.
it|e_downgrade|L'ultima versione %s del canale %s è più vecchia di quella installata %s: usa --force per il downgrade.
pt|e_downgrade|A última versão %s do canal %s é mais antiga do que a instalada %s: use --force para reverter.
nl|e_downgrade|De nieuwste versie %s van kanaal %s is ouder dan de geïnstalleerde %s: gebruik --force om terug te gaan.
ru|e_downgrade|Последний релиз %s канала %s старше установленного %s: используйте --force для понижения версии.
zh|e_downgrade|最新版本 %s（通道 %s）比已安装的 %s 旧：使用 --force 降级。
ar|e_downgrade|أحدث إصدار %s في القناة %s أقدم من المثبّت %s: استخدم --force للرجوع.
en|s_sigok|release signature verified, key %s
fr|s_sigok|signature de la version vérifiée, clé %s
es|s_sigok|firma de la versión verificada, clave %s
de|s_sigok|Release-Signatur geprüft, Schlüssel %s
it|s_sigok|firma della release verificata, chiave %s
pt|s_sigok|assinatura da versão verificada, chave %s
nl|s_sigok|release-handtekening gecontroleerd, sleutel %s
ru|s_sigok|подпись релиза проверена, ключ %s
zh|s_sigok|发布签名校验通过，密钥 %s
ar|s_sigok|تم التحقق من توقيع الإصدار، المفتاح %s
en|w_sigold|release %s was published without a signature (releases before 0.2.0-dev.7 are unsigned): only SHA-256 was verified, the signature could not be checked
fr|w_sigold|la version %s a été publiée sans signature (les versions antérieures à 0.2.0-dev.7 ne sont pas signées) : seul le SHA-256 a été vérifié, la signature n'a pas pu l'être
es|w_sigold|la versión %s se publicó sin firma (las anteriores a 0.2.0-dev.7 no están firmadas): solo se verificó el SHA-256, no se pudo comprobar la firma
de|w_sigold|Version %s wurde ohne Signatur veröffentlicht (Versionen vor 0.2.0-dev.7 sind unsigniert): nur SHA-256 wurde geprüft, die Signatur konnte nicht geprüft werden
it|w_sigold|la versione %s è stata pubblicata senza firma (le versioni precedenti a 0.2.0-dev.7 non sono firmate): è stato verificato solo lo SHA-256, la firma non ha potuto essere controllata
pt|w_sigold|a versão %s foi publicada sem assinatura (as anteriores a 0.2.0-dev.7 não são assinadas): só o SHA-256 foi verificado, a assinatura não pôde ser conferida
nl|w_sigold|versie %s is zonder handtekening gepubliceerd (versies vóór 0.2.0-dev.7 zijn niet ondertekend): alleen SHA-256 is gecontroleerd, de handtekening kon niet worden gecontroleerd
ru|w_sigold|версия %s опубликована без подписи (версии до 0.2.0-dev.7 не подписаны): проверена только SHA-256, подпись проверить не удалось
zh|w_sigold|版本 %s 发布时没有签名（0.2.0-dev.7 之前的版本均未签名）：仅校验了 SHA-256，无法校验签名
ar|w_sigold|الإصدار %s نُشر بدون توقيع (الإصدارات قبل 0.2.0-dev.7 غير موقّعة): تم التحقق من SHA-256 فقط ولم يمكن التحقق من التوقيع
en|w_sigskip|release signature NOT verified: openssl.exe was not found in PATH (Windows has no built-in Ed25519 verification), only SHA-256 was checked. Install OpenSSL 3 and run again to verify against key %s
fr|w_sigskip|signature de la version NON vérifiée : openssl.exe est introuvable dans le PATH (Windows n'a pas de vérification Ed25519 intégrée), seul le SHA-256 a été contrôlé. Installez OpenSSL 3 et relancez pour vérifier avec la clé %s
es|w_sigskip|firma de la versión NO verificada: no se encontró openssl.exe en el PATH (Windows no incluye verificación Ed25519), solo se comprobó el SHA-256. Instale OpenSSL 3 y vuelva a ejecutar para verificar con la clave %s
de|w_sigskip|Release-Signatur NICHT geprüft: openssl.exe wurde im PATH nicht gefunden (Windows hat keine eingebaute Ed25519-Prüfung), nur SHA-256 wurde geprüft. OpenSSL 3 installieren und erneut ausführen, um mit Schlüssel %s zu prüfen
it|w_sigskip|firma della release NON verificata: openssl.exe non trovato nel PATH (Windows non ha una verifica Ed25519 integrata), è stato controllato solo lo SHA-256. Installa OpenSSL 3 ed esegui di nuovo per verificare con la chiave %s
pt|w_sigskip|assinatura da versão NÃO verificada: openssl.exe não foi encontrado no PATH (o Windows não tem verificação Ed25519 integrada), só o SHA-256 foi conferido. Instale o OpenSSL 3 e execute de novo para verificar com a chave %s
nl|w_sigskip|release-handtekening NIET gecontroleerd: openssl.exe niet gevonden in PATH (Windows heeft geen ingebouwde Ed25519-controle), alleen SHA-256 is gecontroleerd. Installeer OpenSSL 3 en voer opnieuw uit om te controleren met sleutel %s
ru|w_sigskip|подпись релиза НЕ проверена: openssl.exe не найден в PATH (в Windows нет встроенной проверки Ed25519), проверена только SHA-256. Установите OpenSSL 3 и запустите снова, чтобы проверить по ключу %s
zh|w_sigskip|未校验发布签名：PATH 中找不到 openssl.exe（Windows 没有内置 Ed25519 校验），仅校验了 SHA-256。请安装 OpenSSL 3 并重新运行，以使用密钥 %s 校验
ar|w_sigskip|لم يتم التحقق من توقيع الإصدار: لم يتم العثور على openssl.exe في PATH (لا يوفر Windows تحققا مدمجا من Ed25519) وتم التحقق من SHA-256 فقط. ثبّت OpenSSL 3 وأعد التشغيل للتحقق بالمفتاح %s
en|done|Done.
fr|done|Terminé.
es|done|Hecho.
de|done|Fertig.
it|done|Fatto.
pt|done|Concluído.
nl|done|Klaar.
ru|done|Готово.
zh|done|完成。
ar|done|تم.
en|failed|Failed
fr|failed|Échec
es|failed|Error
de|failed|Fehlgeschlagen
it|failed|Fallito
pt|failed|Falhou
nl|failed|Mislukt
ru|failed|Ошибка
zh|failed|失败
ar|failed|فشل
en|log_hint|Full log: %s
fr|log_hint|Journal complet : %s
es|log_hint|Registro completo: %s
de|log_hint|Vollständiges Protokoll: %s
it|log_hint|Log completo: %s
pt|log_hint|Registo completo: %s
nl|log_hint|Volledig logboek: %s
ru|log_hint|Полный журнал: %s
zh|log_hint|完整日志：%s
ar|log_hint|السجل الكامل: %s
en|dry_done|Dry run: nothing was changed.
fr|dry_done|Simulation : rien n'a été modifié.
es|dry_done|Simulación: no se ha cambiado nada.
de|dry_done|Testlauf: nichts wurde geändert.
it|dry_done|Simulazione: nulla è stato modificato.
pt|dry_done|Simulação: nada foi alterado.
nl|dry_done|Proefrun: niets is gewijzigd.
ru|dry_done|Пробный запуск: ничего не изменено.
zh|dry_done|试运行：未做任何更改。
ar|dry_done|تشغيل تجريبي: لم يتم تغيير أي شيء.
en|sum_title|Installation summary
fr|sum_title|Récapitulatif de l'installation
es|sum_title|Resumen de la instalación
de|sum_title|Zusammenfassung der Installation
it|sum_title|Riepilogo dell'installazione
pt|sum_title|Resumo da instalação
nl|sum_title|Samenvatting van de installatie
ru|sum_title|Итоги установки
zh|sum_title|安装摘要
ar|sum_title|ملخص التثبيت
en|sum_panel|Panel links
fr|sum_panel|Liens du panneau
es|sum_panel|Enlaces del panel
de|sum_panel|Panel-Links
it|sum_panel|Link del pannello
pt|sum_panel|Ligações do painel
nl|sum_panel|Paneellinks
ru|sum_panel|Ссылки на панель
zh|sum_panel|面板链接
ar|sum_panel|روابط اللوحة
en|sum_tls_note|HTTPS only. The certificate is self-signed until you install your own: the browser will show a warning.
fr|sum_tls_note|HTTPS uniquement. Le certificat est auto-signé tant que vous n'installez pas le vôtre : le navigateur affichera un avertissement.
es|sum_tls_note|Solo HTTPS. El certificado es autofirmado hasta que instale el suyo: el navegador mostrará una advertencia.
de|sum_tls_note|Nur HTTPS. Das Zertifikat ist selbstsigniert, bis Sie ein eigenes installieren: der Browser warnt.
it|sum_tls_note|Solo HTTPS. Il certificato è autofirmato finché non installi il tuo: il browser mostrerà un avviso.
pt|sum_tls_note|Apenas HTTPS. O certificado é autoassinado até instalar o seu: o navegador mostrará um aviso.
nl|sum_tls_note|Alleen HTTPS. Het certificaat is zelfondertekend tot u uw eigen installeert: de browser toont een waarschuwing.
ru|sum_tls_note|Только HTTPS. Сертификат самоподписанный, пока вы не установите свой: браузер покажет предупреждение.
zh|sum_tls_note|仅 HTTPS。在安装您自己的证书之前使用自签名证书：浏览器会显示警告。
ar|sum_tls_note|HTTPS فقط. الشهادة موقعة ذاتيا حتى تثبت شهادتك: سيعرض المتصفح تحذيرا.
en|sum_local|Local addresses
fr|sum_local|Adresses locales
es|sum_local|Direcciones locales
de|sum_local|Lokale Adressen
it|sum_local|Indirizzi locali
pt|sum_local|Endereços locais
nl|sum_local|Lokale adressen
ru|sum_local|Локальные адреса
zh|sum_local|本地地址
ar|sum_local|العناوين المحلية
en|sum_public|Public address
fr|sum_public|Adresse publique
es|sum_public|Dirección pública
de|sum_public|Öffentliche Adresse
it|sum_public|Indirizzo pubblico
pt|sum_public|Endereço público
nl|sum_public|Publiek adres
ru|sum_public|Публичный адрес
zh|sum_public|公网地址
ar|sum_public|العنوان العام
en|sum_public_unknown|The public IP address could not be detected (offline or blocked). Use your server's public IP or DNS name instead of the local addresses, or re-run with --public-host.
fr|sum_public_unknown|L'adresse IP publique n'a pas pu être détectée (hors ligne ou bloquée). Utilisez l'IP publique ou le nom DNS de votre serveur à la place des adresses locales, ou relancez avec --public-host.
es|sum_public_unknown|No se pudo detectar la IP pública (sin conexión o bloqueada). Use la IP pública o el nombre DNS de su servidor en lugar de las direcciones locales, o vuelva a ejecutar con --public-host.
de|sum_public_unknown|Die öffentliche IP konnte nicht ermittelt werden (offline oder blockiert). Verwenden Sie die öffentliche IP oder den DNS-Namen Ihres Servers statt der lokalen Adressen oder starten Sie mit --public-host neu.
it|sum_public_unknown|Impossibile rilevare l'IP pubblico (offline o bloccato). Usa l'IP pubblico o il nome DNS del server al posto degli indirizzi locali, oppure riesegui con --public-host.
pt|sum_public_unknown|Não foi possível detetar o IP público (offline ou bloqueado). Use o IP público ou o nome DNS do servidor no lugar dos endereços locais, ou execute de novo com --public-host.
nl|sum_public_unknown|Het publieke IP kon niet worden gedetecteerd (offline of geblokkeerd). Gebruik het publieke IP of de DNS-naam van uw server in plaats van de lokale adressen, of voer opnieuw uit met --public-host.
ru|sum_public_unknown|Не удалось определить публичный IP (нет сети или блокировка). Используйте публичный IP или DNS-имя сервера вместо локальных адресов или запустите снова с --public-host.
zh|sum_public_unknown|无法检测公网 IP（离线或被拦截）。请使用服务器的公网 IP 或域名代替本地地址，或使用 --public-host 重新运行。
ar|sum_public_unknown|تعذر اكتشاف عنوان IP العام (دون اتصال أو محجوب). استخدم عنوان IP العام لخادمك أو اسم DNS بدلا من العناوين المحلية، أو أعد التشغيل مع --public-host.
en|sum_admin|Administrator account
fr|sum_admin|Compte administrateur
es|sum_admin|Cuenta de administrador
de|sum_admin|Administratorkonto
it|sum_admin|Account amministratore
pt|sum_admin|Conta de administrador
nl|sum_admin|Beheerdersaccount
ru|sum_admin|Учётная запись администратора
zh|sum_admin|管理员账户
ar|sum_admin|حساب المسؤول
en|sum_user|Username
fr|sum_user|Identifiant
es|sum_user|Usuario
de|sum_user|Benutzername
it|sum_user|Nome utente
pt|sum_user|Utilizador
nl|sum_user|Gebruikersnaam
ru|sum_user|Имя пользователя
zh|sum_user|用户名
ar|sum_user|اسم المستخدم
en|sum_password|Password
fr|sum_password|Mot de passe
es|sum_password|Contraseña
de|sum_password|Passwort
it|sum_password|Password
pt|sum_password|Palavra-passe
nl|sum_password|Wachtwoord
ru|sum_password|Пароль
zh|sum_password|密码
ar|sum_password|كلمة المرور
en|sum_pw_once|shown ONCE only - change it in Settings > Access / Account
fr|sum_pw_once|affiché UNE SEULE fois - modifiable dans Réglages > Accès / Compte
es|sum_pw_once|se muestra UNA sola vez - cámbiela en Ajustes > Acceso / Cuenta
de|sum_pw_once|wird nur EINMAL angezeigt - änderbar unter Einstellungen > Zugang / Konto
it|sum_pw_once|mostrata UNA sola volta - modificabile in Impostazioni > Accesso / Account
pt|sum_pw_once|mostrada apenas UMA vez - altere em Definições > Acesso / Conta
nl|sum_pw_once|slechts EENMAAL getoond - wijzig het in Instellingen > Toegang / Account
ru|sum_pw_once|показывается ТОЛЬКО ОДИН раз - измените в Настройки > Доступ / Аккаунт
zh|sum_pw_once|仅显示一次 - 可在 设置 > 访问 / 账户 中修改
ar|sum_pw_once|تظهر مرة واحدة فقط - يمكن تغييرها في الإعدادات > الوصول / الحساب
en|sum_pw_unchanged|unchanged (never regenerated). Reset it with: toutwaf-cp admin reset-password --user %s
fr|sum_pw_unchanged|inchangé (jamais régénéré). Réinitialisez-le avec : toutwaf-cp admin reset-password --user %s
es|sum_pw_unchanged|sin cambios (nunca se regenera). Restablézcala con: toutwaf-cp admin reset-password --user %s
de|sum_pw_unchanged|unverändert (wird nie neu erzeugt). Zurücksetzen mit: toutwaf-cp admin reset-password --user %s
it|sum_pw_unchanged|invariata (mai rigenerata). Reimpostala con: toutwaf-cp admin reset-password --user %s
pt|sum_pw_unchanged|inalterada (nunca regenerada). Reponha com: toutwaf-cp admin reset-password --user %s
nl|sum_pw_unchanged|ongewijzigd (nooit opnieuw gegenereerd). Reset met: toutwaf-cp admin reset-password --user %s
ru|sum_pw_unchanged|не изменён (никогда не генерируется заново). Сброс: toutwaf-cp admin reset-password --user %s
zh|sum_pw_unchanged|保持不变（不会重新生成）。重置命令：toutwaf-cp admin reset-password --user %s
ar|sum_pw_unchanged|دون تغيير (لا يعاد توليدها أبدا). لإعادة التعيين: toutwaf-cp admin reset-password --user %s
en|sum_setup|One-time setup link
fr|sum_setup|Lien d'installation à usage unique
es|sum_setup|Enlace de configuración de un solo uso
de|sum_setup|Einmaliger Einrichtungslink
it|sum_setup|Link di configurazione monouso
pt|sum_setup|Ligação de configuração de utilização única
nl|sum_setup|Eenmalige installatielink
ru|sum_setup|Одноразовая ссылка настройки
zh|sum_setup|一次性设置链接
ar|sum_setup|رابط الإعداد لمرة واحدة
en|sum_setup_note|Open it to configure the panel link, the account and the password in the web installer.
fr|sum_setup_note|Ouvrez-le pour configurer le lien du panneau, le compte et le mot de passe dans l'assistant web.
es|sum_setup_note|Ábralo para configurar el enlace del panel, la cuenta y la contraseña en el asistente web.
de|sum_setup_note|Öffnen Sie ihn, um Panel-Link, Konto und Passwort im Web-Assistenten festzulegen.
it|sum_setup_note|Aprilo per configurare il link del pannello, l'account e la password nell'installer web.
pt|sum_setup_note|Abra-a para configurar a ligação do painel, a conta e a palavra-passe no assistente web.
nl|sum_setup_note|Open hem om de paneellink, het account en het wachtwoord in de webinstallatie in te stellen.
ru|sum_setup_note|Откройте её, чтобы настроить ссылку панели, учётную запись и пароль в веб-установщике.
zh|sum_setup_note|打开它即可在 Web 安装向导中设置面板链接、账户和密码。
ar|sum_setup_note|افتحه لضبط رابط اللوحة والحساب وكلمة المرور في معالج الويب.
en|p_dpapi_warn|Port 9444 (data-plane API) is NOT opened: allow it only from your data-plane nodes
fr|p_dpapi_warn|Le port 9444 (API data plane) n'est PAS ouvert : autorisez-le uniquement depuis vos nœuds data plane
es|p_dpapi_warn|El puerto 9444 (API del data plane) NO está abierto: permítalo solo desde sus nodos data plane
de|p_dpapi_warn|Port 9444 (Data-Plane-API) ist NICHT geöffnet: nur von Ihren Data-Plane-Knoten freigeben
it|p_dpapi_warn|La porta 9444 (API data plane) NON è aperta: consentila solo dai tuoi nodi data plane
pt|p_dpapi_warn|A porta 9444 (API do data plane) NÃO está aberta: permita-a apenas a partir dos seus nós data plane
nl|p_dpapi_warn|Poort 9444 (data-plane-API) is NIET geopend: sta alleen toe vanuit uw data-plane-nodes
ru|p_dpapi_warn|Порт 9444 (API data plane) НЕ открыт: разрешайте его только с ваших узлов data plane
zh|p_dpapi_warn|端口 9444（数据平面 API）未开放：仅允许来自您的数据平面节点的访问
ar|p_dpapi_warn|المنفذ 9444 (واجهة data plane) غير مفتوح: اسمح به فقط من عقد data plane الخاصة بك
en|p_dpapi_only|9444/tcp only from your data planes, e.g.:
fr|p_dpapi_only|9444/tcp uniquement depuis vos data planes, par ex. :
es|p_dpapi_only|9444/tcp solo desde sus data planes, p. ej.:
de|p_dpapi_only|9444/tcp nur von Ihren Data Planes, z. B.:
it|p_dpapi_only|9444/tcp solo dai tuoi data plane, ad es.:
pt|p_dpapi_only|9444/tcp apenas a partir dos seus data planes, ex.:
nl|p_dpapi_only|9444/tcp alleen vanuit uw data planes, bijv.:
ru|p_dpapi_only|9444/tcp только с ваших data plane, например:
zh|p_dpapi_only|9444/tcp 仅允许来自您的数据平面，例如：
ar|p_dpapi_only|9444/tcp فقط من data planes الخاصة بك، مثال:
en|sum_setup_none|No setup link this time (already issued, or the account already existed). Create a new one with: toutwaf-cp setup-link --regenerate
fr|sum_setup_none|Pas de lien d'installation cette fois (déjà émis, ou compte déjà existant). Pour en créer un : toutwaf-cp setup-link --regenerate
es|sum_setup_none|Esta vez no hay enlace de configuración (ya emitido, o la cuenta ya existía). Cree uno con: toutwaf-cp setup-link --regenerate
de|sum_setup_none|Diesmal kein Einrichtungslink (bereits ausgestellt oder Konto bestand schon). Neu erzeugen: toutwaf-cp setup-link --regenerate
it|sum_setup_none|Nessun link di configurazione questa volta (già emesso, o account già esistente). Creane uno con: toutwaf-cp setup-link --regenerate
pt|sum_setup_none|Sem ligação de configuração desta vez (já emitida, ou a conta já existia). Crie uma com: toutwaf-cp setup-link --regenerate
nl|sum_setup_none|Nu geen installatielink (al uitgegeven, of account bestond al). Maak een nieuwe met: toutwaf-cp setup-link --regenerate
ru|sum_setup_none|Ссылки настройки сейчас нет (уже выдана или учётная запись уже существовала). Создать новую: toutwaf-cp setup-link --regenerate
zh|sum_setup_none|本次没有设置链接（已签发，或账户已存在）。重新生成：toutwaf-cp setup-link --regenerate
ar|sum_setup_none|لا يوجد رابط إعداد هذه المرة (صدر سابقا أو الحساب موجود). لإنشاء رابط جديد: toutwaf-cp setup-link --regenerate
en|sum_ports|Ports to open in the firewall
fr|sum_ports|Ports à ouvrir dans le pare-feu
es|sum_ports|Puertos a abrir en el cortafuegos
de|sum_ports|In der Firewall zu öffnende Ports
it|sum_ports|Porte da aprire nel firewall
pt|sum_ports|Portas a abrir na firewall
nl|sum_ports|Te openen poorten in de firewall
ru|sum_ports|Порты для открытия в брандмауэре
zh|sum_ports|需要在防火墙放行的端口
ar|sum_ports|المنافذ المطلوب فتحها في جدار الحماية
en|sum_cmds|Commands
fr|sum_cmds|Commandes
es|sum_cmds|Comandos
de|sum_cmds|Befehle
it|sum_cmds|Comandi
pt|sum_cmds|Comandos
nl|sum_cmds|Opdrachten
ru|sum_cmds|Команды
zh|sum_cmds|命令
ar|sum_cmds|الأوامر
en|sum_cloud|Cloud / hosting: also open these ports in the provider's security group / network ACL.
fr|sum_cloud|Cloud / hébergeur : ouvrez aussi ces ports dans le groupe de sécurité / les ACL réseau du fournisseur.
es|sum_cloud|Nube / hosting: abra también estos puertos en el grupo de seguridad / ACL de red del proveedor.
de|sum_cloud|Cloud / Hosting: Öffnen Sie diese Ports auch in der Sicherheitsgruppe / Netzwerk-ACL des Anbieters.
it|sum_cloud|Cloud / hosting: apri queste porte anche nel security group / ACL di rete del provider.
pt|sum_cloud|Cloud / alojamento: abra também estas portas no grupo de segurança / ACL de rede do fornecedor.
nl|sum_cloud|Cloud / hosting: open deze poorten ook in de beveiligingsgroep / netwerk-ACL van de provider.
ru|sum_cloud|Облако / хостинг: откройте эти порты также в группе безопасности / сетевом ACL провайдера.
zh|sum_cloud|云服务器 / 托管：还需在服务商的安全组 / 网络 ACL 中放行这些端口。
ar|sum_cloud|السحابة / الاستضافة: افتح هذه المنافذ أيضا في مجموعة الأمان / قائمة ACL لدى المزود.
en|sum_file|Summary saved (root only): %s
fr|sum_file|Récapitulatif enregistré (root uniquement) : %s
es|sum_file|Resumen guardado (solo root): %s
de|sum_file|Zusammenfassung gespeichert (nur root): %s
it|sum_file|Riepilogo salvato (solo root): %s
pt|sum_file|Resumo guardado (apenas root): %s
nl|sum_file|Samenvatting opgeslagen (alleen root): %s
ru|sum_file|Итоги сохранены (только root): %s
zh|sum_file|摘要已保存（仅 root 可读）：%s
ar|sum_file|تم حفظ الملخص (root فقط): %s
en|sum_fallback|This control plane has no 'bootstrap' command yet: open the console URL and follow the setup page.
fr|sum_fallback|Ce plan de contrôle n'a pas encore de commande 'bootstrap' : ouvrez l'URL de la console et suivez la page de configuration.
es|sum_fallback|Este plano de control aún no tiene el comando 'bootstrap': abra la URL de la consola y siga la página de configuración.
de|sum_fallback|Diese Control Plane hat noch kein 'bootstrap'-Kommando: öffnen Sie die Konsolen-URL und folgen Sie der Einrichtungsseite.
it|sum_fallback|Questo control plane non ha ancora il comando 'bootstrap': apri l'URL della console e segui la pagina di configurazione.
pt|sum_fallback|Este plano de controlo ainda não tem o comando 'bootstrap': abra a URL da consola e siga a página de configuração.
nl|sum_fallback|Deze control plane heeft nog geen 'bootstrap'-opdracht: open de console-URL en volg de installatiepagina.
ru|sum_fallback|У этого control plane пока нет команды 'bootstrap': откройте URL консоли и следуйте странице настройки.
zh|sum_fallback|该控制平面尚无 'bootstrap' 命令：请打开控制台地址并按设置页面操作。
ar|sum_fallback|مستوى التحكم هذا لا يتضمن أمر 'bootstrap' بعد: افتح عنوان لوحة التحكم واتبع صفحة الإعداد.
en|sum_node_hint|To manage this node from the console: Nodes > Add node, then set control_plane.url / enroll_token in %s.
fr|sum_node_hint|Pour piloter ce nœud depuis la console : Nœuds > Ajouter un nœud, puis renseignez control_plane.url / enroll_token dans %s.
es|sum_node_hint|Para gestionar este nodo desde la consola: Nodos > Agregar nodo y configure control_plane.url / enroll_token en %s.
de|sum_node_hint|Um diesen Knoten über die Konsole zu verwalten: Knoten > Knoten hinzufügen, dann control_plane.url / enroll_token in %s setzen.
it|sum_node_hint|Per gestire questo nodo dalla console: Nodi > Aggiungi nodo, poi imposta control_plane.url / enroll_token in %s.
pt|sum_node_hint|Para gerir este nó a partir da consola: Nós > Adicionar nó e defina control_plane.url / enroll_token em %s.
nl|sum_node_hint|Om deze node via de console te beheren: Nodes > Node toevoegen, stel daarna control_plane.url / enroll_token in %s in.
ru|sum_node_hint|Чтобы управлять этим узлом из консоли: Узлы > Добавить узел, затем задайте control_plane.url / enroll_token в %s.
zh|sum_node_hint|要在控制台管理此节点：节点 > 添加节点，然后在 %s 中设置 control_plane.url / enroll_token。
ar|sum_node_hint|لإدارة هذه العقدة من لوحة التحكم: العقد > إضافة عقدة، ثم اضبط control_plane.url / enroll_token في %s.
en|q_fwmodule|Do you also want ToutWAF to manage this machine's firewall?
fr|q_fwmodule|Voulez-vous aussi que ToutWAF gère le pare-feu de cette machine ?
es|q_fwmodule|¿Quiere que ToutWAF gestione también el cortafuegos de esta máquina?
de|q_fwmodule|Soll ToutWAF auch die Firewall dieses Rechners verwalten?
it|q_fwmodule|Vuoi che ToutWAF gestisca anche il firewall di questa macchina?
pt|q_fwmodule|Quer que o ToutWAF também faça a gestão da firewall desta máquina?
nl|q_fwmodule|Wilt u dat ToutWAF ook de firewall van deze machine beheert?
ru|q_fwmodule|Хотите, чтобы ToutWAF также управлял брандмауэром этой машины?
zh|q_fwmodule|是否也让 ToutWAF 管理本机的防火墙？
ar|q_fwmodule|هل تريد أن يدير ToutWAF جدار الحماية لهذا الجهاز أيضا؟
en|fwmod_n1|Optional module, off unless you say yes. Nothing is applied during the installation: you review every change in the console.
fr|fwmod_n1|Module optionnel, éteint sauf si vous répondez oui. Rien n'est appliqué pendant l'installation : vous relisez chaque changement dans la console.
es|fwmod_n1|Módulo opcional, apagado salvo que diga sí. No se aplica nada durante la instalación: revisa cada cambio en la consola.
de|fwmod_n1|Optionales Modul, aus, außer Sie sagen ja. Während der Installation wird nichts angewendet: Sie prüfen jede Änderung in der Konsole.
it|fwmod_n1|Modulo opzionale, spento salvo risposta affermativa. Durante l'installazione non viene applicato nulla: ogni modifica si rivede nella console.
pt|fwmod_n1|Módulo opcional, desligado a não ser que diga que sim. Nada é aplicado durante a instalação: revê cada alteração na consola.
nl|fwmod_n1|Optionele module, uit tenzij u ja zegt. Tijdens de installatie wordt niets toegepast: u controleert elke wijziging in de console.
ru|fwmod_n1|Необязательный модуль, выключен, если вы не ответите «да». Во время установки ничего не применяется: каждое изменение вы проверяете в консоли.
zh|fwmod_n1|可选模块，除非回答“是”否则保持关闭。安装期间不会应用任何规则：每项更改都在控制台中审核。
ar|fwmod_n1|وحدة اختيارية، متوقفة ما لم تجب بنعم. لا يُطبَّق شيء أثناء التثبيت: تراجع كل تغيير في لوحة التحكم.
en|s_bkclient|Installing the ToutWAF Backup client (signature checked)
fr|s_bkclient|Installation du client ToutWAF Backup (signature vérifiée)
es|s_bkclient|Instalando el cliente ToutWAF Backup (firma verificada)
de|s_bkclient|ToutWAF-Backup-Client wird installiert (Signatur geprüft)
it|s_bkclient|Installazione del client ToutWAF Backup (firma verificata)
pt|s_bkclient|A instalar o cliente ToutWAF Backup (assinatura verificada)
nl|s_bkclient|ToutWAF Backup-client wordt geïnstalleerd (handtekening gecontroleerd)
ru|s_bkclient|Установка клиента ToutWAF Backup (подпись проверена)
zh|s_bkclient|正在安装 ToutWAF Backup 客户端（已校验签名）
ar|s_bkclient|تثبيت عميل ToutWAF Backup (تم التحقق من التوقيع)
en|bkc_done|ToutWAF Backup client installed. Next: console, Backups > Backup servers, to pair a backup server.
fr|bkc_done|Client ToutWAF Backup installé. Étape suivante : console, Sauvegardes > Serveurs de sauvegarde, pour associer un serveur.
es|bkc_done|Cliente ToutWAF Backup instalado. Siguiente: consola, Copias > Servidores de copia, para vincular un servidor.
de|bkc_done|ToutWAF-Backup-Client installiert. Weiter: Konsole, Backups > Backup-Server, um einen Server zu koppeln.
it|bkc_done|Client ToutWAF Backup installato. Poi: console, Backup > Server di backup, per associare un server.
pt|bkc_done|Cliente ToutWAF Backup instalado. Seguinte: consola, Cópias > Servidores de cópia, para associar um servidor.
nl|bkc_done|ToutWAF Backup-client geïnstalleerd. Volgende stap: console, Back-ups > Back-upservers, om een server te koppelen.
ru|bkc_done|Клиент ToutWAF Backup установлен. Далее: консоль, Резервные копии > Серверы копирования, чтобы привязать сервер.
zh|bkc_done|ToutWAF Backup 客户端已安装。下一步：控制台“备份 > 备份服务器”，配对备份服务器。
ar|bkc_done|تم تثبيت عميل ToutWAF Backup. التالي: الوحدة، النسخ الاحتياطي > خوادم النسخ، لربط خادم.
en|bkc_fail|The ToutWAF Backup client was NOT installed (%s). The installation goes on; install it later with --with-backup-client.
fr|bkc_fail|Le client ToutWAF Backup n’a PAS été installé (%s). L’installation continue ; installez-le plus tard avec --with-backup-client.
es|bkc_fail|El cliente ToutWAF Backup NO se instaló (%s). La instalación continúa; instálelo después con --with-backup-client.
de|bkc_fail|Der ToutWAF-Backup-Client wurde NICHT installiert (%s). Die Installation läuft weiter; später mit --with-backup-client nachholen.
it|bkc_fail|Il client ToutWAF Backup NON è stato installato (%s). L’installazione prosegue; installalo più tardi con --with-backup-client.
pt|bkc_fail|O cliente ToutWAF Backup NÃO foi instalado (%s). A instalação continua; instale-o depois com --with-backup-client.
nl|bkc_fail|De ToutWAF Backup-client is NIET geïnstalleerd (%s). De installatie gaat door; installeer hem later met --with-backup-client.
ru|bkc_fail|Клиент ToutWAF Backup НЕ установлен (%s). Установка продолжается; установите его позже с --with-backup-client.
zh|bkc_fail|ToutWAF Backup 客户端未安装（%s）。安装继续；稍后可用 --with-backup-client 安装。
ar|bkc_fail|لم يتم تثبيت عميل ToutWAF Backup (%s). يستمر التثبيت؛ ثبّته لاحقا باستخدام --with-backup-client.
en|bkc_nokey|The ToutWAF Backup client was NOT installed: no release public key. Give it with --backup-client-pubkey (or TOUTWAF_BACKUP_PUBKEY, or the file backup-release.pub in the configuration folder); nothing is installed without a verified signature.
fr|bkc_nokey|Le client ToutWAF Backup n’a PAS été installé : aucune clé publique de version. Donnez-la avec --backup-client-pubkey (ou TOUTWAF_BACKUP_PUBKEY, ou le fichier backup-release.pub du dossier de configuration) ; rien n’est installé sans signature vérifiée.
es|bkc_nokey|El cliente ToutWAF Backup NO se instaló: falta la clave pública de la versión. Indíquela con --backup-client-pubkey (o TOUTWAF_BACKUP_PUBKEY, o el archivo backup-release.pub de la carpeta de configuración); nada se instala sin firma verificada.
de|bkc_nokey|Der ToutWAF-Backup-Client wurde NICHT installiert: kein öffentlicher Release-Schlüssel. Angeben mit --backup-client-pubkey (oder TOUTWAF_BACKUP_PUBKEY oder der Datei backup-release.pub im Konfigurationsordner); ohne geprüfte Signatur wird nichts installiert.
it|bkc_nokey|Il client ToutWAF Backup NON è stato installato: manca la chiave pubblica della release. Indicala con --backup-client-pubkey (o TOUTWAF_BACKUP_PUBKEY, o il file backup-release.pub nella cartella di configurazione); senza firma verificata non si installa nulla.
pt|bkc_nokey|O cliente ToutWAF Backup NÃO foi instalado: falta a chave pública da versão. Indique-a com --backup-client-pubkey (ou TOUTWAF_BACKUP_PUBKEY, ou o ficheiro backup-release.pub na pasta de configuração); nada é instalado sem assinatura verificada.
nl|bkc_nokey|De ToutWAF Backup-client is NIET geïnstalleerd: geen publieke releasesleutel. Geef die op met --backup-client-pubkey (of TOUTWAF_BACKUP_PUBKEY, of het bestand backup-release.pub in de configuratiemap); zonder gecontroleerde handtekening wordt niets geïnstalleerd.
ru|bkc_nokey|Клиент ToutWAF Backup НЕ установлен: нет открытого ключа релиза. Укажите его через --backup-client-pubkey (или TOUTWAF_BACKUP_PUBKEY, или файл backup-release.pub в каталоге конфигурации); без проверенной подписи ничего не устанавливается.
zh|bkc_nokey|ToutWAF Backup 客户端未安装：缺少发布公钥。请用 --backup-client-pubkey（或 TOUTWAF_BACKUP_PUBKEY，或配置目录中的 backup-release.pub）提供；没有通过校验的签名就不会安装任何内容。
ar|bkc_nokey|لم يتم تثبيت عميل ToutWAF Backup: لا يوجد مفتاح عام للإصدار. مرّره عبر --backup-client-pubkey (أو TOUTWAF_BACKUP_PUBKEY أو الملف backup-release.pub في مجلد الإعدادات)؛ لا يُثبَّت شيء دون توقيع مُتحقَّق منه.
en|bkc_badsig|The ToutWAF Backup client was NOT installed: the signature of the release is NOT valid. Nothing was installed.
fr|bkc_badsig|Le client ToutWAF Backup n’a PAS été installé : la signature de la version n’est PAS valide. Rien n’a été installé.
es|bkc_badsig|El cliente ToutWAF Backup NO se instaló: la firma de la versión NO es válida. No se instaló nada.
de|bkc_badsig|Der ToutWAF-Backup-Client wurde NICHT installiert: die Signatur der Version ist NICHT gültig. Es wurde nichts installiert.
it|bkc_badsig|Il client ToutWAF Backup NON è stato installato: la firma della release NON è valida. Non è stato installato nulla.
pt|bkc_badsig|O cliente ToutWAF Backup NÃO foi instalado: a assinatura da versão NÃO é válida. Nada foi instalado.
nl|bkc_badsig|De ToutWAF Backup-client is NIET geïnstalleerd: de handtekening van de release is NIET geldig. Er is niets geïnstalleerd.
ru|bkc_badsig|Клиент ToutWAF Backup НЕ установлен: подпись релиза НЕДЕЙСТВИТЕЛЬНА. Ничего не установлено.
zh|bkc_badsig|ToutWAF Backup 客户端未安装：发布签名无效。未安装任何内容。
ar|bkc_badsig|لم يتم تثبيت عميل ToutWAF Backup: توقيع الإصدار غير صالح. لم يُثبَّت شيء.
en|tele_on|Telemetry: by default ToutWAF shares with the publisher space (app.toutwaf.com) the attacks it blocked (attacker address, country, type of attack, rule) and aggregate figures, and the host names of the protected sites. Never the content of requests, never legitimate visitors. Switch it off in one click in the console (Settings, Privacy and telemetry), or install with --no-telemetry (or TOUTWAF_TELEMETRY=0) for zero telemetry. Details: docs/confidentialite-telemetrie.md
fr|tele_on|Télémétrie : par défaut, ToutWAF partage avec l'espace éditeur (app.toutwaf.com) les attaques qu'il a bloquées (adresse de l'attaquant, pays, type d'attaque, règle), des chiffres agrégés et les noms d'hôte des sites protégés. Jamais le contenu des requêtes ni les visiteurs légitimes. Désactivable en un clic dans la console (Paramètres, Confidentialité et télémétrie), ou installez avec --no-telemetry (ou TOUTWAF_TELEMETRY=0) pour une télémétrie zéro. Détails : docs/confidentialite-telemetrie.md
es|tele_on|Telemetría: por defecto ToutWAF comparte con el espacio del editor (app.toutwaf.com) los ataques que bloqueó (dirección del atacante, país, tipo de ataque, regla), cifras agregadas y los nombres de host de los sitios protegidos. Nunca el contenido de las solicitudes ni a los visitantes legítimos. Se desactiva con un clic en la consola (Ajustes, Privacidad y telemetría), o instale con --no-telemetry (o TOUTWAF_TELEMETRY=0) para telemetría cero. Detalles: docs/confidentialite-telemetrie.md
de|tele_on|Telemetrie: Standardmäßig teilt ToutWAF mit dem Herausgeberbereich (app.toutwaf.com) die blockierten Angriffe (Adresse des Angreifers, Land, Angriffsart, Regel), aggregierte Zahlen und die Hostnamen der geschützten Sites. Niemals den Inhalt von Anfragen und niemals legitime Besucher. Mit einem Klick in der Konsole abschaltbar (Einstellungen, Datenschutz und Telemetrie), oder installieren Sie mit --no-telemetry (oder TOUTWAF_TELEMETRY=0) für Null-Telemetrie. Details: docs/confidentialite-telemetrie.md
it|tele_on|Telemetria: per impostazione predefinita ToutWAF condivide con lo spazio dell'editore (app.toutwaf.com) gli attacchi bloccati (indirizzo dell'attaccante, paese, tipo di attacco, regola), cifre aggregate e i nomi host dei siti protetti. Mai il contenuto delle richieste né i visitatori legittimi. Disattivabile con un clic nella console (Impostazioni, Privacy e telemetria), oppure installa con --no-telemetry (o TOUTWAF_TELEMETRY=0) per la telemetria zero. Dettagli: docs/confidentialite-telemetrie.md
pt|tele_on|Telemetria: por predefinição, o ToutWAF partilha com o espaço do editor (app.toutwaf.com) os ataques que bloqueou (endereço do atacante, país, tipo de ataque, regra), números agregados e os nomes de anfitrião dos sites protegidos. Nunca o conteúdo dos pedidos nem os visitantes legítimos. Desativável com um clique na consola (Definições, Privacidade e telemetria), ou instale com --no-telemetry (ou TOUTWAF_TELEMETRY=0) para telemetria zero. Detalhes: docs/confidentialite-telemetrie.md
nl|tele_on|Telemetrie: standaard deelt ToutWAF met de ruimte van de uitgever (app.toutwaf.com) de geblokkeerde aanvallen (adres van de aanvaller, land, type aanval, regel), geaggregeerde cijfers en de hostnamen van de beschermde sites. Nooit de inhoud van verzoeken en nooit legitieme bezoekers. Met één klik uit te zetten in de console (Instellingen, Privacy en telemetrie), of installeer met --no-telemetry (of TOUTWAF_TELEMETRY=0) voor nultelemetrie. Details: docs/confidentialite-telemetrie.md
ru|tele_on|Телеметрия: по умолчанию ToutWAF передаёт пространству издателя (app.toutwaf.com) заблокированные атаки (адрес атакующего, страна, тип атаки, правило), агрегированные цифры и имена хостов защищаемых сайтов. Никогда содержимое запросов и никогда законных посетителей. Отключается одним щелчком в консоли (Настройки, Конфиденциальность и телеметрия), либо установите с --no-telemetry (или TOUTWAF_TELEMETRY=0) для нулевой телеметрии. Подробности: docs/confidentialite-telemetrie.md
zh|tele_on|遥测：默认情况下，ToutWAF 会与发布方空间（app.toutwaf.com）共享其拦截的攻击（攻击者地址、国家、攻击类型、规则）、汇总数据以及受保护站点的主机名。绝不包含请求内容，也绝不包含合法访客。可在控制台中一键关闭（设置 > 隐私与遥测），或使用 --no-telemetry（或 TOUTWAF_TELEMETRY=0）安装以获得零遥测。详情：docs/confidentialite-telemetrie.md
ar|tele_on|القياس عن بُعد: يشارك ToutWAF افتراضيًا مع فضاء الناشر (app.toutwaf.com) الهجمات التي حجبها (عنوان المهاجم والبلد ونوع الهجوم والقاعدة) وأرقامًا مجمّعة وأسماء مضيفي المواقع المحمية. لا محتوى الطلبات أبدًا ولا الزوار الشرعيين. يمكن إيقافه بنقرة في الوحدة (الإعدادات، الخصوصية والقياس عن بُعد) أو ثبّت مع --no-telemetry (أو TOUTWAF_TELEMETRY=0) للحصول على قياس صفري. التفاصيل: docs/confidentialite-telemetrie.md
en|tele_off|Telemetry: zero telemetry was requested (--no-telemetry / TOUTWAF_TELEMETRY=0). Nothing will be sent to the publisher space, nothing will be received from it, and the console starts with the "Zero telemetry" switch on. You can change this later in the console (Settings, Privacy and telemetry).
fr|tele_off|Télémétrie : la télémétrie zéro a été demandée (--no-telemetry / TOUTWAF_TELEMETRY=0). Rien ne sera envoyé à l'espace éditeur, rien n'en sera reçu, et la console démarre avec l'interrupteur « Télémétrie zéro » activé. Vous pourrez changer cela plus tard dans la console (Paramètres, Confidentialité et télémétrie).
es|tele_off|Telemetría: se pidió telemetría cero (--no-telemetry / TOUTWAF_TELEMETRY=0). No se enviará nada al espacio del editor, no se recibirá nada de él y la consola arrancará con el interruptor «Telemetría cero» activado. Podrá cambiarlo más tarde en la consola (Ajustes, Privacidad y telemetría).
de|tele_off|Telemetrie: Null-Telemetrie wurde angefordert (--no-telemetry / TOUTWAF_TELEMETRY=0). Es wird nichts an den Herausgeberbereich gesendet und nichts von ihm empfangen; die Konsole startet mit aktivem Schalter „Null-Telemetrie“. Sie können das später in der Konsole ändern (Einstellungen, Datenschutz und Telemetrie).
it|tele_off|Telemetria: è stata richiesta la telemetria zero (--no-telemetry / TOUTWAF_TELEMETRY=0). Non verrà inviato nulla allo spazio dell'editore né ricevuto da esso, e la console parte con l'interruttore «Telemetria zero» attivo. Potrai cambiarlo più tardi nella console (Impostazioni, Privacy e telemetria).
pt|tele_off|Telemetria: foi pedida a telemetria zero (--no-telemetry / TOUTWAF_TELEMETRY=0). Nada será enviado ao espaço do editor nem recebido dele, e a consola arranca com o interruptor «Telemetria zero» ativo. Poderá alterá-lo mais tarde na consola (Definições, Privacidade e telemetria).
nl|tele_off|Telemetrie: nultelemetrie is aangevraagd (--no-telemetry / TOUTWAF_TELEMETRY=0). Er wordt niets naar de ruimte van de uitgever gestuurd en niets van hem ontvangen; de console start met de schakelaar «Nultelemetrie» aan. U kunt dit later wijzigen in de console (Instellingen, Privacy en telemetrie).
ru|tele_off|Телеметрия: запрошена нулевая телеметрия (--no-telemetry / TOUTWAF_TELEMETRY=0). Ничего не будет отправлено в пространство издателя и ничего не будет получено от него; консоль запустится с включённым переключателем «Нулевая телеметрия». Позже это можно изменить в консоли (Настройки, Конфиденциальность и телеметрия).
zh|tele_off|遥测：已请求零遥测（--no-telemetry / TOUTWAF_TELEMETRY=0）。不会向发布方空间发送任何内容，也不会从它接收任何内容；控制台启动时“零遥测”开关为开启状态。您以后可在控制台中更改（设置 > 隐私与遥测）。
ar|tele_off|القياس عن بُعد: طُلب القياس الصفري (--no-telemetry / TOUTWAF_TELEMETRY=0). لن يُرسل شيء إلى فضاء الناشر ولن يُستقبل منه شيء، وتبدأ الوحدة والمفتاح «القياس الصفري» مفعّل. يمكنك تغيير ذلك لاحقًا في الوحدة (الإعدادات، الخصوصية والقياس عن بُعد).
en|fwmod_n2|Every change runs as a trial with a countdown and rolls back by itself unless you keep it; an anti-lockout guard refuses any rule that would cut SSH or the console.
fr|fwmod_n2|Chaque changement passe par un essai avec compte à rebours et revient en arrière tout seul si vous ne le gardez pas ; un garde-fou anti-lockout refuse toute règle qui couperait SSH ou la console.
es|fwmod_n2|Cada cambio se prueba con cuenta atrás y se revierte solo si no lo conserva; una protección anti-bloqueo rechaza toda regla que cortaría SSH o la consola.
de|fwmod_n2|Jede Änderung läuft als Test mit Countdown und wird von selbst zurückgenommen, wenn Sie sie nicht behalten; ein Aussperrschutz lehnt jede Regel ab, die SSH oder die Konsole kappen würde.
it|fwmod_n2|Ogni modifica passa da una prova con conto alla rovescia e torna indietro da sola se non la conservi; una protezione anti-lockout rifiuta ogni regola che taglierebbe SSH o la console.
pt|fwmod_n2|Cada alteração passa por um ensaio com contagem decrescente e volta atrás sozinha se não a mantiver; uma proteção anti-bloqueio recusa qualquer regra que cortaria o SSH ou a consola.
nl|fwmod_n2|Elke wijziging draait als proef met aftelling en wordt vanzelf teruggedraaid als u haar niet behoudt; een anti-lockout-beveiliging weigert elke regel die SSH of de console zou afsnijden.
ru|fwmod_n2|Каждое изменение проходит пробный период с обратным отсчётом и откатывается само, если вы его не сохраните; защита от блокировки отклоняет любое правило, которое отрезало бы SSH или консоль.
zh|fwmod_n2|每项更改都先试用并倒计时，若不保留会自动回退；防锁死保护会拒绝任何可能切断 SSH 或控制台的规则。
ar|fwmod_n2|كل تغيير يمر بتجربة مع عد تنازلي ويتراجع تلقائيا ما لم تحتفظ به؛ وتمنع حماية مضادة للإقفال أي قاعدة قد تقطع SSH أو لوحة التحكم.
en|fwmod_n3|This is not the question above, which only opens the ports ToutWAF needs in the system firewall (--no-firewall).
fr|fwmod_n3|Ce n'est pas la question précédente, qui ouvre seulement les ports dont ToutWAF a besoin dans le pare-feu du système (--no-firewall).
es|fwmod_n3|No es la pregunta anterior, que solo abre los puertos que ToutWAF necesita en el cortafuegos del sistema (--no-firewall).
de|fwmod_n3|Das ist nicht die Frage davor, die nur die von ToutWAF benötigten Ports in der System-Firewall öffnet (--no-firewall).
it|fwmod_n3|Non è la domanda precedente, che apre solo le porte necessarie a ToutWAF nel firewall di sistema (--no-firewall).
pt|fwmod_n3|Não é a pergunta anterior, que apenas abre as portas de que o ToutWAF precisa na firewall do sistema (--no-firewall).
nl|fwmod_n3|Dit is niet de vorige vraag, die alleen de poorten opent die ToutWAF nodig heeft in de systeemfirewall (--no-firewall).
ru|fwmod_n3|Это не предыдущий вопрос, который лишь открывает нужные ToutWAF порты в системном брандмауэре (--no-firewall).
zh|fwmod_n3|这不同于上一个问题（它只在系统防火墙中放行 ToutWAF 需要的端口，对应 --no-firewall）。
ar|fwmod_n3|هذا ليس السؤال السابق الذي يفتح فقط المنافذ التي يحتاجها ToutWAF في جدار حماية النظام (--no-firewall).
en|s_fwmod|Enabling the firewall module (no rule applied)
fr|s_fwmod|Activation du module pare-feu (aucune règle appliquée)
es|s_fwmod|Activando el módulo de cortafuegos (ninguna regla aplicada)
de|s_fwmod|Firewall-Modul wird aktiviert (keine Regel angewendet)
it|s_fwmod|Attivazione del modulo firewall (nessuna regola applicata)
pt|s_fwmod|A ativar o módulo de firewall (nenhuma regra aplicada)
nl|s_fwmod|Firewallmodule wordt ingeschakeld (geen regel toegepast)
ru|s_fwmod|Включение модуля брандмауэра (правила не применяются)
zh|s_fwmod|正在启用防火墙模块（不应用任何规则）
ar|s_fwmod|تفعيل وحدة جدار الحماية (دون تطبيق أي قاعدة)
en|fwmod_done|Firewall module enabled. Nothing was applied: open Firewall in the console to review and try rules.
fr|fwmod_done|Module pare-feu activé. Rien n'a été appliqué : ouvrez Pare-feu dans la console pour relire et essayer des règles.
es|fwmod_done|Módulo de cortafuegos activado. No se aplicó nada: abra Cortafuegos en la consola para revisar y probar reglas.
de|fwmod_done|Firewall-Modul aktiviert. Es wurde nichts angewendet: Öffnen Sie Firewall in der Konsole, um Regeln zu prüfen und zu testen.
it|fwmod_done|Modulo firewall attivato. Non è stato applicato nulla: apri Firewall nella console per rivedere e provare le regole.
pt|fwmod_done|Módulo de firewall ativado. Nada foi aplicado: abra Firewall na consola para rever e testar regras.
nl|fwmod_done|Firewallmodule ingeschakeld. Er is niets toegepast: open Firewall in de console om regels te bekijken en te proberen.
ru|fwmod_done|Модуль брандмауэра включён. Ничего не применено: откройте «Брандмауэр» в консоли, чтобы проверить и опробовать правила.
zh|fwmod_done|防火墙模块已启用。未应用任何规则：请在控制台打开“防火墙”来审核并试用规则。
ar|fwmod_done|تم تفعيل وحدة جدار الحماية. لم يُطبَّق شيء: افتح «جدار الحماية» في لوحة التحكم لمراجعة القواعد وتجربتها.
en|fwmod_fail|Could not enable the firewall module (%s). The installation goes on; switch it on later in Settings > Modules.
fr|fwmod_fail|Impossible d'activer le module pare-feu (%s). L'installation continue ; activez-le plus tard dans Paramètres > Modules.
es|fwmod_fail|No se pudo activar el módulo de cortafuegos (%s). La instalación continúa; actívelo después en Ajustes > Módulos.
de|fwmod_fail|Das Firewall-Modul konnte nicht aktiviert werden (%s). Die Installation läuft weiter; aktivieren Sie es später unter Einstellungen > Module.
it|fwmod_fail|Impossibile attivare il modulo firewall (%s). L'installazione prosegue; attivalo più tardi in Impostazioni > Moduli.
pt|fwmod_fail|Não foi possível ativar o módulo de firewall (%s). A instalação continua; ative-o depois em Definições > Módulos.
nl|fwmod_fail|Het firewallmodule kon niet worden ingeschakeld (%s). De installatie gaat door; schakel het later in via Instellingen > Modules.
ru|fwmod_fail|Не удалось включить модуль брандмауэра (%s). Установка продолжается; включите его позже в «Настройки > Модули».
zh|fwmod_fail|无法启用防火墙模块（%s）。安装继续；稍后可在“设置 > 模块”中启用。
ar|fwmod_fail|تعذّر تفعيل وحدة جدار الحماية (%s). يستمر التثبيت؛ فعّلها لاحقا من الإعدادات > الوحدات.
en|s_link|Linking the data plane to the console
fr|s_link|Liaison du plan de données à la console
es|s_link|Vinculando el plano de datos a la consola
de|s_link|Data Plane wird mit der Konsole verbunden
it|s_link|Collegamento del data plane alla console
pt|s_link|A ligar o plano de dados à consola
nl|s_link|Dataplane koppelen aan de console
ru|s_link|Привязка плоскости данных к консоли
zh|s_link|正在将数据平面关联到控制台
ar|s_link|ربط مستوى البيانات بلوحة التحكم
en|dp_link_ok|Data plane linked to the console automatically: nothing to configure by hand.
fr|dp_link_ok|Plan de données lié automatiquement à la console : rien à configurer à la main.
es|dp_link_ok|Plano de datos vinculado automáticamente a la consola: nada que configurar a mano.
de|dp_link_ok|Data Plane automatisch mit der Konsole verbunden: nichts von Hand zu konfigurieren.
it|dp_link_ok|Data plane collegato automaticamente alla console: nulla da configurare a mano.
pt|dp_link_ok|Plano de dados ligado automaticamente à consola: nada a configurar à mão.
nl|dp_link_ok|Dataplane automatisch aan de console gekoppeld: niets handmatig te configureren.
ru|dp_link_ok|Плоскость данных автоматически привязана к консоли: вручную настраивать ничего не нужно.
zh|dp_link_ok|数据平面已自动关联到控制台：无需手动配置。
ar|dp_link_ok|تم ربط مستوى البيانات بلوحة التحكم تلقائيًا: لا شيء لضبطه يدويًا.
en|dp_link_same|Data plane already linked to the console; its configuration was not touched.
fr|dp_link_same|Plan de données déjà lié à la console ; sa configuration n'a pas été modifiée.
es|dp_link_same|El plano de datos ya está vinculado a la consola; su configuración no se modificó.
de|dp_link_same|Data Plane bereits mit der Konsole verbunden; die Konfiguration blieb unverändert.
it|dp_link_same|Data plane già collegato alla console; la sua configurazione non è stata modificata.
pt|dp_link_same|O plano de dados já está ligado à consola; a configuração não foi alterada.
nl|dp_link_same|Dataplane is al aan de console gekoppeld; de configuratie is ongewijzigd gelaten.
ru|dp_link_same|Плоскость данных уже привязана к консоли; её конфигурация не изменена.
zh|dp_link_same|数据平面已关联到控制台；其配置未作修改。
ar|dp_link_same|مستوى البيانات مرتبط بلوحة التحكم بالفعل؛ لم يتم تعديل تكوينه.
en|dp_link_fixed|Data-plane configuration repaired (duplicated control_plane blocks merged into one); the previous file was kept.
fr|dp_link_fixed|Configuration du plan de données réparée (blocs control_plane en double fusionnés en un seul) ; l'ancien fichier est conservé.
es|dp_link_fixed|Configuración del plano de datos reparada (bloques control_plane duplicados fusionados en uno); se conservó el archivo anterior.
de|dp_link_fixed|Data-Plane-Konfiguration repariert (doppelte control_plane-Blöcke zu einem zusammengeführt); die vorherige Datei blieb erhalten.
it|dp_link_fixed|Configurazione del data plane riparata (blocchi control_plane duplicati uniti in uno); il file precedente è stato conservato.
pt|dp_link_fixed|Configuração do plano de dados reparada (blocos control_plane duplicados fundidos num só); o ficheiro anterior foi mantido.
nl|dp_link_fixed|Dataplane-configuratie hersteld (dubbele control_plane-blokken samengevoegd); het vorige bestand is bewaard.
ru|dp_link_fixed|Конфигурация плоскости данных исправлена (дублирующиеся блоки control_plane объединены); прежний файл сохранён.
zh|dp_link_fixed|数据平面配置已修复（重复的 control_plane 块已合并为一个）；原文件已保留。
ar|dp_link_fixed|تم إصلاح تكوين مستوى البيانات (دُمجت كتل control_plane المكررة في كتلة واحدة)؛ تم الاحتفاظ بالملف السابق.
en|dp_link_remote|The data plane on this machine is configured for another console; it was left unchanged.
fr|dp_link_remote|Le plan de données de cette machine est configuré pour une autre console ; il n'a pas été modifié.
es|dp_link_remote|El plano de datos de esta máquina está configurado para otra consola; no se modificó.
de|dp_link_remote|Die Data Plane dieses Rechners ist für eine andere Konsole konfiguriert und blieb unverändert.
it|dp_link_remote|Il data plane di questa macchina è configurato per un'altra console; non è stato modificato.
pt|dp_link_remote|O plano de dados desta máquina está configurado para outra consola; não foi alterado.
nl|dp_link_remote|Het dataplane op deze machine is voor een andere console geconfigureerd en is ongewijzigd gelaten.
ru|dp_link_remote|Плоскость данных на этой машине настроена на другую консоль; она не изменена.
zh|dp_link_remote|此机器上的数据平面已配置为使用另一个控制台；未作修改。
ar|dp_link_remote|مستوى البيانات على هذا الجهاز مضبوط للعمل مع لوحة تحكم أخرى؛ لم يتم تعديله.
en|dp_link_fail|The data plane could not be linked to the console automatically: %s
fr|dp_link_fail|Le plan de données n'a pas pu être lié automatiquement à la console : %s
es|dp_link_fail|No se pudo vincular automáticamente el plano de datos a la consola: %s
de|dp_link_fail|Die Data Plane konnte nicht automatisch mit der Konsole verbunden werden: %s
it|dp_link_fail|Non è stato possibile collegare automaticamente il data plane alla console: %s
pt|dp_link_fail|Não foi possível ligar automaticamente o plano de dados à consola: %s
nl|dp_link_fail|Het dataplane kon niet automatisch aan de console worden gekoppeld: %s
ru|dp_link_fail|Не удалось автоматически привязать плоскость данных к консоли: %s
zh|dp_link_fail|无法自动将数据平面关联到控制台：%s
ar|dp_link_fail|تعذّر ربط مستوى البيانات بلوحة التحكم تلقائيًا: %s
en|dp_link_fail_hint|The data plane keeps its standalone configuration, so sites answer HTTP 421 until it is linked. Fix the cause above and run this installer again: it links the node by itself.
fr|dp_link_fail_hint|Le plan de données garde sa configuration autonome : les sites répondent HTTP 421 tant qu'il n'est pas lié. Corrigez la cause ci-dessus et relancez cet installateur : il lie le nœud tout seul.
es|dp_link_fail_hint|El plano de datos conserva su configuración autónoma, por lo que los sitios responden HTTP 421 hasta que se vincule. Corrija la causa indicada y vuelva a ejecutar este instalador: vincula el nodo por sí solo.
de|dp_link_fail_hint|Die Data Plane behält ihre eigenständige Konfiguration; Sites antworten mit HTTP 421, bis sie verbunden ist. Beheben Sie die oben genannte Ursache und starten Sie diesen Installer erneut: Er verbindet den Knoten selbst.
it|dp_link_fail_hint|Il data plane mantiene la configurazione autonoma, quindi i siti rispondono HTTP 421 finché non è collegato. Correggi la causa indicata sopra ed esegui di nuovo questo installer: collega il nodo da solo.
pt|dp_link_fail_hint|O plano de dados mantém a configuração autónoma, por isso os sites respondem HTTP 421 até ser ligado. Corrija a causa acima e execute novamente este instalador: liga o nó sozinho.
nl|dp_link_fail_hint|Het dataplane behoudt zijn zelfstandige configuratie, dus sites antwoorden met HTTP 421 tot het is gekoppeld. Los de oorzaak hierboven op en voer dit installatieprogramma opnieuw uit: het koppelt de node zelf.
ru|dp_link_fail_hint|Плоскость данных сохраняет автономную конфигурацию, поэтому сайты отвечают HTTP 421, пока она не привязана. Устраните причину выше и запустите установщик снова: он привяжет узел сам.
zh|dp_link_fail_hint|数据平面保留其独立配置，在关联之前站点将返回 HTTP 421。请排除上述原因后重新运行此安装程序：它会自动关联该节点。
ar|dp_link_fail_hint|يحتفظ مستوى البيانات بتكوينه المستقل، لذا تردّ المواقع بالرمز HTTP 421 إلى أن يتم ربطه. أصلح السبب أعلاه وأعد تشغيل هذا المثبّت: فهو يربط العقدة بنفسه.
en|st_title|Status
fr|st_title|État
es|st_title|Estado
de|st_title|Status
it|st_title|Stato
pt|st_title|Estado
nl|st_title|Status
ru|st_title|Состояние
zh|st_title|状态
ar|st_title|الحالة
en|st_healthy|healthy
fr|st_healthy|sain
es|st_healthy|sano
de|st_healthy|gesund
it|st_healthy|funzionante
pt|st_healthy|saudável
nl|st_healthy|gezond
ru|st_healthy|работает
zh|st_healthy|正常
ar|st_healthy|سليم
en|st_unhealthy|NOT healthy
fr|st_unhealthy|NON sain
es|st_unhealthy|NO sano
de|st_unhealthy|NICHT gesund
it|st_unhealthy|NON funzionante
pt|st_unhealthy|NÃO saudável
nl|st_unhealthy|NIET gezond
ru|st_unhealthy|НЕ работает
zh|st_unhealthy|异常
ar|st_unhealthy|غير سليم
en|st_active|active
fr|st_active|actif
es|st_active|activo
de|st_active|aktiv
it|st_active|attivo
pt|st_active|ativo
nl|st_active|actief
ru|st_active|активна
zh|st_active|运行中
ar|st_active|نشط
en|st_inactive|inactive
fr|st_inactive|inactif
es|st_inactive|inactivo
de|st_inactive|inaktiv
it|st_inactive|inattivo
pt|st_inactive|inativo
nl|st_inactive|inactief
ru|st_inactive|не активна
zh|st_inactive|未运行
ar|st_inactive|غير نشط
en|st_listening|listening
fr|st_listening|en écoute
es|st_listening|escuchando
de|st_listening|lauscht
it|st_listening|in ascolto
pt|st_listening|a escutar
nl|st_listening|luistert
ru|st_listening|слушает
zh|st_listening|监听中
ar|st_listening|يستمع
en|st_closed|not listening
fr|st_closed|fermé
es|st_closed|no escucha
de|st_closed|lauscht nicht
it|st_closed|non in ascolto
pt|st_closed|não escuta
nl|st_closed|luistert niet
ru|st_closed|не слушает
zh|st_closed|未监听
ar|st_closed|لا يستمع
en|un_title|Uninstalling ToutWAF
fr|un_title|Désinstallation de ToutWAF
es|un_title|Desinstalando ToutWAF
de|un_title|ToutWAF wird deinstalliert
it|un_title|Disinstallazione di ToutWAF
pt|un_title|A desinstalar o ToutWAF
nl|un_title|ToutWAF verwijderen
ru|un_title|Удаление ToutWAF
zh|un_title|正在卸载 ToutWAF
ar|un_title|جار إزالة ToutWAF
en|un_kept|Configuration kept in %s, data in %s (use --purge to delete).
fr|un_kept|Configuration conservée dans %s, données dans %s (--purge pour supprimer).
es|un_kept|Configuración conservada en %s, datos en %s (use --purge para borrar).
de|un_kept|Konfiguration bleibt in %s, Daten in %s (--purge zum Löschen).
it|un_kept|Configurazione mantenuta in %s, dati in %s (usa --purge per eliminare).
pt|un_kept|Configuração mantida em %s, dados em %s (use --purge para apagar).
nl|un_kept|Configuratie bewaard in %s, data in %s (gebruik --purge om te wissen).
ru|un_kept|Настройки сохранены в %s, данные в %s (--purge для удаления).
zh|un_kept|配置保留在 %s，数据保留在 %s（使用 --purge 删除）。
ar|un_kept|تم الاحتفاظ بالإعدادات في %s والبيانات في %s (استخدم --purge للحذف).
en|un_purged|Configuration, data and logs deleted.
fr|un_purged|Configuration, données et journaux supprimés.
es|un_purged|Configuración, datos y registros eliminados.
de|un_purged|Konfiguration, Daten und Logs gelöscht.
it|un_purged|Configurazione, dati e log eliminati.
pt|un_purged|Configuração, dados e logs apagados.
nl|un_purged|Configuratie, data en logs gewist.
ru|un_purged|Настройки, данные и журналы удалены.
zh|un_purged|配置、数据和日志已删除。
ar|un_purged|تم حذف الإعدادات والبيانات والسجلات.
en|p_console|web console + API
fr|p_console|console web + API
es|p_console|consola web + API
de|p_console|Web-Konsole + API
it|p_console|console web + API
pt|p_console|consola web + API
nl|p_console|webconsole + API
ru|p_console|веб-консоль + API
zh|p_console|Web 控制台 + API
ar|p_console|وحدة تحكم الويب + API
en|p_http|HTTP (reverse proxy)
fr|p_http|HTTP (reverse proxy)
es|p_http|HTTP (proxy inverso)
de|p_http|HTTP (Reverse-Proxy)
it|p_http|HTTP (reverse proxy)
pt|p_http|HTTP (proxy reverso)
nl|p_http|HTTP (reverse proxy)
ru|p_http|HTTP (reverse proxy)
zh|p_http|HTTP（反向代理）
ar|p_http|HTTP (وكيل عكسي)
en|p_https|HTTPS (reverse proxy)
fr|p_https|HTTPS (reverse proxy)
es|p_https|HTTPS (proxy inverso)
de|p_https|HTTPS (Reverse-Proxy)
it|p_https|HTTPS (reverse proxy)
pt|p_https|HTTPS (proxy reverso)
nl|p_https|HTTPS (reverse proxy)
ru|p_https|HTTPS (reverse proxy)
zh|p_https|HTTPS（反向代理）
ar|p_https|HTTPS (وكيل عكسي)
en|p_dpapi|data-plane API: ONLY if data planes run on OTHER hosts (restrict to their IPs)
fr|p_dpapi|API des plans de données : UNIQUEMENT si des plans de données sont sur D'AUTRES hôtes (limiter à leurs IP)
es|p_dpapi|API de planos de datos: SOLO si hay planos de datos en OTROS hosts (limitar a sus IP)
de|p_dpapi|Data-Plane-API: NUR wenn Data Planes auf ANDEREN Hosts laufen (auf deren IPs beschränken)
it|p_dpapi|API dei data plane: SOLO se i data plane sono su ALTRI host (limita ai loro IP)
pt|p_dpapi|API dos planos de dados: APENAS se houver planos de dados noutros hosts (limite aos seus IPs)
nl|p_dpapi|data-plane-API: ALLEEN als data planes op ANDERE hosts draaien (beperk tot hun IP's)
ru|p_dpapi|API data plane: ТОЛЬКО если data plane работают на ДРУГИХ хостах (ограничьте их IP)
zh|p_dpapi|数据平面 API：仅当数据平面运行在其他主机时才需要（限制为其 IP）
ar|p_dpapi|واجهة API لمستوى البيانات: فقط إذا كانت مستويات البيانات على مضيفات أخرى (قيّدها بعناوينها)
en|w_fw_manual|Port %s/tcp was not opened automatically: see the commands in the summary.
fr|w_fw_manual|Le port %s/tcp n'a pas été ouvert automatiquement : voir les commandes du récapitulatif.
es|w_fw_manual|El puerto %s/tcp no se abrió automáticamente: vea los comandos del resumen.
de|w_fw_manual|Port %s/tcp wurde nicht automatisch geöffnet: siehe Befehle in der Zusammenfassung.
it|w_fw_manual|La porta %s/tcp non è stata aperta automaticamente: vedi i comandi nel riepilogo.
pt|w_fw_manual|A porta %s/tcp não foi aberta automaticamente: veja os comandos no resumo.
nl|w_fw_manual|Poort %s/tcp is niet automatisch geopend: zie de opdrachten in de samenvatting.
ru|w_fw_manual|Порт %s/tcp не открыт автоматически: см. команды в итогах.
zh|w_fw_manual|端口 %s/tcp 未自动放行：请见摘要中的命令。
ar|w_fw_manual|لم يتم فتح المنفذ %s/tcp تلقائيا: راجع الأوامر في الملخص.
en|need_cp|A control plane URL is required when an enrolment token is given.
fr|need_cp|Une URL de plan de contrôle est nécessaire lorsqu'un jeton d'enrôlement est fourni.
es|need_cp|Se necesita la URL de un plano de control cuando se indica un token de alta.
de|need_cp|Mit einem Registrierungstoken wird die URL einer Control Plane benötigt.
it|need_cp|Serve l'URL di un control plane quando si indica un token di registrazione.
pt|need_cp|É necessária a URL de um plano de controlo quando se indica um token de inscrição.
nl|need_cp|Met een inschrijftoken is een control-plane-URL nodig.
ru|need_cp|При указании токена регистрации нужен URL control plane.
zh|need_cp|提供注册令牌时需要控制平面 URL。
ar|need_cp|يلزم عنوان مستوى التحكم عند تقديم رمز التسجيل.
en|cp_title|System compatibility
fr|cp_title|Compatibilité du système
es|cp_title|Compatibilidad del sistema
de|cp_title|Systemkompatibilität
it|cp_title|Compatibilità del sistema
pt|cp_title|Compatibilidade do sistema
nl|cp_title|Systeemcompatibiliteit
ru|cp_title|Совместимость системы
zh|cp_title|系统兼容性
ar|cp_title|توافق النظام
en|cp_detected|Detected: %s, arch %s, glibc %s, systemd %s, kernel %s
fr|cp_detected|Détecté : %s, arch %s, glibc %s, systemd %s, noyau %s
es|cp_detected|Detectado: %s, arq. %s, glibc %s, systemd %s, kernel %s
de|cp_detected|Erkannt: %s, Arch %s, glibc %s, systemd %s, Kernel %s
it|cp_detected|Rilevato: %s, arch %s, glibc %s, systemd %s, kernel %s
pt|cp_detected|Detetado: %s, arq. %s, glibc %s, systemd %s, kernel %s
nl|cp_detected|Gedetecteerd: %s, arch %s, glibc %s, systemd %s, kernel %s
ru|cp_detected|Обнаружено: %s, арх. %s, glibc %s, systemd %s, ядро %s
zh|cp_detected|检测到：%s，架构 %s，glibc %s，systemd %s，内核 %s
ar|cp_detected|تم الكشف: %s، المعمارية %s، glibc %s، systemd %s، النواة %s
en|cp_ok|Compatible: %s (%s)
fr|cp_ok|Compatible : %s (%s)
es|cp_ok|Compatible: %s (%s)
de|cp_ok|Kompatibel: %s (%s)
it|cp_ok|Compatibile: %s (%s)
pt|cp_ok|Compatível: %s (%s)
nl|cp_ok|Compatibel: %s (%s)
ru|cp_ok|Совместимо: %s (%s)
zh|cp_ok|兼容：%s（%s）
ar|cp_ok|متوافق: %s (%s)
en|cp_tested|tested
fr|cp_tested|testé
es|cp_tested|probado
de|cp_tested|getestet
it|cp_tested|testato
pt|cp_tested|testado
nl|cp_tested|getest
ru|cp_tested|проверено
zh|cp_tested|已测试
ar|cp_tested|تم اختباره
en|cp_expected|expected
fr|cp_expected|attendu
es|cp_expected|esperado
de|cp_expected|erwartet
it|cp_expected|previsto
pt|cp_expected|esperado
nl|cp_expected|verwacht
ru|cp_expected|ожидается
zh|cp_expected|预期兼容
ar|cp_expected|متوقع
en|cp_w_like|%s is not in the compatibility table: treated as the %s family (expected). Continuing.
fr|cp_w_like|%s n'est pas dans la table de compatibilité : traité comme la famille %s (attendu). On continue.
es|cp_w_like|%s no figura en la tabla de compatibilidad: se trata como la familia %s (esperado). Se continúa.
de|cp_w_like|%s steht nicht in der Kompatibilitätstabelle: wird als Familie %s behandelt (erwartet). Es geht weiter.
it|cp_w_like|%s non è nella tabella di compatibilità: trattato come famiglia %s (previsto). Si continua.
pt|cp_w_like|%s não consta da tabela de compatibilidade: tratado como a família %s (esperado). A continuar.
nl|cp_w_like|%s staat niet in de compatibiliteitstabel: behandeld als de familie %s (verwacht). Er wordt doorgegaan.
ru|cp_w_like|%s нет в таблице совместимости: обрабатывается как семейство %s (ожидается). Продолжаем.
zh|cp_w_like|%s 不在兼容性表中：按 %s 系列处理（预期兼容）。继续。
ar|cp_w_like|%s غير موجود في جدول التوافق: يُعامل كعائلة %s (متوقع). المتابعة.
en|cp_w_newer|%s %s is newer than the listed versions: not validated yet (expected). Continuing.
fr|cp_w_newer|%s %s est plus récent que les versions listées : pas encore validé (attendu). On continue.
es|cp_w_newer|%s %s es más reciente que las versiones listadas: aún no validado (esperado). Se continúa.
de|cp_w_newer|%s %s ist neuer als die gelisteten Versionen: noch nicht validiert (erwartet). Es geht weiter.
it|cp_w_newer|%s %s è più recente delle versioni elencate: non ancora validato (previsto). Si continua.
pt|cp_w_newer|%s %s é mais recente do que as versões listadas: ainda não validado (esperado). A continuar.
nl|cp_w_newer|%s %s is nieuwer dan de vermelde versies: nog niet gevalideerd (verwacht). Er wordt doorgegaan.
ru|cp_w_newer|%s %s новее перечисленных версий: ещё не проверено (ожидается). Продолжаем.
zh|cp_w_newer|%s %s 比列出的版本更新：尚未验证（预期兼容）。继续。
ar|cp_w_newer|%s %s أحدث من الإصدارات المدرجة: لم يتم التحقق منه بعد (متوقع). المتابعة.
en|cp_w_unlisted|%s %s is not listed in the table: treated as expected. Continuing.
fr|cp_w_unlisted|%s %s n'est pas listé dans la table : traité comme attendu. On continue.
es|cp_w_unlisted|%s %s no figura en la tabla: se trata como esperado. Se continúa.
de|cp_w_unlisted|%s %s steht nicht in der Tabelle: wird als erwartet behandelt. Es geht weiter.
it|cp_w_unlisted|%s %s non è elencato nella tabella: trattato come previsto. Si continua.
pt|cp_w_unlisted|%s %s não consta da tabela: tratado como esperado. A continuar.
nl|cp_w_unlisted|%s %s staat niet in de tabel: behandeld als verwacht. Er wordt doorgegaan.
ru|cp_w_unlisted|%s %s нет в таблице: считается ожидаемо совместимой. Продолжаем.
zh|cp_w_unlisted|%s %s 不在表中：按预期兼容处理。继续。
ar|cp_w_unlisted|%s %s غير مدرج في الجدول: يُعامل كمتوقع. المتابعة.
en|cp_w_nover|%s reports no version (rolling or testing release): treated as expected. Continuing.
fr|cp_w_nover|%s ne déclare aucune version (distribution en continu ou testing) : traité comme attendu. On continue.
es|cp_w_nover|%s no declara versión (rolling o testing): se trata como esperado. Se continúa.
de|cp_w_nover|%s meldet keine Version (Rolling oder Testing): wird als erwartet behandelt. Es geht weiter.
it|cp_w_nover|%s non dichiara una versione (rolling o testing): trattato come previsto. Si continua.
pt|cp_w_nover|%s não declara versão (rolling ou testing): tratado como esperado. A continuar.
nl|cp_w_nover|%s meldt geen versie (rolling of testing): behandeld als verwacht. Er wordt doorgegaan.
ru|cp_w_nover|%s не сообщает версию (rolling или testing): считается ожидаемо совместимой. Продолжаем.
zh|cp_w_nover|%s 未报告版本（滚动或测试版）：按预期兼容处理。继续。
ar|cp_w_nover|%s لا يعلن عن إصدار (تحديث مستمر أو اختباري): يُعامل كمتوقع. المتابعة.
en|cp_w_glibc|The glibc version could not be determined; continuing.
fr|cp_w_glibc|La version de glibc n'a pas pu être déterminée ; on continue.
es|cp_w_glibc|No se pudo determinar la versión de glibc; se continúa.
de|cp_w_glibc|Die glibc-Version konnte nicht ermittelt werden; es geht weiter.
it|cp_w_glibc|Impossibile determinare la versione di glibc; si continua.
pt|cp_w_glibc|Não foi possível determinar a versão da glibc; continuando.
nl|cp_w_glibc|De glibc-versie kon niet worden bepaald; er wordt doorgegaan.
ru|cp_w_glibc|Не удалось определить версию glibc; продолжаем.
zh|cp_w_glibc|无法确定 glibc 版本；继续。
ar|cp_w_glibc|تعذر تحديد إصدار glibc؛ المتابعة.
en|cp_w_skip|--skip-os-check: the compatibility check is bypassed. This system is NOT supported: continuing at your own risk.
fr|cp_w_skip|--skip-os-check : le contrôle de compatibilité est ignoré. Ce système n'est PAS pris en charge : vous continuez à vos risques.
es|cp_w_skip|--skip-os-check: se omite la comprobación de compatibilidad. Este sistema NO es compatible: continúa bajo su responsabilidad.
de|cp_w_skip|--skip-os-check: die Kompatibilitätsprüfung wird übergangen. Dieses System wird NICHT unterstützt: Fortfahren auf eigenes Risiko.
it|cp_w_skip|--skip-os-check: il controllo di compatibilità è ignorato. Questo sistema NON è supportato: si continua a proprio rischio.
pt|cp_w_skip|--skip-os-check: a verificação de compatibilidade foi ignorada. Este sistema NÃO é suportado: a continuar por sua conta e risco.
nl|cp_w_skip|--skip-os-check: de compatibiliteitscontrole wordt overgeslagen. Dit systeem wordt NIET ondersteund: doorgaan op eigen risico.
ru|cp_w_skip|--skip-os-check: проверка совместимости пропущена. Эта система НЕ поддерживается: продолжаем на ваш риск.
zh|cp_w_skip|--skip-os-check：已跳过兼容性检查。此系统不受支持：风险自负，继续。
ar|cp_w_skip|--skip-os-check: تم تجاوز فحص التوافق. هذا النظام غير مدعوم: المتابعة على مسؤوليتك.
en|cp_w_stage|Staging (--destdir): the compatibility verdict is informational only, nothing is refused.
fr|cp_w_stage|Préparation (--destdir) : le verdict de compatibilité est informatif, rien n'est refusé.
es|cp_w_stage|Preparación (--destdir): el veredicto de compatibilidad es informativo, no se rechaza nada.
de|cp_w_stage|Staging (--destdir): das Kompatibilitätsergebnis ist nur informativ, nichts wird abgelehnt.
it|cp_w_stage|Staging (--destdir): il verdetto di compatibilità è solo informativo, nulla viene rifiutato.
pt|cp_w_stage|Staging (--destdir): o veredito de compatibilidade é apenas informativo, nada é recusado.
nl|cp_w_stage|Staging (--destdir): het compatibiliteitsoordeel is slechts informatief, er wordt niets geweigerd.
ru|cp_w_stage|Staging (--destdir): вердикт совместимости носит информационный характер, ничего не отклоняется.
zh|cp_w_stage|暂存模式（--destdir）：兼容性结论仅供参考，不会拒绝。
ar|cp_w_stage|التجهيز (--destdir): نتيجة التوافق للعلم فقط ولا يُرفض شيء.
en|cp_refused|This system is not compatible with ToutWAF:
fr|cp_refused|Ce système n'est pas compatible avec ToutWAF :
es|cp_refused|Este sistema no es compatible con ToutWAF:
de|cp_refused|Dieses System ist nicht mit ToutWAF kompatibel:
it|cp_refused|Questo sistema non è compatibile con ToutWAF:
pt|cp_refused|Este sistema não é compatível com o ToutWAF:
nl|cp_refused|Dit systeem is niet compatibel met ToutWAF:
ru|cp_refused|Эта система несовместима с ToutWAF:
zh|cp_refused|此系统与 ToutWAF 不兼容：
ar|cp_refused|هذا النظام غير متوافق مع ToutWAF:
en|cp_r_old|%s %s is older than the minimum supported version (%s).
fr|cp_r_old|%s %s est plus ancien que la version minimale prise en charge (%s).
es|cp_r_old|%s %s es anterior a la versión mínima compatible (%s).
de|cp_r_old|%s %s ist älter als die minimal unterstützte Version (%s).
it|cp_r_old|%s %s è più vecchio della versione minima supportata (%s).
pt|cp_r_old|%s %s é mais antigo do que a versão mínima suportada (%s).
nl|cp_r_old|%s %s is ouder dan de minimaal ondersteunde versie (%s).
ru|cp_r_old|%s %s старше минимальной поддерживаемой версии (%s).
zh|cp_r_old|%s %s 低于支持的最低版本（%s）。
ar|cp_r_old|%s %s أقدم من الحد الأدنى للإصدار المدعوم (%s).
en|cp_r_eol|%s %s is end of life, or its glibc / systemd is too old.
fr|cp_r_eol|%s %s est en fin de vie, ou sa glibc / son systemd est trop ancien.
es|cp_r_eol|%s %s ha llegado al fin de su vida útil, o su glibc / systemd es demasiado antiguo.
de|cp_r_eol|%s %s ist am Ende seines Lebenszyklus oder seine glibc / systemd ist zu alt.
it|cp_r_eol|%s %s è a fine vita, oppure la sua glibc / systemd è troppo vecchia.
pt|cp_r_eol|%s %s chegou ao fim de vida, ou a sua glibc / systemd é demasiado antiga.
nl|cp_r_eol|%s %s is end-of-life, of de glibc / systemd is te oud.
ru|cp_r_eol|%s %s снята с поддержки, либо её glibc / systemd слишком стар.
zh|cp_r_eol|%s %s 已停止维护，或其 glibc / systemd 过旧。
ar|cp_r_eol|%s %s انتهى عمره أو أن glibc / systemd فيه قديم جدا.
en|cp_r_glibc|glibc %s found: %s or newer is required.
fr|cp_r_glibc|glibc %s trouvée : %s ou plus récente est requise.
es|cp_r_glibc|glibc %s encontrada: se requiere %s o posterior.
de|cp_r_glibc|glibc %s gefunden: %s oder neuer ist erforderlich.
it|cp_r_glibc|glibc %s trovata: serve %s o successiva.
pt|cp_r_glibc|glibc %s encontrada: é necessária a %s ou posterior.
nl|cp_r_glibc|glibc %s gevonden: %s of nieuwer is vereist.
ru|cp_r_glibc|Найдена glibc %s: требуется %s или новее.
zh|cp_r_glibc|发现 glibc %s：需要 %s 或更新版本。
ar|cp_r_glibc|تم العثور على glibc %s: مطلوب %s أو أحدث.
en|cp_r_musl|musl libc found: glibc %s or newer is required.
fr|cp_r_musl|musl libc trouvée : glibc %s ou plus récente est requise.
es|cp_r_musl|musl libc encontrada: se requiere glibc %s o posterior.
de|cp_r_musl|musl libc gefunden: glibc %s oder neuer ist erforderlich.
it|cp_r_musl|musl libc trovata: serve glibc %s o successiva.
pt|cp_r_musl|musl libc encontrada: é necessária a glibc %s ou posterior.
nl|cp_r_musl|musl libc gevonden: glibc %s of nieuwer is vereist.
ru|cp_r_musl|Найдена musl libc: требуется glibc %s или новее.
zh|cp_r_musl|发现 musl libc：需要 glibc %s 或更新版本。
ar|cp_r_musl|تم العثور على musl libc: مطلوب glibc %s أو أحدث.
en|cp_r_init|%s %s does not use systemd, which ToutWAF requires.
fr|cp_r_init|%s %s n'utilise pas systemd, requis par ToutWAF.
es|cp_r_init|%s %s no usa systemd, que ToutWAF requiere.
de|cp_r_init|%s %s verwendet kein systemd, das ToutWAF benötigt.
it|cp_r_init|%s %s non usa systemd, richiesto da ToutWAF.
pt|cp_r_init|%s %s não usa systemd, exigido pelo ToutWAF.
nl|cp_r_init|%s %s gebruikt geen systemd, dat ToutWAF vereist.
ru|cp_r_init|%s %s не использует systemd, который нужен ToutWAF.
zh|cp_r_init|%s %s 不使用 systemd，而 ToutWAF 需要它。
ar|cp_r_init|%s %s لا يستخدم systemd الذي يتطلبه ToutWAF.
en|cp_r_immutable|%s %s has an immutable root filesystem (not supported).
fr|cp_r_immutable|%s %s a un système de fichiers racine immuable (non pris en charge).
es|cp_r_immutable|%s %s tiene un sistema de archivos raíz inmutable (no compatible).
de|cp_r_immutable|%s %s hat ein unveränderliches Root-Dateisystem (nicht unterstützt).
it|cp_r_immutable|%s %s ha un filesystem root immutabile (non supportato).
pt|cp_r_immutable|%s %s tem um sistema de ficheiros raiz imutável (não suportado).
nl|cp_r_immutable|%s %s heeft een onveranderlijk root-bestandssysteem (niet ondersteund).
ru|cp_r_immutable|%s %s использует неизменяемую корневую ФС (не поддерживается).
zh|cp_r_immutable|%s %s 使用不可变根文件系统（不支持）。
ar|cp_r_immutable|%s %s يستخدم نظام ملفات جذر غير قابل للتعديل (غير مدعوم).
en|cp_r_layout|%s %s does not follow the standard Linux filesystem layout (not supported).
fr|cp_r_layout|%s %s ne suit pas l'arborescence Linux standard (non pris en charge).
es|cp_r_layout|%s %s no sigue la estructura estándar de Linux (no compatible).
de|cp_r_layout|%s %s folgt nicht der Linux-Standardverzeichnisstruktur (nicht unterstützt).
it|cp_r_layout|%s %s non segue la struttura standard di Linux (non supportato).
pt|cp_r_layout|%s %s não segue a estrutura padrão do Linux (não suportado).
nl|cp_r_layout|%s %s volgt niet de standaard Linux-mapstructuur (niet ondersteund).
ru|cp_r_layout|%s %s не следует стандартной структуре каталогов Linux (не поддерживается).
zh|cp_r_layout|%s %s 不遵循标准 Linux 目录结构（不支持）。
ar|cp_r_layout|%s %s لا يتبع بنية ملفات Linux القياسية (غير مدعوم).
en|cp_r_arch|Architecture %s is not supported (supported: %s).
fr|cp_r_arch|L'architecture %s n'est pas prise en charge (prise en charge : %s).
es|cp_r_arch|La arquitectura %s no es compatible (compatible: %s).
de|cp_r_arch|Die Architektur %s wird nicht unterstützt (unterstützt: %s).
it|cp_r_arch|L'architettura %s non è supportata (supportata: %s).
pt|cp_r_arch|A arquitetura %s não é suportada (suportada: %s).
nl|cp_r_arch|Architectuur %s wordt niet ondersteund (ondersteund: %s).
ru|cp_r_arch|Архитектура %s не поддерживается (поддерживается: %s).
zh|cp_r_arch|不支持架构 %s（支持：%s）。
ar|cp_r_arch|المعمارية %s غير مدعومة (المدعوم: %s).
en|cp_r_distro_arch|%s %s runs on an architecture without a ToutWAF build.
fr|cp_r_distro_arch|%s %s tourne sur une architecture sans build ToutWAF.
es|cp_r_distro_arch|%s %s funciona en una arquitectura sin compilación de ToutWAF.
de|cp_r_distro_arch|%s %s läuft auf einer Architektur ohne ToutWAF-Build.
it|cp_r_distro_arch|%s %s gira su un'architettura senza build di ToutWAF.
pt|cp_r_distro_arch|%s %s corre numa arquitetura sem build do ToutWAF.
nl|cp_r_distro_arch|%s %s draait op een architectuur zonder ToutWAF-build.
ru|cp_r_distro_arch|%s %s работает на архитектуре без сборки ToutWAF.
zh|cp_r_distro_arch|%s %s 运行在没有 ToutWAF 构建的架构上。
ar|cp_r_distro_arch|%s %s يعمل على معمارية بلا إصدار من ToutWAF.
en|cp_r_systemd|systemd is not running as the init system (/run/systemd/system is missing): it is required for the services.
fr|cp_r_systemd|systemd ne tourne pas comme système d'init (/run/systemd/system est absent) : il est requis pour les services.
es|cp_r_systemd|systemd no se ejecuta como sistema init (falta /run/systemd/system): es necesario para los servicios.
de|cp_r_systemd|systemd läuft nicht als Init-System (/run/systemd/system fehlt): es wird für die Dienste benötigt.
it|cp_r_systemd|systemd non è in esecuzione come init (manca /run/systemd/system): è necessario per i servizi.
pt|cp_r_systemd|o systemd não está em execução como init (falta /run/systemd/system): é necessário para os serviços.
nl|cp_r_systemd|systemd draait niet als init-systeem (/run/systemd/system ontbreekt): het is vereist voor de diensten.
ru|cp_r_systemd|systemd не запущен как init (нет /run/systemd/system): он нужен для служб.
zh|cp_r_systemd|systemd 未作为 init 系统运行（缺少 /run/systemd/system）：服务需要它。
ar|cp_r_systemd|systemd لا يعمل كنظام init (المجلد /run/systemd/system غير موجود): مطلوب للخدمات.
en|cp_r_systemd_old|systemd %s found: %s or newer is required.
fr|cp_r_systemd_old|systemd %s trouvé : %s ou plus récent est requis.
es|cp_r_systemd_old|systemd %s encontrado: se requiere %s o posterior.
de|cp_r_systemd_old|systemd %s gefunden: %s oder neuer ist erforderlich.
it|cp_r_systemd_old|systemd %s trovato: serve %s o successivo.
pt|cp_r_systemd_old|systemd %s encontrado: é necessário %s ou posterior.
nl|cp_r_systemd_old|systemd %s gevonden: %s of nieuwer is vereist.
ru|cp_r_systemd_old|Найден systemd %s: требуется %s или новее.
zh|cp_r_systemd_old|发现 systemd %s：需要 %s 或更新版本。
ar|cp_r_systemd_old|تم العثور على systemd %s: مطلوب %s أو أحدث.
en|cp_r_kernel|Linux kernel %s found: %s or newer is required.
fr|cp_r_kernel|Noyau Linux %s trouvé : %s ou plus récent est requis.
es|cp_r_kernel|Kernel Linux %s encontrado: se requiere %s o posterior.
de|cp_r_kernel|Linux-Kernel %s gefunden: %s oder neuer ist erforderlich.
it|cp_r_kernel|Kernel Linux %s trovato: serve %s o successivo.
pt|cp_r_kernel|Kernel Linux %s encontrado: é necessário %s ou posterior.
nl|cp_r_kernel|Linux-kernel %s gevonden: %s of nieuwer is vereist.
ru|cp_r_kernel|Найдено ядро Linux %s: требуется %s или новее.
zh|cp_r_kernel|发现 Linux 内核 %s：需要 %s 或更新版本。
ar|cp_r_kernel|تم العثور على نواة Linux %s: مطلوب %s أو أحدث.
en|cp_r_unknown|Distribution '%s' is not recognised and declares no known family (ID_LIKE='%s').
fr|cp_r_unknown|La distribution '%s' n'est pas reconnue et ne déclare aucune famille connue (ID_LIKE='%s').
es|cp_r_unknown|La distribución '%s' no se reconoce y no declara ninguna familia conocida (ID_LIKE='%s').
de|cp_r_unknown|Die Distribution '%s' ist unbekannt und nennt keine bekannte Familie (ID_LIKE='%s').
it|cp_r_unknown|La distribuzione '%s' non è riconosciuta e non dichiara alcuna famiglia nota (ID_LIKE='%s').
pt|cp_r_unknown|A distribuição '%s' não é reconhecida e não declara nenhuma família conhecida (ID_LIKE='%s').
nl|cp_r_unknown|Distributie '%s' wordt niet herkend en vermeldt geen bekende familie (ID_LIKE='%s').
ru|cp_r_unknown|Дистрибутив '%s' не распознан и не указывает известного семейства (ID_LIKE='%s').
zh|cp_r_unknown|无法识别发行版 '%s'，且未声明已知系列（ID_LIKE='%s'）。
ar|cp_r_unknown|التوزيعة '%s' غير معروفة ولا تعلن عن عائلة معروفة (ID_LIKE='%s').
en|cp_r_noosr|/etc/os-release is missing: the distribution cannot be identified.
fr|cp_r_noosr|/etc/os-release est absent : la distribution ne peut pas être identifiée.
es|cp_r_noosr|Falta /etc/os-release: no se puede identificar la distribución.
de|cp_r_noosr|/etc/os-release fehlt: die Distribution kann nicht erkannt werden.
it|cp_r_noosr|Manca /etc/os-release: impossibile identificare la distribuzione.
pt|cp_r_noosr|Falta /etc/os-release: não é possível identificar a distribuição.
nl|cp_r_noosr|/etc/os-release ontbreekt: de distributie kan niet worden herkend.
ru|cp_r_noosr|Нет /etc/os-release: дистрибутив определить невозможно.
zh|cp_r_noosr|缺少 /etc/os-release：无法识别发行版。
ar|cp_r_noosr|الملف /etc/os-release غير موجود: لا يمكن تحديد التوزيعة.
en|cp_nochange|Nothing has been changed on this system.
fr|cp_nochange|Rien n'a été modifié sur ce système.
es|cp_nochange|No se ha modificado nada en este sistema.
de|cp_nochange|An diesem System wurde nichts geändert.
it|cp_nochange|Nessuna modifica è stata apportata a questo sistema.
pt|cp_nochange|Nada foi alterado neste sistema.
nl|cp_nochange|Er is niets gewijzigd op dit systeem.
ru|cp_nochange|В системе ничего не изменено.
zh|cp_nochange|未对此系统做任何更改。
ar|cp_nochange|لم يتم تغيير أي شيء في هذا النظام.
en|cp_list|Compatible systems (amd64 and arm64, glibc %s or newer, systemd %s or newer):
fr|cp_list|Systèmes compatibles (amd64 et arm64, glibc %s ou plus récente, systemd %s ou plus récent) :
es|cp_list|Sistemas compatibles (amd64 y arm64, glibc %s o posterior, systemd %s o posterior):
de|cp_list|Kompatible Systeme (amd64 und arm64, glibc %s oder neuer, systemd %s oder neuer):
it|cp_list|Sistemi compatibili (amd64 e arm64, glibc %s o successiva, systemd %s o successivo):
pt|cp_list|Sistemas compatíveis (amd64 e arm64, glibc %s ou posterior, systemd %s ou posterior):
nl|cp_list|Compatibele systemen (amd64 en arm64, glibc %s of nieuwer, systemd %s of nieuwer):
ru|cp_list|Совместимые системы (amd64 и arm64, glibc %s или новее, systemd %s или новее):
zh|cp_list|兼容的系统（amd64 和 arm64，glibc %s 或更新，systemd %s 或更新）：
ar|cp_list|الأنظمة المتوافقة (amd64 وarm64، glibc %s أو أحدث، systemd %s أو أحدث):
en|cp_rolling|rolling
fr|cp_rolling|en continu
es|cp_rolling|rolling
de|cp_rolling|Rolling
it|cp_rolling|rolling
pt|cp_rolling|rolling
nl|cp_rolling|rolling
ru|cp_rolling|rolling
zh|cp_rolling|滚动发行
ar|cp_rolling|تحديث مستمر
en|cp_any|any version
fr|cp_any|toute version
es|cp_any|cualquier versión
de|cp_any|jede Version
it|cp_any|qualsiasi versione
pt|cp_any|qualquer versão
nl|cp_any|elke versie
ru|cp_any|любая версия
zh|cp_any|任意版本
ar|cp_any|أي إصدار
en|cp_override|To install anyway, at your own risk: --skip-os-check. Details: docs/install/platforms.md
fr|cp_override|Pour installer quand même, à vos risques : --skip-os-check. Détails : docs/install/platforms.md
es|cp_override|Para instalar de todos modos, bajo su responsabilidad: --skip-os-check. Detalles: docs/install/platforms.md
de|cp_override|Trotzdem installieren, auf eigenes Risiko: --skip-os-check. Details: docs/install/platforms.md
it|cp_override|Per installare comunque, a proprio rischio: --skip-os-check. Dettagli: docs/install/platforms.md
pt|cp_override|Para instalar mesmo assim, por sua conta e risco: --skip-os-check. Detalhes: docs/install/platforms.md
nl|cp_override|Toch installeren, op eigen risico: --skip-os-check. Details: docs/install/platforms.md
ru|cp_override|Установить всё равно, на свой риск: --skip-os-check. Подробности: docs/install/platforms.md
zh|cp_override|仍要安装（风险自负）：--skip-os-check。详情：docs/install/platforms.md
ar|cp_override|للتثبيت رغم ذلك على مسؤوليتك: --skip-os-check. التفاصيل: docs/install/platforms.md
en|cp_not_root|Not running as root: use sudo to install (the check itself does not need root).
fr|cp_not_root|Pas exécuté en root : utilisez sudo pour installer (le contrôle lui-même n'en a pas besoin).
es|cp_not_root|No se ejecuta como root: use sudo para instalar (la comprobación no lo necesita).
de|cp_not_root|Nicht als root ausgeführt: zum Installieren sudo verwenden (die Prüfung selbst braucht kein root).
it|cp_not_root|Non eseguito come root: usare sudo per installare (il controllo non lo richiede).
pt|cp_not_root|Não executado como root: use sudo para instalar (a verificação não precisa).
nl|cp_not_root|Niet als root uitgevoerd: gebruik sudo om te installeren (de controle zelf heeft geen root nodig).
ru|cp_not_root|Запущено не от root: для установки используйте sudo (сама проверка root не требует).
zh|cp_not_root|未以 root 运行：安装请使用 sudo（检查本身不需要 root）。
ar|cp_not_root|لا يعمل كمستخدم root: استخدم sudo للتثبيت (الفحص نفسه لا يحتاج root).
en|sum_compat|Compatibility
fr|sum_compat|Compatibilité
es|sum_compat|Compatibilidad
de|sum_compat|Kompatibilität
it|sum_compat|Compatibilità
pt|sum_compat|Compatibilidade
nl|sum_compat|Compatibiliteit
ru|sum_compat|Совместимость
zh|sum_compat|兼容性
ar|sum_compat|التوافق
en|cp_prereq_arch|The package databases are not synchronised. Run 'pacman -Syu' first (a partial upgrade is not supported on Arch), then re-run the installer.
fr|cp_prereq_arch|Les bases de paquets ne sont pas synchronisées. Lancez d'abord 'pacman -Syu' (une mise à jour partielle n'est pas prise en charge sur Arch), puis relancez l'installateur.
es|cp_prereq_arch|Las bases de datos de paquetes no están sincronizadas. Ejecute primero 'pacman -Syu' (una actualización parcial no es compatible en Arch) y vuelva a ejecutar el instalador.
de|cp_prereq_arch|Die Paketdatenbanken sind nicht synchronisiert. Führen Sie zuerst 'pacman -Syu' aus (ein Teil-Update wird unter Arch nicht unterstützt) und starten Sie den Installer erneut.
it|cp_prereq_arch|I database dei pacchetti non sono sincronizzati. Eseguire prima 'pacman -Syu' (un aggiornamento parziale non è supportato su Arch), poi rilanciare l'installer.
pt|cp_prereq_arch|As bases de dados de pacotes não estão sincronizadas. Execute primeiro 'pacman -Syu' (uma atualização parcial não é suportada no Arch) e volte a executar o instalador.
nl|cp_prereq_arch|De pakketdatabases zijn niet gesynchroniseerd. Voer eerst 'pacman -Syu' uit (een gedeeltelijke update wordt op Arch niet ondersteund) en start het installatieprogramma opnieuw.
ru|cp_prereq_arch|Базы пакетов не синхронизированы. Сначала выполните 'pacman -Syu' (частичное обновление в Arch не поддерживается), затем запустите установщик снова.
zh|cp_prereq_arch|软件包数据库未同步。请先运行 'pacman -Syu'（Arch 不支持部分升级），然后重新运行安装程序。
ar|cp_prereq_arch|قواعد بيانات الحزم غير متزامنة. شغّل 'pacman -Syu' أولا (التحديث الجزئي غير مدعوم في Arch) ثم أعد تشغيل المثبت.
en|cp_wdetected|Detected: %s (build %s), arch %s
fr|cp_wdetected|Détecté : %s (build %s), arch %s
es|cp_wdetected|Detectado: %s (build %s), arq. %s
de|cp_wdetected|Erkannt: %s (Build %s), Arch %s
it|cp_wdetected|Rilevato: %s (build %s), arch %s
pt|cp_wdetected|Detetado: %s (build %s), arq. %s
nl|cp_wdetected|Gedetecteerd: %s (build %s), arch %s
ru|cp_wdetected|Обнаружено: %s (сборка %s), арх. %s
zh|cp_wdetected|检测到：%s（内部版本 %s），架构 %s
ar|cp_wdetected|تم الكشف: %s (البنية %s)، المعمارية %s
en|cp_wlist|Compatible Windows versions (amd64 and arm64; arm64 untested on real hardware):
fr|cp_wlist|Versions de Windows compatibles (amd64 et arm64 ; arm64 non testé sur du matériel réel) :
es|cp_wlist|Versiones de Windows compatibles (amd64 y arm64; arm64 sin probar en hardware real):
de|cp_wlist|Kompatible Windows-Versionen (amd64 und arm64; arm64 nicht auf echter Hardware getestet):
it|cp_wlist|Versioni di Windows compatibili (amd64 e arm64; arm64 non testato su hardware reale):
pt|cp_wlist|Versões do Windows compatíveis (amd64 e arm64; arm64 não testado em hardware real):
nl|cp_wlist|Compatibele Windows-versies (amd64 en arm64; arm64 niet getest op echte hardware):
ru|cp_wlist|Совместимые версии Windows (amd64 и arm64; arm64 не проверялась на реальном оборудовании):
zh|cp_wlist|兼容的 Windows 版本（amd64 和 arm64；arm64 未在真实硬件上测试）：
ar|cp_wlist|إصدارات Windows المتوافقة (amd64 وarm64؛ arm64 لم يُختبر على أجهزة حقيقية):
en|cp_r_arm32|32-bit ARM (armv7) is not supported by ToutWAF. Install a 64-bit OS (Raspberry Pi OS 64-bit, Ubuntu or Debian arm64; Raspberry Pi 3, 4, 5 or Zero 2 W), then run the installer again.
fr|cp_r_arm32|L'ARM 32 bits (armv7) n'est pas pris en charge par ToutWAF. Installez un système 64 bits (Raspberry Pi OS 64 bits, Ubuntu ou Debian arm64 ; Raspberry Pi 3, 4, 5 ou Zero 2 W), puis relancez l'installateur.
es|cp_r_arm32|ARM de 32 bits (armv7) no es compatible con ToutWAF. Instale un sistema de 64 bits (Raspberry Pi OS 64 bits, Ubuntu o Debian arm64; Raspberry Pi 3, 4, 5 o Zero 2 W) y vuelva a ejecutar el instalador.
de|cp_r_arm32|32-Bit-ARM (armv7) wird von ToutWAF nicht unterstützt. Installieren Sie ein 64-Bit-System (Raspberry Pi OS 64 Bit, Ubuntu oder Debian arm64; Raspberry Pi 3, 4, 5 oder Zero 2 W) und starten Sie den Installer erneut.
it|cp_r_arm32|ARM a 32 bit (armv7) non è supportato da ToutWAF. Installare un sistema a 64 bit (Raspberry Pi OS 64 bit, Ubuntu o Debian arm64; Raspberry Pi 3, 4, 5 o Zero 2 W) e rilanciare l'installer.
pt|cp_r_arm32|ARM de 32 bits (armv7) não é suportado pelo ToutWAF. Instale um sistema de 64 bits (Raspberry Pi OS 64 bits, Ubuntu ou Debian arm64; Raspberry Pi 3, 4, 5 ou Zero 2 W) e execute o instalador novamente.
nl|cp_r_arm32|32-bits ARM (armv7) wordt niet ondersteund door ToutWAF. Installeer een 64-bits besturingssysteem (Raspberry Pi OS 64-bit, Ubuntu of Debian arm64; Raspberry Pi 3, 4, 5 of Zero 2 W) en start het installatieprogramma opnieuw.
ru|cp_r_arm32|32-разрядный ARM (armv7) не поддерживается ToutWAF. Установите 64-разрядную ОС (Raspberry Pi OS 64-bit, Ubuntu или Debian arm64; Raspberry Pi 3, 4, 5 или Zero 2 W) и запустите установщик снова.
zh|cp_r_arm32|ToutWAF 不支持 32 位 ARM（armv7）。请安装 64 位系统（64 位 Raspberry Pi OS、Ubuntu 或 Debian arm64；Raspberry Pi 3、4、5 或 Zero 2 W），然后重新运行安装程序。
ar|cp_r_arm32|ToutWAF لا يدعم ARM بنظام 32 بت (armv7). ثبّت نظاما بنظام 64 بت (Raspberry Pi OS 64 بت أو Ubuntu أو Debian arm64؛ Raspberry Pi 3 أو 4 أو 5 أو Zero 2 W) ثم أعد تشغيل المثبت.
en|cp_r_arm_userland32|The kernel is 64-bit but the system (userland) is 32-bit. ToutWAF needs a 64-bit OS: reinstall with Raspberry Pi OS 64-bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) or Ubuntu / Debian arm64.
fr|cp_r_arm_userland32|Le noyau est 64 bits mais le système (userland) est en 32 bits. ToutWAF exige un système 64 bits : réinstallez avec Raspberry Pi OS 64 bits (Raspberry Pi Imager : Raspberry Pi OS (64-bit)) ou Ubuntu / Debian arm64.
es|cp_r_arm_userland32|El kernel es de 64 bits pero el sistema (userland) es de 32 bits. ToutWAF necesita un sistema de 64 bits: reinstale con Raspberry Pi OS 64 bits (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) o Ubuntu / Debian arm64.
de|cp_r_arm_userland32|Der Kernel ist 64-Bit, das System (Userland) aber 32-Bit. ToutWAF benötigt ein 64-Bit-System: Installieren Sie Raspberry Pi OS 64 Bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) oder Ubuntu / Debian arm64 neu.
it|cp_r_arm_userland32|Il kernel è a 64 bit ma il sistema (userland) è a 32 bit. ToutWAF richiede un sistema a 64 bit: reinstallare con Raspberry Pi OS 64 bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) o Ubuntu / Debian arm64.
pt|cp_r_arm_userland32|O kernel é de 64 bits mas o sistema (userland) é de 32 bits. O ToutWAF precisa de um sistema de 64 bits: reinstale com Raspberry Pi OS 64 bits (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) ou Ubuntu / Debian arm64.
nl|cp_r_arm_userland32|De kernel is 64-bits maar het systeem (userland) is 32-bits. ToutWAF vereist een 64-bits besturingssysteem: installeer opnieuw met Raspberry Pi OS 64-bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) of Ubuntu / Debian arm64.
ru|cp_r_arm_userland32|Ядро 64-разрядное, но система (userland) 32-разрядная. ToutWAF нужна 64-разрядная ОС: переустановите с Raspberry Pi OS 64-bit (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) или Ubuntu / Debian arm64.
zh|cp_r_arm_userland32|内核是 64 位，但系统（用户空间）是 32 位。ToutWAF 需要 64 位系统：请重新安装 64 位 Raspberry Pi OS（Raspberry Pi Imager：Raspberry Pi OS (64-bit)）或 Ubuntu / Debian arm64。
ar|cp_r_arm_userland32|النواة 64 بت لكن النظام (userland) 32 بت. يحتاج ToutWAF إلى نظام 64 بت: أعد التثبيت باستخدام Raspberry Pi OS 64 بت (Raspberry Pi Imager: Raspberry Pi OS (64-bit)) أو Ubuntu / Debian arm64.
en|cp_w_pi|Raspberry Pi detected: arm64 is only smoke-tested under emulation, not on real hardware. Put the data and logs on an SSD / USB drive rather than the SD card, and avoid the all-in-one install below 2 GB of RAM (see docs/install/raspberry-pi.md).
fr|cp_w_pi|Raspberry Pi détecté : l'arm64 n'a été éprouvé que sous émulation, pas sur du matériel réel. Placez données et journaux sur un SSD / disque USB plutôt que sur la carte SD, et évitez l'installation tout-en-un sous 2 Go de RAM (voir docs/install/raspberry-pi.md).
es|cp_w_pi|Raspberry Pi detectada: arm64 solo se ha probado bajo emulación, no en hardware real. Ponga datos y registros en un SSD / disco USB en lugar de la tarjeta SD y evite la instalación todo en uno con menos de 2 GB de RAM (vea docs/install/raspberry-pi.md).
de|cp_w_pi|Raspberry Pi erkannt: arm64 wurde nur unter Emulation getestet, nicht auf echter Hardware. Legen Sie Daten und Logs auf eine SSD / ein USB-Laufwerk statt auf die SD-Karte und vermeiden Sie die All-in-one-Installation unter 2 GB RAM (siehe docs/install/raspberry-pi.md).
it|cp_w_pi|Raspberry Pi rilevato: arm64 è stato provato solo in emulazione, non su hardware reale. Mettere dati e log su un SSD / disco USB invece che sulla scheda SD ed evitare l'installazione tutto-in-uno sotto 2 GB di RAM (vedere docs/install/raspberry-pi.md).
pt|cp_w_pi|Raspberry Pi detetado: o arm64 só foi testado em emulação, não em hardware real. Coloque dados e registos num SSD / disco USB em vez do cartão SD e evite a instalação tudo-em-um com menos de 2 GB de RAM (ver docs/install/raspberry-pi.md).
nl|cp_w_pi|Raspberry Pi gedetecteerd: arm64 is alleen onder emulatie getest, niet op echte hardware. Zet data en logs op een SSD / USB-schijf in plaats van op de SD-kaart en vermijd de alles-in-één-installatie onder 2 GB RAM (zie docs/install/raspberry-pi.md).
ru|cp_w_pi|Обнаружен Raspberry Pi: arm64 проверялась только в эмуляции, не на реальном оборудовании. Храните данные и журналы на SSD / USB-диске, а не на SD-карте, и избегайте установки «всё в одном» при менее чем 2 ГБ ОЗУ (см. docs/install/raspberry-pi.md).
zh|cp_w_pi|检测到 Raspberry Pi：arm64 仅在仿真下做过冒烟测试，未在真实硬件上测试。请把数据和日志放在 SSD / USB 盘而不是 SD 卡上，内存低于 2 GB 时避免一体化安装（见 docs/install/raspberry-pi.md）。
ar|cp_w_pi|تم اكتشاف Raspberry Pi: لم تُختبر arm64 إلا تحت المحاكاة وليس على أجهزة حقيقية. ضع البيانات والسجلات على SSD / قرص USB بدلا من بطاقة SD وتجنب التثبيت الشامل بأقل من 2 جيجابايت من الذاكرة (راجع docs/install/raspberry-pi.md).
en|pf_title|Checking what this machine needs
fr|pf_title|Vérification de ce dont cette machine a besoin
es|pf_title|Comprobando lo que necesita esta máquina
de|pf_title|Prüfung dessen, was dieser Rechner braucht
it|pf_title|Verifica di ciò di cui ha bisogno questa macchina
pt|pf_title|A verificar o que esta máquina precisa
nl|pf_title|Controle van wat deze machine nodig heeft
ru|pf_title|Проверка того, что нужно этой машине
zh|pf_title|正在检查这台机器的需求
ar|pf_title|التحقق مما يحتاجه هذا الجهاز
en|pf_ok|Nothing is in the way: the ports ToutWAF needs are free.
fr|pf_ok|Rien ne gêne : les ports dont ToutWAF a besoin sont libres.
es|pf_ok|Nada estorba: los puertos que necesita ToutWAF están libres.
de|pf_ok|Nichts steht im Weg: Die Ports, die ToutWAF braucht, sind frei.
it|pf_ok|Nulla è d'intralcio: le porte di cui ha bisogno ToutWAF sono libere.
pt|pf_ok|Nada está no caminho: as portas de que o ToutWAF precisa estão livres.
nl|pf_ok|Niets staat in de weg: de poorten die ToutWAF nodig heeft zijn vrij.
ru|pf_ok|Ничто не мешает: порты, нужные ToutWAF, свободны.
zh|pf_ok|没有任何阻碍：ToutWAF 需要的端口都是空闲的。
ar|pf_ok|لا شيء يعيق: المنافذ التي يحتاجها ToutWAF حرة.
en|pf_refused|ToutWAF cannot be installed on this machine as it is. Nothing was changed.
fr|pf_refused|ToutWAF ne peut pas être installé sur cette machine en l'état. Rien n'a été modifié.
es|pf_refused|ToutWAF no se puede instalar en esta máquina tal como está. No se ha cambiado nada.
de|pf_refused|ToutWAF kann auf diesem Rechner so nicht installiert werden. Es wurde nichts geändert.
it|pf_refused|ToutWAF non può essere installato su questa macchina così com'è. Non è stato modificato nulla.
pt|pf_refused|O ToutWAF não pode ser instalado nesta máquina como está. Nada foi alterado.
nl|pf_refused|ToutWAF kan niet op deze machine worden geïnstalleerd zoals ze nu is. Er is niets gewijzigd.
ru|pf_refused|ToutWAF нельзя установить на эту машину в её нынешнем состоянии. Ничего не изменено.
zh|pf_refused|ToutWAF 无法在这台机器的当前状态下安装。未做任何更改。
ar|pf_refused|لا يمكن تثبيت ToutWAF على هذا الجهاز بحالته الحالية. لم يتغير شيء.
en|pf_ok_warn|Nothing prevents the installation, but read the points above.
fr|pf_ok_warn|Rien n'empêche l'installation, mais lisez les points ci-dessus.
es|pf_ok_warn|Nada impide la instalación, pero lea los puntos anteriores.
de|pf_ok_warn|Nichts verhindert die Installation, aber lesen Sie die Punkte oben.
it|pf_ok_warn|Nulla impedisce l'installazione, ma leggi i punti qui sopra.
pt|pf_ok_warn|Nada impede a instalação, mas leia os pontos acima.
nl|pf_ok_warn|Niets verhindert de installatie, maar lees de punten hierboven.
ru|pf_ok_warn|Установке ничто не мешает, но прочитайте пункты выше.
zh|pf_ok_warn|没有什么会阻止安装，但请阅读上面的几点。
ar|pf_ok_warn|لا شيء يمنع التثبيت، لكن اقرأ النقاط أعلاه.
en|pf_l_refuse|refused
fr|pf_l_refuse|refusé
es|pf_l_refuse|rechazado
de|pf_l_refuse|abgelehnt
it|pf_l_refuse|rifiutato
pt|pf_l_refuse|recusado
nl|pf_l_refuse|geweigerd
ru|pf_l_refuse|отказ
zh|pf_l_refuse|拒绝
ar|pf_l_refuse|مرفوض
en|pf_l_warn|warning
fr|pf_l_warn|attention
es|pf_l_warn|atención
de|pf_l_warn|Hinweis
it|pf_l_warn|attenzione
pt|pf_l_warn|atenção
nl|pf_l_warn|let op
ru|pf_l_warn|внимание
zh|pf_l_warn|注意
ar|pf_l_warn|تنبيه
en|pf_l_info|note
fr|pf_l_info|à savoir
es|pf_l_info|nota
de|pf_l_info|Info
it|pf_l_info|nota
pt|pf_l_info|nota
nl|pf_l_info|opmerking
ru|pf_l_info|заметка
zh|pf_l_info|说明
ar|pf_l_info|ملاحظة
en|pf_port_busy|Port %s is already used by %s.
fr|pf_port_busy|Le port %s est déjà utilisé par %s.
es|pf_port_busy|El puerto %s ya lo usa %s.
de|pf_port_busy|Port %s wird bereits von %s verwendet.
it|pf_port_busy|La porta %s è già usata da %s.
pt|pf_port_busy|A porta %s já é usada por %s.
nl|pf_port_busy|Poort %s wordt al gebruikt door %s.
ru|pf_port_busy|Порт %s уже занят: %s.
zh|pf_port_busy|%s 端口已被 %s 占用。
ar|pf_port_busy|المنفذ %s مستخدم بالفعل من %s.
en|pf_prog_other|another program
fr|pf_prog_other|un autre programme
es|pf_prog_other|otro programa
de|pf_prog_other|ein anderes Programm
it|pf_prog_other|un altro programma
pt|pf_prog_other|outro programa
nl|pf_prog_other|een ander programma
ru|pf_prog_other|другая программа
zh|pf_prog_other|另一个程序
ar|pf_prog_other|برنامج آخر
en|pf_prog_unknown|another program (its name could not be read)
fr|pf_prog_unknown|un autre programme (son nom n'a pas pu être lu)
es|pf_prog_unknown|otro programa (no se pudo leer su nombre)
de|pf_prog_unknown|ein anderes Programm (sein Name konnte nicht gelesen werden)
it|pf_prog_unknown|un altro programma (il suo nome non è leggibile)
pt|pf_prog_unknown|outro programa (não foi possível ler o nome)
nl|pf_prog_unknown|een ander programma (de naam kon niet worden gelezen)
ru|pf_prog_unknown|другая программа (её имя не удалось прочитать)
zh|pf_prog_unknown|另一个程序（无法读取其名称）
ar|pf_prog_unknown|برنامج آخر (تعذّرت قراءة اسمه)
en|pf_act_web|ToutWAF needs ports %s and %s to protect your sites. Stop that program, or move it to other ports (ToutPanel, installed beside ToutWAF, places its web server on 8080 and 8443), then run the installer again.
fr|pf_act_web|ToutWAF a besoin des ports %s et %s pour protéger vos sites. Arrêtez ce programme ou déplacez-le sur d'autres ports (ToutPanel, installé à côté de ToutWAF, place son serveur web sur 8080 et 8443), puis relancez l'installateur.
es|pf_act_web|ToutWAF necesita los puertos %s y %s para proteger sus sitios. Detenga ese programa o muévalo a otros puertos (ToutPanel, instalado junto a ToutWAF, coloca su servidor web en 8080 y 8443) y vuelva a ejecutar el instalador.
de|pf_act_web|ToutWAF braucht die Ports %s und %s, um Ihre Sites zu schützen. Beenden Sie dieses Programm oder verlegen Sie es auf andere Ports (ToutPanel, neben ToutWAF installiert, legt seinen Webserver auf 8080 und 8443) und starten Sie den Installer erneut.
it|pf_act_web|ToutWAF ha bisogno delle porte %s e %s per proteggere i tuoi siti. Ferma quel programma o spostalo su altre porte (ToutPanel, installato accanto a ToutWAF, mette il suo server web su 8080 e 8443), poi rilancia l'installer.
pt|pf_act_web|O ToutWAF precisa das portas %s e %s para proteger os seus sites. Pare esse programa ou mova-o para outras portas (o ToutPanel, instalado ao lado do ToutWAF, coloca o seu servidor web em 8080 e 8443) e volte a executar o instalador.
nl|pf_act_web|ToutWAF heeft poort %s en %s nodig om uw sites te beschermen. Stop dat programma of verplaats het naar andere poorten (ToutPanel zet, naast ToutWAF geïnstalleerd, zijn webserver op 8080 en 8443) en start het installatieprogramma opnieuw.
ru|pf_act_web|ToutWAF нужны порты %s и %s, чтобы защищать ваши сайты. Остановите эту программу или перенесите её на другие порты (ToutPanel, установленный рядом с ToutWAF, размещает свой веб-сервер на портах 8080 и 8443) и запустите установщик снова.
zh|pf_act_web|ToutWAF 需要 %s 和 %s 端口来保护您的站点。请停止该程序，或将其移到其他端口（与 ToutWAF 安装在一起的 ToutPanel 会把它的 Web 服务器放在 8080 和 8443 端口），然后重新运行安装程序。
ar|pf_act_web|يحتاج ToutWAF إلى المنفذين %s و%s لحماية مواقعك. أوقف هذا البرنامج أو انقله إلى منافذ أخرى (يضع ToutPanel المثبّت بجانب ToutWAF خادم الويب الخاص به على 8080 و8443) ثم أعد تشغيل المثبت.
en|pf_act_console|The console of ToutWAF needs this port. Free it, or choose another console port (the installer asks for it in its menu), then run the installer again.
fr|pf_act_console|La console de ToutWAF a besoin de ce port. Libérez-le, ou choisissez un autre port pour la console (l'installateur le demande dans son menu), puis relancez l'installateur.
es|pf_act_console|La consola de ToutWAF necesita este puerto. Libérelo o elija otro puerto para la consola (el instalador lo pregunta en su menú) y vuelva a ejecutar el instalador.
de|pf_act_console|Die Konsole von ToutWAF braucht diesen Port. Geben Sie ihn frei oder wählen Sie einen anderen Konsolen-Port (der Installer fragt in seinem Menü danach) und starten Sie den Installer erneut.
it|pf_act_console|La console di ToutWAF ha bisogno di questa porta. Liberala oppure scegli un'altra porta per la console (l'installer la chiede nel suo menu), poi rilancia l'installer.
pt|pf_act_console|A consola do ToutWAF precisa desta porta. Liberte-a ou escolha outra porta para a consola (o instalador pergunta no seu menu) e volte a executar o instalador.
nl|pf_act_console|De console van ToutWAF heeft deze poort nodig. Maak de poort vrij of kies een andere consolepoort (het installatieprogramma vraagt ernaar in zijn menu) en start het installatieprogramma opnieuw.
ru|pf_act_console|Этот порт нужен консоли ToutWAF. Освободите его или выберите другой порт консоли (установщик спрашивает об этом в своём меню) и запустите установщик снова.
zh|pf_act_console|ToutWAF 的控制台需要使用此端口。请释放该端口，或为控制台选择其他端口（安装程序会在菜单中询问），然后重新运行安装程序。
ar|pf_act_console|تحتاج لوحة تحكم ToutWAF إلى هذا المنفذ. حرّره أو اختر منفذًا آخر للوحة (يسأل المثبت عنه في قائمته) ثم أعد تشغيل المثبت.
en|pf_act_agent|ToutWAF uses this port for the data planes and agents that connect to it. Free it, then run the installer again.
fr|pf_act_agent|ToutWAF utilise ce port pour les plans de données et les agents qui s'y connectent. Libérez-le, puis relancez l'installateur.
es|pf_act_agent|ToutWAF usa este puerto para los planos de datos y los agentes que se conectan a él. Libérelo y vuelva a ejecutar el instalador.
de|pf_act_agent|ToutWAF nutzt diesen Port für die Data Planes und Agenten, die sich damit verbinden. Geben Sie ihn frei und starten Sie den Installer erneut.
it|pf_act_agent|ToutWAF usa questa porta per i data plane e gli agenti che vi si collegano. Liberala, poi rilancia l'installer.
pt|pf_act_agent|O ToutWAF usa esta porta para os planos de dados e os agentes que se ligam a ele. Liberte-a e volte a executar o instalador.
nl|pf_act_agent|ToutWAF gebruikt deze poort voor de data planes en agents die er verbinding mee maken. Maak de poort vrij en start het installatieprogramma opnieuw.
ru|pf_act_agent|ToutWAF использует этот порт для подключающихся к нему узлов обработки данных и агентов. Освободите его и запустите установщик снова.
zh|pf_act_agent|ToutWAF 使用此端口接收连接它的数据平面和代理。请释放该端口，然后重新运行安装程序。
ar|pf_act_agent|يستخدم ToutWAF هذا المنفذ لمستويات البيانات والوكلاء المتصلين به. حرّره ثم أعد تشغيل المثبت.
en|pf_act_admin|The data plane uses this port on this machine only, for its own health check. Free it, then run the installer again.
fr|pf_act_admin|Le plan de données utilise ce port sur cette machine seulement, pour son propre contrôle de santé. Libérez-le, puis relancez l'installateur.
es|pf_act_admin|El plano de datos usa este puerto solo en esta máquina, para su propia comprobación de estado. Libérelo y vuelva a ejecutar el instalador.
de|pf_act_admin|Die Data Plane nutzt diesen Port nur auf diesem Rechner, für ihre eigene Zustandsprüfung. Geben Sie ihn frei und starten Sie den Installer erneut.
it|pf_act_admin|Il data plane usa questa porta solo su questa macchina, per il proprio controllo di stato. Liberala, poi rilancia l'installer.
pt|pf_act_admin|O plano de dados usa esta porta apenas nesta máquina, para a sua própria verificação de estado. Liberte-a e volte a executar o instalador.
nl|pf_act_admin|De data plane gebruikt deze poort alleen op deze machine, voor zijn eigen gezondheidscontrole. Maak de poort vrij en start het installatieprogramma opnieuw.
ru|pf_act_admin|Узел обработки данных использует этот порт только на этой машине, для собственной проверки состояния. Освободите его и запустите установщик снова.
zh|pf_act_admin|数据平面仅在这台机器上使用此端口，用于自身的健康检查。请释放该端口，然后重新运行安装程序。
ar|pf_act_admin|يستخدم مستوى البيانات هذا المنفذ على هذا الجهاز فقط لفحص حالته. حرّره ثم أعد تشغيل المثبت.
en|pf_nostart|(nothing is started now, so this is only reported)
fr|pf_nostart|(rien n'est démarré maintenant, ce n'est donc que signalé)
es|pf_nostart|(ahora no se inicia nada, así que solo se informa)
de|pf_nostart|(es wird jetzt nichts gestartet, daher nur ein Hinweis)
it|pf_nostart|(ora non viene avviato nulla, quindi è solo una segnalazione)
pt|pf_nostart|(nada é iniciado agora, por isso é apenas assinalado)
nl|pf_nostart|(er wordt nu niets gestart, dus dit wordt alleen gemeld)
ru|pf_nostart|(сейчас ничего не запускается, поэтому это лишь сообщение)
zh|pf_nostart|（现在不会启动任何服务，因此仅作提示）
ar|pf_nostart|(لن يُشغَّل شيء الآن، لذلك يُكتفى بالتنبيه)
en|pf_boot|%s is installed and starts with the machine, although it is stopped now. After the next restart it would take ports %s and %s before ToutWAF.
fr|pf_boot|%s est installé et démarre avec la machine, bien qu'il soit arrêté en ce moment. Au prochain redémarrage il prendrait les ports %s et %s avant ToutWAF.
es|pf_boot|%s está instalado y arranca con la máquina, aunque ahora esté detenido. En el próximo reinicio ocuparía los puertos %s y %s antes que ToutWAF.
de|pf_boot|%s ist installiert und startet mit dem Rechner, obwohl es gerade gestoppt ist. Beim nächsten Neustart würde es die Ports %s und %s vor ToutWAF belegen.
it|pf_boot|%s è installato e parte con la macchina, anche se ora è fermo. Al prossimo riavvio occuperebbe le porte %s e %s prima di ToutWAF.
pt|pf_boot|%s está instalado e arranca com a máquina, embora esteja parado neste momento. No próximo reinício ocuparia as portas %s e %s antes do ToutWAF.
nl|pf_boot|%s is geïnstalleerd en start met de machine, hoewel het nu gestopt is. Bij de volgende herstart zou het poort %s en %s bezetten vóór ToutWAF.
ru|pf_boot|%s установлен и запускается вместе с машиной, хотя сейчас остановлен. После следующей перезагрузки он займёт порты %s и %s раньше ToutWAF.
zh|pf_boot|%s 已安装并会随机器启动，尽管它现在已停止。下次重启后，它会抢在 ToutWAF 之前占用 %s 和 %s 端口。
ar|pf_boot|%s مثبّت ويبدأ مع الجهاز رغم أنه متوقف الآن. عند إعادة التشغيل التالية سيحجز المنفذين %s و%s قبل ToutWAF.
en|pf_act_boot|Disable it so that it does not start with the machine, or move it to other ports, before the machine restarts.
fr|pf_act_boot|Désactivez-le pour qu'il ne démarre plus avec la machine, ou déplacez-le sur d'autres ports, avant le redémarrage de la machine.
es|pf_act_boot|Desactívelo para que no arranque con la máquina, o muévalo a otros puertos, antes de reiniciar la máquina.
de|pf_act_boot|Deaktivieren Sie den Autostart oder verlegen Sie es auf andere Ports, bevor der Rechner neu startet.
it|pf_act_boot|Disattivalo perché non parta con la macchina, oppure spostalo su altre porte, prima del riavvio della macchina.
pt|pf_act_boot|Desative-o para que não arranque com a máquina, ou mova-o para outras portas, antes de reiniciar a máquina.
nl|pf_act_boot|Schakel het uit zodat het niet met de machine start, of verplaats het naar andere poorten, vóór de machine opnieuw start.
ru|pf_act_boot|Отключите его автозапуск или перенесите на другие порты до перезагрузки машины.
zh|pf_act_boot|请在机器重启前禁用它的开机启动，或将其移到其他端口。
ar|pf_act_boot|عطّل تشغيله مع الجهاز أو انقله إلى منافذ أخرى قبل إعادة تشغيل الجهاز.
en|pf_fw_cause|A firewall (%s) is active and does not let ports %s and %s through, and the installer was told not to change it.
fr|pf_fw_cause|Un pare-feu (%s) est actif et ne laisse pas passer les ports %s et %s, et l'installateur a reçu l'ordre de ne pas le modifier.
es|pf_fw_cause|Hay un cortafuegos (%s) activo que no deja pasar los puertos %s y %s, y se ha indicado al instalador que no lo modifique.
de|pf_fw_cause|Eine Firewall (%s) ist aktiv und lässt die Ports %s und %s nicht durch, und der Installer soll sie nicht ändern.
it|pf_fw_cause|Un firewall (%s) è attivo e non lascia passare le porte %s e %s, e all'installer è stato detto di non modificarlo.
pt|pf_fw_cause|Uma firewall (%s) está ativa e não deixa passar as portas %s e %s, e o instalador foi instruído a não a alterar.
nl|pf_fw_cause|Een firewall (%s) is actief en laat poort %s en %s niet door, en het installatieprogramma mag hem niet wijzigen.
ru|pf_fw_cause|Активен межсетевой экран (%s), он не пропускает порты %s и %s, а установщику велено его не менять.
zh|pf_fw_cause|防火墙（%s）处于启用状态且不放行 %s 和 %s 端口，而安装程序被要求不要修改它。
ar|pf_fw_cause|جدار حماية (%s) نشط ولا يسمح بمرور المنفذين %s و%s، وقد طُلب من المثبت ألا يغيّره.
en|pf_fw_action|Open these ports in the firewall, or let the installer do it (do not use --no-firewall). Without that, your sites cannot be reached from outside.
fr|pf_fw_action|Ouvrez ces ports dans le pare-feu, ou laissez l'installateur le faire (sans l'option --no-firewall). Sinon, vos sites ne seront pas joignables de l'extérieur.
es|pf_fw_action|Abra esos puertos en el cortafuegos o deje que lo haga el instalador (sin la opción --no-firewall). Si no, sus sitios no serán accesibles desde el exterior.
de|pf_fw_action|Öffnen Sie diese Ports in der Firewall oder lassen Sie den Installer es tun (ohne die Option --no-firewall). Sonst sind Ihre Sites von außen nicht erreichbar.
it|pf_fw_action|Apri queste porte nel firewall oppure lascia che lo faccia l'installer (senza l'opzione --no-firewall). Altrimenti i tuoi siti non saranno raggiungibili dall'esterno.
pt|pf_fw_action|Abra essas portas na firewall ou deixe o instalador fazê-lo (sem a opção --no-firewall). Caso contrário, os seus sites não serão acessíveis do exterior.
nl|pf_fw_action|Open deze poorten in de firewall of laat het installatieprogramma het doen (zonder de optie --no-firewall). Anders zijn uw sites van buitenaf niet bereikbaar.
ru|pf_fw_action|Откройте эти порты в межсетевом экране или позвольте это сделать установщику (без параметра --no-firewall). Иначе ваши сайты будут недоступны снаружи.
zh|pf_fw_action|请在防火墙中开放这些端口，或让安装程序来做（不要使用 --no-firewall 选项）。否则外部无法访问您的站点。
ar|pf_fw_action|افتح هذين المنفذين في جدار الحماية أو دع المثبت يفعل ذلك (بدون الخيار --no-firewall). وإلا فلن تكون مواقعك قابلة للوصول من الخارج.
en|pf_fwx_cause|The firewall of this machine (%s) refuses incoming connections by default and has no rule for ports %s and %s.
fr|pf_fwx_cause|Le pare-feu de cette machine (%s) refuse les connexions entrantes par défaut et n'a aucune règle pour les ports %s et %s.
es|pf_fwx_cause|El cortafuegos de esta máquina (%s) rechaza las conexiones entrantes por defecto y no tiene ninguna regla para los puertos %s y %s.
de|pf_fwx_cause|Die Firewall dieses Rechners (%s) lehnt eingehende Verbindungen standardmäßig ab und hat keine Regel für die Ports %s und %s.
it|pf_fwx_cause|Il firewall di questa macchina (%s) rifiuta le connessioni in ingresso per impostazione predefinita e non ha regole per le porte %s e %s.
pt|pf_fwx_cause|A firewall desta máquina (%s) recusa por defeito as ligações de entrada e não tem nenhuma regra para as portas %s e %s.
nl|pf_fwx_cause|De firewall van deze machine (%s) weigert inkomende verbindingen standaard en heeft geen regel voor poort %s en %s.
ru|pf_fwx_cause|Межсетевой экран этой машины (%s) по умолчанию отклоняет входящие соединения и не имеет правил для портов %s и %s.
zh|pf_fwx_cause|这台机器的防火墙（%s）默认拒绝入站连接，且没有针对 %s 和 %s 端口的规则。
ar|pf_fwx_cause|جدار حماية هذا الجهاز (%s) يرفض الاتصالات الواردة افتراضيًا وليس فيه قاعدة للمنفذين %s و%s.
en|pf_fwx_action|ToutWAF never changes the rules of this kind of firewall itself: open these ports in its configuration, then check your sites.
fr|pf_fwx_action|ToutWAF ne modifie jamais lui-même les règles de ce type de pare-feu : ouvrez ces ports dans sa configuration, puis vérifiez vos sites.
es|pf_fwx_action|ToutWAF nunca modifica por sí mismo las reglas de este tipo de cortafuegos: abra esos puertos en su configuración y compruebe sus sitios.
de|pf_fwx_action|ToutWAF ändert die Regeln dieser Art von Firewall nie selbst: Öffnen Sie diese Ports in deren Konfiguration und prüfen Sie dann Ihre Sites.
it|pf_fwx_action|ToutWAF non modifica mai da solo le regole di questo tipo di firewall: apri queste porte nella sua configurazione, poi controlla i tuoi siti.
pt|pf_fwx_action|O ToutWAF nunca altera por si as regras deste tipo de firewall: abra essas portas na sua configuração e verifique os seus sites.
nl|pf_fwx_action|ToutWAF wijzigt de regels van dit soort firewall nooit zelf: open deze poorten in de configuratie ervan en controleer daarna uw sites.
ru|pf_fwx_action|ToutWAF никогда сам не меняет правила такого межсетевого экрана: откройте эти порты в его настройках, затем проверьте свои сайты.
zh|pf_fwx_action|ToutWAF 绝不会自行修改这类防火墙的规则：请在其配置中开放这些端口，然后检查您的站点。
ar|pf_fwx_action|لا يعدّل ToutWAF بنفسه أبدًا قواعد هذا النوع من جدران الحماية: افتح هذين المنفذين في إعداداته ثم تحقق من مواقعك.
en|pf_cp_cause|The control plane %s cannot be reached from this machine.
fr|pf_cp_cause|Le plan de contrôle %s est injoignable depuis cette machine.
es|pf_cp_cause|No se puede alcanzar el plano de control %s desde esta máquina.
de|pf_cp_cause|Die Control Plane %s ist von diesem Rechner aus nicht erreichbar.
it|pf_cp_cause|Il control plane %s non è raggiungibile da questa macchina.
pt|pf_cp_cause|O plano de controlo %s não é acessível a partir desta máquina.
nl|pf_cp_cause|De control plane %s is vanaf deze machine niet bereikbaar.
ru|pf_cp_cause|Управляющий узел %s недоступен с этой машины.
zh|pf_cp_cause|无法从这台机器访问控制平面 %s。
ar|pf_cp_cause|تعذّر الوصول إلى مستوى التحكم %s من هذا الجهاز.
en|pf_cp_action|Check the address, that the control plane is running, and that its firewall lets this machine reach it (port 9444 by default), then run the installer again.
fr|pf_cp_action|Vérifiez l'adresse, que le plan de contrôle fonctionne et que son pare-feu laisse cette machine l'atteindre (port 9444 par défaut), puis relancez l'installateur.
es|pf_cp_action|Compruebe la dirección, que el plano de control funciona y que su cortafuegos deja que esta máquina lo alcance (puerto 9444 por defecto) y vuelva a ejecutar el instalador.
de|pf_cp_action|Prüfen Sie die Adresse, ob die Control Plane läuft und ob deren Firewall diesen Rechner durchlässt (standardmäßig Port 9444), und starten Sie den Installer erneut.
it|pf_cp_action|Verifica l'indirizzo, che il control plane sia in funzione e che il suo firewall lasci raggiungerlo da questa macchina (porta 9444 per impostazione predefinita), poi rilancia l'installer.
pt|pf_cp_action|Verifique o endereço, se o plano de controlo está a funcionar e se a sua firewall deixa esta máquina chegar a ele (porta 9444 por defeito) e volte a executar o instalador.
nl|pf_cp_action|Controleer het adres, of de control plane draait en of zijn firewall deze machine toelaat (standaard poort 9444) en start het installatieprogramma opnieuw.
ru|pf_cp_action|Проверьте адрес, работает ли управляющий узел и пропускает ли его межсетевой экран эту машину (по умолчанию порт 9444), и запустите установщик снова.
zh|pf_cp_action|请检查地址、控制平面是否在运行，以及其防火墙是否允许这台机器访问它（默认 9444 端口），然后重新运行安装程序。
ar|pf_cp_action|تحقق من العنوان ومن أن مستوى التحكم يعمل وأن جدار الحماية فيه يسمح لهذا الجهاز بالوصول إليه (المنفذ 9444 افتراضيًا) ثم أعد تشغيل المثبت.
en|pf_router_cause|This machine has a private address (%s): it is probably behind a router or a box.
fr|pf_router_cause|Cette machine a une adresse privée (%s) : elle est probablement derrière un routeur ou une box.
es|pf_router_cause|Esta máquina tiene una dirección privada (%s): probablemente está detrás de un router.
de|pf_router_cause|Dieser Rechner hat eine private Adresse (%s): Er steht wahrscheinlich hinter einem Router.
it|pf_router_cause|Questa macchina ha un indirizzo privato (%s): probabilmente è dietro un router.
pt|pf_router_cause|Esta máquina tem um endereço privado (%s): provavelmente está atrás de um router.
nl|pf_router_cause|Deze machine heeft een privéadres (%s): ze staat waarschijnlijk achter een router.
ru|pf_router_cause|У этой машины частный адрес (%s): скорее всего, она находится за маршрутизатором.
zh|pf_router_cause|这台机器使用专用地址（%s）：它很可能位于路由器之后。
ar|pf_router_cause|لهذا الجهاز عنوان خاص (%s): من المرجح أنه خلف راوتر.
en|pf_router_action|Once installed, ToutWAF shows which ports to forward to this machine and gives the files for the usual routers. There is nothing to prepare now.
fr|pf_router_action|Une fois installé, ToutWAF indique les ports à rediriger vers cette machine et fournit les fichiers pour les routeurs usuels. Il n'y a rien à préparer maintenant.
es|pf_router_action|Una vez instalado, ToutWAF indica qué puertos redirigir a esta máquina y proporciona los archivos para los routers habituales. No hay nada que preparar ahora.
de|pf_router_action|Nach der Installation zeigt ToutWAF, welche Ports an diesen Rechner weitergeleitet werden müssen, und liefert die Dateien für gängige Router. Jetzt ist nichts vorzubereiten.
it|pf_router_action|Una volta installato, ToutWAF indica quali porte inoltrare a questa macchina e fornisce i file per i router più comuni. Non c'è nulla da preparare ora.
pt|pf_router_action|Depois de instalado, o ToutWAF indica que portas reencaminhar para esta máquina e fornece os ficheiros para os routers habituais. Não há nada a preparar agora.
nl|pf_router_action|Na de installatie toont ToutWAF welke poorten naar deze machine doorgestuurd moeten worden en geeft het de bestanden voor de gangbare routers. Nu hoeft u niets voor te bereiden.
ru|pf_router_action|После установки ToutWAF покажет, какие порты нужно пробросить на эту машину, и даст файлы для распространённых маршрутизаторов. Сейчас ничего готовить не нужно.
zh|pf_router_action|安装后，ToutWAF 会显示需要转发到这台机器的端口，并提供常见路由器的配置文件。现在无需准备任何东西。
ar|pf_router_action|بعد التثبيت سيعرض ToutWAF المنافذ التي يجب توجيهها إلى هذا الجهاز ويقدّم ملفات للراوترات الشائعة. لا شيء يلزم تحضيره الآن.
en|pf_skipped|The environment check was skipped as you asked: what is in the way will make the installation or the start fail later.
fr|pf_skipped|La vérification de l'environnement a été sautée à votre demande : ce qui gêne fera échouer l'installation ou le démarrage plus tard.
es|pf_skipped|Se omitió la comprobación del entorno como pidió: lo que estorbe hará fallar la instalación o el arranque más adelante.
de|pf_skipped|Die Umgebungsprüfung wurde auf Ihren Wunsch übersprungen: Was im Weg steht, lässt die Installation oder den Start später scheitern.
it|pf_skipped|La verifica dell'ambiente è stata saltata come richiesto: ciò che è d'intralcio farà fallire più tardi l'installazione o l'avvio.
pt|pf_skipped|A verificação do ambiente foi ignorada a seu pedido: o que estiver no caminho fará falhar mais tarde a instalação ou o arranque.
nl|pf_skipped|De controle van de omgeving is op uw verzoek overgeslagen: wat in de weg staat laat de installatie of de start later mislukken.
ru|pf_skipped|Проверка окружения пропущена по вашей просьбе: то, что мешает, приведёт к сбою установки или запуска позже.
zh|pf_skipped|已按您的要求跳过环境检查：存在的阻碍将导致之后的安装或启动失败。
ar|pf_skipped|تم تخطي فحص البيئة بناءً على طلبك: ما يعيق سيؤدي إلى فشل التثبيت أو التشغيل لاحقًا.
en|s_sysupdate|Updating the system packages (this can take several minutes)
fr|s_sysupdate|Mise à jour des paquets système (cela peut prendre plusieurs minutes)
es|s_sysupdate|Actualizando los paquetes del sistema (puede tardar varios minutos)
de|s_sysupdate|Systempakete werden aktualisiert (das kann einige Minuten dauern)
it|s_sysupdate|Aggiornamento dei pacchetti di sistema (può richiedere qualche minuto)
pt|s_sysupdate|A atualizar os pacotes do sistema (pode demorar alguns minutos)
nl|s_sysupdate|Systeempakketten worden bijgewerkt (dit kan enkele minuten duren)
ru|s_sysupdate|Обновление системных пакетов (это может занять несколько минут)
zh|s_sysupdate|正在更新系统软件包（可能需要几分钟）
ar|s_sysupdate|جارٍ تحديث حزم النظام (قد يستغرق ذلك عدة دقائق)
en|su_skipped|The system packages are not updated first (TOUTWAF_SKIP_SYSUPDATE).
fr|su_skipped|Les paquets système ne sont pas mis à jour au préalable (TOUTWAF_SKIP_SYSUPDATE).
es|su_skipped|Los paquetes del sistema no se actualizan antes (TOUTWAF_SKIP_SYSUPDATE).
de|su_skipped|Die Systempakete werden nicht vorher aktualisiert (TOUTWAF_SKIP_SYSUPDATE).
it|su_skipped|I pacchetti di sistema non vengono aggiornati prima (TOUTWAF_SKIP_SYSUPDATE).
pt|su_skipped|Os pacotes do sistema não são atualizados antes (TOUTWAF_SKIP_SYSUPDATE).
nl|su_skipped|De systeempakketten worden niet eerst bijgewerkt (TOUTWAF_SKIP_SYSUPDATE).
ru|su_skipped|Системные пакеты предварительно не обновляются (TOUTWAF_SKIP_SYSUPDATE).
zh|su_skipped|不会先更新系统软件包（TOUTWAF_SKIP_SYSUPDATE）。
ar|su_skipped|لن يتم تحديث حزم النظام أولاً (TOUTWAF_SKIP_SYSUPDATE).
en|su_recent|The system packages were updated less than 6 hours ago: not repeated.
fr|su_recent|Les paquets système ont été mis à jour il y a moins de 6 heures : pas de nouvelle mise à jour.
es|su_recent|Los paquetes del sistema se actualizaron hace menos de 6 horas: no se repite.
de|su_recent|Die Systempakete wurden vor weniger als 6 Stunden aktualisiert: keine Wiederholung.
it|su_recent|I pacchetti di sistema sono stati aggiornati meno di 6 ore fa: non si ripete.
pt|su_recent|Os pacotes do sistema foram atualizados há menos de 6 horas: não se repete.
nl|su_recent|De systeempakketten zijn minder dan 6 uur geleden bijgewerkt: niet herhaald.
ru|su_recent|Системные пакеты обновлялись менее 6 часов назад: повторно не обновляются.
zh|su_recent|系统软件包在 6 小时内已更新过，不再重复。
ar|su_recent|تم تحديث حزم النظام قبل أقل من 6 ساعات: لن يُكرَّر التحديث.
en|su_dry|the system packages would be updated first (skip it with TOUTWAF_SKIP_SYSUPDATE=1)
fr|su_dry|les paquets système seraient d'abord mis à jour (à éviter avec TOUTWAF_SKIP_SYSUPDATE=1)
es|su_dry|los paquetes del sistema se actualizarían primero (se omite con TOUTWAF_SKIP_SYSUPDATE=1)
de|su_dry|die Systempakete würden zuerst aktualisiert (überspringen mit TOUTWAF_SKIP_SYSUPDATE=1)
it|su_dry|i pacchetti di sistema verrebbero aggiornati per primi (si salta con TOUTWAF_SKIP_SYSUPDATE=1)
pt|su_dry|os pacotes do sistema seriam atualizados primeiro (para saltar: TOUTWAF_SKIP_SYSUPDATE=1)
nl|su_dry|de systeempakketten zouden eerst worden bijgewerkt (overslaan met TOUTWAF_SKIP_SYSUPDATE=1)
ru|su_dry|сначала были бы обновлены системные пакеты (пропустить: TOUTWAF_SKIP_SYSUPDATE=1)
zh|su_dry|将先更新系统软件包（使用 TOUTWAF_SKIP_SYSUPDATE=1 可跳过）
ar|su_dry|سيتم تحديث حزم النظام أولاً (لتخطي ذلك: TOUTWAF_SKIP_SYSUPDATE=1)
en|su_nopm|No supported package manager to update the system packages: skipped, the installation goes on.
fr|su_nopm|Aucun gestionnaire de paquets pris en charge pour mettre le système à jour : étape ignorée, l'installation continue.
es|su_nopm|No hay un gestor de paquetes compatible para actualizar el sistema: se omite y la instalación continúa.
de|su_nopm|Kein unterstützter Paketmanager für die Systemaktualisierung: übersprungen, die Installation läuft weiter.
it|su_nopm|Nessun gestore di pacchetti supportato per aggiornare il sistema: saltato, l'installazione continua.
pt|su_nopm|Nenhum gestor de pacotes suportado para atualizar o sistema: ignorado, a instalação continua.
nl|su_nopm|Geen ondersteunde pakketbeheerder om het systeem bij te werken: overgeslagen, de installatie gaat door.
ru|su_nopm|Нет поддерживаемого менеджера пакетов для обновления системы: шаг пропущен, установка продолжается.
zh|su_nopm|没有受支持的包管理器可用于更新系统：已跳过，安装继续。
ar|su_nopm|لا يوجد مدير حزم مدعوم لتحديث النظام: تم التخطي وتستمر عملية التثبيت.
en|su_failed|The update of the system packages failed (exit %s); the installation goes on without it. Details: %s. Fix: run the update yourself and read its error (broken repository? another package manager running?), or run this command again with TOUTWAF_SKIP_SYSUPDATE=1.
fr|su_failed|La mise à jour des paquets système a échoué (code %s) ; l'installation continue sans elle. Détails : %s. Correction : lancez la mise à jour vous-même et lisez son erreur (dépôt cassé ? un autre gestionnaire de paquets en cours ?), ou relancez cette commande avec TOUTWAF_SKIP_SYSUPDATE=1.
es|su_failed|La actualización de los paquetes del sistema ha fallado (código %s); la instalación continúa sin ella. Detalles: %s. Solución: ejecute usted mismo la actualización y lea su error (¿repositorio roto? ¿otro gestor de paquetes en ejecución?), o vuelva a ejecutar este comando con TOUTWAF_SKIP_SYSUPDATE=1.
de|su_failed|Die Aktualisierung der Systempakete ist fehlgeschlagen (Code %s); die Installation läuft ohne sie weiter. Details: %s. Abhilfe: Führen Sie die Aktualisierung selbst aus und lesen Sie die Fehlermeldung (defektes Repository? läuft ein anderer Paketmanager?), oder starten Sie diesen Befehl erneut mit TOUTWAF_SKIP_SYSUPDATE=1.
it|su_failed|L'aggiornamento dei pacchetti di sistema non è riuscito (codice %s); l'installazione continua senza. Dettagli: %s. Soluzione: esegui tu l'aggiornamento e leggi l'errore (repository guasto? un altro gestore di pacchetti in esecuzione?), oppure rilancia questo comando con TOUTWAF_SKIP_SYSUPDATE=1.
pt|su_failed|A atualização dos pacotes do sistema falhou (código %s); a instalação continua sem ela. Detalhes: %s. Solução: execute a atualização e leia o erro (repositório danificado? outro gestor de pacotes em execução?), ou volte a executar este comando com TOUTWAF_SKIP_SYSUPDATE=1.
nl|su_failed|Het bijwerken van de systeempakketten is mislukt (code %s); de installatie gaat zonder verder. Details: %s. Oplossing: voer de update zelf uit en lees de foutmelding (kapotte repository? draait er een andere pakketbeheerder?), of voer dit commando opnieuw uit met TOUTWAF_SKIP_SYSUPDATE=1.
ru|su_failed|Не удалось обновить системные пакеты (код %s); установка продолжается без этого. Подробности: %s. Что делать: запустите обновление вручную и прочитайте ошибку (повреждён репозиторий? работает другой менеджер пакетов?) либо повторите эту команду с TOUTWAF_SKIP_SYSUPDATE=1.
zh|su_failed|系统软件包更新失败（退出码 %s）；安装将在不更新的情况下继续。详情：%s。处理方法：请自行运行更新并查看错误（软件源损坏？另一个包管理器正在运行？），或加上 TOUTWAF_SKIP_SYSUPDATE=1 重新运行此命令。
ar|su_failed|فشل تحديث حزم النظام (الرمز %s)؛ ستستمر عملية التثبيت بدونه. التفاصيل: %s. الحل: شغّل التحديث بنفسك واقرأ رسالة الخطأ (مستودع معطّل؟ مدير حزم آخر قيد التشغيل؟) أو أعد تشغيل هذا الأمر مع TOUTWAF_SKIP_SYSUPDATE=1.
en|su_reboot|A restart of this server is needed to finish the system update (new kernel or libraries). ToutWAF never restarts it for you: do it when you can.
fr|su_reboot|Un redémarrage de ce serveur est nécessaire pour terminer la mise à jour du système (nouveau noyau ou nouvelles bibliothèques). ToutWAF ne le redémarre jamais à votre place : faites-le dès que possible.
es|su_reboot|Hace falta reiniciar este servidor para terminar la actualización del sistema (nuevo kernel o bibliotecas). ToutWAF nunca lo reinicia por usted: hágalo cuando pueda.
de|su_reboot|Zum Abschluss der Systemaktualisierung ist ein Neustart dieses Servers nötig (neuer Kernel oder neue Bibliotheken). ToutWAF startet ihn nie für Sie neu: Tun Sie es, wenn es passt.
it|su_reboot|Serve riavviare questo server per completare l'aggiornamento del sistema (nuovo kernel o librerie). ToutWAF non lo riavvia mai al posto tuo: fallo quando puoi.
pt|su_reboot|É preciso reiniciar este servidor para concluir a atualização do sistema (novo kernel ou bibliotecas). O ToutWAF nunca o reinicia por si: faça-o quando puder.
nl|su_reboot|Een herstart van deze server is nodig om de systeemupdate af te ronden (nieuwe kernel of bibliotheken). ToutWAF herstart hem nooit voor u: doe het wanneer het kan.
ru|su_reboot|Для завершения обновления системы нужно перезагрузить этот сервер (новое ядро или библиотеки). ToutWAF никогда не перезагружает его за вас: сделайте это, когда сможете.
zh|su_reboot|需要重启此服务器才能完成系统更新（新内核或库）。ToutWAF 绝不会替您重启：请在方便时自行重启。
ar|su_reboot|يلزم إعادة تشغيل هذا الخادم لإكمال تحديث النظام (نواة أو مكتبات جديدة). لا يعيد ToutWAF تشغيله نيابةً عنك أبداً: افعل ذلك عندما تستطيع.
en|q_sysupdate|Update the system packages first (recommended)?
fr|q_sysupdate|Mettre d'abord à jour les paquets système (recommandé) ?
es|q_sysupdate|¿Actualizar primero los paquetes del sistema (recomendado)?
de|q_sysupdate|Zuerst die Systempakete aktualisieren (empfohlen)?
it|q_sysupdate|Aggiornare prima i pacchetti di sistema (consigliato)?
pt|q_sysupdate|Atualizar primeiro os pacotes do sistema (recomendado)?
nl|q_sysupdate|Eerst de systeempakketten bijwerken (aanbevolen)?
ru|q_sysupdate|Сначала обновить системные пакеты (рекомендуется)?
zh|q_sysupdate|先更新系统软件包（推荐）？
ar|q_sysupdate|هل تريد تحديث حزم النظام أولاً (موصى به)؟
en|pr_disk_full|Only %s MB are free on %s (at least %s MB are needed): the installation could not finish.
fr|pr_disk_full|Seulement %s Mo sont libres sur %s (il en faut au moins %s Mo) : l'installation ne pourrait pas se terminer.
es|pr_disk_full|Solo quedan %s MB libres en %s (se necesitan al menos %s MB): la instalación no podría terminar.
de|pr_disk_full|Nur %s MB sind frei auf %s (mindestens %s MB werden benötigt): Die Installation könnte nicht abgeschlossen werden.
it|pr_disk_full|Solo %s MB liberi su %s (ne servono almeno %s MB): l'installazione non potrebbe concludersi.
pt|pr_disk_full|Apenas %s MB livres em %s (são precisos pelo menos %s MB): a instalação não poderia terminar.
nl|pr_disk_full|Slechts %s MB vrij op %s (minstens %s MB nodig): de installatie zou niet kunnen worden voltooid.
ru|pr_disk_full|Свободно только %s МБ на %s (нужно не менее %s МБ): установка не сможет завершиться.
zh|pr_disk_full|仅剩 %s MB 可用空间，位于 %s（至少需要 %s MB）：安装无法完成。
ar|pr_disk_full|المساحة الحرة %s ميغابايت فقط على %s (المطلوب %s ميغابايت على الأقل): لا يمكن إكمال التثبيت.
en|pr_disk_full_a|Free some space (package cache: apt-get clean or dnf clean all; old logs: journalctl --vacuum-size=100M), then run this command again. To go on anyway: TOUTWAF_SKIP_PREREQ=1.
fr|pr_disk_full_a|Libérez de la place (cache des paquets : apt-get clean ou dnf clean all ; anciens journaux : journalctl --vacuum-size=100M), puis relancez cette commande. Pour continuer malgré tout : TOUTWAF_SKIP_PREREQ=1.
es|pr_disk_full_a|Libere espacio (caché de paquetes: apt-get clean o dnf clean all; registros antiguos: journalctl --vacuum-size=100M) y vuelva a ejecutar este comando. Para continuar de todos modos: TOUTWAF_SKIP_PREREQ=1.
de|pr_disk_full_a|Schaffen Sie Platz (Paket-Cache: apt-get clean oder dnf clean all; alte Logs: journalctl --vacuum-size=100M) und führen Sie diesen Befehl erneut aus. Trotzdem fortfahren: TOUTWAF_SKIP_PREREQ=1.
it|pr_disk_full_a|Libera spazio (cache dei pacchetti: apt-get clean o dnf clean all; vecchi log: journalctl --vacuum-size=100M), poi rilancia questo comando. Per proseguire comunque: TOUTWAF_SKIP_PREREQ=1.
pt|pr_disk_full_a|Liberte espaço (cache de pacotes: apt-get clean ou dnf clean all; registos antigos: journalctl --vacuum-size=100M) e volte a executar este comando. Para continuar mesmo assim: TOUTWAF_SKIP_PREREQ=1.
nl|pr_disk_full_a|Maak ruimte vrij (pakketcache: apt-get clean of dnf clean all; oude logs: journalctl --vacuum-size=100M) en voer dit commando opnieuw uit. Toch doorgaan: TOUTWAF_SKIP_PREREQ=1.
ru|pr_disk_full_a|Освободите место (кэш пакетов: apt-get clean или dnf clean all; старые журналы: journalctl --vacuum-size=100M) и повторите эту команду. Чтобы всё равно продолжить: TOUTWAF_SKIP_PREREQ=1.
zh|pr_disk_full_a|请释放一些空间（软件包缓存：apt-get clean 或 dnf clean all；旧日志：journalctl --vacuum-size=100M），然后重新运行此命令。如要强行继续：TOUTWAF_SKIP_PREREQ=1。
ar|pr_disk_full_a|حرّر بعض المساحة (ذاكرة الحزم المؤقتة: apt-get clean أو dnf clean all؛ السجلات القديمة: journalctl --vacuum-size=100M) ثم أعد تشغيل هذا الأمر. للمتابعة رغم ذلك: TOUTWAF_SKIP_PREREQ=1.
en|pr_disk_full_w_a|Free some space (Disk Cleanup, empty the recycle bin), then run this command again. To go on anyway: $env:TOUTWAF_SKIP_PREREQ=1
fr|pr_disk_full_w_a|Libérez de la place (Nettoyage de disque, vidage de la corbeille), puis relancez cette commande. Pour continuer malgré tout : $env:TOUTWAF_SKIP_PREREQ=1
es|pr_disk_full_w_a|Libere espacio (Liberador de espacio en disco, vaciar la papelera) y vuelva a ejecutar este comando. Para continuar de todos modos: $env:TOUTWAF_SKIP_PREREQ=1
de|pr_disk_full_w_a|Schaffen Sie Platz (Datenträgerbereinigung, Papierkorb leeren) und führen Sie diesen Befehl erneut aus. Trotzdem fortfahren: $env:TOUTWAF_SKIP_PREREQ=1
it|pr_disk_full_w_a|Libera spazio (Pulizia disco, svuota il cestino), poi rilancia questo comando. Per proseguire comunque: $env:TOUTWAF_SKIP_PREREQ=1
pt|pr_disk_full_w_a|Liberte espaço (Limpeza do Disco, esvaziar a reciclagem) e volte a executar este comando. Para continuar mesmo assim: $env:TOUTWAF_SKIP_PREREQ=1
nl|pr_disk_full_w_a|Maak ruimte vrij (Schijfopruiming, prullenbak legen) en voer dit commando opnieuw uit. Toch doorgaan: $env:TOUTWAF_SKIP_PREREQ=1
ru|pr_disk_full_w_a|Освободите место (Очистка диска, очистка корзины) и повторите эту команду. Чтобы всё равно продолжить: $env:TOUTWAF_SKIP_PREREQ=1
zh|pr_disk_full_w_a|请释放一些空间（磁盘清理、清空回收站），然后重新运行此命令。如要强行继续：$env:TOUTWAF_SKIP_PREREQ=1
ar|pr_disk_full_w_a|حرّر بعض المساحة (تنظيف القرص، إفراغ سلة المحذوفات) ثم أعد تشغيل هذا الأمر. للمتابعة رغم ذلك: $env:TOUTWAF_SKIP_PREREQ=1
en|pr_disk_low|Only %s MB are free on %s (about %s MB are comfortable).
fr|pr_disk_low|Seulement %s Mo sont libres sur %s (environ %s Mo sont confortables).
es|pr_disk_low|Solo quedan %s MB libres en %s (unos %s MB son lo cómodo).
de|pr_disk_low|Nur %s MB sind frei auf %s (etwa %s MB sind komfortabel).
it|pr_disk_low|Solo %s MB liberi su %s (circa %s MB sono comodi).
pt|pr_disk_low|Apenas %s MB livres em %s (cerca de %s MB são confortáveis).
nl|pr_disk_low|Slechts %s MB vrij op %s (ongeveer %s MB is comfortabel).
ru|pr_disk_low|Свободно только %s МБ на %s (комфортно — около %s МБ).
zh|pr_disk_low|仅剩 %s MB 可用空间，位于 %s（约 %s MB 较为宽裕）。
ar|pr_disk_low|المساحة الحرة %s ميغابايت فقط على %s (يُفضَّل نحو %s ميغابايت).
en|pr_disk_low_a|Free some space or add disk space; the installation can go on.
fr|pr_disk_low_a|Libérez de la place ou ajoutez du disque ; l'installation peut continuer.
es|pr_disk_low_a|Libere espacio o añada disco; la instalación puede continuar.
de|pr_disk_low_a|Schaffen Sie Platz oder fügen Sie Speicher hinzu; die Installation kann weiterlaufen.
it|pr_disk_low_a|Libera spazio o aggiungi disco; l'installazione può proseguire.
pt|pr_disk_low_a|Liberte espaço ou adicione disco; a instalação pode continuar.
nl|pr_disk_low_a|Maak ruimte vrij of voeg schijfruimte toe; de installatie kan doorgaan.
ru|pr_disk_low_a|Освободите место или добавьте диск; установка может продолжаться.
zh|pr_disk_low_a|请释放空间或增加磁盘；安装可以继续。
ar|pr_disk_low_a|حرّر بعض المساحة أو أضف قرصاً؛ يمكن أن يستمر التثبيت.
en|pr_dns|This machine cannot resolve the name %s (DNS).
fr|pr_dns|Cette machine ne parvient pas à résoudre le nom %s (DNS).
es|pr_dns|Esta máquina no puede resolver el nombre %s (DNS).
de|pr_dns|Dieser Rechner kann den Namen %s nicht auflösen (DNS).
it|pr_dns|Questa macchina non riesce a risolvere il nome %s (DNS).
pt|pr_dns|Esta máquina não consegue resolver o nome %s (DNS).
nl|pr_dns|Deze machine kan de naam %s niet omzetten (DNS).
ru|pr_dns|Эта машина не может разрешить имя %s (DNS).
zh|pr_dns|这台机器无法解析名称 %s（DNS）。
ar|pr_dns|لا يستطيع هذا الجهاز حلّ الاسم %s (DNS).
en|pr_dns_a|Check the DNS servers (cat /etc/resolv.conf, resolvectl status), add a working one such as nameserver 9.9.9.9, then run this command again.
fr|pr_dns_a|Vérifiez les serveurs DNS (cat /etc/resolv.conf, resolvectl status), ajoutez-en un qui fonctionne, par exemple nameserver 9.9.9.9, puis relancez cette commande.
es|pr_dns_a|Compruebe los servidores DNS (cat /etc/resolv.conf, resolvectl status), añada uno que funcione, por ejemplo nameserver 9.9.9.9, y vuelva a ejecutar este comando.
de|pr_dns_a|Prüfen Sie die DNS-Server (cat /etc/resolv.conf, resolvectl status), tragen Sie einen funktionierenden ein, z. B. nameserver 9.9.9.9, und führen Sie diesen Befehl erneut aus.
it|pr_dns_a|Controlla i server DNS (cat /etc/resolv.conf, resolvectl status), aggiungine uno funzionante, ad esempio nameserver 9.9.9.9, poi rilancia questo comando.
pt|pr_dns_a|Verifique os servidores DNS (cat /etc/resolv.conf, resolvectl status), adicione um que funcione, por exemplo nameserver 9.9.9.9, e volte a executar este comando.
nl|pr_dns_a|Controleer de DNS-servers (cat /etc/resolv.conf, resolvectl status), voeg een werkende toe, bijvoorbeeld nameserver 9.9.9.9, en voer dit commando opnieuw uit.
ru|pr_dns_a|Проверьте DNS-серверы (cat /etc/resolv.conf, resolvectl status), добавьте рабочий, например nameserver 9.9.9.9, и повторите эту команду.
zh|pr_dns_a|请检查 DNS 服务器（cat /etc/resolv.conf、resolvectl status），添加一个可用的服务器，例如 nameserver 9.9.9.9，然后重新运行此命令。
ar|pr_dns_a|تحقق من خوادم DNS (cat /etc/resolv.conf، resolvectl status) وأضف خادماً يعمل مثل nameserver 9.9.9.9 ثم أعد تشغيل هذا الأمر.
en|pr_dns_w_a|Check the DNS servers with 'ipconfig /all', set a working one (for example 9.9.9.9) in the network adapter settings, then run this command again.
fr|pr_dns_w_a|Vérifiez les serveurs DNS avec 'ipconfig /all', indiquez-en un qui fonctionne (par exemple 9.9.9.9) dans les paramètres de la carte réseau, puis relancez cette commande.
es|pr_dns_w_a|Compruebe los servidores DNS con 'ipconfig /all', indique uno que funcione (por ejemplo 9.9.9.9) en la configuración del adaptador de red y vuelva a ejecutar este comando.
de|pr_dns_w_a|Prüfen Sie die DNS-Server mit 'ipconfig /all', tragen Sie in den Einstellungen des Netzwerkadapters einen funktionierenden ein (z. B. 9.9.9.9) und führen Sie diesen Befehl erneut aus.
it|pr_dns_w_a|Controlla i server DNS con 'ipconfig /all', imposta un server funzionante (ad esempio 9.9.9.9) nelle impostazioni della scheda di rete, poi rilancia questo comando.
pt|pr_dns_w_a|Verifique os servidores DNS com 'ipconfig /all', defina um que funcione (por exemplo 9.9.9.9) nas definições do adaptador de rede e volte a executar este comando.
nl|pr_dns_w_a|Controleer de DNS-servers met 'ipconfig /all', stel een werkende in (bijvoorbeeld 9.9.9.9) bij de instellingen van de netwerkadapter en voer dit commando opnieuw uit.
ru|pr_dns_w_a|Проверьте DNS-серверы командой 'ipconfig /all', укажите рабочий (например, 9.9.9.9) в настройках сетевого адаптера и повторите эту команду.
zh|pr_dns_w_a|请用 'ipconfig /all' 检查 DNS 服务器，在网络适配器设置中填入一个可用的服务器（例如 9.9.9.9），然后重新运行此命令。
ar|pr_dns_w_a|تحقق من خوادم DNS باستخدام 'ipconfig /all' وحدّد خادماً يعمل (مثل 9.9.9.9) في إعدادات بطاقة الشبكة ثم أعد تشغيل هذا الأمر.
en|pr_clock|The clock of this machine is %s seconds away from the Internet time: TLS certificates and signatures fail when the clock is wrong.
fr|pr_clock|L'horloge de cette machine est décalée de %s secondes par rapport à l'heure d'Internet : les certificats TLS et les signatures échouent quand l'horloge est fausse.
es|pr_clock|El reloj de esta máquina está desfasado %s segundos respecto a la hora de Internet: los certificados TLS y las firmas fallan cuando el reloj es incorrecto.
de|pr_clock|Die Uhr dieses Rechners weicht um %s Sekunden von der Internetzeit ab: TLS-Zertifikate und Signaturen schlagen fehl, wenn die Uhr falsch geht.
it|pr_clock|L'orologio di questa macchina è sfasato di %s secondi rispetto all'ora di Internet: certificati TLS e firme falliscono se l'orologio è sbagliato.
pt|pr_clock|O relógio desta máquina está desfasado %s segundos em relação à hora da Internet: os certificados TLS e as assinaturas falham quando o relógio está errado.
nl|pr_clock|De klok van deze machine wijkt %s seconden af van de internettijd: TLS-certificaten en handtekeningen mislukken bij een verkeerde klok.
ru|pr_clock|Часы этой машины расходятся с интернет-временем на %s с: сертификаты TLS и подписи не проходят проверку при неверных часах.
zh|pr_clock|这台机器的时钟与互联网时间相差 %s 秒：时钟不准时，TLS 证书和签名校验会失败。
ar|pr_clock|ساعة هذا الجهاز تختلف عن توقيت الإنترنت بمقدار %s ثانية: تفشل شهادات TLS والتوقيعات عندما تكون الساعة خاطئة.
en|pr_clock_a|Synchronise it: timedatectl set-ntp true (or chronyc makestep), check with timedatectl, then run this command again.
fr|pr_clock_a|Synchronisez-la : timedatectl set-ntp true (ou chronyc makestep), vérifiez avec timedatectl, puis relancez cette commande.
es|pr_clock_a|Sincronícelo: timedatectl set-ntp true (o chronyc makestep), compruebe con timedatectl y vuelva a ejecutar este comando.
de|pr_clock_a|Synchronisieren Sie sie: timedatectl set-ntp true (oder chronyc makestep), prüfen Sie mit timedatectl und führen Sie diesen Befehl erneut aus.
it|pr_clock_a|Sincronizzalo: timedatectl set-ntp true (o chronyc makestep), verifica con timedatectl, poi rilancia questo comando.
pt|pr_clock_a|Sincronize-o: timedatectl set-ntp true (ou chronyc makestep), verifique com timedatectl e volte a executar este comando.
nl|pr_clock_a|Synchroniseer de klok: timedatectl set-ntp true (of chronyc makestep), controleer met timedatectl en voer dit commando opnieuw uit.
ru|pr_clock_a|Синхронизируйте часы: timedatectl set-ntp true (или chronyc makestep), проверьте через timedatectl и повторите эту команду.
zh|pr_clock_a|请同步时钟：timedatectl set-ntp true（或 chronyc makestep），用 timedatectl 检查，然后重新运行此命令。
ar|pr_clock_a|قم بمزامنتها: timedatectl set-ntp true (أو chronyc makestep) وتحقق باستخدام timedatectl ثم أعد تشغيل هذا الأمر.
en|pr_clock_w_a|Synchronise it: w32tm /resync (or Settings > Time and language > Sync now), then run this command again.
fr|pr_clock_w_a|Synchronisez-la : w32tm /resync (ou Paramètres > Heure et langue > Synchroniser maintenant), puis relancez cette commande.
es|pr_clock_w_a|Sincronícelo: w32tm /resync (o Configuración > Hora e idioma > Sincronizar ahora) y vuelva a ejecutar este comando.
de|pr_clock_w_a|Synchronisieren Sie sie: w32tm /resync (oder Einstellungen > Zeit und Sprache > Jetzt synchronisieren) und führen Sie diesen Befehl erneut aus.
it|pr_clock_w_a|Sincronizzalo: w32tm /resync (oppure Impostazioni > Ora e lingua > Sincronizza ora), poi rilancia questo comando.
pt|pr_clock_w_a|Sincronize-o: w32tm /resync (ou Definições > Hora e idioma > Sincronizar agora) e volte a executar este comando.
nl|pr_clock_w_a|Synchroniseer de klok: w32tm /resync (of Instellingen > Tijd en taal > Nu synchroniseren) en voer dit commando opnieuw uit.
ru|pr_clock_w_a|Синхронизируйте часы: w32tm /resync (или Параметры > Время и язык > Синхронизировать) и повторите эту команду.
zh|pr_clock_w_a|请同步时钟：w32tm /resync（或 设置 > 时间和语言 > 立即同步），然后重新运行此命令。
ar|pr_clock_w_a|قم بمزامنتها: w32tm /resync (أو الإعدادات > الوقت واللغة > مزامنة الآن) ثم أعد تشغيل هذا الأمر.
en|pr_ok|Disk space, DNS and the clock are fine.
fr|pr_ok|L'espace disque, le DNS et l'horloge sont en ordre.
es|pr_ok|El espacio en disco, el DNS y el reloj están en orden.
de|pr_ok|Speicherplatz, DNS und Uhr sind in Ordnung.
it|pr_ok|Spazio su disco, DNS e orologio sono a posto.
pt|pr_ok|O espaço em disco, o DNS e o relógio estão em ordem.
nl|pr_ok|Schijfruimte, DNS en klok zijn in orde.
ru|pr_ok|Место на диске, DNS и часы в порядке.
zh|pr_ok|磁盘空间、DNS 和时钟均正常。
ar|pr_ok|مساحة القرص وDNS والساعة بحالة جيدة.
en|cloud_https|--cloud-url must be an https:// address (the node never talks to the cloud in clear).
fr|cloud_https|--cloud-url doit être une adresse https:// (le nœud ne parle jamais au cloud en clair).
es|cloud_https|--cloud-url debe ser una dirección https:// (el nodo nunca habla con la nube en claro).
de|cloud_https|--cloud-url muss eine https://-Adresse sein (der Knoten spricht nie unverschlüsselt mit der Cloud).
it|cloud_https|--cloud-url deve essere un indirizzo https:// (il nodo non parla mai con il cloud in chiaro).
pt|cloud_https|--cloud-url tem de ser um endereço https:// (o nó nunca fala com a nuvem em claro).
nl|cloud_https|--cloud-url moet een https://-adres zijn (de node praat nooit onversleuteld met de cloud).
ru|cloud_https|--cloud-url должен быть адресом https:// (узел никогда не общается с облаком в открытом виде).
zh|cloud_https|--cloud-url 必须是 https:// 地址（节点绝不以明文与云端通信）。
ar|cloud_https|يجب أن يكون --cloud-url عنوان https:// (العقدة لا تتحدث إلى السحابة دون تشفير أبدًا).
en|cloud_dp_only|--cloud-url installs a protection node: use it with --component dp (the default in cloud mode).
fr|cloud_dp_only|--cloud-url installe un nœud de protection : utilisez-le avec --component dp (le défaut en mode cloud).
es|cloud_dp_only|--cloud-url instala un nodo de protección: úselo con --component dp (el valor por defecto en modo nube).
de|cloud_dp_only|--cloud-url installiert einen Schutzknoten: mit --component dp verwenden (Standard im Cloud-Modus).
it|cloud_dp_only|--cloud-url installa un nodo di protezione: usarlo con --component dp (predefinito in modalità cloud).
pt|cloud_dp_only|--cloud-url instala um nó de proteção: use-o com --component dp (o predefinido no modo nuvem).
nl|cloud_dp_only|--cloud-url installeert een beschermingsnode: gebruik het met --component dp (de standaard in cloudmodus).
ru|cloud_dp_only|--cloud-url устанавливает узел защиты: используйте его с --component dp (по умолчанию в облачном режиме).
zh|cloud_dp_only|--cloud-url 安装防护节点：请与 --component dp 一起使用（云模式下的默认值）。
ar|cloud_dp_only|--cloud-url يثبّت عقدة حماية: استخدمه مع --component dp (الافتراضي في وضع السحابة).
en|cloud_need_token|An enrolment token is required to connect this node to your account (--enroll-token; console: Nodes > Add my first node).
fr|cloud_need_token|Un jeton d'enrôlement est nécessaire pour relier ce nœud à votre compte (--enroll-token ; console : Nœuds > Ajouter mon premier nœud).
es|cloud_need_token|Se necesita un token de alta para conectar este nodo a su cuenta (--enroll-token; consola: Nodos > Agregar mi primer nodo).
de|cloud_need_token|Zum Verbinden dieses Knotens mit Ihrem Konto ist ein Registrierungstoken nötig (--enroll-token; Konsole: Knoten > Meinen ersten Knoten hinzufügen).
it|cloud_need_token|Serve un token di iscrizione per collegare questo nodo al tuo account (--enroll-token; console: Nodi > Aggiungi il mio primo nodo).
pt|cloud_need_token|É necessário um token de registo para ligar este nó à sua conta (--enroll-token; consola: Nós > Adicionar o meu primeiro nó).
nl|cloud_need_token|Een registratietoken is nodig om deze node met uw account te verbinden (--enroll-token; console: Nodes > Mijn eerste node toevoegen).
ru|cloud_need_token|Для подключения этого узла к вашей учётной записи нужен токен регистрации (--enroll-token; консоль: Узлы > Добавить первый узел).
zh|cloud_need_token|将此节点连接到您的账户需要注册令牌（--enroll-token；控制台：节点 > 添加我的第一个节点）。
ar|cloud_need_token|يلزم رمز تسجيل لربط هذه العقدة بحسابك (--enroll-token؛ لوحة التحكم: العقد > إضافة أول عقدة).
en|cloud_ca_local|--cloud-ca must be a local file.
fr|cloud_ca_local|--cloud-ca doit être un fichier local.
es|cloud_ca_local|--cloud-ca debe ser un archivo local.
de|cloud_ca_local|--cloud-ca muss eine lokale Datei sein.
it|cloud_ca_local|--cloud-ca deve essere un file locale.
pt|cloud_ca_local|--cloud-ca tem de ser um ficheiro local.
nl|cloud_ca_local|--cloud-ca moet een lokaal bestand zijn.
ru|cloud_ca_local|--cloud-ca должен быть локальным файлом.
zh|cloud_ca_local|--cloud-ca 必须是本地文件。
ar|cloud_ca_local|يجب أن يكون --cloud-ca ملفًا محليًا.
en|cloud_nolink|This release does not contain the ToutWAF Cloud link (toutwaf-cloudlink): update the installer or use a newer release.
fr|cloud_nolink|Cette version ne contient pas le lien ToutWAF Cloud (toutwaf-cloudlink) : mettez l'installateur à jour ou utilisez une version plus récente.
es|cloud_nolink|Esta versión no incluye el enlace ToutWAF Cloud (toutwaf-cloudlink): actualice el instalador o use una versión más reciente.
de|cloud_nolink|Diese Version enthält die ToutWAF-Cloud-Verbindung (toutwaf-cloudlink) nicht: Installer aktualisieren oder neuere Version verwenden.
it|cloud_nolink|Questa versione non contiene il collegamento ToutWAF Cloud (toutwaf-cloudlink): aggiorna l'installer o usa una versione più recente.
pt|cloud_nolink|Esta versão não contém a ligação ToutWAF Cloud (toutwaf-cloudlink): atualize o instalador ou use uma versão mais recente.
nl|cloud_nolink|Deze versie bevat de ToutWAF Cloud-koppeling (toutwaf-cloudlink) niet: werk het installatieprogramma bij of gebruik een nieuwere versie.
ru|cloud_nolink|В этой версии нет компонента связи ToutWAF Cloud (toutwaf-cloudlink): обновите установщик или используйте более новую версию.
zh|cloud_nolink|此版本不包含 ToutWAF Cloud 链接组件（toutwaf-cloudlink）：请更新安装程序或使用更新的版本。
ar|cloud_nolink|لا يتضمن هذا الإصدار رابط ToutWAF Cloud (toutwaf-cloudlink): حدّث المثبّت أو استخدم إصدارًا أحدث.
en|cloud_enrol_failed|The node could not be enrolled with your account (see the lines above). The token may be used or expired: create a new one in the console.
fr|cloud_enrol_failed|Le nœud n'a pas pu être enrôlé auprès de votre compte (voir les lignes ci-dessus). Le jeton est peut-être utilisé ou périmé : créez-en un nouveau dans la console.
es|cloud_enrol_failed|No se pudo dar de alta el nodo en su cuenta (vea las líneas anteriores). El token puede estar usado o caducado: cree uno nuevo en la consola.
de|cloud_enrol_failed|Der Knoten konnte nicht in Ihrem Konto registriert werden (siehe Zeilen oben). Das Token ist vielleicht verbraucht oder abgelaufen: Erstellen Sie in der Konsole ein neues.
it|cloud_enrol_failed|Non è stato possibile iscrivere il nodo al tuo account (vedi le righe sopra). Il token potrebbe essere usato o scaduto: creane uno nuovo nella console.
pt|cloud_enrol_failed|Não foi possível registar o nó na sua conta (veja as linhas acima). O token pode estar usado ou expirado: crie um novo na consola.
nl|cloud_enrol_failed|De node kon niet bij uw account worden geregistreerd (zie de regels hierboven). Het token is misschien gebruikt of verlopen: maak een nieuw token in de console.
ru|cloud_enrol_failed|Не удалось зарегистрировать узел в вашей учётной записи (см. строки выше). Токен мог быть использован или истечь: создайте новый в консоли.
zh|cloud_enrol_failed|无法将节点注册到您的账户（见上方输出）。令牌可能已使用或已过期：请在控制台中创建新令牌。
ar|cloud_enrol_failed|تعذّر تسجيل العقدة في حسابك (انظر الأسطر أعلاه). ربما استُخدم الرمز أو انتهت صلاحيته: أنشئ رمزًا جديدًا في لوحة التحكم.
en|pf_cloud_action|Allow this machine to reach your ToutWAF Cloud address on port 443 (outbound only), or set HTTPS_PROXY if a proxy is required. Nothing needs to be opened for inbound traffic.
fr|pf_cloud_action|Autorisez cette machine à joindre l'adresse de votre ToutWAF Cloud sur le port 443 (sortant uniquement), ou définissez HTTPS_PROXY si un proxy est nécessaire. Rien n'est à ouvrir en entrée.
es|pf_cloud_action|Permita que esta máquina llegue a la dirección de su ToutWAF Cloud por el puerto 443 (solo saliente), o defina HTTPS_PROXY si se necesita un proxy. No hay que abrir nada de entrada.
de|pf_cloud_action|Erlauben Sie diesem Rechner, die Adresse Ihrer ToutWAF Cloud über Port 443 zu erreichen (nur ausgehend), oder setzen Sie HTTPS_PROXY, falls ein Proxy nötig ist. Eingehend muss nichts geöffnet werden.
it|pf_cloud_action|Consenti a questa macchina di raggiungere l'indirizzo del tuo ToutWAF Cloud sulla porta 443 (solo in uscita), oppure imposta HTTPS_PROXY se serve un proxy. Non va aperto nulla in ingresso.
pt|pf_cloud_action|Permita que esta máquina alcance o endereço do seu ToutWAF Cloud na porta 443 (apenas saída), ou defina HTTPS_PROXY se for necessário um proxy. Nada precisa de ser aberto à entrada.
nl|pf_cloud_action|Sta deze machine toe het adres van uw ToutWAF Cloud op poort 443 te bereiken (alleen uitgaand), of stel HTTPS_PROXY in als een proxy nodig is. Inkomend hoeft niets open.
ru|pf_cloud_action|Разрешите этой машине обращаться к адресу вашего ToutWAF Cloud по порту 443 (только исходящие) или задайте HTTPS_PROXY, если нужен прокси. Для входящего трафика ничего открывать не нужно.
zh|pf_cloud_action|允许本机通过 443 端口访问您的 ToutWAF Cloud 地址（仅出站），如需代理请设置 HTTPS_PROXY。入站方向无需开放任何端口。
ar|pf_cloud_action|اسمح لهذا الجهاز بالوصول إلى عنوان ToutWAF Cloud الخاص بك عبر المنفذ 443 (صادر فقط)، أو عيّن HTTPS_PROXY إذا لزم وكيل. لا حاجة لفتح أي شيء للوارد.
en|s_db|Preparing the database
fr|s_db|Préparation de la base de données
es|s_db|Preparando la base de datos
de|s_db|Datenbank wird vorbereitet
it|s_db|Preparazione del database
pt|s_db|A preparar a base de dados
nl|s_db|Database voorbereiden
ru|s_db|Подготовка базы данных
zh|s_db|正在准备数据库
ar|s_db|تجهيز قاعدة البيانات
en|db_choose|Which database should ToutWAF use?
fr|db_choose|Quelle base de données ToutWAF doit-il utiliser ?
es|db_choose|¿Qué base de datos debe usar ToutWAF?
de|db_choose|Welche Datenbank soll ToutWAF verwenden?
it|db_choose|Quale database deve usare ToutWAF?
pt|db_choose|Que base de dados o ToutWAF deve usar?
nl|db_choose|Welke database moet ToutWAF gebruiken?
ru|db_choose|Какую базу данных использовать ToutWAF?
zh|db_choose|ToutWAF 应使用哪种数据库？
ar|db_choose|ما قاعدة البيانات التي سيستخدمها ToutWAF؟
en|db_opt_pg|PostgreSQL (recommended)
fr|db_opt_pg|PostgreSQL (recommandé)
es|db_opt_pg|PostgreSQL (recomendado)
de|db_opt_pg|PostgreSQL (empfohlen)
it|db_opt_pg|PostgreSQL (consigliato)
pt|db_opt_pg|PostgreSQL (recomendado)
nl|db_opt_pg|PostgreSQL (aanbevolen)
ru|db_opt_pg|PostgreSQL (рекомендуется)
zh|db_opt_pg|PostgreSQL（推荐）
ar|db_opt_pg|PostgreSQL (موصى به)
en|db_opt_pg_local|Install PostgreSQL on this machine (created and configured for you)
fr|db_opt_pg_local|Installer PostgreSQL sur cette machine (créé et configuré pour vous)
es|db_opt_pg_local|Instalar PostgreSQL en esta máquina (creado y configurado por usted)
de|db_opt_pg_local|PostgreSQL auf diesem Rechner installieren (wird für Sie eingerichtet)
it|db_opt_pg_local|Installare PostgreSQL su questa macchina (creato e configurato per te)
pt|db_opt_pg_local|Instalar o PostgreSQL nesta máquina (criado e configurado por si)
nl|db_opt_pg_local|PostgreSQL op deze machine installeren (voor u aangemaakt en ingesteld)
ru|db_opt_pg_local|Установить PostgreSQL на этой машине (создаётся и настраивается автоматически)
zh|db_opt_pg_local|在本机安装 PostgreSQL（自动创建并配置）
ar|db_opt_pg_local|تثبيت PostgreSQL على هذا الجهاز (يُنشأ ويُهيّأ تلقائيًا)
en|db_opt_pg_remote|Use an existing PostgreSQL server (tested, then prepared if you allow it)
fr|db_opt_pg_remote|Utiliser un serveur PostgreSQL existant (testé, puis préparé si vous l'autorisez)
es|db_opt_pg_remote|Usar un servidor PostgreSQL existente (se prueba y se prepara si lo permite)
de|db_opt_pg_remote|Vorhandenen PostgreSQL-Server verwenden (wird getestet und bei Erlaubnis vorbereitet)
it|db_opt_pg_remote|Usare un server PostgreSQL esistente (testato, poi preparato se lo consenti)
pt|db_opt_pg_remote|Usar um servidor PostgreSQL existente (testado e preparado, se permitir)
nl|db_opt_pg_remote|Bestaande PostgreSQL-server gebruiken (getest en, indien toegestaan, voorbereid)
ru|db_opt_pg_remote|Использовать существующий сервер PostgreSQL (проверка и подготовка, если разрешите)
zh|db_opt_pg_remote|使用现有 PostgreSQL 服务器（先测试，经允许后自动准备）
ar|db_opt_pg_remote|استخدام خادم PostgreSQL موجود (يُختبر ثم يُجهَّز إذا سمحت)
en|db_opt_sqlite|SQLite (small installation, one server only)
fr|db_opt_sqlite|SQLite (petite installation, un seul serveur)
es|db_opt_sqlite|SQLite (instalación pequeña, un solo servidor)
de|db_opt_sqlite|SQLite (kleine Installation, nur ein Server)
it|db_opt_sqlite|SQLite (piccola installazione, un solo server)
pt|db_opt_sqlite|SQLite (instalação pequena, um só servidor)
nl|db_opt_sqlite|SQLite (kleine installatie, slechts één server)
ru|db_opt_sqlite|SQLite (небольшая установка, один сервер)
zh|db_opt_sqlite|SQLite（小型安装，仅单台服务器）
ar|db_opt_sqlite|SQLite (تثبيت صغير، خادم واحد فقط)
en|db_sqlite_note|SQLite is one file on this machine: fine for a small installation on one server. It cannot be shared by several control planes and has no replication. You can move to PostgreSQL later with: toutwaf-cp db migrate.
fr|db_sqlite_note|SQLite est un fichier sur cette machine : adapté à une petite installation sur un seul serveur. Il ne peut pas être partagé entre plusieurs plans de contrôle et n'a pas de réplication. Vous pourrez passer à PostgreSQL plus tard avec : toutwaf-cp db migrate.
es|db_sqlite_note|SQLite es un archivo en esta máquina: válido para una instalación pequeña en un servidor. No se puede compartir entre varios planos de control y no tiene replicación. Podrá pasar a PostgreSQL más tarde con: toutwaf-cp db migrate.
de|db_sqlite_note|SQLite ist eine Datei auf diesem Rechner: gut für eine kleine Installation auf einem Server. Sie kann nicht von mehreren Control Planes geteilt werden und hat keine Replikation. Später können Sie zu PostgreSQL wechseln: toutwaf-cp db migrate.
it|db_sqlite_note|SQLite è un file su questa macchina: va bene per una piccola installazione su un solo server. Non può essere condiviso tra più piani di controllo e non ha replica. Potrai passare a PostgreSQL più tardi con: toutwaf-cp db migrate.
pt|db_sqlite_note|O SQLite é um ficheiro nesta máquina: adequado a uma instalação pequena num só servidor. Não pode ser partilhado por vários planos de controlo e não tem replicação. Poderá passar para PostgreSQL mais tarde com: toutwaf-cp db migrate.
nl|db_sqlite_note|SQLite is één bestand op deze machine: prima voor een kleine installatie op één server. Het kan niet door meerdere control planes worden gedeeld en heeft geen replicatie. U kunt later overstappen naar PostgreSQL met: toutwaf-cp db migrate.
ru|db_sqlite_note|SQLite — это один файл на этой машине: подходит для небольшой установки на одном сервере. Его нельзя разделять между несколькими control plane, репликации нет. Позже можно перейти на PostgreSQL: toutwaf-cp db migrate.
zh|db_sqlite_note|SQLite 是本机上的一个文件：适合单台服务器的小型安装。它不能被多个控制平面共享，也没有复制功能。以后可用 toutwaf-cp db migrate 迁移到 PostgreSQL。
ar|db_sqlite_note|SQLite ملف واحد على هذا الجهاز: مناسب لتثبيت صغير على خادم واحد. لا يمكن مشاركته بين عدة وحدات تحكم ولا يدعم النسخ المتماثل. يمكنك الانتقال إلى PostgreSQL لاحقًا عبر: toutwaf-cp db migrate.
en|db_q_host|PostgreSQL host
fr|db_q_host|Hôte PostgreSQL
es|db_q_host|Host de PostgreSQL
de|db_q_host|PostgreSQL-Host
it|db_q_host|Host PostgreSQL
pt|db_q_host|Anfitrião PostgreSQL
nl|db_q_host|PostgreSQL-host
ru|db_q_host|Хост PostgreSQL
zh|db_q_host|PostgreSQL 主机
ar|db_q_host|مضيف PostgreSQL
en|db_q_port|Port
fr|db_q_port|Port
es|db_q_port|Puerto
de|db_q_port|Port
it|db_q_port|Porta
pt|db_q_port|Porta
nl|db_q_port|Poort
ru|db_q_port|Порт
zh|db_q_port|端口
ar|db_q_port|المنفذ
en|db_q_name|Database name
fr|db_q_name|Nom de la base
es|db_q_name|Nombre de la base de datos
de|db_q_name|Datenbankname
it|db_q_name|Nome del database
pt|db_q_name|Nome da base de dados
nl|db_q_name|Naam van de database
ru|db_q_name|Имя базы данных
zh|db_q_name|数据库名称
ar|db_q_name|اسم قاعدة البيانات
en|db_q_user|Database user
fr|db_q_user|Utilisateur de la base
es|db_q_user|Usuario de la base de datos
de|db_q_user|Datenbankbenutzer
it|db_q_user|Utente del database
pt|db_q_user|Utilizador da base de dados
nl|db_q_user|Databasegebruiker
ru|db_q_user|Пользователь базы данных
zh|db_q_user|数据库用户
ar|db_q_user|مستخدم قاعدة البيانات
en|db_q_pw|Password of that user (empty if an administrator account creates it)
fr|db_q_pw|Mot de passe de cet utilisateur (vide si un compte administrateur le crée)
es|db_q_pw|Contraseña de ese usuario (vacía si lo crea una cuenta de administrador)
de|db_q_pw|Passwort dieses Benutzers (leer, wenn ein Administratorkonto ihn anlegt)
it|db_q_pw|Password di quell'utente (vuota se lo crea un account amministratore)
pt|db_q_pw|Palavra-passe desse utilizador (vazia se uma conta de administrador o criar)
nl|db_q_pw|Wachtwoord van die gebruiker (leeg als een beheerdersaccount hem aanmaakt)
ru|db_q_pw|Пароль этого пользователя (пусто, если его создаёт учётная запись администратора)
zh|db_q_pw|该用户的密码（若由管理员账户创建则留空）
ar|db_q_pw|كلمة مرور هذا المستخدم (اتركها فارغة إذا أنشأه حساب مسؤول)
en|db_q_tls|TLS mode (disable, prefer, require, verify-ca, verify-full)
fr|db_q_tls|Mode TLS (disable, prefer, require, verify-ca, verify-full)
es|db_q_tls|Modo TLS (disable, prefer, require, verify-ca, verify-full)
de|db_q_tls|TLS-Modus (disable, prefer, require, verify-ca, verify-full)
it|db_q_tls|Modalità TLS (disable, prefer, require, verify-ca, verify-full)
pt|db_q_tls|Modo TLS (disable, prefer, require, verify-ca, verify-full)
nl|db_q_tls|TLS-modus (disable, prefer, require, verify-ca, verify-full)
ru|db_q_tls|Режим TLS (disable, prefer, require, verify-ca, verify-full)
zh|db_q_tls|TLS 模式（disable、prefer、require、verify-ca、verify-full）
ar|db_q_tls|وضع TLS (disable، prefer، require، verify-ca، verify-full)
en|db_q_ca|CA certificate file of the server (for verify-ca / verify-full)
fr|db_q_ca|Fichier du certificat de l'autorité du serveur (pour verify-ca / verify-full)
es|db_q_ca|Archivo del certificado de la CA del servidor (para verify-ca / verify-full)
de|db_q_ca|CA-Zertifikatsdatei des Servers (für verify-ca / verify-full)
it|db_q_ca|File del certificato CA del server (per verify-ca / verify-full)
pt|db_q_ca|Ficheiro do certificado da CA do servidor (para verify-ca / verify-full)
nl|db_q_ca|CA-certificaatbestand van de server (voor verify-ca / verify-full)
ru|db_q_ca|Файл сертификата ЦС сервера (для verify-ca / verify-full)
zh|db_q_ca|服务器 CA 证书文件（用于 verify-ca / verify-full）
ar|db_q_ca|ملف شهادة CA للخادم (لوضعي verify-ca / verify-full)
en|db_q_admin|Administrator account that creates the user and the database (empty = they already exist)
fr|db_q_admin|Compte administrateur qui crée l'utilisateur et la base (vide = ils existent déjà)
es|db_q_admin|Cuenta de administrador que crea el usuario y la base (vacío = ya existen)
de|db_q_admin|Administratorkonto, das Benutzer und Datenbank anlegt (leer = existieren bereits)
it|db_q_admin|Account amministratore che crea utente e database (vuoto = esistono già)
pt|db_q_admin|Conta de administrador que cria o utilizador e a base (vazio = já existem)
nl|db_q_admin|Beheerdersaccount dat gebruiker en database aanmaakt (leeg = bestaan al)
ru|db_q_admin|Учётная запись администратора, создающая пользователя и базу (пусто = уже существуют)
zh|db_q_admin|用于创建用户和数据库的管理员账户（留空 = 已存在）
ar|db_q_admin|حساب المسؤول الذي ينشئ المستخدم وقاعدة البيانات (فارغ = موجودان مسبقًا)
en|db_q_adminpw|Password of the administrator account (used once, never stored)
fr|db_q_adminpw|Mot de passe du compte administrateur (utilisé une fois, jamais stocké)
es|db_q_adminpw|Contraseña de la cuenta de administrador (se usa una vez, nunca se guarda)
de|db_q_adminpw|Passwort des Administratorkontos (einmal verwendet, nie gespeichert)
it|db_q_adminpw|Password dell'account amministratore (usata una volta, mai salvata)
pt|db_q_adminpw|Palavra-passe da conta de administrador (usada uma vez, nunca guardada)
nl|db_q_adminpw|Wachtwoord van het beheerdersaccount (eenmalig gebruikt, nooit opgeslagen)
ru|db_q_adminpw|Пароль администратора (используется один раз, не сохраняется)
zh|db_q_adminpw|管理员账户密码（仅使用一次，不会保存）
ar|db_q_adminpw|كلمة مرور حساب المسؤول (تُستخدم مرة واحدة ولا تُحفظ)
en|db_hint|Database: SQLite (default). For a server install or several control planes use --db postgres (--db-install-local installs it for you).
fr|db_hint|Base de données : SQLite (par défaut). Pour une installation serveur ou plusieurs plans de contrôle, utilisez --db postgres (--db-install-local l'installe pour vous).
es|db_hint|Base de datos: SQLite (por defecto). Para un servidor o varios planos de control use --db postgres (--db-install-local lo instala por usted).
de|db_hint|Datenbank: SQLite (Standard). Für eine Server-Installation oder mehrere Control Planes verwenden Sie --db postgres (--db-install-local installiert es für Sie).
it|db_hint|Database: SQLite (predefinito). Per un'installazione server o più piani di controllo usa --db postgres (--db-install-local lo installa per te).
pt|db_hint|Base de dados: SQLite (predefinição). Para um servidor ou vários planos de controlo use --db postgres (--db-install-local instala-o por si).
nl|db_hint|Database: SQLite (standaard). Voor een serverinstallatie of meerdere control planes gebruikt u --db postgres (--db-install-local installeert het voor u).
ru|db_hint|База данных: SQLite (по умолчанию). Для серверной установки или нескольких control plane используйте --db postgres (--db-install-local установит её).
zh|db_hint|数据库：SQLite（默认）。服务器安装或多个控制平面请使用 --db postgres（--db-install-local 会自动安装）。
ar|db_hint|قاعدة البيانات: SQLite (افتراضي). للتثبيت على خادم أو لعدة وحدات تحكم استخدم --db postgres (و--db-install-local يثبّتها لك).
en|db_no_pkg|PostgreSQL cannot be installed automatically on this system: install the server package yourself, then run the installer again with --db postgres.
fr|db_no_pkg|PostgreSQL ne peut pas être installé automatiquement sur ce système : installez vous-même le paquet serveur, puis relancez l'installateur avec --db postgres.
es|db_no_pkg|PostgreSQL no se puede instalar automáticamente en este sistema: instale usted el paquete del servidor y vuelva a ejecutar el instalador con --db postgres.
de|db_no_pkg|PostgreSQL lässt sich auf diesem System nicht automatisch installieren: installieren Sie das Serverpaket selbst und starten Sie den Installer erneut mit --db postgres.
it|db_no_pkg|PostgreSQL non può essere installato automaticamente su questo sistema: installa tu il pacchetto server, poi riesegui l'installer con --db postgres.
pt|db_no_pkg|O PostgreSQL não pode ser instalado automaticamente neste sistema: instale o pacote do servidor e volte a executar o instalador com --db postgres.
nl|db_no_pkg|PostgreSQL kan op dit systeem niet automatisch worden geïnstalleerd: installeer zelf het serverpakket en start het installatieprogramma opnieuw met --db postgres.
ru|db_no_pkg|PostgreSQL нельзя установить автоматически в этой системе: установите серверный пакет сами и снова запустите установщик с --db postgres.
zh|db_no_pkg|无法在此系统上自动安装 PostgreSQL：请自行安装服务器软件包，然后使用 --db postgres 重新运行安装程序。
ar|db_no_pkg|تعذّر تثبيت PostgreSQL تلقائيًا على هذا النظام: ثبّت حزمة الخادم بنفسك ثم أعد تشغيل المثبّت مع --db postgres.
en|db_install_failed|Installing the PostgreSQL package failed. The log says why (/var/log/toutwaf-install.log).
fr|db_install_failed|L'installation du paquet PostgreSQL a échoué. Le journal dit pourquoi (/var/log/toutwaf-install.log).
es|db_install_failed|Falló la instalación del paquete PostgreSQL. El registro dice por qué (/var/log/toutwaf-install.log).
de|db_install_failed|Die Installation des PostgreSQL-Pakets ist fehlgeschlagen. Das Protokoll nennt den Grund (/var/log/toutwaf-install.log).
it|db_install_failed|L'installazione del pacchetto PostgreSQL è fallita. Il registro ne indica il motivo (/var/log/toutwaf-install.log).
pt|db_install_failed|A instalação do pacote PostgreSQL falhou. O registo diz porquê (/var/log/toutwaf-install.log).
nl|db_install_failed|Het installeren van het PostgreSQL-pakket is mislukt. Het logboek zegt waarom (/var/log/toutwaf-install.log).
ru|db_install_failed|Не удалось установить пакет PostgreSQL. Причина — в журнале (/var/log/toutwaf-install.log).
zh|db_install_failed|安装 PostgreSQL 软件包失败。原因见日志（/var/log/toutwaf-install.log）。
ar|db_install_failed|فشل تثبيت حزمة PostgreSQL. السبب في السجل (/var/log/toutwaf-install.log).
en|db_init_failed|The PostgreSQL cluster could not be initialised. The log says why.
fr|db_init_failed|Le cluster PostgreSQL n'a pas pu être initialisé. Le journal dit pourquoi.
es|db_init_failed|No se pudo inicializar el clúster de PostgreSQL. El registro dice por qué.
de|db_init_failed|Der PostgreSQL-Cluster konnte nicht initialisiert werden. Das Protokoll nennt den Grund.
it|db_init_failed|Impossibile inizializzare il cluster PostgreSQL. Il registro ne indica il motivo.
pt|db_init_failed|Não foi possível inicializar o cluster PostgreSQL. O registo diz porquê.
nl|db_init_failed|Het PostgreSQL-cluster kon niet worden geïnitialiseerd. Het logboek zegt waarom.
ru|db_init_failed|Не удалось инициализировать кластер PostgreSQL. Причина — в журнале.
zh|db_init_failed|无法初始化 PostgreSQL 集群。原因见日志。
ar|db_init_failed|تعذّرت تهيئة مجموعة PostgreSQL. السبب في السجل.
en|db_start_failed|PostgreSQL does not start. Check: systemctl status postgresql, and the log.
fr|db_start_failed|PostgreSQL ne démarre pas. Vérifiez : systemctl status postgresql, et le journal.
es|db_start_failed|PostgreSQL no arranca. Compruebe: systemctl status postgresql y el registro.
de|db_start_failed|PostgreSQL startet nicht. Prüfen Sie: systemctl status postgresql und das Protokoll.
it|db_start_failed|PostgreSQL non si avvia. Controlla: systemctl status postgresql e il registro.
pt|db_start_failed|O PostgreSQL não arranca. Verifique: systemctl status postgresql e o registo.
nl|db_start_failed|PostgreSQL start niet. Controleer: systemctl status postgresql en het logboek.
ru|db_start_failed|PostgreSQL не запускается. Проверьте: systemctl status postgresql и журнал.
zh|db_start_failed|PostgreSQL 无法启动。请检查：systemctl status postgresql 和日志。
ar|db_start_failed|لا يبدأ PostgreSQL. افحص: systemctl status postgresql والسجل.
en|db_too_old|The PostgreSQL version installed here (%s) is too old: version 13 or newer is required.
fr|db_too_old|La version de PostgreSQL installée ici (%s) est trop ancienne : la version 13 ou plus récente est requise.
es|db_too_old|La versión de PostgreSQL instalada aquí (%s) es demasiado antigua: se requiere la versión 13 o posterior.
de|db_too_old|Die hier installierte PostgreSQL-Version (%s) ist zu alt: Version 13 oder neuer ist erforderlich.
it|db_too_old|La versione di PostgreSQL installata qui (%s) è troppo vecchia: serve la versione 13 o successiva.
pt|db_too_old|A versão do PostgreSQL instalada aqui (%s) é demasiado antiga: é necessária a versão 13 ou posterior.
nl|db_too_old|De hier geïnstalleerde PostgreSQL-versie (%s) is te oud: versie 13 of nieuwer is vereist.
ru|db_too_old|Установленная версия PostgreSQL (%s) слишком старая: нужна версия 13 или новее.
zh|db_too_old|此处安装的 PostgreSQL 版本（%s）过旧：需要 13 或更高版本。
ar|db_too_old|إصدار PostgreSQL المثبّت هنا (%s) قديم جدًا: يلزم الإصدار 13 أو أحدث.
en|db_exists|A database user "%s" or a database "%s" already exists and was not created by this installer: nothing was changed. Choose other names (--db-name, --db-user) or give the existing connection (--db-dsn-file).
fr|db_exists|Un utilisateur "%s" ou une base "%s" existe déjà et n'a pas été créé par cet installateur : rien n'a été modifié. Choisissez d'autres noms (--db-name, --db-user) ou donnez la connexion existante (--db-dsn-file).
es|db_exists|Ya existe un usuario "%s" o una base "%s" que no creó este instalador: no se cambió nada. Elija otros nombres (--db-name, --db-user) o indique la conexión existente (--db-dsn-file).
de|db_exists|Ein Benutzer "%s" oder eine Datenbank "%s" existiert bereits und wurde nicht von diesem Installer angelegt: nichts wurde geändert. Wählen Sie andere Namen (--db-name, --db-user) oder geben Sie die vorhandene Verbindung an (--db-dsn-file).
it|db_exists|Esiste già un utente "%s" o un database "%s" non creato da questo installer: nulla è stato modificato. Scegli altri nomi (--db-name, --db-user) o indica la connessione esistente (--db-dsn-file).
pt|db_exists|Já existe um utilizador "%s" ou uma base "%s" que não foi criado por este instalador: nada foi alterado. Escolha outros nomes (--db-name, --db-user) ou indique a ligação existente (--db-dsn-file).
nl|db_exists|Er bestaat al een gebruiker "%s" of database "%s" die niet door dit installatieprogramma is aangemaakt: er is niets gewijzigd. Kies andere namen (--db-name, --db-user) of geef de bestaande verbinding op (--db-dsn-file).
ru|db_exists|Пользователь "%s" или база "%s" уже существует и создана не этим установщиком: ничего не изменено. Выберите другие имена (--db-name, --db-user) или укажите существующее подключение (--db-dsn-file).
zh|db_exists|已存在用户“%s”或数据库“%s”，且不是由本安装程序创建的：未做任何更改。请选择其他名称（--db-name、--db-user）或提供现有连接（--db-dsn-file）。
ar|db_exists|يوجد مستخدم "%s" أو قاعدة "%s" لم ينشئها هذا المثبّت: لم يُغيَّر شيء. اختر أسماء أخرى (--db-name و--db-user) أو قدّم الاتصال الموجود (--db-dsn-file).
en|db_create_failed|The user or the database could not be created. What was created was removed again.
fr|db_create_failed|L'utilisateur ou la base n'a pas pu être créé. Ce qui avait été créé a été supprimé.
es|db_create_failed|No se pudo crear el usuario o la base de datos. Lo creado se eliminó de nuevo.
de|db_create_failed|Benutzer oder Datenbank konnten nicht angelegt werden. Was angelegt wurde, wurde wieder entfernt.
it|db_create_failed|Impossibile creare l'utente o il database. Quanto creato è stato rimosso.
pt|db_create_failed|Não foi possível criar o utilizador ou a base de dados. O que foi criado foi removido.
nl|db_create_failed|De gebruiker of database kon niet worden aangemaakt. Wat was aangemaakt is weer verwijderd.
ru|db_create_failed|Не удалось создать пользователя или базу. Созданное удалено.
zh|db_create_failed|无法创建用户或数据库。已创建的内容已被删除。
ar|db_create_failed|تعذّر إنشاء المستخدم أو قاعدة البيانات. أُزيل ما أُنشئ.
en|db_rights|The account is not allowed to do this. The statements above are the minimum an administrator of the server has to run; then run the installer again.
fr|db_rights|Le compte n'a pas les droits nécessaires. Les instructions ci-dessus sont le minimum qu'un administrateur du serveur doit exécuter ; relancez ensuite l'installateur.
es|db_rights|La cuenta no tiene permiso para hacerlo. Las instrucciones anteriores son lo mínimo que un administrador del servidor debe ejecutar; luego vuelva a ejecutar el instalador.
de|db_rights|Das Konto darf das nicht. Die obigen Anweisungen sind das Minimum, das ein Serveradministrator ausführen muss; starten Sie danach den Installer erneut.
it|db_rights|L'account non ha i permessi necessari. Le istruzioni qui sopra sono il minimo che un amministratore del server deve eseguire; poi riesegui l'installer.
pt|db_rights|A conta não tem permissão para isto. As instruções acima são o mínimo que um administrador do servidor tem de executar; depois volte a executar o instalador.
nl|db_rights|Het account heeft hiervoor geen rechten. De bovenstaande opdrachten zijn het minimum dat een serverbeheerder moet uitvoeren; start daarna het installatieprogramma opnieuw.
ru|db_rights|У учётной записи нет прав. Команды выше — минимум, который должен выполнить администратор сервера; затем снова запустите установщик.
zh|db_rights|该账户无权执行此操作。上面的语句是服务器管理员至少需要执行的内容；执行后请重新运行安装程序。
ar|db_rights|ليس لهذا الحساب صلاحية. التعليمات أعلاه هي الحد الأدنى الذي يجب أن ينفذه مسؤول الخادم؛ ثم أعد تشغيل المثبّت.
en|db_need_conn|No connection to the PostgreSQL server was given: use --db-dsn-file, or --db-host with --db-password-file, or --db-install-local.
fr|db_need_conn|Aucune connexion au serveur PostgreSQL n'a été donnée : utilisez --db-dsn-file, ou --db-host avec --db-password-file, ou --db-install-local.
es|db_need_conn|No se indicó ninguna conexión al servidor PostgreSQL: use --db-dsn-file, o --db-host con --db-password-file, o --db-install-local.
de|db_need_conn|Es wurde keine Verbindung zum PostgreSQL-Server angegeben: verwenden Sie --db-dsn-file, oder --db-host mit --db-password-file, oder --db-install-local.
it|db_need_conn|Nessuna connessione al server PostgreSQL indicata: usa --db-dsn-file, oppure --db-host con --db-password-file, oppure --db-install-local.
pt|db_need_conn|Não foi indicada nenhuma ligação ao servidor PostgreSQL: use --db-dsn-file, ou --db-host com --db-password-file, ou --db-install-local.
nl|db_need_conn|Er is geen verbinding met de PostgreSQL-server opgegeven: gebruik --db-dsn-file, of --db-host met --db-password-file, of --db-install-local.
ru|db_need_conn|Подключение к серверу PostgreSQL не задано: используйте --db-dsn-file, либо --db-host с --db-password-file, либо --db-install-local.
zh|db_need_conn|未提供到 PostgreSQL 服务器的连接：请使用 --db-dsn-file，或 --db-host 加 --db-password-file，或 --db-install-local。
ar|db_need_conn|لم تُحدَّد أي معلومات اتصال بخادم PostgreSQL: استخدم --db-dsn-file أو --db-host مع --db-password-file أو --db-install-local.
en|db_schema_failed|The tables could not be created in the database. The log says why.
fr|db_schema_failed|Les tables n'ont pas pu être créées dans la base. Le journal dit pourquoi.
es|db_schema_failed|No se pudieron crear las tablas en la base de datos. El registro dice por qué.
de|db_schema_failed|Die Tabellen konnten in der Datenbank nicht angelegt werden. Das Protokoll nennt den Grund.
it|db_schema_failed|Impossibile creare le tabelle nel database. Il registro ne indica il motivo.
pt|db_schema_failed|Não foi possível criar as tabelas na base de dados. O registo diz porquê.
nl|db_schema_failed|De tabellen konden niet in de database worden aangemaakt. Het logboek zegt waarom.
ru|db_schema_failed|Не удалось создать таблицы в базе. Причина — в журнале.
zh|db_schema_failed|无法在数据库中创建表。原因见日志。
ar|db_schema_failed|تعذّر إنشاء الجداول في قاعدة البيانات. السبب في السجل.
en|db_no_pgdump|pg_dump is missing: the daily database backup will report an error until the PostgreSQL client package is installed.
fr|db_no_pgdump|pg_dump est absent : la sauvegarde quotidienne de la base signalera une erreur tant que le paquet client PostgreSQL n'est pas installé.
es|db_no_pgdump|Falta pg_dump: la copia diaria de la base dará error hasta que se instale el paquete cliente de PostgreSQL.
de|db_no_pgdump|pg_dump fehlt: die tägliche Datenbanksicherung meldet einen Fehler, bis das PostgreSQL-Client-Paket installiert ist.
it|db_no_pgdump|pg_dump manca: il backup giornaliero del database segnalerà un errore finché non sarà installato il pacchetto client PostgreSQL.
pt|db_no_pgdump|Falta o pg_dump: a cópia diária da base de dados dará erro até o pacote cliente PostgreSQL ser instalado.
nl|db_no_pgdump|pg_dump ontbreekt: de dagelijkse databaseback-up meldt een fout totdat het PostgreSQL-clientpakket is geïnstalleerd.
ru|db_no_pgdump|pg_dump отсутствует: ежедневная копия базы будет выдавать ошибку, пока не установлен клиентский пакет PostgreSQL.
zh|db_no_pgdump|缺少 pg_dump：在安装 PostgreSQL 客户端软件包之前，每日数据库备份会报错。
ar|db_no_pgdump|pg_dump غير موجود: ستُبلغ النسخة اليومية لقاعدة البيانات عن خطأ حتى تُثبَّت حزمة عميل PostgreSQL.
en|db_sum_engine|Database: %s
fr|db_sum_engine|Base de données : %s
es|db_sum_engine|Base de datos: %s
de|db_sum_engine|Datenbank: %s
it|db_sum_engine|Database: %s
pt|db_sum_engine|Base de dados: %s
nl|db_sum_engine|Database: %s
ru|db_sum_engine|База данных: %s
zh|db_sum_engine|数据库：%s
ar|db_sum_engine|قاعدة البيانات: %s
en|db_sum_local|PostgreSQL runs on this machine (loopback only); database %s, user %s (no administrator rights)
fr|db_sum_local|PostgreSQL tourne sur cette machine (boucle locale uniquement) ; base %s, utilisateur %s (sans droits d'administration)
es|db_sum_local|PostgreSQL funciona en esta máquina (solo bucle local); base %s, usuario %s (sin derechos de administración)
de|db_sum_local|PostgreSQL läuft auf diesem Rechner (nur Loopback); Datenbank %s, Benutzer %s (ohne Administratorrechte)
it|db_sum_local|PostgreSQL gira su questa macchina (solo loopback); database %s, utente %s (senza diritti di amministrazione)
pt|db_sum_local|O PostgreSQL corre nesta máquina (apenas loopback); base %s, utilizador %s (sem direitos de administração)
nl|db_sum_local|PostgreSQL draait op deze machine (alleen loopback); database %s, gebruiker %s (zonder beheerdersrechten)
ru|db_sum_local|PostgreSQL работает на этой машине (только loopback); база %s, пользователь %s (без прав администратора)
zh|db_sum_local|PostgreSQL 运行在本机（仅回环地址）；数据库 %s，用户 %s（无管理员权限）
ar|db_sum_local|يعمل PostgreSQL على هذا الجهاز (الواجهة المحلية فقط)؛ القاعدة %s والمستخدم %s (بلا صلاحيات إدارية)
en|db_sum_remote|Existing PostgreSQL server; database %s, user %s
fr|db_sum_remote|Serveur PostgreSQL existant ; base %s, utilisateur %s
es|db_sum_remote|Servidor PostgreSQL existente; base %s, usuario %s
de|db_sum_remote|Vorhandener PostgreSQL-Server; Datenbank %s, Benutzer %s
it|db_sum_remote|Server PostgreSQL esistente; database %s, utente %s
pt|db_sum_remote|Servidor PostgreSQL existente; base %s, utilizador %s
nl|db_sum_remote|Bestaande PostgreSQL-server; database %s, gebruiker %s
ru|db_sum_remote|Существующий сервер PostgreSQL; база %s, пользователь %s
zh|db_sum_remote|现有 PostgreSQL 服务器；数据库 %s，用户 %s
ar|db_sum_remote|خادم PostgreSQL موجود؛ القاعدة %s والمستخدم %s
en|db_sum_schema|Schema: %s
fr|db_sum_schema|Schéma : %s
es|db_sum_schema|Esquema: %s
de|db_sum_schema|Schema: %s
it|db_sum_schema|Schema: %s
pt|db_sum_schema|Esquema: %s
nl|db_sum_schema|Schema: %s
ru|db_sum_schema|Схема: %s
zh|db_sum_schema|架构：%s
ar|db_sum_schema|المخطط: %s
en|db_sum_secret|The connection (with its password) is in %s, readable by the ToutWAF service only
fr|db_sum_secret|La connexion (avec son mot de passe) est dans %s, lisible par le seul service ToutWAF
es|db_sum_secret|La conexión (con su contraseña) está en %s, legible solo por el servicio ToutWAF
de|db_sum_secret|Die Verbindung (mit Passwort) liegt in %s und ist nur für den ToutWAF-Dienst lesbar
it|db_sum_secret|La connessione (con la password) è in %s, leggibile solo dal servizio ToutWAF
pt|db_sum_secret|A ligação (com a palavra-passe) está em %s, legível apenas pelo serviço ToutWAF
nl|db_sum_secret|De verbinding (met wachtwoord) staat in %s, alleen leesbaar voor de ToutWAF-dienst
ru|db_sum_secret|Подключение (с паролем) хранится в %s и читается только службой ToutWAF
zh|db_sum_secret|连接信息（含密码）保存在 %s，仅 ToutWAF 服务可读
ar|db_sum_secret|الاتصال (مع كلمة المرور) في %s ولا يقرؤه إلا خدمة ToutWAF
en|db_sum_backup|A verified pg_dump runs every night (7 kept); status in the console, Santé
fr|db_sum_backup|Un pg_dump vérifié s'exécute chaque nuit (7 conservés) ; état dans la console, Santé
es|db_sum_backup|Cada noche se ejecuta un pg_dump verificado (se conservan 7); estado en la consola, Salud
de|db_sum_backup|Jede Nacht läuft ein geprüftes pg_dump (7 bleiben erhalten); Status in der Konsole, Santé
it|db_sum_backup|Ogni notte gira un pg_dump verificato (se ne conservano 7); stato nella console, Santé
pt|db_sum_backup|Todas as noites corre um pg_dump verificado (guardam-se 7); estado na consola, Santé
nl|db_sum_backup|Elke nacht draait een gecontroleerde pg_dump (7 bewaard); status in de console, Santé
ru|db_sum_backup|Каждую ночь выполняется проверенный pg_dump (хранится 7); состояние в консоли, Santé
zh|db_sum_backup|每晚运行经验证的 pg_dump（保留 7 份）；状态见控制台 Santé
ar|db_sum_backup|يعمل pg_dump موثَّق كل ليلة (يُحتفظ بـ 7)؛ الحالة في وحدة التحكم، Santé
en|db_sum_nobackup|No automatic database backup: schedule pg_dump or use the backup of your database provider
fr|db_sum_nobackup|Pas de sauvegarde automatique de la base : planifiez pg_dump ou utilisez la sauvegarde de votre hébergeur de base
es|db_sum_nobackup|Sin copia automática de la base: programe pg_dump o use la copia de su proveedor de base de datos
de|db_sum_nobackup|Keine automatische Datenbanksicherung: planen Sie pg_dump oder nutzen Sie die Sicherung Ihres Datenbankanbieters
it|db_sum_nobackup|Nessun backup automatico del database: pianifica pg_dump o usa il backup del tuo fornitore di database
pt|db_sum_nobackup|Sem cópia automática da base: agende o pg_dump ou use a cópia do seu fornecedor de base de dados
nl|db_sum_nobackup|Geen automatische databaseback-up: plan pg_dump in of gebruik de back-up van uw databaseaanbieder
ru|db_sum_nobackup|Автоматической копии базы нет: запланируйте pg_dump или используйте копирование вашего поставщика БД
zh|db_sum_nobackup|没有自动数据库备份：请安排 pg_dump 或使用数据库提供商的备份
ar|db_sum_nobackup|لا توجد نسخة احتياطية تلقائية لقاعدة البيانات: جدول pg_dump أو استخدم نسخ مزوّد قاعدة البيانات
en|db_sum_sqlite|Database: SQLite, one file on this machine (small installation). Move to PostgreSQL later: toutwaf-cp db migrate
fr|db_sum_sqlite|Base de données : SQLite, un fichier sur cette machine (petite installation). Passer à PostgreSQL plus tard : toutwaf-cp db migrate
es|db_sum_sqlite|Base de datos: SQLite, un archivo en esta máquina (instalación pequeña). Pasar a PostgreSQL más tarde: toutwaf-cp db migrate
de|db_sum_sqlite|Datenbank: SQLite, eine Datei auf diesem Rechner (kleine Installation). Später zu PostgreSQL wechseln: toutwaf-cp db migrate
it|db_sum_sqlite|Database: SQLite, un file su questa macchina (piccola installazione). Passare a PostgreSQL più tardi: toutwaf-cp db migrate
pt|db_sum_sqlite|Base de dados: SQLite, um ficheiro nesta máquina (instalação pequena). Passar para PostgreSQL mais tarde: toutwaf-cp db migrate
nl|db_sum_sqlite|Database: SQLite, één bestand op deze machine (kleine installatie). Later overstappen naar PostgreSQL: toutwaf-cp db migrate
ru|db_sum_sqlite|База данных: SQLite, один файл на этой машине (небольшая установка). Позже перейти на PostgreSQL: toutwaf-cp db migrate
zh|db_sum_sqlite|数据库：SQLite，本机上的一个文件（小型安装）。以后可迁移到 PostgreSQL：toutwaf-cp db migrate
ar|db_sum_sqlite|قاعدة البيانات: SQLite، ملف واحد على هذا الجهاز (تثبيت صغير). الانتقال إلى PostgreSQL لاحقًا: toutwaf-cp db migrate
en|s_extras|Extras: Windows agent and antivirus programs
fr|s_extras|Extras : agent Windows et programmes de l'antivirus
es|s_extras|Extras: agente de Windows y programas del antivirus
de|s_extras|Extras: Windows-Agent und Antivirus-Programme
it|s_extras|Extra: agente Windows e programmi dell'antivirus
pt|s_extras|Extras: agente Windows e programas do antivírus
nl|s_extras|Extra's: Windows-agent en antivirusprogramma's
ru|s_extras|Дополнения: агент для Windows и программы антивируса
zh|s_extras|附加包：Windows 代理和杀毒程序
ar|s_extras|الإضافات: وكيل Windows وبرامج مكافحة الفيروسات
en|s_extras_ok|Extras installed: %s programs in %s
fr|s_extras_ok|Extras installés : %s programmes dans %s
es|s_extras_ok|Extras instalados: %s programas en %s
de|s_extras_ok|Extras installiert: %s Programme in %s
it|s_extras_ok|Extra installati: %s programmi in %s
pt|s_extras_ok|Extras instalados: %s programas em %s
nl|s_extras_ok|Extra's geïnstalleerd: %s programma's in %s
ru|s_extras_ok|Дополнения установлены: %s программ в %s
zh|s_extras_ok|附加包已安装：%s 个程序，位于 %s
ar|s_extras_ok|تم تثبيت الإضافات: %s برنامج في %s
en|s_extras_sha|Extras verified: %s file(s), %s MiB (SHA-256 and signature)
fr|s_extras_sha|Extras vérifiés : %s fichier(s), %s Mio (SHA-256 et signature)
es|s_extras_sha|Extras verificados: %s archivo(s), %s MiB (SHA-256 y firma)
de|s_extras_sha|Extras geprüft: %s Datei(en), %s MiB (SHA-256 und Signatur)
it|s_extras_sha|Extra verificati: %s file, %s MiB (SHA-256 e firma)
pt|s_extras_sha|Extras verificados: %s ficheiro(s), %s MiB (SHA-256 e assinatura)
nl|s_extras_sha|Extra's gecontroleerd: %s bestand(en), %s MiB (SHA-256 en handtekening)
ru|s_extras_sha|Дополнения проверены: файлов %s, %s МиБ (SHA-256 и подпись)
zh|s_extras_sha|附加包已校验：%s 个文件，%s MiB（SHA-256 与签名）
ar|s_extras_sha|تم التحقق من الإضافات: %s ملف، %s ميبيبايت (SHA-256 والتوقيع)
en|s_extras_unchecked|Extras taken as given, without a SHA256SUMS to check them: %s
fr|s_extras_unchecked|Extras pris tels quels, sans SHA256SUMS pour les vérifier : %s
es|s_extras_unchecked|Extras tomados tal cual, sin SHA256SUMS para verificarlos: %s
de|s_extras_unchecked|Extras unverändert übernommen, ohne SHA256SUMS zur Prüfung: %s
it|s_extras_unchecked|Extra usati così come sono, senza SHA256SUMS per verificarli: %s
pt|s_extras_unchecked|Extras usados tal como estão, sem SHA256SUMS para os verificar: %s
nl|s_extras_unchecked|Extra's zoals ze zijn overgenomen, zonder SHA256SUMS om ze te controleren: %s
ru|s_extras_unchecked|Дополнения взяты как есть, без SHA256SUMS для проверки: %s
zh|s_extras_unchecked|附加包按原样使用，没有 SHA256SUMS 可供校验：%s
ar|s_extras_unchecked|تم أخذ الإضافات كما هي دون SHA256SUMS للتحقق منها: %s
en|w_extras_dl|The extras could not be downloaded (%s). ToutWAF works without them, but this console will not offer Windows nor the antivirus until they are installed.
fr|w_extras_dl|Les extras n'ont pas pu être téléchargés (%s). ToutWAF fonctionne sans eux, mais cette console ne proposera ni Windows ni l'antivirus tant qu'ils ne sont pas installés.
es|w_extras_dl|No se pudieron descargar los extras (%s). ToutWAF funciona sin ellos, pero esta consola no ofrecerá Windows ni el antivirus hasta que se instalen.
de|w_extras_dl|Die Extras konnten nicht heruntergeladen werden (%s). ToutWAF läuft auch ohne sie, doch diese Konsole bietet weder Windows noch den Virenschutz an, bis sie installiert sind.
it|w_extras_dl|Impossibile scaricare gli extra (%s). ToutWAF funziona senza, ma questa console non proporrà Windows né l'antivirus finché non saranno installati.
pt|w_extras_dl|Não foi possível transferir os extras (%s). O ToutWAF funciona sem eles, mas esta consola não oferecerá o Windows nem o antivírus enquanto não estiverem instalados.
nl|w_extras_dl|De extra's konden niet worden gedownload (%s). ToutWAF werkt zonder, maar deze console biedt geen Windows of antivirus aan zolang ze niet geïnstalleerd zijn.
ru|w_extras_dl|Не удалось загрузить дополнения (%s). ToutWAF работает без них, но эта консоль не предложит Windows и антивирус, пока они не установлены.
zh|w_extras_dl|无法下载附加包（%s）。ToutWAF 没有它们也能运行，但在安装之前，此控制台不会提供 Windows 和杀毒功能。
ar|w_extras_dl|تعذر تنزيل الإضافات (%s). يعمل ToutWAF بدونها، لكن هذه اللوحة لن تعرض Windows ولا مكافحة الفيروسات حتى يتم تثبيتها.
en|w_extras_sum|The extras %s do not match their SHA-256 in the signed SHA256SUMS: they were NOT installed.
fr|w_extras_sum|Les extras %s ne correspondent pas à leur SHA-256 du SHA256SUMS signé : ils n'ont PAS été installés.
es|w_extras_sum|Los extras %s no coinciden con su SHA-256 del SHA256SUMS firmado: NO se instalaron.
de|w_extras_sum|Die Extras %s stimmen nicht mit ihrem SHA-256 im signierten SHA256SUMS überein: sie wurden NICHT installiert.
it|w_extras_sum|Gli extra %s non corrispondono al loro SHA-256 nel SHA256SUMS firmato: NON sono stati installati.
pt|w_extras_sum|Os extras %s não correspondem ao seu SHA-256 no SHA256SUMS assinado: NÃO foram instalados.
nl|w_extras_sum|De extra's %s komen niet overeen met hun SHA-256 in de ondertekende SHA256SUMS: ze zijn NIET geïnstalleerd.
ru|w_extras_sum|Дополнения %s не совпадают со своей суммой SHA-256 в подписанном SHA256SUMS: они НЕ установлены.
zh|w_extras_sum|附加包 %s 与已签名 SHA256SUMS 中的 SHA-256 不一致：未安装。
ar|w_extras_sum|الإضافات %s لا تطابق قيمة SHA-256 في SHA256SUMS الموقّع: لم يتم تثبيتها.
en|w_extras_bad|The extras file %s is not a valid extras archive: it was NOT installed.
fr|w_extras_bad|Le fichier d'extras %s n'est pas une archive d'extras valide : il n'a PAS été installé.
es|w_extras_bad|El archivo de extras %s no es un archivo de extras válido: NO se instaló.
de|w_extras_bad|Die Extras-Datei %s ist kein gültiges Extras-Archiv: sie wurde NICHT installiert.
it|w_extras_bad|Il file di extra %s non è un archivio di extra valido: NON è stato installato.
pt|w_extras_bad|O ficheiro de extras %s não é um arquivo de extras válido: NÃO foi instalado.
nl|w_extras_bad|Het extra-bestand %s is geen geldig extra-archief: het is NIET geïnstalleerd.
ru|w_extras_bad|Файл дополнений %s не является допустимым архивом дополнений: он НЕ установлен.
zh|w_extras_bad|附加包文件 %s 不是有效的附加包归档：未安装。
ar|w_extras_bad|ملف الإضافات %s ليس أرشيف إضافات صالحا: لم يتم تثبيته.
en|w_extras_ver|The extras are for version %s, this installation is %s: they were NOT installed.
fr|w_extras_ver|Les extras sont de la version %s, cette installation est en %s : ils n'ont PAS été installés.
es|w_extras_ver|Los extras son de la versión %s, esta instalación es %s: NO se instalaron.
de|w_extras_ver|Die Extras gehören zu Version %s, diese Installation ist %s: sie wurden NICHT installiert.
it|w_extras_ver|Gli extra sono della versione %s, questa installazione è %s: NON sono stati installati.
pt|w_extras_ver|Os extras são da versão %s, esta instalação é %s: NÃO foram instalados.
nl|w_extras_ver|De extra's zijn van versie %s, deze installatie is %s: ze zijn NIET geïnstalleerd.
ru|w_extras_ver|Дополнения от версии %s, а эта установка — %s: они НЕ установлены.
zh|w_extras_ver|附加包适用于版本 %s，而此安装为 %s：未安装。
ar|w_extras_ver|الإضافات خاصة بالإصدار %s وهذا التثبيت هو %s: لم يتم تثبيتها.
en|w_extras_inc|The release lists %s part(s) of the extras but says it has %s: the publication is damaged, the extras were NOT installed.
fr|w_extras_inc|La version liste %s partie(s) des extras mais annonce %s : la publication est abîmée, les extras n'ont PAS été installés.
es|w_extras_inc|La versión lista %s parte(s) de los extras pero indica %s: la publicación está dañada, los extras NO se instalaron.
de|w_extras_inc|Die Version listet %s Teil(e) der Extras, nennt aber %s: die Veröffentlichung ist beschädigt, die Extras wurden NICHT installiert.
it|w_extras_inc|La versione elenca %s parte/i degli extra ma ne dichiara %s: la pubblicazione è danneggiata, gli extra NON sono stati installati.
pt|w_extras_inc|A versão lista %s parte(s) dos extras mas indica %s: a publicação está danificada, os extras NÃO foram instalados.
nl|w_extras_inc|De versie vermeldt %s deel/delen van de extra's maar zegt er %s te hebben: de publicatie is beschadigd, de extra's zijn NIET geïnstalleerd.
ru|w_extras_inc|Релиз перечисляет %s частей дополнений, но заявляет %s: публикация повреждена, дополнения НЕ установлены.
zh|w_extras_inc|该版本列出了附加包的 %s 个部分，但声明共有 %s 个：发布已损坏，未安装附加包。
ar|w_extras_inc|يسرد الإصدار %s جزءا من الإضافات لكنه يذكر %s: النشر تالف ولم يتم تثبيت الإضافات.
en|w_extras_nofile|The extras file %s does not exist.
fr|w_extras_nofile|Le fichier d'extras %s n'existe pas.
es|w_extras_nofile|El archivo de extras %s no existe.
de|w_extras_nofile|Die Extras-Datei %s existiert nicht.
it|w_extras_nofile|Il file di extra %s non esiste.
pt|w_extras_nofile|O ficheiro de extras %s não existe.
nl|w_extras_nofile|Het extra-bestand %s bestaat niet.
ru|w_extras_nofile|Файл дополнений %s не существует.
zh|w_extras_nofile|附加包文件 %s 不存在。
ar|w_extras_nofile|ملف الإضافات %s غير موجود.
en|w_extras_none|This release carries no extras: this console will not offer Windows nor the antivirus.
fr|w_extras_none|Cette version ne contient pas d'extras : cette console ne proposera ni Windows ni l'antivirus.
es|w_extras_none|Esta versión no incluye extras: esta consola no ofrecerá Windows ni el antivirus.
de|w_extras_none|Diese Version enthält keine Extras: diese Konsole bietet weder Windows noch den Virenschutz an.
it|w_extras_none|Questa versione non contiene extra: questa console non proporrà Windows né l'antivirus.
pt|w_extras_none|Esta versão não inclui extras: esta consola não oferecerá o Windows nem o antivírus.
nl|w_extras_none|Deze versie bevat geen extra's: deze console biedt geen Windows of antivirus aan.
ru|w_extras_none|В этом релизе нет дополнений: эта консоль не предложит Windows и антивирус.
zh|w_extras_none|此版本不含附加包：此控制台不会提供 Windows 和杀毒功能。
ar|w_extras_none|لا يحتوي هذا الإصدار على إضافات: لن تعرض هذه اللوحة Windows ولا مكافحة الفيروسات.
en|w_extras_todo|Extras not installed. When the network allows it, run as root: %s
fr|w_extras_todo|Extras non installés. Quand le réseau le permet, lancez en root : %s
es|w_extras_todo|Extras no instalados. Cuando la red lo permita, ejecute como root: %s
de|w_extras_todo|Extras nicht installiert. Sobald das Netz es erlaubt, als root ausführen: %s
it|w_extras_todo|Extra non installati. Quando la rete lo consente, eseguire come root: %s
pt|w_extras_todo|Extras não instalados. Quando a rede o permitir, execute como root: %s
nl|w_extras_todo|Extra's niet geïnstalleerd. Zodra het netwerk het toelaat, voer uit als root: %s
ru|w_extras_todo|Дополнения не установлены. Когда сеть позволит, выполните от root: %s
zh|w_extras_todo|附加包未安装。网络可用时请以 root 运行：%s
ar|w_extras_todo|لم يتم تثبيت الإضافات. عندما تسمح الشبكة، شغّل بصلاحيات root: %s
en|extras_needs_cp|The extras belong to the control plane: it is not installed on this machine.
fr|extras_needs_cp|Les extras appartiennent au plan de contrôle : il n'est pas installé sur cette machine.
es|extras_needs_cp|Los extras pertenecen al plano de control: no está instalado en esta máquina.
de|extras_needs_cp|Die Extras gehören zur Control Plane: sie ist auf diesem Rechner nicht installiert.
it|extras_needs_cp|Gli extra appartengono al control plane: non è installato su questa macchina.
pt|extras_needs_cp|Os extras pertencem ao plano de controlo: não está instalado nesta máquina.
nl|extras_needs_cp|De extra's horen bij de control plane: die is niet geïnstalleerd op deze machine.
ru|extras_needs_cp|Дополнения относятся к control plane: он не установлен на этой машине.
zh|extras_needs_cp|附加包属于控制平面：本机未安装控制平面。
ar|extras_needs_cp|الإضافات تخص مستوى التحكم: وهو غير مثبت على هذا الجهاز.
en|extras_other_release|The published release (%s) is not the installed one (%s): the extras come with it. Run --update.
fr|extras_other_release|La version publiée (%s) n'est pas celle qui est installée (%s) : les extras viennent avec elle. Lancez --update.
es|extras_other_release|La versión publicada (%s) no es la instalada (%s): los extras vienen con ella. Ejecute --update.
de|extras_other_release|Die veröffentlichte Version (%s) ist nicht die installierte (%s): die Extras kommen mit ihr. --update ausführen.
it|extras_other_release|La versione pubblicata (%s) non è quella installata (%s): gli extra arrivano con essa. Eseguire --update.
pt|extras_other_release|A versão publicada (%s) não é a instalada (%s): os extras vêm com ela. Execute --update.
nl|extras_other_release|De gepubliceerde versie (%s) is niet de geïnstalleerde (%s): de extra's komen daarmee mee. Voer --update uit.
ru|extras_other_release|Опубликованный релиз (%s) не совпадает с установленным (%s): дополнения идут вместе с ним. Выполните --update.
zh|extras_other_release|已发布的版本（%s）不是已安装的版本（%s）：附加包随它一起提供。请运行 --update。
ar|extras_other_release|الإصدار المنشور (%s) ليس المثبت (%s): الإضافات تأتي معه. شغّل --update.
en|st_extras_ok|Extras: installed (Windows agent, antivirus programs)
fr|st_extras_ok|Extras : installés (agent Windows, programmes de l'antivirus)
es|st_extras_ok|Extras: instalados (agente de Windows, programas del antivirus)
de|st_extras_ok|Extras: installiert (Windows-Agent, Antivirus-Programme)
it|st_extras_ok|Extra: installati (agente Windows, programmi dell'antivirus)
pt|st_extras_ok|Extras: instalados (agente Windows, programas do antivírus)
nl|st_extras_ok|Extra's: geïnstalleerd (Windows-agent, antivirusprogramma's)
ru|st_extras_ok|Дополнения: установлены (агент для Windows, программы антивируса)
zh|st_extras_ok|附加包：已安装（Windows 代理、杀毒程序）
ar|st_extras_ok|الإضافات: مثبتة (وكيل Windows وبرامج مكافحة الفيروسات)
en|st_extras_none|Extras missing: Windows and the antivirus are not offered. Run as root: %s
fr|st_extras_none|Extras absents : Windows et l'antivirus ne sont pas proposés. Lancez en root : %s
es|st_extras_none|Extras ausentes: Windows y el antivirus no se ofrecen. Ejecute como root: %s
de|st_extras_none|Extras fehlen: Windows und der Virenschutz werden nicht angeboten. Als root ausführen: %s
it|st_extras_none|Extra mancanti: Windows e l'antivirus non sono proposti. Eseguire come root: %s
pt|st_extras_none|Extras em falta: o Windows e o antivírus não são oferecidos. Execute como root: %s
nl|st_extras_none|Extra's ontbreken: Windows en antivirus worden niet aangeboden. Voer uit als root: %s
ru|st_extras_none|Дополнения отсутствуют: Windows и антивирус не предлагаются. Выполните от root: %s
zh|st_extras_none|缺少附加包：不提供 Windows 和杀毒功能。请以 root 运行：%s
ar|st_extras_none|الإضافات مفقودة: لا يتم عرض Windows ولا مكافحة الفيروسات. شغّل بصلاحيات root: %s
# END CATALOG
TW_CATALOG
}
CATALOG="$(read_catalog)"

# t KEY [args...]: localized text with printf-style %s placeholders (falls back to English, then to the key)
t() {
  local key="$1" line fmt; shift
  line="$(printf '%s\n' "$CATALOG" | grep -m1 "^${LANG_CODE:-en}|$key|" || true)"
  [ -n "$line" ] || line="$(printf '%s\n' "$CATALOG" | grep -m1 "^en|$key|" || true)"
  fmt="${line#*|*|}"; [ -n "$line" ] || fmt="$key"
  # shellcheck disable=SC2059
  printf -- "$fmt" "$@"
}

# ------------------------------------------------------------------------------------------------ platform data
# Distributions, versions and their status come from deploy/platforms.json (single source of truth, also rendered to
# docs/install/platforms.md). Generated: edit deploy/platforms.json and run deploy/tools/gen-platforms.py, not these lines.
# BEGIN PLATFORMS (generated by tools/gen-platforms.py)
read_platforms() { cat <<'TW_PLATFORMS'
req|glibc|2.28
req|systemd|239
req|kernel|4.18
arch|amd64|supported|-|x86_64 amd64
arch|arm64|supported|-|aarch64 arm64
arch|arm32|unsupported|arch|armv7l armv6l armhf arm
family|rhel|Red Hat family|dnf|firewalld|selinux
like|rhel|rhel
like|rhel|fedora
like|rhel|centos
pkg|rhel|curl|curl
pkg|rhel|tar|tar
pkg|rhel|gzip|gzip
pkg|rhel|coreutils|coreutils
pkg|rhel|awk|gawk
pkg|rhel|openssl|openssl
pkg|rhel|ca|ca-certificates
pkg|rhel|libcap|libcap
pkg|rhel|selinux|policycoreutils-python-utils
pkg|rhel|logrotate|logrotate
family|amazon|Amazon Linux|dnf|firewalld|selinux
pkg|amazon|curl|curl
pkg|amazon|tar|tar
pkg|amazon|gzip|gzip
pkg|amazon|coreutils|coreutils
pkg|amazon|awk|gawk
pkg|amazon|openssl|openssl
pkg|amazon|ca|ca-certificates
pkg|amazon|libcap|libcap
pkg|amazon|selinux|policycoreutils-python-utils
pkg|amazon|logrotate|logrotate
family|debian|Debian family|apt|ufw|apparmor
like|debian|debian
like|debian|ubuntu
pkg|debian|curl|curl
pkg|debian|tar|tar
pkg|debian|gzip|gzip
pkg|debian|coreutils|coreutils
pkg|debian|awk|mawk
pkg|debian|openssl|openssl
pkg|debian|ca|ca-certificates
pkg|debian|libcap|libcap2-bin
pkg|debian|selinux|policycoreutils-python-utils
pkg|debian|logrotate|logrotate
family|suse|SUSE family|zypper|firewalld|apparmor
like|suse|suse
like|suse|opensuse
pkg|suse|curl|curl
pkg|suse|tar|tar
pkg|suse|gzip|gzip
pkg|suse|coreutils|coreutils
pkg|suse|awk|gawk
pkg|suse|openssl|openssl
pkg|suse|ca|ca-certificates-mozilla
pkg|suse|libcap|libcap-progs
pkg|suse|selinux|policycoreutils-python-utils
pkg|suse|logrotate|logrotate
family|arch|Arch family|pacman|none|none
like|arch|arch
pkg|arch|curl|curl
pkg|arch|tar|tar
pkg|arch|gzip|gzip
pkg|arch|coreutils|coreutils
pkg|arch|awk|gawk
pkg|arch|openssl|openssl
pkg|arch|ca|ca-certificates
pkg|arch|libcap|libcap
pkg|arch|selinux|-
pkg|arch|logrotate|logrotate
distro|almalinux|rhel|AlmaLinux|8|major|-
ver|almalinux|10|tested|-
ver|almalinux|9|tested|-
ver|almalinux|8|tested|-
distro|rocky|rhel|Rocky Linux|8|major|-
ver|rocky|10|tested|-
ver|rocky|9|tested|-
ver|rocky|8|tested|-
distro|rhel|rhel|Red Hat Enterprise Linux|8|major|-
ver|rhel|10|tested|-
ver|rhel|9|tested|-
ver|rhel|8|tested|-
ver|rhel|7|unsupported|eol
distro|centos|rhel|CentOS Stream|9|major|-
ver|centos|10|tested|-
ver|centos|9|tested|-
ver|centos|8|unsupported|eol
ver|centos|7|unsupported|eol
distro|ol|rhel|Oracle Linux|8|major|-
ver|ol|10|tested|-
ver|ol|9|tested|-
ver|ol|8|tested|-
ver|ol|7|unsupported|eol
distro|fedora|rhel|Fedora|41|major|-
ver|fedora|44|tested|-
ver|fedora|43|tested|-
ver|fedora|42|tested|-
ver|fedora|41|tested|-
distro|amzn|amazon|Amazon Linux|2023|major|-
ver|amzn|2023|tested|-
ver|amzn|2|unsupported|eol
distro|debian|debian|Debian|11|major|-
ver|debian|13|tested|-
ver|debian|12|tested|-
ver|debian|11|tested|-
ver|debian|10|unsupported|eol
distro|ubuntu|debian|Ubuntu|20.04|minor|-
ver|ubuntu|26.04|tested|-
ver|ubuntu|25.10|tested|-
ver|ubuntu|24.04|tested|-
ver|ubuntu|22.04|tested|-
ver|ubuntu|20.04|tested|-
ver|ubuntu|18.04|unsupported|glibc
distro|linuxmint|debian|Linux Mint / LMDE|-|major|derived
ver|linuxmint|*|expected|-
distro|pop|debian|Pop!_OS|-|major|derived
ver|pop|*|expected|-
distro|zorin|debian|Zorin OS|-|major|derived
ver|zorin|*|expected|-
distro|elementary|debian|elementary OS|-|major|derived
ver|elementary|*|expected|-
distro|kali|debian|Kali Linux|-|major|rolling
ver|kali|*|expected|-
distro|raspbian|debian|Raspberry Pi OS (32-bit, Raspbian)|-|major|-
ver|raspbian|*|unsupported|arm32
distro|devuan|debian|Devuan|-|major|-
ver|devuan|*|unsupported|init
distro|opensuse-leap|suse|openSUSE Leap|15.6|minor|-
ver|opensuse-leap|16.0|tested|-
ver|opensuse-leap|15.6|tested|-
distro|opensuse-tumbleweed|suse|openSUSE Tumbleweed|-|major|rolling
ver|opensuse-tumbleweed|*|tested|-
distro|opensuse-slowroll|suse|openSUSE Slowroll|-|major|rolling
ver|opensuse-slowroll|*|expected|-
distro|sles|suse|SUSE Linux Enterprise Server|15.6|minor|-
ver|sles|16.0|expected|-
ver|sles|15.7|expected|-
ver|sles|15.6|expected|-
distro|sle-micro|suse|SUSE Linux Micro / MicroOS / Aeon|-|major|-
ver|sle-micro|*|unsupported|immutable
distro|opensuse-microos|suse|openSUSE MicroOS / Aeon / Kalpa|-|major|-
alias|opensuse-aeon|opensuse-microos
alias|opensuse-kalpa|opensuse-microos
ver|opensuse-microos|*|unsupported|immutable
distro|arch|arch|Arch Linux|-|major|rolling
ver|arch|*|tested|-
distro|manjaro|arch|Manjaro|-|major|rolling
ver|manjaro|*|expected|-
distro|endeavouros|arch|EndeavourOS|-|major|rolling
ver|endeavouros|*|expected|-
distro|garuda|arch|Garuda Linux|-|major|rolling
ver|garuda|*|expected|-
distro|cachyos|arch|CachyOS|-|major|rolling
ver|cachyos|*|expected|-
distro|artix|arch|Artix Linux|-|major|-
ver|artix|*|unsupported|init
distro|alpine|-|Alpine Linux|-|major|-
ver|alpine|*|unsupported|musl
distro|void|-|Void Linux|-|major|-
ver|void|*|unsupported|init
distro|nixos|-|NixOS|-|major|-
ver|nixos|*|unsupported|layout
TW_PLATFORMS
}
# END PLATFORMS
PLATFORMS="$(read_platforms)"

# ------------------------------------------------------------------------------------------------ UI helpers
UI_COLOR=0; UI_UTF=0; UI_TRUECOLOR=0; BANNER_DONE=0
SPIN_PID=""; LOG=""; CUR_STEP=""; WARNINGS=()
R=""; B=""; D=""; RED=""; GRN=""; YLW=""; ACC=""; VIO=""
exec 3>&2                                       # original stderr (die/warn must stay visible while steps are redirected)

detect_ui() {
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ] && [ "$NO_COLOR_FLAG" = 0 ]; then UI_COLOR=1; fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UI_UTF=1;; esac
  [ "${TOUTWAF_UTF8:-}" = 1 ] && UI_UTF=1
  case "${COLORTERM:-}" in truecolor|24bit) UI_TRUECOLOR=1;; esac
  if [ "$UI_COLOR" = 1 ]; then
    R=$'\033[0m'; B=$'\033[1m'; D=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'
    ACC=$'\033[38;5;75m'; VIO=$'\033[38;5;141m'
  fi
  if [ "$UI_UTF" = 1 ]; then
    OKM="✔"; ERM="✖"; WRM="!"; BUL="•"; H="─"; V="│"; TL="╭"; BL="╰"; ARW="›"
    SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    OKM="[ok]"; ERM="[x]"; WRM="[!]"; BUL="*"; H="-"; V="|"; TL="+"; BL="+"; ARW=">"
    SPIN_FRAMES=('|' '/' '-' '\')
  fi
  # accents and non-Latin scripts need a UTF-8 terminal: otherwise fall back to English
  if [ "$UI_UTF" = 0 ] && [ "${LANG_CODE:-en}" != en ]; then LANG_CODE=en; fi
  return 0
}

detect_lang() {
  # order: --fr / --lang fr, then TOUTWAF_LANG, then the system language (LANG), then English
  if [ -z "$LANG_CODE" ]; then
    local l="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"; LANG_CODE="${l%%[_.@-]*}"
  fi
  case "$LANG_CODE" in en|fr|es|de|it|pt|nl|ru|zh|ar) ;; *) LANG_CODE=en;; esac
}

paint() { printf '%s%s%s' "$1" "$2" "$R"; }
say()  { if [ "$QUIET" = 0 ]; then printf '%s\n' "$*"; fi; return 0; }
rule() { local n="${1:-60}" i s=""; for ((i = 0; i < n; i++)); do s+="$H"; done; printf '%s' "$s"; }

banner() {
  [ "$QUIET" = 1 ] && return 0
  [ "$BANNER_DONE" = 1 ] && return 0
  BANNER_DONE=1
  local rows=() row i w ch out r g b idx pal lastidx
  if [ "$UI_UTF" = 1 ]; then
    rows=(
"████████╗ ██████╗ ██╗   ██╗████████╗██╗    ██╗ █████╗ ███████╗"
"╚══██╔══╝██╔═══██╗██║   ██║╚══██╔══╝██║    ██║██╔══██╗██╔════╝"
"   ██║   ██║   ██║██║   ██║   ██║   ██║ █╗ ██║███████║█████╗"
"   ██║   ██║   ██║██║   ██║   ██║   ██║███╗██║██╔══██║██╔══╝"
"   ██║   ╚██████╔╝╚██████╔╝   ██║   ╚███╔███╔╝██║  ██║██║"
"   ╚═╝    ╚═════╝  ╚═════╝    ╚═╝    ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝")
  else
    rows=(
' _____ ___  _   _ _____ __        ___    _____ '
'|_   _/ _ \| | | |_   _|\ \      / / \  |  ___|'
'  | || | | | | | | | |   \ \ /\ / / _ \ | |_   '
'  | || |_| | |_| | | |    \ V  V / ___ \|  _|  '
'  |_| \___/ \___/  |_|     \_/\_/_/   \_\_|    ')
  fi
  echo
  pal=(27 33 69 105 141 135)
  for row in "${rows[@]}"; do
    # a UTF-8 terminal with a locale bash does not have counts bytes, not characters: no per-character gradient then
    if [ "$UI_COLOR" = 1 ] && [ "$UI_UTF" = 1 ] && [ "${#row}" -eq "$(printf '%s' "$row" | wc -c)" ]; then printf '  %s%s%s\n' "$VIO" "$row" "$R"
    elif [ "$UI_COLOR" = 1 ]; then
      w=${#row}; out="  "; lastidx=""
      for ((i = 0; i < w; i++)); do
        ch="${row:i:1}"
        if [ "$ch" = " " ]; then out+=" "; continue; fi
        if [ "$UI_TRUECOLOR" = 1 ]; then   # blue (59,130,246) -> violet (139,92,246)
          r=$((59 + (139 - 59) * i / w)); g=$((130 + (92 - 130) * i / w)); b=246
          printf -v idx '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
        else
          printf -v idx '\033[38;5;%dm' "${pal[$((i * 6 / w))]}"
          if [ "$idx" = "$lastidx" ]; then idx=""; else lastidx="$idx"; fi    # emit a colour code only when it changes
        fi
        out+="$idx$ch"
      done
      printf '%s%s\n' "$out" "$R"
    else printf '  %s\n' "$row"; fi
  done
  printf '  %s%s%s  %s·%s  %sinstaller v%s%s\n\n' "$B" "$(t tagline)" "$R" "$D" "$R" "$D" "$INSTALLER_VERSION" "$R"
}

FRAME_W=78
frame_fill() { local n=$((FRAME_W - 4 - ${#1})); [ "$n" -ge 3 ] || n=3; rule "$n"; }
box_top()    { [ "$QUIET" = 1 ] || printf '%s%s%s %s%s%s %s%s\n' "$ACC" "$TL" "$H" "$B" "$1" "$R$ACC" "$(frame_fill "$1")" "$R"; }
box_line()   { [ "$QUIET" = 1 ] || printf '%s%s%s %s\n' "$ACC" "$V" "$R" "$1"; }
box_bottom() { [ "$QUIET" = 1 ] || printf '%s%s%s%s\n' "$ACC" "$BL" "$(rule $((FRAME_W - 1)))" "$R"; }

log()  { printf '%s\n' "$*" >>"${LOG:-/dev/null}" 2>/dev/null || true; return 0; }
# progress: when the control plane's update helper runs us (TOUTWAF_PROGRESS_FILE), every step is appended there for the console
progress() { if [ -n "${TOUTWAF_PROGRESS_FILE:-}" ]; then printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$TOUTWAF_PROGRESS_FILE" 2>/dev/null || true; fi; return 0; }
# info: detail line; shown on plain (non-TTY / --no-color) output, kept in the log only while a spinner runs
info() {
  log "$*"
  if [ "$SPIN_PID" = "" ] && [ "$UI_COLOR" = 0 ] && [ "$QUIET" = 0 ]; then printf '    %s %s\n' "$BUL" "$*" >&3; fi
  return 0
}
warn() {
  WARNINGS+=("$*"); log "[warn] $*"; progress "[warn] $*"
  if [ "$SPIN_PID" = "" ] && [ "$UI_COLOR" = 0 ] && [ "$QUIET" = 0 ]; then printf '[warn] %s\n' "$*" >&3; fi
  return 0
}
spin_kill() { if [ -n "$SPIN_PID" ]; then kill "$SPIN_PID" 2>/dev/null || true; wait "$SPIN_PID" 2>/dev/null || true; SPIN_PID=""; printf '\r\033[K'; fi; return 0; }
fail_report() {   # message
  progress "ERROR $1${2:+ ($2)}"
  spin_kill
  [ "$UI_COLOR" = 1 ] && printf '\033[?25h'
  printf '%s%s %s%s%s\n' "$RED" "$ERM" "$1" "$R" "${2:+ ($2)}" >&3
  if [ -n "$LOG" ] && [ -s "$LOG" ]; then tail -n 15 "$LOG" | sed 's/^/    /' >&3; printf '    %s\n' "$(t log_hint "$LOG")" >&3; fi
}
die() { fail_report "$*"; exit 1; }
on_err() { local rc=$?; trap - ERR; fail_report "${CUR_STEP:-$(t failed)}" "$(t failed) rc=$rc"; exit "$rc"; }
cleanup() {
  # the spinner runs in a background subshell that may inherit this EXIT trap: only the main shell may clean up
  [ "${BASHPID:-$$}" = "$$" ] || return 0
  spin_kill; [ -n "${TMP:-}" ] && rm -rf "$TMP"; [ "$UI_COLOR" = 1 ] && printf '\033[?25h'; return 0; }
trap cleanup EXIT
trap on_err ERR

# step "message" cmd args...: spinner (TTY) or bullet, output of the command goes to the log; a failure aborts (ERR trap)
step() {
  CUR_STEP="$1"; shift; progress "$CUR_STEP"
  if [ "$DRY_RUN" = 1 ]; then printf '  %s %s\n' "$BUL" "$CUR_STEP"; "$@"; return 0; fi
  if [ "$QUIET" = 0 ] && [ "$UI_COLOR" = 1 ]; then
    printf '\033[?25l'
    ( trap - EXIT ERR; i=0; while :; do printf '\r  %s%s%s %s\033[K' "$ACC" "${SPIN_FRAMES[$((i % ${#SPIN_FRAMES[@]}))]}" "$R" "$CUR_STEP"; i=$((i + 1)); sleep 0.1; done ) >&3 &
    SPIN_PID=$!
  elif [ "$QUIET" = 0 ]; then printf '  %s %s\n' "$BUL" "$CUR_STEP"; fi
  printf '== %s\n' "$CUR_STEP" >>"$LOG"
  "$@" >>"$LOG" 2>&1 </dev/null
  if [ "$SPIN_PID" != "" ]; then spin_kill; printf '\033[?25h'; fi
  if [ "$QUIET" = 0 ] && [ "$UI_COLOR" = 1 ]; then printf '  %s%s%s %s\n' "$GRN" "$OKM" "$R" "$CUR_STEP"; fi
  CUR_STEP=""
  return 0
}

run()  { if [ "$DRY_RUN" = 1 ]; then local IFS=' '; printf '%s[dry-run]%s %s\n' "$D" "$R" "$*"; else "$@" </dev/null; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
# firewalld_running: true only when the daemon is really up. "firewall-cmd --state" alone is not a safe probe: with firewalld installed but stopped it
# triggers D-Bus activation (starts the daemon as a side effect, or blocks ~50 s when it cannot start, e.g. in a container)
firewalld_running() {
  have firewall-cmd || return 1
  if [ -d /run/systemd/system ] && have systemctl; then systemctl is-active --quiet firewalld 2>/dev/null || return 1
  elif have pgrep; then pgrep -x firewalld >/dev/null 2>&1 || return 1; fi
  if have timeout; then timeout 20 firewall-cmd --state >/dev/null 2>&1; else firewall-cmd --state >/dev/null 2>&1; fi
}
p()    { printf '%s%s' "$DESTDIR" "$1"; }       # path inside DESTDIR
same_file() { [ -f "$1" ] && [ -f "$2" ] && [ "$(sha256sum <"$1" | cut -d' ' -f1)" = "$(sha256sum <"$2" | cut -d' ' -f1)" ]; }   # cmp(1) (diffutils) is absent on minimal images
fqdn() { hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || echo localhost; }   # hostname(1) is absent on minimal images
port_listening() { (exec 4<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ------------------------------------------------------------------------------------------------ compatibility check
# Pre-flight verdict, computed before anything is changed (install / update / --dry-run / --check-compat).
# The pre-flight runs BEFORE the prerequisites are installed and must work on a bare image: bash + coreutils + grep + sed only (no awk).
pf_lines() { local l; while IFS= read -r l; do case "$l" in "$1|"*) printf '%s\n' "$l";; esac; done <<<"$PLATFORMS"; }   # every line of one kind
# pf_get KIND MATCHCOL MATCHVALUE OUTCOL: field OUTCOL of the first KIND line whose field MATCHCOL equals MATCHVALUE ("kind" is field 0)
pf_get() {
  local l pa
  while IFS= read -r l; do
    case "$l" in "$1|"*) IFS='|' read -r -a pa <<<"$l"; if [ "${pa[$2]:-}" = "$3" ]; then printf '%s' "${pa[$4]:-}"; return 0; fi;; esac
  done <<<"$PLATFORMS"
  return 0
}
pf_req() { pf_get req 1 "$1" 2; }
pf_fam() { pf_get family 1 "$1" "$2"; }                                       # pf_fam FAMILY COL: 2 name, 3 package manager, 4 firewall, 5 MAC (fields counted from 0 = "family")
pf_pkg() {                                                                    # pf_pkg FAMILY LOGICAL-NAME -> package name ("-" = none)
  local l pa
  while IFS= read -r l; do
    case "$l" in "pkg|$1|$2|"*) IFS='|' read -r -a pa <<<"$l"; printf '%s' "${pa[3]}"; return 0;; esac
  done <<<"$PLATFORMS"
  return 0
}
# vcmp A B: -1 / 0 / 1 for dotted numeric versions (non-numeric characters are ignored)
vcmp() {
  local IFS=. va=() vb=() i x y
  read -ra va <<<"$1"; read -ra vb <<<"$2"
  for i in 0 1 2 3; do
    x="${va[i]:-0}"; y="${vb[i]:-0}"; x="${x//[!0-9]/}"; y="${y//[!0-9]/}"; x=$((10#${x:-0})); y=$((10#${y:-0}))
    if [ "$x" -lt "$y" ]; then echo -1; return 0; fi
    if [ "$x" -gt "$y" ]; then echo 1; return 0; fi
  done
  echo 0
}
vlt() { [ "$(vcmp "$1" "$2")" = -1 ]; }

CP_NAME=""; CP_LABEL=""; CP_STATUS="expected"; CP_FAMILY=""; CP_REASONS=(); CP_NOTES=()
CP_HARD=0; COMPAT_OK=0; CP_GLIBC="?"; CP_SYSTEMD="?"; CP_KERNEL="?"; CP_ARCHRAW=""; COMPAT_LINE=""; SKIP_OS_CHECK="${SKIP_OS_CHECK:-0}"
cp_reason() { CP_REASONS+=("$(t "$@")"); }
cp_note()   { CP_NOTES+=("$(t "$@")"); }

compat_eval() {
  local IFS=' ' line l id al fam name min key flags ver wild entry k max st code tok v1 s1 c1
  local aid ast archok un m gl sv kv ub pim
  CP_REASONS=(); CP_NOTES=(); CP_STATUS=expected; CP_FAMILY=""; CP_NAME="${OS_NAME:-$OS_ID}"; CP_LABEL="$CP_NAME"
  # ---- distribution and version
  if [ "$OS_RELEASE_MISSING" = 1 ]; then
    CP_STATUS=unsupported; cp_reason cp_r_noosr
  else
    id="$OS_ID"; al="$(pf_get alias 1 "$id" 2)"; [ -z "$al" ] || id="$al"
    line=""
    while IFS= read -r l; do case "$l" in "distro|$id|"*) line="$l"; break;; esac; done <<<"$PLATFORMS"
    if [ -n "$line" ]; then
      IFS='|' read -r _ _ fam name min key flags <<<"$line"
      [ "$fam" != "-" ] || fam=""
      CP_FAMILY="$fam"; CP_NAME="$name"; ver="$OS_VER"; CP_LABEL="$name${ver:+ $ver}"
      case ",$flags," in *,derived,*) CP_LABEL="${OS_NAME:-$name}";; *,rolling,*) CP_LABEL="$name";; esac
      st=""; code="-"; wild=0; entry=0; max=""; k=""
      case "$key" in minor) k="$(printf '%s' "$ver" | cut -d. -f1-2)";; *) k="${ver%%.*}";; esac
      while IFS= read -r l; do                                  # the version lines of this distribution
        case "$l" in "ver|$id|"*) ;; *) continue;; esac
        IFS='|' read -r _ _ v1 s1 c1 <<<"$l"
        if [ "$v1" = "*" ]; then st="$s1"; code="$c1"; wild=1
        elif [ -n "$ver" ] && [ "$v1" = "$k" ]; then st="$s1"; code="$c1"; entry=1; fi
        if [ "$s1" != unsupported ] && [ "$v1" != "*" ] && { [ -z "$max" ] || vlt "$max" "$v1"; }; then max="$v1"; fi
      done <<<"$PLATFORMS"
      if [ "$wild" = 1 ]; then :                                 # derived / rolling / one status for every version
      elif [ -z "$ver" ]; then st=expected; cp_note cp_w_nover "$name"
      elif [ "$entry" = 1 ]; then :
      elif [ "$min" != "-" ] && vlt "$k" "$min"; then st=unsupported; code=old
      else
        st=expected
        if [ -n "$max" ] && vlt "$max" "$k"; then cp_note cp_w_newer "$name" "$ver"; else cp_note cp_w_unlisted "$name" "$ver"; fi
      fi
      if [ "$st" = unsupported ]; then
        CP_STATUS=unsupported
        case "$code" in
          old) cp_reason cp_r_old "$name" "$ver" "$min";;
          init) cp_reason cp_r_init "$name" "$ver";;
          immutable) cp_reason cp_r_immutable "$name" "$ver";;
          layout) cp_reason cp_r_layout "$name" "$ver";;
          musl) cp_reason cp_r_musl "$(pf_req glibc)";;
          arm32) cp_reason cp_r_arm32; CP_HARD=1;;
          arch) cp_reason cp_r_distro_arch "$name" "$ver";;
          *) cp_reason cp_r_eol "$name" "$ver";;
        esac
      else CP_STATUS="$st"; fi
    else
      # unknown identifier: a known family in ID_LIKE is enough (derivative), otherwise refuse
      fam=""
      for tok in $OS_LIKE; do
        fam="$(pf_get like 2 "$tok" 1)"; [ -z "$fam" ] || break
      done
      if [ -n "$fam" ]; then CP_FAMILY="$fam"; cp_note cp_w_like "$CP_NAME" "$(pf_fam "$fam" 2)"
      else CP_STATUS=unsupported; cp_reason cp_r_unknown "$OS_ID" "$OS_LIKE"; fi
    fi
  fi
  # ---- architecture
  m="${TEST_ARCH:-$(uname -m)}"; CP_ARCHRAW="$m"; ARCH="$m"
  ast=unknown; archok=""
  while IFS= read -r l; do
    case "$l" in "arch|"*) ;; *) continue;; esac
    IFS='|' read -r _ aid s1 _ un <<<"$l"
    [ "$s1" != supported ] || archok="$archok${archok:+ }$aid"
    case " $un " in *" $m "*) ARCH="$aid"; ast="$s1";; esac
  done <<<"$PLATFORMS"
  if [ "$ARCH" = arm32 ]; then cp_reason cp_r_arm32; CP_HARD=1                       # no binary exists: --skip-os-check cannot help
  elif [ "$ast" != supported ]; then cp_reason cp_r_arch "$m" "$archok"
  elif [ "$ARCH" = arm64 ]; then                                                  # a 64-bit kernel can run a 32-bit userland (32-bit Raspberry Pi OS on a Pi 4 / 5)
    ub="${TEST_USERLAND_BITS:-$(getconf LONG_BIT 2>/dev/null || true)}"
    if [ -z "$ub" ] && have dpkg; then case "$(dpkg --print-architecture 2>/dev/null || true)" in armhf|armel) ub=32;; esac; fi
    if [ "$ub" = 32 ]; then cp_reason cp_r_arm_userland32; CP_HARD=1; fi
    pim=""; if [ -r "${TEST_DT_MODEL:-/proc/device-tree/model}" ]; then pim="$(tr -d '\0' <"${TEST_DT_MODEL:-/proc/device-tree/model}" 2>/dev/null || true)"; fi
    [ "$CP_STATUS" != tested ] || CP_STATUS=expected        # arm64 is only emulation-tested: never "tested"
    case "$pim" in "Raspberry Pi"*) cp_note cp_w_pi;; esac
  fi
  # ---- glibc
  gl="${TEST_GLIBC:-}"
  if [ -z "$gl" ]; then
    gl="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"; case "$gl" in glibc\ *) gl="${gl#glibc }";; *) gl="";; esac
    if [ -z "$gl" ]; then
      gl="$(ldd --version 2>&1 | head -n1 || true)"
      case "$gl" in *[Mm][Uu][Ss][Ll]*) gl=musl;; *) gl="$(printf '%s' "$gl" | grep -Eo '[0-9]+\.[0-9]+$' || true)";; esac
    fi
  fi
  if [ "$gl" = musl ]; then CP_GLIBC=musl; cp_reason cp_r_musl "$(pf_req glibc)"
  elif [ -n "$gl" ]; then
    CP_GLIBC="$gl"
    if vlt "$gl" "$(pf_req glibc)"; then cp_reason cp_r_glibc "$gl" "$(pf_req glibc)"; fi
  else cp_note cp_w_glibc; fi
  # ---- systemd (running as init, version)
  sv="${TEST_SYSTEMD:-}"
  if [ "$STAGING" = 1 ] && [ -z "$sv" ]; then sv="?"            # staging (--destdir) does not use the running systemd
  elif [ -z "$sv" ]; then
    if [ -d /run/systemd/system ] && have systemctl; then sv="$(systemctl --version 2>/dev/null | head -n1 || true)"; sv="${sv#systemd }"; sv="${sv%%[!0-9]*}"; [ -n "$sv" ] || sv="?"
    else sv=none; fi
  fi
  if [ "$sv" = none ]; then CP_SYSTEMD=none; cp_reason cp_r_systemd
  else
    CP_SYSTEMD="$sv"
    if [ "$sv" != "?" ] && vlt "$sv" "$(pf_req systemd)"; then cp_reason cp_r_systemd_old "$sv" "$(pf_req systemd)"; fi
  fi
  # ---- kernel
  kv="${TEST_KERNEL:-$(uname -r)}"; kv="$(printf '%s' "$kv" | grep -Eo '^[0-9]+(\.[0-9]+)*' || true)"
  if [ -n "$kv" ]; then
    CP_KERNEL="$kv"
    if vlt "$kv" "$(pf_req kernel)"; then cp_reason cp_r_kernel "$kv" "$(pf_req kernel)"; fi
  fi
  [ "${#CP_REASONS[@]}" -eq 0 ] || CP_STATUS=unsupported
  return 0
}

# compact table of the compatible systems (generated from the platform data)
compat_table() {
  local IFS=' ' l id fam name min key flags tested exp any v s lab seen
  printf '  %s\n' "$(t cp_list "$(pf_req glibc)" "$(pf_req systemd)")"
  while IFS= read -r l; do
    case "$l" in "distro|"*) ;; *) continue;; esac
    IFS='|' read -r _ id fam name min key flags <<<"$l"
    tested=""; exp=""; any=""; seen=0
    while IFS= read -r l; do
      case "$l" in "ver|$id|"*) ;; *) continue;; esac
      IFS='|' read -r _ _ v s _ <<<"$l"
      [ "$s" != unsupported ] || continue
      seen=1
      if [ "$v" = "*" ]; then
        case ",$flags," in *,rolling,*) lab="$(t cp_rolling)";; *) lab="$(t cp_any)";; esac
        any="$lab ($(t "cp_$s"))"
      elif [ "$s" = tested ]; then tested="$tested $v"
      else exp="$exp $v"; fi
    done <<<"$PLATFORMS"
    [ "$seen" = 1 ] || continue
    s="$any"
    [ -z "$tested" ] || s="$s${s:+; }$(t cp_tested):${tested}"
    [ -z "$exp" ] || s="$s${s:+; }$(t cp_expected):${exp}"
    printf '    %-34s %s\n' "$name" "$s"
  done <<<"$PLATFORMS"
}

# compat_print: verdict + table on stdout (or stderr with a refusal when called as compat_print err)
compat_print() {
  local r w
  printf '\n  %s\n' "$(t cp_title)"
  printf '  %s\n' "$(t cp_detected "$CP_LABEL" "$CP_ARCHRAW" "$CP_GLIBC" "$CP_SYSTEMD" "$CP_KERNEL")"
  if [ "$CP_STATUS" = unsupported ]; then
    printf '  %s\n' "$(t cp_refused)"
    for r in "${CP_REASONS[@]}"; do printf '    - %s\n' "$r"; done
  else
    printf '  %s\n' "$(t cp_ok "$CP_LABEL" "$(t "cp_$CP_STATUS")")"
    for w in ${CP_NOTES[@]+"${CP_NOTES[@]}"}; do printf '  [warn] %s\n' "$w"; done
  fi
  echo
  compat_table
  echo
}

# compat_gate: called once the action is known (never for --uninstall / --status / --links): refuse before any change
compat_gate() {
  local r
  if [ "$ACTION" = update ] && [ "$(conf_get SKIP_OS_CHECK)" = 1 ]; then SKIP_OS_CHECK=1; fi   # an installation made with --skip-os-check stays updatable
  if [ "$CP_STATUS" = unsupported ]; then
    if [ "$SKIP_OS_CHECK" = 1 ] && [ "$CP_HARD" = 0 ]; then
      warn "$(t cp_w_skip)"; for r in "${CP_REASONS[@]}"; do warn "  - $r"; done
      COMPAT_LINE="$(t cp_w_skip) ${CP_REASONS[*]}"
    elif [ "$STAGING" = 1 ]; then
      warn "$(t cp_w_stage)"; for r in "${CP_REASONS[@]}"; do warn "  - $r"; done
      COMPAT_LINE="$(t cp_w_stage) ${CP_REASONS[*]}"
    else
      { compat_print; printf '  %s\n' "$(t cp_nochange)"; [ "$CP_HARD" = 1 ] || printf '  %s\n' "$(t cp_override)"; echo; } >&2
      exit 3
    fi
  else
    COMPAT_LINE="$(t cp_ok "$CP_LABEL" "$(t "cp_$CP_STATUS")")"
    COMPAT_OK=1
  fi
  case "$ARCH" in amd64|arm64) ;; *) die "unsupported architecture: $CP_ARCHRAW";; esac
  return 0
}

# ------------------------------------------------------------------------------------------------ environment check (the installation matrix)
# "One does not install what will not work" (docs/install/modes-matrix.md). Before anything is changed, the installer looks at what the
# components it is about to install need from THIS machine: the ports (another web server on 80 and 443 is the usual cause of a failed
# installation), a web server that starts at boot and would win them back at the next restart, a firewall, the control plane a data plane
# has to reach, a router in front of the machine. Each problem is said with its cause and what to do; nothing is left to guess and
# nobody is asked to type a command. A refusal exits with status 4 and changes nothing. Read-only; --check-env prints the verdict and
# stops; --skip-env-check goes on regardless (and says so).
SKIP_ENV_CHECK=0
EC_LV=(); EC_CA=(); EC_AC=()
ec_raw=""

ec_prog_label() {   # raw program (or service) name -> the name shown
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    apache|apache2*|httpd*) printf 'Apache';;
    nginx*|openresty*) printf 'Nginx';;
    caddy*) printf 'Caddy';;
    litespeed*|lshttpd*|openlitespeed*|lsws*) printf 'LiteSpeed';;
    haproxy*) printf 'HAProxy';;
    toutwaf*|toutpanel*) printf 'ToutWAF';;
    "") t pf_prog_unknown;;
    *) t pf_prog_other;;
  esac
}

ec_load() {   # who listens where: ss, or netstat on a machine without it
  ec_raw=""
  if have ss; then ec_raw="$(ss -ltnp 2>/dev/null || ss -ltn 2>/dev/null || true)"
  elif have netstat; then ec_raw="$(netstat -ltnp 2>/dev/null || netstat -ltn 2>/dev/null || true)"; fi
}

ec_owner() {   # ec_owner PORT -> "x:NAME" when something listens on the TCP port (NAME empty when it cannot be read), nothing when it is free
  local port="$1" line name
  line="$(printf '%s\n' "$ec_raw" | awk -v p="$port" '($1 == "LISTEN" || $1 ~ /^tcp/) { for (i = 1; i <= NF; i++) if ($i ~ ("[:.]" p "$")) { print; exit } }' || true)"
  [ -n "$line" ] || return 0
  name="$(printf '%s' "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p; s/.* [0-9][0-9]*\/\([^ :]*\).*/\1/p' | head -n1 || true)"
  printf 'x:%s' "$name"
}

ec_add() {   # ec_add LEVEL CAUSE ACTION (the same cause is said once)
  local i=0 n=${#EC_CA[@]}
  while [ "$i" -lt "$n" ]; do [ "${EC_CA[$i]}" = "$2" ] && return 0; i=$((i + 1)); done
  EC_LV+=("$1"); EC_CA+=("$2"); EC_AC+=("$3")
}

ec_is_private() {   # RFC 1918 and carrier-grade NAT addresses
  case "$1" in
    10.*|192.168.*) return 0;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0;;
  esac
  return 1
}

env_check() {   # fills EC_LV / EC_CA / EC_AC from what this machine is; changes nothing
  EC_LV=(); EC_CA=(); EC_AC=()
  local reinstall=0 refuse=refuse port purpose own prog act u fw="" p fwp="" nostart=""
  if [ "$STAGING" = 1 ] || [ "$DRY_RUN" = 1 ] || [ "$NO_START" = 1 ]; then refuse=warn; nostart=" $(t pf_nostart)"; fi   # nothing is started: the ports are only reported
  [ "$CHECK_ENV_STARTS" = 1 ] && { refuse=refuse; nostart=""; }
  detect_installed
  { [ "$INST_DP" = 1 ] || [ "$INST_CP" = 1 ]; } && reinstall=1
  ec_load

  # 1. the ports the components listen on
  local needs=""
  if want_dp; then needs+="$HTTP_PORT|web"$'\n'"$HTTPS_PORT|web"$'\n'"9101|admin"$'\n'; fi
  if want_cp; then needs+="$CP_PORT|console"$'\n'"9444|agent"$'\n'; fi
  local line
  while IFS='|' read -r port purpose; do
    [ -n "$port" ] || continue
    own="$(ec_owner "$port")"
    [ -n "$own" ] || continue
    prog="${own#x:}"
    if [ "$reinstall" = 1 ] && [ "$(ec_prog_label "$prog")" = ToutWAF ]; then continue; fi   # an update or a repair: ToutWAF's own programs are expected
    case "$purpose" in
      web) act="$(t pf_act_web "$HTTP_PORT" "$HTTPS_PORT")";;
      console) act="$(t pf_act_console)";;
      agent) act="$(t pf_act_agent)";;
      *) act="$(t pf_act_admin)";;
    esac
    ec_add "$refuse" "$(t pf_port_busy "$port" "$(ec_prog_label "$prog")")$nostart" "$act"
  done <<<"$needs"

  # 2. a web server that is stopped now but starts at boot takes 80 and 443 back at the next restart
  if want_dp && { [ "$HTTP_PORT" = 80 ] || [ "$HTTPS_PORT" = 443 ]; } && have systemctl; then
    for u in apache2 httpd nginx caddy lighttpd openlitespeed lsws haproxy; do
      systemctl is-enabled --quiet "$u" 2>/dev/null || continue
      systemctl is-active --quiet "$u" 2>/dev/null && continue   # running: the ports it holds were looked at above
      ec_add warn "$(t pf_boot "$(ec_prog_label "$u")" "$HTTP_PORT" "$HTTPS_PORT")" "$(t pf_act_boot)"
    done
  fi

  # 3. the firewall, when the installer was told not to open it (otherwise it opens what is needed), and the ones it never changes
  if want_dp; then
    if firewalld_running; then
      fw=firewalld
      for p in "$HTTP_PORT" "$HTTPS_PORT"; do
        firewall-cmd --query-port="$p/tcp" >/dev/null 2>&1 && continue
        { [ "$p" = 80 ] && firewall-cmd --query-service=http >/dev/null 2>&1; } && continue
        { [ "$p" = 443 ] && firewall-cmd --query-service=https >/dev/null 2>&1; } && continue
        fwp="$fwp $p"
      done
      if [ "$OPEN_FW" = 0 ] && [ -n "$fwp" ]; then ec_add warn "$(t pf_fw_cause "$fw" "$HTTP_PORT" "$HTTPS_PORT")" "$(t pf_fw_action)"; fi
    elif have ufw && ufw status 2>/dev/null | head -n1 | grep -qi 'status: active'; then
      fw=ufw
      for p in "$HTTP_PORT" "$HTTPS_PORT"; do
        ufw status 2>/dev/null | grep -Eq "^$p(/tcp)?[[:space:]]+ALLOW" || fwp="$fwp $p"
      done
      if [ "$OPEN_FW" = 0 ] && [ -n "$fwp" ]; then ec_add warn "$(t pf_fw_cause "$fw" "$HTTP_PORT" "$HTTPS_PORT")" "$(t pf_fw_action)"; fi
    elif have iptables && iptables -S INPUT 2>/dev/null | head -n1 | grep -Eq '^-P INPUT (DROP|REJECT)'; then
      for p in "$HTTP_PORT" "$HTTPS_PORT"; do
        iptables -S INPUT 2>/dev/null | grep -Eq -- "--dports? ([0-9:,]*,)?$p([, ]|$).*-j ACCEPT" || fwp="$fwp $p"
      done
      if [ -n "$fwp" ]; then ec_add warn "$(t pf_fwx_cause iptables "$HTTP_PORT" "$HTTPS_PORT")" "$(t pf_fwx_action)"; fi
    elif have nft && nft list ruleset 2>/dev/null | grep -q 'policy drop'; then
      for p in "$HTTP_PORT" "$HTTPS_PORT"; do
        nft list ruleset 2>/dev/null | grep -Eq "dport (\{[^}]*\b$p\b[^}]*\}|$p)\b.*accept" || fwp="$fwp $p"
      done
      if [ -n "$fwp" ]; then ec_add warn "$(t pf_fwx_cause nftables "$HTTP_PORT" "$HTTPS_PORT")" "$(t pf_fwx_action)"; fi
    fi
  fi

  # 4. a data plane that has to enrol with a control plane it cannot reach
  if want_dp && [ -n "$CLOUD_URL" ] && [ "$COMPONENT" = dp ]; then
    local ok=1
    # the cloud is reached with the proxy of the environment (HTTPS_PROXY), certificate verified: a node that cannot get out cannot enrol
    # a platform with a private certificate authority (--cloud-ca) is checked with that authority, like the link will do
    if have curl; then curl -s -o /dev/null --max-time 15 ${CLOUD_CA:+--cacert "$CLOUD_CA"} "$CLOUD_URL/cloud/v1/node/info" >/dev/null 2>&1 || ok=0
    elif have wget; then wget -q -O /dev/null --timeout=15 ${CLOUD_CA:+--ca-certificate="$CLOUD_CA"} "$CLOUD_URL/cloud/v1/node/info" >/dev/null 2>&1 || ok=0; fi
    [ "$ok" = 1 ] || ec_add "$refuse" "$(t pf_cp_cause "$CLOUD_URL")$nostart" "$(t pf_cloud_action)"
  elif want_dp && [ -n "$CP_URL" ] && [ "$COMPONENT" = dp ]; then
    local ok=1
    if have curl; then curl -sk -o /dev/null --max-time 8 "$CP_URL" >/dev/null 2>&1 || ok=0
    else
      local hp="${CP_URL#*://}"; hp="${hp%%/*}"
      { if have timeout; then timeout 8 bash -c "exec 4<>/dev/tcp/${hp%%:*}/${hp##*:}"; else bash -c "exec 4<>/dev/tcp/${hp%%:*}/${hp##*:}"; fi; } >/dev/null 2>&1 || ok=0
    fi
    [ "$ok" = 1 ] || ec_add "$refuse" "$(t pf_cp_cause "$CP_URL")$nostart" "$(t pf_cp_action)"
  fi

  # 5. a private address: probably behind a router (said once installed, by the console; here a note so that nothing is a surprise)
  if want_dp && [ "$STAGING" = 0 ]; then
    local lip; lip="$(local_ips | head -n1 || true)"
    if [ -n "$lip" ] && ec_is_private "$lip"; then ec_add info "$(t pf_router_cause "$lip")" "$(t pf_router_action)"; fi
  fi
  return 0
}

ec_refusals() { local i=0 n=${#EC_LV[@]} c=0; while [ "$i" -lt "$n" ]; do [ "${EC_LV[$i]}" = refuse ] && c=$((c + 1)); i=$((i + 1)); done; echo "$c"; }

ec_print() {   # ec_print FD-OF-THE-PROBLEMS: the title, then each finding with its cause and its action
  local fd="$1" i=0 n=${#EC_LV[@]} lab col
  { printf '\n  %s\n' "$(paint "$B" "$(t pf_title)")"
    while [ "$i" -lt "$n" ]; do
      case "${EC_LV[$i]}" in refuse) lab="$(t pf_l_refuse)"; col="$RED";; warn) lab="$(t pf_l_warn)"; col="$YLW";; *) lab="$(t pf_l_info)"; col="$D";; esac
      printf '  %s %s\n      %s\n' "$(paint "$col" "[$lab]")" "${EC_CA[$i]}" "${EC_AC[$i]}"
      i=$((i + 1))
    done
  } >&"$fd"
}

CHECK_ENV_STARTS=0
env_gate() {   # called before the installation; exits 4 on a refusal
  if [ "$SKIP_ENV_CHECK" = 1 ]; then warn "$(t pf_skipped)"; return 0; fi
  # test hook (like the TOUTWAF_TEST_* of the compatibility check): with --dry-run nothing can be changed, so a test may ask for the verdict a real run would get
  if [ "${TOUTWAF_TEST_ENV_STRICT:-}" = 1 ] && [ "$DRY_RUN" = 1 ]; then CHECK_ENV_STARTS=1; fi
  env_check
  [ "${#EC_LV[@]}" -gt 0 ] || return 0
  if [ "$(ec_refusals)" -gt 0 ]; then
    ec_print 2
    printf '\n  %s\n\n' "$(t pf_refused)" >&2
    exit 4
  fi
  [ "$QUIET" = 1 ] || ec_print 1
  return 0
}

env_run_check() {   # --check-env: the verdict, nothing is changed; exit 0 (nothing refuses) or 4
  CHECK_ENV_STARTS=1
  env_check
  if [ "${#EC_LV[@]}" -eq 0 ]; then printf '\n  %s\n  %s %s\n\n' "$(paint "$B" "$(t pf_title)")" "$(paint "$GRN" "$OKM")" "$(t pf_ok)"; return 0; fi
  if [ "$(ec_refusals)" -gt 0 ]; then ec_print 2; printf '\n  %s\n\n' "$(t pf_refused)" >&2; return 4; fi
  ec_print 1
  printf '\n  %s %s\n\n' "$(paint "$GRN" "$OKM")" "$(t pf_ok_warn)"
  return 0
}

# ------------------------------------------------------------------------------------------------ prerequisites of the machine, then the system update
# Said BEFORE anything is changed, each problem with its cause and its fix (the same words and thresholds as the link command the console gives for a web
# server). Only a disk that is really full refuses (exit 4; TOUTWAF_SKIP_PREREQ=1 goes on anyway): an unresolvable name or a wrong clock is a warning.
# Then the packages of the system are updated (Linux, a real installation only) unless TOUTWAF_SKIP_SYSUPDATE=1 (--skip-sysupdate). That never blocks (a
# failure is a warning), it is not repeated within 6 hours, and the machine is never restarted. Read-only checks: running them again changes nothing.
# BEGIN prereq (extracted by tests/prereq-test.sh: keep the markers)
SKIP_PREREQ="${TOUTWAF_SKIP_PREREQ:-0}"
SKIP_SYSUPDATE="${TOUTWAF_SKIP_SYSUPDATE:-${TOUTWAF_NO_SYSTEM_UPDATE:-0}}"
prereq_dir() {   # the nearest existing directory of a path: a path that does not exist yet lives on the file system of its parent
  local d="$1"
  while [ -n "$d" ] && [ "$d" != / ] && [ ! -d "$d" ]; do d="$(dirname "$d")"; done
  printf '%s' "${d:-/}"
}
prereq_host() {   # URL -> its host NAME (nothing for an IP address, a file:// URL or an empty URL)
  local h
  case "$1" in ""|file://*|*://\[*) return 0;; esac
  h="${1#*://}"; h="${h%%/*}"; h="${h##*@}"; h="${h%%:*}"
  case "$h" in ""|*[!A-Za-z0-9.-]*|*[!0-9.]*) ;; *) return 0;; esac   # only digits and dots: an IP address
  case "$h" in ""|*[!A-Za-z0-9.-]*) return 0;; esac
  printf '%s' "$h"
}
prereq_resolves() {   # NAME -> 0 when it resolves (or when this machine has no tool to ask)
  local to=()
  have timeout && to=(timeout 15)
  if have getent; then "${to[@]+"${to[@]}"}" getent ahosts "$1" >/dev/null 2>&1
  elif have host; then "${to[@]+"${to[@]}"}" host "$1" >/dev/null 2>&1
  elif have nslookup; then "${to[@]+"${to[@]}"}" nslookup "$1" >/dev/null 2>&1
  else return 0; fi
}
prereq_check() {   # fills EC_LV / EC_CA / EC_AC; changes nothing
  EC_LV=(); EC_CA=(); EC_AC=()
  local refuse=refuse e d min wrn free mnt seen=" " h hosts=() n ds t0 skew
  [ "$SKIP_PREREQ" = 0 ] || refuse=warn
  # 1. disk space where the programs, the data and the download go (MIN: below it the installation could not finish; WARN: comfortable)
  for e in "$BIN_DIR:300:1024" "$DATA_DIR:300:1024" "$TMP:100:300"; do
    d="$(prereq_dir "${e%%:*}")"; min="${e#*:}"; wrn="${min#*:}"; min="${min%%:*}"
    mnt="$(df -P "$d" 2>/dev/null | awk 'NR==2 {print $6}' || true)"; free="$(df -Pm "$d" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    case "$free" in ""|*[!0-9]*) continue;; esac
    case "$seen" in *" ${mnt:-$d} "*) continue;; esac
    seen+="${mnt:-$d} "
    if [ "$free" -lt "$min" ]; then ec_add "$refuse" "$(t pr_disk_full "$free" "${mnt:-$d}" "$min")" "$(t pr_disk_full_a)"
    elif [ "$free" -lt "$wrn" ]; then ec_add warn "$(t pr_disk_low "$free" "${mnt:-$d}" "$wrn")" "$(t pr_disk_low_a)"; fi
  done
  # 2. DNS and 3. the clock, for the places the installation downloads from (nothing to resolve when it installs from a local archive)
  if [ -z "$TARBALL" ]; then
    if [ -n "$BASE_URL" ]; then hosts+=("$(prereq_host "$BASE_URL")"); else hosts+=("$(prereq_host "$SRC_PRIMARY")" "$(prereq_host "$SRC_FALLBACK")"); fi
  fi
  hosts+=("$(prereq_host "$CP_URL")")
  seen=" "; ds=""
  for h in ${hosts[@]+"${hosts[@]}"}; do
    [ -n "$h" ] || continue
    case "$seen" in *" $h "*) continue;; esac
    seen+="$h "
    if prereq_resolves "$h"; then
      [ -n "$ds" ] || [ -n "$TARBALL" ] || ds="$h"
    else
      ec_add warn "$(t pr_dns "$h")" "$(t pr_dns_a)"
    fi
  done
  if [ -n "$ds" ] && have curl; then   # the date of a server of the download against ours
    n="$(curl -skI --connect-timeout 5 -m 10 "https://$ds/" 2>/dev/null | sed -n 's/^[Dd]ate: *//p' | head -n1 | tr -d '\r' || true)"
    if [ -n "$n" ] && t0="$(date -d "$n" +%s 2>/dev/null)"; then
      skew=$(( $(date +%s) - t0 )); [ "$skew" -ge 0 ] || skew=$(( -skew ))
      if [ "$skew" -gt 300 ]; then ec_add warn "$(t pr_clock "$skew")" "$(t pr_clock_a)"; fi
    fi
  fi
  return 0
}
prereq_gate() {   # before an installation or an update; exits 4 only for a full disk. Nothing is changed or downloaded in staging or dry-run
  { [ "$STAGING" = 0 ] && [ "$DRY_RUN" = 0 ]; } || return 0
  prereq_check
  [ "${#EC_LV[@]}" -gt 0 ] || return 0
  if [ "$(ec_refusals)" -gt 0 ]; then
    ec_print 2
    printf '\n  %s\n\n' "$(t pf_refused)" >&2
    exit 4
  fi
  [ "$QUIET" = 1 ] || ec_print 1
  return 0
}
# shellcheck disable=SC2034  # the outcome of the update: read by deploy/tests/prereq-test.sh, which sources this block
SYSUPD=skipped
sysupdate_do() {   # the update itself, run as a step (output goes to the log); never fails
  local pm="" rc=0 to=() fam="${FAMILY:-${FAMILY_GUESS:-}}" stamp="${TOUTWAF_STAMP:-/var/lib/toutwaf-system-update.stamp}"
  have timeout && to=(timeout "${TOUTWAF_UPDATE_TIMEOUT:-1800}")
  case "$(pf_fam "$fam" 3)" in
    dnf) if have dnf; then pm=dnf; elif have yum; then pm=yum; fi;;
    apt) have apt-get && pm=apt;;
    zypper) have zypper && pm=zypper;;
  esac
  if [ -z "$pm" ] && [ "$(pf_fam "$fam" 3)" != pacman ]; then   # the family is unknown: whatever is installed (Arch is a rolling release: never updated from here)
    if have dnf; then pm=dnf; elif have yum; then pm=yum; elif have apt-get; then pm=apt; elif have zypper; then pm=zypper; fi
  fi
  if [ -z "$pm" ]; then warn "$(t su_nopm)"; return 0; fi
  log "System update with $pm"
  case "$pm" in
    dnf) "${to[@]+"${to[@]}"}" dnf -y update || rc=$?;;
    yum) "${to[@]+"${to[@]}"}" yum -y update || rc=$?;;
    apt) export DEBIAN_FRONTEND=noninteractive
         { "${to[@]+"${to[@]}"}" apt-get -o DPkg::Lock::Timeout=120 update \
             && "${to[@]+"${to[@]}"}" apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y upgrade; } || rc=$?;;
    zypper) "${to[@]+"${to[@]}"}" zypper --non-interactive update || rc=$?;;
  esac
  if [ "$rc" = 0 ]; then
    SYSUPD=ok; { mkdir -p "$(dirname "$stamp")" && : >"$stamp"; } 2>/dev/null || true
  else
    SYSUPD=failed; warn "$(t su_failed "$rc" "$LOG")"
  fi
  if { have needs-restarting && ! needs-restarting -r >/dev/null 2>&1; } || [ -f /var/run/reboot-required ]; then warn "$(t su_reboot)"; fi
  return 0
}
sysupdate_run() {   # before the prerequisites are installed: a failed or skipped update never changes what follows
  # shellcheck disable=SC2034  # the outcome of the update: read by deploy/tests/prereq-test.sh, which sources this block
  SYSUPD=skipped
  { [ "$STAGING" = 0 ] && [ "$ACTION" = install ]; } || return 0
  if [ "$SKIP_SYSUPDATE" = 1 ]; then say "  $BUL $(t su_skipped)"; return 0; fi
  if [ "$DRY_RUN" = 1 ]; then say "  $BUL (dry-run) $(t su_dry)"; return 0; fi
  local stamp="${TOUTWAF_STAMP:-/var/lib/toutwaf-system-update.stamp}"
  if [ "${TOUTWAF_FORCE_SYSTEM_UPDATE:-}" != 1 ] && [ -n "$(find "$stamp" -mmin -360 2>/dev/null || true)" ]; then say "  $BUL $(t su_recent)"; return 0; fi
  step "$(t s_sysupdate)" sysupdate_do
  return 0
}
# END prereq
prereq_run_check() {   # --check-prereq: the verdict on the disk space, DNS and the clock, nothing is changed; exit 0 (nothing refuses) or 4
  prereq_check
  if [ "${#EC_LV[@]}" -eq 0 ]; then printf '\n  %s\n  %s %s\n\n' "$(paint "$B" "$(t pf_title)")" "$(paint "$GRN" "$OKM")" "$(t pr_ok)"; return 0; fi
  if [ "$(ec_refusals)" -gt 0 ]; then ec_print 2; printf '\n  %s\n\n' "$(t pf_refused)" >&2; return 4; fi
  ec_print 1
  printf '\n  %s %s\n\n' "$(paint "$GRN" "$OKM")" "$(t pf_ok_warn)"
  return 0
}

# ------------------------------------------------------------------------------------------------ interactive input
TTY_DEV=""
if [ -t 0 ] && [ -t 1 ]; then TTY_DEV=/dev/stdin
elif [ -t 1 ] && { : </dev/tty; } 2>/dev/null; then TTY_DEV=/dev/tty; fi
interactive() { [ -n "$TTY_DEV" ] && [ "$ASSUME_YES" = 0 ] && [ "$ACCEPT_DEFAULTS" = 0 ]; }

ask() {   # VAR label default [secret]
  local var="$1" label="$2" def="${3:-}" ans=""
  printf '  %s%s%s %s%s%s%s ' "$ACC" "$ARW" "$R" "$label" "$D" "${def:+ [$def]}" "$R" >&3
  if [ "${4:-}" = secret ]; then IFS= read -r -s ans <"$TTY_DEV" || true; echo >&3; else IFS= read -r ans <"$TTY_DEV" || true; fi
  printf -v "$var" '%s' "${ans:-$def}"
}
ask_yn() {  # VAR label default(1|0)
  local var="$1" label="$2" def="$3" ans hint="Y/n"; [ "$def" = 0 ] && hint="y/N"
  while :; do
    printf '  %s%s%s %s %s[%s]%s ' "$ACC" "$ARW" "$R" "$label" "$D" "$hint" "$R" >&3
    IFS= read -r ans <"$TTY_DEV" || true
    case "$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')" in
      "") printf -v "$var" '%s' "$def"; return;;
      y*|o*|j*|s*|d*|1|是*|ن*|д*) printf -v "$var" 1; return;;
      n*|0|否*|л*|н*) printf -v "$var" 0; return;;
    esac
  done
}

# ------------------------------------------------------------------------------------------------ usage
# ------------------------------------------------------------------------------------------------ --via-repo (ToutWAF's own package repository)
# BEGIN via-repo (extracted by tools/tests/build-repos-test.sh: keep the markers)
# --via-repo adds ToutWAF's package repository to dnf / apt (signed .repo / .list), DOWNLOADS the package `toutwaf` without installing it (apt-get
# download / dnf download: no maintainer script runs), unpacks it to read the staged signed release archive, verifies SHA256SUMS and the Ed25519
# release signature of this installer, and only then installs the package (it only stages the archive under /usr/share/toutwaf/release, nothing is
# started). The repository key is checked against REPO_KEY_FPR, a fingerprint FROZEN in this installer: while it is empty --via-repo is refused (never
# trust on first use) and the normal download (GitLab, then GitHub) takes over. ANY problem leaves the system as it was: this option never blocks an
# installation. See tools/repo/README.md.
VIA_REPO="${TOUTWAF_VIA_REPO:-0}"
REPO_LINUX="${TOUTWAF_REPO_LINUX_URL:-https://repo.qu3ntin.com/include/toutwaf/linux/-/raw}"   # + /main (stable) or /dev
REPO_KEY_FPR=""                               # 40-hex fingerprint of the repository key, frozen here at release time (no environment override); empty = --via-repo refused
VIA_REPO_EL="9 10"                            # Enterprise Linux majors the repository serves
VIA_PAYLOAD="${TOUTWAF_VIA_PAYLOAD:-/usr/share/toutwaf/release}"
via_repo_fail() { warn "--via-repo: $*; using the direct download instead (GitLab, then GitHub)"; return 1; }
via_repo_stage() {   # DIR (the unpacked package payload) -> BASE_URL = a file:// tree in the release layout; 1 when the payload is unusable or not signed by the release key
  local d="$1" asset="toutwaf-linux-$ARCH.tar.gz" pv want got tree="$TMP/viarepo" f vrc=0
  for f in "$asset" SHA256SUMS SHA256SUMS.sig channel.json; do [ -s "$d/$f" ] || { via_repo_fail "the package has no $f"; return 1; }; done
  CH_JSON="$(cat "$d/channel.json")"; pv="$(ch_str version | tr -d '[:space:]')"; CH_JSON=""
  [ -n "$pv" ] && [[ "$pv" =~ ^[0-9A-Za-z.+~-]+$ ]] || { via_repo_fail "the package carries no valid version"; return 1; }
  if [ "$VERSION" != latest ] && [ "$pv" != "${VERSION#v}" ]; then via_repo_fail "the repository holds $pv, not $VERSION"; return 1; fi
  want="$(grep " $asset\$" "$d/SHA256SUMS" | awk '{print $1}' | tr 'A-F' 'a-f' | head -n1)"; got="$(sha256sum "$d/$asset" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ] || { via_repo_fail "the packaged $asset does not match its SHA256SUMS"; return 1; }
  mkdir -p "$tree/releases/$pv" && cp "$d/channel.json" "$tree/" && cp "$d/$asset" "$d/SHA256SUMS" "$d/SHA256SUMS.sig" "$tree/releases/$pv/" || { via_repo_fail "cannot stage the package"; return 1; }
  # the Ed25519 signature is checked HERE, before the package is installed. verify_signature dies on a bad one: in a subshell whose die only logs
  # and exits, so that a bad package means "use the direct download" and not "the installation failed"
  cp "$d/SHA256SUMS" "$TMP/SHA256SUMS" || { via_repo_fail "cannot stage the package"; return 1; }
  ( die() { printf 'via-repo: %s\n' "$*" >>"$LOG"; exit 1; }; RESOLVED_VERSION="$pv"; verify_signature "file://$tree/releases/$pv" "" ) || vrc=$?
  [ "$vrc" = 0 ] || { via_repo_fail "the Ed25519 release signature of the package could not be verified (see $LOG)"; return 1; }
  BASE_URL="file://$tree"
  return 0
}
via_repo_unpack() {   # PKGFILE DESTDIR: unpack a .deb / .rpm WITHOUT running anything from it
  case "$1" in
    *.deb) have dpkg-deb && dpkg-deb -x "$1" "$2" >>"$LOG" 2>&1;;
    *.rpm) have rpm2cpio && have cpio && (cd "$2" && rpm2cpio "$1" | cpio -idm --quiet) >>"$LOG" 2>&1;;
    *) return 1;;
  esac
}
via_repo_try() {
  local pm="" base branch suite maj="" rarch probe keyurl key="$TMP/toutwaf-repo.key" fpr want="toutwaf" cfg="" keydst="" v pkgdir="$TMP/viapkg" pkg="" ex="$TMP/viaroot"
  local to=(); have timeout && to=(timeout 900)
  [ "$STAGING" = 0 ] || return 1
  if [ "$DRY_RUN" = 1 ]; then say "  $BUL (dry-run) --via-repo: would add the ToutWAF package repository ($REPO_LINUX), download the package 'toutwaf', verify its release signature, then install it and install from it; any failure falls back to the direct download"; return 1; fi
  [[ "$REPO_KEY_FPR" =~ ^[0-9A-Fa-f]{40}$ ]] || { via_repo_fail "this installer carries no pinned fingerprint of the repository key yet, so the repository is not trusted"; return 1; }
  have curl || { via_repo_fail "curl is missing"; return 1; }
  have gpg || { via_repo_fail "gpg is needed to check the repository key fingerprint"; return 1; }
  case "$ARCH" in amd64) rarch=x86_64;; arm64) rarch=aarch64;; *) via_repo_fail "architecture '$ARCH' has no package"; return 1;; esac
  suite=stable; branch=main; if [ "$CHANNEL" = dev ]; then suite=dev; branch=dev; fi
  base="${REPO_LINUX%/}/$branch"
  if have apt-get && [ "$(pf_fam "${FAMILY:-${FAMILY_GUESS:-}}" 3)" = apt ]; then pm=apt
  elif have dnf; then
    case "$OS_ID" in almalinux|rocky|rhel|centos|ol) maj="${OS_VER%%.*}";; esac
    case " $VIA_REPO_EL " in *" ${maj:-x} "*) pm=dnf;; esac
  fi
  [ -n "$pm" ] || { via_repo_fail "this system is not covered by the package repository (AlmaLinux / Rocky / RHEL $VIA_REPO_EL, Debian family)"; return 1; }
  if [ "$pm" = apt ]; then probe="$base/deb/dists/$suite/InRelease"; keyurl="$base/toutwaf.gpg"; keydst=/usr/share/keyrings/toutwaf.gpg; cfg=/etc/apt/sources.list.d/toutwaf.list
  else probe="$base/rpm/el$maj/$rarch/repodata/repomd.xml"; keyurl="$base/toutwaf.asc"; keydst=/etc/pki/rpm-gpg/RPM-GPG-KEY-toutwaf; cfg=/etc/yum.repos.d/toutwaf.repo; fi
  curl -fsSL --connect-timeout 8 --max-time 25 -o "$TMP/via-probe" "$probe" 2>>"$LOG" || { via_repo_fail "the ToutWAF repository is not reachable ($probe)"; return 1; }
  curl -fsSL --connect-timeout 8 --max-time 25 -o "$key" "$keyurl" 2>>"$LOG" || { via_repo_fail "cannot download the repository key ($keyurl)"; return 1; }
  fpr="$(gpg --batch --show-keys --with-colons "$key" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
  [ "$(printf '%s' "$fpr" | tr 'a-f' 'A-F')" = "$(printf '%s' "$REPO_KEY_FPR" | tr -d ' ' | tr 'a-f' 'A-F')" ] || { via_repo_fail "the repository key fingerprint (${fpr:-unreadable}) is not the expected one"; return 1; }
  # the repository definition is generated here from this installer's own constants, never downloaded
  run install -d -m 0755 "$(p "$(dirname "$keydst")")" "$(p "$(dirname "$cfg")")" || { via_repo_fail "cannot create $(dirname "$cfg")"; return 1; }
  run install -m 0644 "$key" "$(p "$keydst")" || { via_repo_fail "cannot write $keydst"; return 1; }
  if [ "$pm" = apt ]; then
    printf '# ToutWAF package repository (%s channel), written by install.sh --via-repo\ndeb [signed-by=%s] %s/deb %s main\n' "$suite" "$keydst" "$base" "$suite" >"$(p "$cfg")" \
      || { via_repo_fail "cannot write $cfg"; return 1; }
  else
    printf '# ToutWAF package repository (%s channel), written by install.sh --via-repo\n[toutwaf]\nname=ToutWAF (%s)\nbaseurl=%s/rpm/el%s/$basearch/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=file://%s\nskip_if_unavailable=1\nmetadata_expire=1h\n' \
      "$suite" "$suite" "$base" "$maj" "$keydst" >"$(p "$cfg")" || { via_repo_fail "cannot write $cfg"; return 1; }
  fi
  if [ "$VERSION" != latest ]; then v="$(printf '%s' "${VERSION#v}" | sed 's/-/~/')"; if [ "$pm" = apt ]; then want="toutwaf=$v-*"; else want="toutwaf-$v"; fi; fi
  info "downloading the package $want from the ToutWAF repository ($pm, $suite); it is installed only after its release signature is verified"
  mkdir -p "$pkgdir" "$ex" || { rm -f "$(p "$cfg")"; via_repo_fail "cannot create a work directory"; return 1; }
  if [ "$pm" = apt ]; then
    "${to[@]+"${to[@]}"}" apt-get -o DPkg::Lock::Timeout=300 update -qq >>"$LOG" 2>&1 </dev/null || true   # another repository may be unhappy: that is not ours to fix
    ( cd "$pkgdir" && DEBIAN_FRONTEND=noninteractive "${to[@]+"${to[@]}"}" apt-get -o DPkg::Lock::Timeout=300 download "$want" ) >>"$LOG" 2>&1 </dev/null \
      || { rm -f "$(p "$cfg")"; via_repo_fail "apt-get could not download $want from the ToutWAF repository"; return 1; }
  else
    "${to[@]+"${to[@]}"}" dnf download -y --refresh --destdir "$pkgdir" "$want" >>"$LOG" 2>&1 </dev/null || { rm -f "$(p "$cfg")"; via_repo_fail "dnf could not download $want from the ToutWAF repository"; return 1; }
  fi
  for v in "$pkgdir"/*.deb "$pkgdir"/*.rpm; do [ -f "$v" ] && { pkg="$v"; break; }; done
  [ -n "$pkg" ] || { rm -f "$(p "$cfg")"; via_repo_fail "no package was downloaded"; return 1; }
  via_repo_unpack "$pkg" "$ex" || { rm -f "$(p "$cfg")"; via_repo_fail "cannot unpack the package to check it (dpkg-deb, or rpm2cpio and cpio, are needed)"; return 1; }
  via_repo_stage "$ex$VIA_PAYLOAD" || { rm -f "$(p "$cfg")"; return 1; }
  # verified: only now does the package manager install it (its maintainer scripts run from here on)
  if [ "$pm" = apt ]; then
    DEBIAN_FRONTEND=noninteractive "${to[@]+"${to[@]}"}" apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "$pkg" >>"$LOG" 2>&1 </dev/null \
      || { rm -f "$(p "$cfg")"; via_repo_fail "apt-get could not install the verified package"; return 1; }
  else
    "${to[@]+"${to[@]}"}" dnf install -y "$pkg" >>"$LOG" 2>&1 </dev/null || { rm -f "$(p "$cfg")"; via_repo_fail "dnf could not install the verified package"; return 1; }
  fi
  say "  $BUL source: ToutWAF package repository ($pm, $suite channel)"
  return 0
}
# END via-repo

usage() {
  cat <<EOF
ToutWAF installer v$INSTALLER_VERSION

Without options on a terminal the interactive menu is shown. Unattended examples:
  install.sh --install --yes --public-host waf.example.com
  install.sh --install --component dp --cp-url https://cp.example.com:9444 --enroll-token XXXX --yes

Actions:
  --install | --update | --uninstall | --status | --links | --extras-only
                             install (default), update to the newest release, remove, health check, show panel links
Options:
  --component dp|cp|all      what to install (default: all)
  --version X.Y.Z|latest     release to install (default: latest of the channel)
  --channel stable|dev       release channel: stable = branch main, dev = branch dev (remembered in <home>/conf/installer.conf)
  --tarball FILE             install from a local release tarball (offline)
  --extras FILE              also install the extras of the release (host agent for Windows, antivirus programs) from a local file
                             toutwaf-extras*.tar.gz (offline; repeat for a release cut in parts). Without it the extras are downloaded with the
                             archive, checked like it (SHA-256 and signature) and installed; a failure is a warning, the installation goes on
  --no-extras                do not download nor install the extras (also TOUTWAF_NO_EXTRAS=1): the console then offers neither Windows nor the antivirus
  --extras-only              install (or refresh) only the extras of the release that is installed, stopping nothing
  --base-url URL             mirror of the release tree (expects <URL>/channel.json and <URL>/releases/<version>/..., see deploy/RELEASE-LAYOUT.md)
  --via-repo                 install from ToutWAF's own package repository (adds a signed dnf .repo / apt .list, installs the package \`toutwaf\`);
                             when it is unreachable or the system is not covered, falls back to the direct download (GitLab, then GitHub)
  --cp-url URL               enrol the data plane with this control plane (e.g. https://cp:9444)
  --enroll-token TOKEN       one-time enrolment token (console: Nodes > Add node)
  --node-token TOKEN         existing node token instead of enrolment
  --cloud-url URL            ToutWAF CLOUD: enrol this node with your hosted account (https://<account>.cloud.<domain>) with --enroll-token. Installs the
                             data plane and the cloud link; the node connects OUTBOUND over HTTPS (port 443, HTTPS_PROXY honoured), no port is opened
                             for the platform, and your visitors' traffic never goes through ToutWAF servers
  --cloud-pin PIN            (cloud) sha256//<base64> pin of the key of the platform certificate (repeatable); the console gives it when needed
  --cloud-ca FILE            (cloud) PEM CA of a platform that uses a private CA
  --cp-ca FILE               PEM CA / certificate of the control plane (self-signed control planes)
  --group NAME               node group (default: default)
  --cp-port N                console port (default 9443)        --http-port N / --https-port N   data-plane ports (80 / 443)
  --public-host HOST         public host name or IP shown in the panel links (default: auto-detected)
  --open-firewall            open the needed firewall ports (default when firewalld or ufw is active): 80/443 for the data plane and the
                             console port. The data-plane API port (9444) is never opened by the installer.
  --console-from CIDR        only allow this address / network to reach the console port (e.g. 203.0.113.0/24); default: anywhere
  --no-firewall              never touch the firewall (nftables / iptables hosts are never modified either: the commands are printed)
  --no-telemetry             install with ZERO telemetry: nothing is sent to the publisher space (also TOUTWAF_TELEMETRY=0). Without it,
                             the attacks ToutWAF blocks and aggregate figures are shared with app.toutwaf.com, never the content of
                             requests nor legitimate visitors; it can be switched off at any time in the console (Settings, Privacy and telemetry)
  --with-firewall            ALSO let ToutWAF manage this machine's firewall (the optional Firewall module, off by default; also
                             TOUTWAF_WITH_FIREWALL=1). It only switches the module on: no rule is applied by the installation, and every
                             later change runs as a trial with automatic rollback and an anti-lockout guard (SSH and the console stay reachable).
                             Not the same as the options above, which only decide whether the installer opens the ports ToutWAF needs.
  --no-firewall-module       do not enable the Firewall module (the default; skips the question of the interactive mode)
  --with-backup-client       ALSO install the ToutWAF Backup client (toutwaf-backup) next to the control plane, so that this machine can back itself up to a
                             ToutWAF Backup server (console: Backups > Backup servers). Downloaded from the release channel of that product; the Ed25519
                             signature of SHA256SUMS and the SHA-256 of the archive are verified BEFORE anything is installed (fail closed). Needs the public key
                             of that product: --backup-client-pubkey (base64 of the raw key, or a PEM file), TOUTWAF_BACKUP_PUBKEY or $CONF_DIR/backup-release.pub.
                             Also TOUTWAF_WITH_BACKUP_CLIENT=1. A failure is a warning: the installation goes on.
  --backup-client-pubkey K   the release public key of ToutWAF Backup     --backup-client-version V   a version instead of the latest of the channel
  --backup-client-base-url U where channel.json and releases/ of ToutWAF Backup are served (https://, or file:// for a mirror; default: the public repository)
  --db postgres|sqlite       the database of the control plane (default: asked in the interactive mode, SQLite otherwise = unchanged behaviour).
                             PostgreSQL is recommended for a server install and is required for several control planes; it is prepared
                             COMPLETELY by the installer, no SQL to type. SQLite: one file, small installation on one server.
  --db-install-local         install PostgreSQL on this machine if missing (package of the distribution), initialise it, listen on the loopback
                             only, create the database and a dedicated user with a random password, schedule a daily verified pg_dump
  --db-host H --db-port N --db-name NAME --db-user USER --db-password-file FILE
                             use an existing PostgreSQL server (the user must exist, or give --db-admin-dsn-file)
  --db-dsn-file FILE         the connection URL of the application user, in a file (copied to $CONF_DIR/db.dsn, mode 0600). --db-dsn URL does
                             the same but the password is then visible in the process list: avoid it. TOUTWAF_DB_DSN / TOUTWAF_DB_DSN_FILE too.
  --db-admin-dsn-file FILE   a privileged connection URL, used ONCE to create the user and the database, kept in memory only, never stored
                             (TOUTWAF_DB_ADMIN_DSN does the same). Without it the user and the database must already exist; if the account
                             lacks a right, the exact GRANT statements to ask the administrator for are printed.
  --db-tls-mode MODE --db-ca FILE   disable|prefer|require|verify-ca|verify-full and the CA file of the server (TLS to the database)
  --no-db-backup             do not schedule the daily pg_dump of a PostgreSQL database
  --no-selinux --no-sysctl --no-start --no-enable
  --check-compat             print whether this system is compatible (and the list of compatible distributions), change nothing;
                             exit 0 when compatible, 3 when not
  --skip-os-check            install although the system is unsupported / unrecognised (warns loudly; at your own risk)
  --check-env                print what this machine lacks for the installation (ports held by another program, a web server that starts at
                             boot, firewall, unreachable control plane) with the cause and what to do, and change nothing;
                             exit 0 when nothing refuses, 4 when the installation would be refused
  --check-prereq             check the disk space, DNS and the clock (cause and fix of each problem), change nothing; exit 0, or 4 when the disk is full
  --skip-env-check           install although that check refuses (at your own risk: what is in the way fails later)
  --skip-sysupdate           do not update the system packages first (same as TOUTWAF_SKIP_SYSUPDATE=1); the update is never blocking: a failure is a warning.
                             Disk space, DNS and the clock are checked first; only a full disk stops (TOUTWAF_SKIP_PREREQ=1 goes on anyway)
  --home DIR                 installation home (default /var/toutwaf, or TOUTWAF_HOME): bin/ conf/ data/ logs/ below it; CLIs are linked in
                             /usr/local/bin. An existing installation keeps its paths and is never moved unless you pass --home.
  --bin-dir DIR | --install-dir DIR   where the binaries go (default HOME/bin; /usr/local/bin for an installation made before HOME existed)
  --purge                    with --uninstall: also delete configuration, data and logs
  --force                    reinstall even when the same version is installed
  --fr --en --es --de --it --pt --nl --ru --zh --ar    language of the installer
  --lang CODE                same as --CODE (or set TOUTWAF_LANG); default: the system language, English when unsupported
  --no-color  --quiet  --accept-defaults   plain output / only the summary / never prompt
  --destdir DIR              stage into DIR without touching the running system
  --dry-run                  print what would be done
  -y, --yes                  non-interactive
EOF
}

# BEGIN db-options
db_valid_ident() { [[ "${1:-}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; }
db_valid_mode() { case "${1:-}" in ""|disable|allow|prefer|require|verify-ca|verify-full) return 0;; esac; return 1; }

# options -> variables (called once, after the command line is read)
db_check_options() {
  case "$DB_ENGINE" in
    ""|sqlite|postgres) ;;
    postgresql|pg) DB_ENGINE=postgres;;
    mysql|mariadb) die "the database engine \"$DB_ENGINE\" is not supported by this version: use postgres (recommended) or sqlite";;
    *) die "--db must be postgres or sqlite";;
  esac
  db_valid_ident "$DB_NAME" || die "--db-name: lower case letters, digits and underscores only"
  db_valid_ident "$DB_USER" || die "--db-user: lower case letters, digits and underscores only"
  db_valid_mode "$DB_TLS_MODE" || die "--db-tls-mode must be disable, allow, prefer, require, verify-ca or verify-full"
  if [ -n "$DB_PORT" ] && ! { [[ "$DB_PORT" =~ ^[0-9]+$ ]] && [ "$DB_PORT" -ge 1 ] && [ "$DB_PORT" -le 65535 ]; }; then die "--db-port: invalid port"; fi
  [ -z "$DB_PASSWORD_FILE" ] || [ -r "$DB_PASSWORD_FILE" ] || die "--db-password-file: cannot read $DB_PASSWORD_FILE"
  [ -z "$DB_CA" ] || [ -r "$DB_CA" ] || die "--db-ca: cannot read $DB_CA"
  [ -z "$DB_ADMIN_DSN_FILE" ] || [ -r "$DB_ADMIN_DSN_FILE" ] || die "--db-admin-dsn-file: cannot read $DB_ADMIN_DSN_FILE"
  if [ -z "$DB_ENGINE" ]; then
    # the options say what is wanted when --db is not given
    if [ "$DB_LOCAL" = 1 ] || [ -n "$DB_DSN$DB_DSN_FILE$DB_HOST" ]; then DB_ENGINE=postgres; fi
  fi
  if [ "$DB_ENGINE" = sqlite ] && { [ "$DB_LOCAL" = 1 ] || [ -n "$DB_DSN$DB_DSN_FILE$DB_HOST" ]; }; then die "--db sqlite cannot be combined with the options of a PostgreSQL server"; fi
  return 0
}
# END db-options

while [ $# -gt 0 ]; do
  case "$1" in
    --install) ACTION=install; shift;;
    --update) ACTION=update; shift;;
    --uninstall) ACTION=uninstall; shift;;
    --status) ACTION=status; shift;;
    --links|--show-links) ACTION=links; shift;;
    --component) COMPONENT="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    --channel) CHANNEL="$2"; shift 2;;
    --tarball) TARBALL="$2"; shift 2;;
    --extras) EXTRAS_LOCAL="${EXTRAS_LOCAL:+$EXTRAS_LOCAL:}$2"; shift 2;;
    --no-extras) NO_EXTRAS=1; shift;;
    --extras-only) ACTION=extras; shift;;
    --base-url) BASE_URL="$2"; shift 2;;
    --via-repo) VIA_REPO=1; shift;;
    --cp-url) CP_URL="$2"; shift 2;;
    --enroll-token) ENROLL_TOKEN="$2"; shift 2;;
    --node-token) NODE_TOKEN="$2"; shift 2;;
    --cloud-url) CLOUD_URL="$2"; shift 2;;
    --cloud-pin) CLOUD_PINS="$CLOUD_PINS $2"; shift 2;;
    --cloud-ca) CLOUD_CA="$2"; shift 2;;
    --cp-ca) CP_CA="$2"; shift 2;;
    --group) NODE_GROUP="$2"; shift 2;;
    --cp-port) CP_PORT="$2"; shift 2;;
    --http-port) HTTP_PORT="$2"; shift 2;;
    --https-port) HTTPS_PORT="$2"; shift 2;;
    --public-host) PUBLIC_HOST="$2"; shift 2;;
    --open-firewall) OPEN_FW=1; shift;;
    --open-cp-port) OPEN_CP_PORT=1; shift;;
    --console-from) CONSOLE_FROM="$2"; shift 2;;
    --no-firewall) OPEN_FW=0; shift;;
    --no-telemetry) NO_TELEMETRY=1; shift;;
    --with-firewall|--with-firewall-module) FW_MODULE=1; shift;;
    --no-firewall-module) FW_MODULE=0; shift;;
    --with-backup-client) BACKUP_CLIENT=1; shift;;
    --backup-client-pubkey) BACKUP_CLIENT_PUBKEY="$2"; shift 2;;
    --backup-client-version) BACKUP_CLIENT_VERSION="$2"; shift 2;;
    --backup-client-base-url) BACKUP_CLIENT_BASE="$2"; shift 2;;
    --db) DB_ENGINE="$2"; shift 2;;
    --db-dsn) DB_DSN="$2"; shift 2;;
    --db-dsn-file) DB_DSN_FILE="$2"; shift 2;;
    --db-install-local) DB_LOCAL=1; shift;;
    --db-host) DB_HOST="$2"; shift 2;;
    --db-port) DB_PORT="$2"; shift 2;;
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-password-file) DB_PASSWORD_FILE="$2"; shift 2;;
    --db-tls-mode) DB_TLS_MODE="$2"; shift 2;;
    --db-ca) DB_CA="$2"; shift 2;;
    --db-admin-dsn-file) DB_ADMIN_DSN_FILE="$2"; shift 2;;
    --no-db-backup) DB_BACKUP_TIMER=0; shift;;
    --no-selinux) NO_SELINUX=1; shift;;
    --no-sysctl) NO_SYSCTL=1; shift;;
    --no-start) NO_START=1; shift;;
    --no-enable) NO_ENABLE=1; shift;;
    --check-compat) CHECK_COMPAT=1; shift;;
    --skip-os-check) SKIP_OS_CHECK=1; shift;;
    --check-env) ACTION=checkenv; shift;;
    --check-prereq) ACTION=checkprereq; shift;;
    --skip-env-check) SKIP_ENV_CHECK=1; shift;;
    --skip-sysupdate) SKIP_SYSUPDATE=1; shift;;
    --home) HOME_DIR="$2"; HOME_EXPLICIT=1; shift 2;;
    --bin-dir|--install-dir) BIN_DIR="$2"; BIN_EXPLICIT=1; shift 2;;
    --force) FORCE=1; shift;;
    --destdir) DESTDIR="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --purge) PURGE=1; shift;;
    --lang) LANG_CODE="$2"; shift 2;;
    --en|--fr|--es|--de|--it|--pt|--nl|--ru|--zh|--ar) LANG_CODE="${1#--}"; shift;;
    --no-color) NO_COLOR_FLAG=1; shift;;
    --quiet|-q) QUIET=1; shift;;
    --accept-defaults) ACCEPT_DEFAULTS=1; shift;;
    -y|--yes) ASSUME_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) printf '[error] unknown option: %s (see --help)\n' "$1" >&2; exit 1;;
  esac
done
detect_lang; detect_ui
db_check_options
case "$COMPONENT" in dp|cp|all) ;; *) die "--component must be dp, cp or all";; esac
case "$CHANNEL" in beta) CHANNEL=dev;; esac
case "$CHANNEL" in ""|stable|dev) ;; *) die "--channel must be stable or dev";; esac
check_ports() { local pv; for pv in "$CP_PORT" "$HTTP_PORT" "$HTTPS_PORT"; do [[ "$pv" =~ ^[0-9]+$ ]] && [ "$pv" -ge 1 ] && [ "$pv" -le 65535 ] || die "invalid port: $pv"; done; }
check_ports
# firewall: opening what ToutWAF needs is the default when firewalld / ufw is active (the helper checks that); --no-firewall opts out
[ -n "$OPEN_FW" ] || OPEN_FW=1
[ "$OPEN_FW" = 1 ] && OPEN_CP_PORT=1
if [ -n "$CONSOLE_FROM" ]; then
  if ! [[ "$CONSOLE_FROM" =~ ^[0-9a-fA-F:.]{2,45}(/[0-9]{1,3})?$ ]] || [[ "$CONSOLE_FROM" == */0 ]]; then die "--console-from must be an address or a CIDR such as 203.0.113.0/24 (not 0.0.0.0/0)"; fi
fi
# ------------------------------------------------------------------------------------------------ environment
[ "$(uname -s)" = "Linux" ] || die "this installer is for Linux; on Windows use install.ps1"
# test hooks (fake os-release / architecture / glibc / systemd / kernel): honoured ONLY when nothing can be changed (--dry-run, --check-compat)
OS_RELEASE_FILE=/etc/os-release; TEST_ARCH=""; TEST_GLIBC=""; TEST_SYSTEMD=""; TEST_KERNEL=""; TEST_USERLAND_BITS=""; TEST_DT_MODEL=""
if [ -n "${TOUTWAF_TEST_OS_RELEASE:-}${TOUTWAF_TEST_ARCH:-}${TOUTWAF_TEST_GLIBC:-}${TOUTWAF_TEST_SYSTEMD:-}${TOUTWAF_TEST_KERNEL:-}${TOUTWAF_TEST_USERLAND_BITS:-}${TOUTWAF_TEST_DT_MODEL:-}" ]; then
  if [ "$DRY_RUN" = 1 ] || [ "$CHECK_COMPAT" = 1 ] || [ "$ACTION" = checkenv ]; then
    [ -z "${TOUTWAF_TEST_OS_RELEASE:-}" ] || OS_RELEASE_FILE="$TOUTWAF_TEST_OS_RELEASE"
    TEST_ARCH="${TOUTWAF_TEST_ARCH:-}"; TEST_GLIBC="${TOUTWAF_TEST_GLIBC:-}"; TEST_SYSTEMD="${TOUTWAF_TEST_SYSTEMD:-}"; TEST_KERNEL="${TOUTWAF_TEST_KERNEL:-}"
    TEST_USERLAND_BITS="${TOUTWAF_TEST_USERLAND_BITS:-}"; TEST_DT_MODEL="${TOUTWAF_TEST_DT_MODEL:-}"
    printf '[test] TOUTWAF_TEST_* hooks active: the compatibility check reads simulated values\n' >&2
  else
    printf '[warn] TOUTWAF_TEST_* variables are ignored: they only work with --dry-run or --check-compat\n' >&2
  fi
fi

OS_ID="unknown"; OS_VER=""; OS_LIKE=""; OS_NAME=""; OS_RELEASE_MISSING=0
if [ -r "$OS_RELEASE_FILE" ]; then
  # read it in a subshell: os-release defines VERSION, NAME, ID ... which would clobber our own variables
  # shellcheck disable=SC1090
  _osr="$( . "$OS_RELEASE_FILE" >/dev/null 2>&1; printf '%s\n%s\n%s\n%s\n' "${ID:-unknown}" "${VERSION_ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-${NAME:-}}" )" || _osr=""
  { IFS= read -r OS_ID || true; IFS= read -r OS_VER || true; IFS= read -r OS_LIKE || true; IFS= read -r OS_NAME || true; } <<<"$_osr"   # (a trailing empty field is stripped by $(...))
  OS_ID="${OS_ID,,}"; OS_LIKE="${OS_LIKE,,}"; [ -n "$OS_ID" ] || OS_ID=unknown
else OS_RELEASE_MISSING=1; fi
STAGING=0; [ -n "$DESTDIR" ] && STAGING=1
compat_eval
FAMILY="$CP_FAMILY"
if [ "$CHECK_COMPAT" = 1 ]; then
  compat_print
  if [ "$(id -u)" -ne 0 ]; then printf '  %s\n\n' "$(t cp_not_root)"; fi
  [ "$CP_STATUS" != unsupported ] || exit 3
  exit 0
fi
if [ "$STAGING" = 0 ] && [ "$DRY_RUN" = 0 ] && [ "$ACTION" != checkenv ] && [ "$ACTION" != checkprereq ] && [ "$(id -u)" -ne 0 ]; then die "$(t root_required)"; fi
TMP="$(mktemp -d)"; LOG="$TMP/install.log"
# persist_log: from now on the log goes to /var/log/toutwaf-install.log (called once the compatibility gate has passed, so that a refused
# run leaves nothing behind)
persist_log() {
  local f=/var/log/toutwaf-install.log
  if [ "$STAGING" = 0 ] && [ "$(id -u)" -eq 0 ] && [ "$LOG" != "$f" ]; then
    if { : >>"$f"; } 2>/dev/null; then chmod 0600 "$f"; cat "$LOG" >>"$f" 2>/dev/null || true; LOG="$f"; fi
  fi
  printf '\n#### %s toutwaf install.sh v%s %s\n' "$(date -u +%FT%TZ)" "$INSTALLER_VERSION" "${ACTION:-menu}" >>"$LOG"
  return 0
}

# package manager when the distribution family is unknown (--skip-os-check on an unlisted system)
if [ -z "$FAMILY" ]; then
  for _pm in "dnf:rhel" "yum:rhel" "apt-get:debian" "zypper:suse" "pacman:arch"; do
    if have "${_pm%%:*}"; then FAMILY_GUESS="${_pm##*:}"; break; fi
  done
  FAMILY_GUESS="${FAMILY_GUESS:-}"
fi
HAS_SYSTEMD=0; { [ -d /run/systemd/system ] && have systemctl; } && HAS_SYSTEMD=1
[ "$STAGING" = 1 ] && HAS_SYSTEMD=0

want_dp() { [ "$COMPONENT" = dp ] || [ "$COMPONENT" = all ]; }
want_cp() { [ "$COMPONENT" = cp ] || [ "$COMPONENT" = all ]; }
svc_active() { [ "$HAS_SYSTEMD" = 1 ] && systemctl is-active --quiet "$1"; }
cp_exe() { printf '%s' "${CP_BIN:-$(p "$BIN_DIR/toutwaf-cp")}"; }

# what is installed right now (binaries on disk)
INST_DP=0; INST_CP=0
detect_installed() {
  INST_DP=0; INST_CP=0
  [ -x "$(p "$BIN_DIR/toutwaf-dp")" ] && INST_DP=1
  [ -x "$(p "$BIN_DIR/toutwaf-cp")" ] && INST_CP=1
  return 0
}
component_from_installed() {
  if [ "$INST_DP" = 1 ] && [ "$INST_CP" = 1 ]; then COMPONENT="all"; elif [ "$INST_CP" = 1 ]; then COMPONENT="cp"; elif [ "$INST_DP" = 1 ]; then COMPONENT="dp"; fi
  return 0
}
installed_version() { { "$1" --version 2>/dev/null || "$1" version 2>/dev/null; } | awk '{print $2}' | head -n1 || true; }
# ---- build identity. The public development version keeps ONE name ("0.3.0-dev") from one publication to the next, so a build (the first 12
# hexadecimal characters of the published commit) is what tells two publications apart. Binaries print it: "toutwaf-dp 0.3.0-dev (build a1b2c3d4e5f6)".
# clean_build prints the normalised identifier, or nothing when there is none / it is not an identifier ("" means unknown inside this script;
# ver_label shows it as "unknown", never as an empty string).
clean_build() {
  local b; b="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$b" in ""|unknown|*[!0-9a-z._-]*) return 0;; esac
  [ "${#b}" -le 40 ] || return 0
  printf '%s' "$b"
}
installed_build() { clean_build "$({ "$1" --version 2>/dev/null || "$1" version 2>/dev/null; } | sed -n 's/.*(build \([^) ]*\)).*/\1/p' | head -n1 || true)"; }
ver_label() { local b; b="$(clean_build "${2:-}")"; printf '%s (build %s)' "${1:-?}" "${b:-unknown}"; }      # 0.3.0-dev (build a1b2c3d4e5f6)
ver_short() { local b; b="$(clean_build "${2:-}")"; printf '%s, build %s' "${1:-?}" "${b:-unknown}"; }       # 0.3.0-dev, build a1b2c3d4e5f6 (for "(%s)")
# the build of what is installed: the binary's own, else the one the installer recorded in installer.conf for that very version
inst_build() {   # BINARY VERSION
  local b; b="$(installed_build "$1")"
  if [ -z "$b" ] && [ -n "${2:-}" ] && [ "$(conf_get INSTALLED_VERSION)" = "$2" ]; then b="$(clean_build "$(conf_get INSTALLED_BUILD)")"; fi
  printf '%s' "$b"
}
installed_label() { local v; v="$(installed_version "$1")"; if [ -n "$v" ]; then ver_label "$v" "$(inst_build "$1" "$v")"; else printf '?'; fi; }
state_line() {
  local s=""; detect_installed
  [ "$INST_DP" = 1 ] && s+="toutwaf-dp $(installed_label "$(p "$BIN_DIR/toutwaf-dp")")  "
  [ "$INST_CP" = 1 ] && s+="toutwaf-cp $(installed_label "$(p "$BIN_DIR/toutwaf-cp")")  "
  printf '%s' "$s"
}
# ports of an existing installation win over the defaults (re-run / update / status / links)
load_existing_ports() {
  local f v
  f="$(p "$CONF_DIR/toutwaf-cp.yaml")"
  if [ -r "$f" ]; then v="$(sed -n 's/^[[:space:]]*console:[[:space:]]*"\{0,1\}[^":]*:\([0-9]\{1,5\}\)"\{0,1\}.*/\1/p' "$f" | head -n1)"; [ -n "$v" ] && CP_PORT="$v"; fi
  f="$(p "$CONF_DIR/toutwaf-dp.yaml")"
  if [ -r "$f" ]; then
    v="$(sed -n 's/^[[:space:]]*http:[[:space:]]*\[[[:space:]]*"[^"]*:\([0-9]\{1,5\}\)".*/\1/p' "$f" | head -n1)"; [ -n "$v" ] && HTTP_PORT="$v"
    v="$(sed -n 's/^[[:space:]]*https:[[:space:]]*\[[[:space:]]*"[^"]*:\([0-9]\{1,5\}\)".*/\1/p' "$f" | head -n1)"; [ -n "$v" ] && HTTPS_PORT="$v"
  fi
  return 0
}

# ------------------------------------------------------------------------------------------------ release channel
INSTALLER_CONF=""
# ---- layout ---------------------------------------------------------------------------------------------------------------------
valid_home() {
  local h="$1"
  [[ "$h" =~ ^/[A-Za-z0-9._/+-]+$ ]] || return 1
  case "$h" in //*|*//*|*/../*|*/..|*/./*|*/.|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*) return 1;; esac
  return 0
}
set_layout_vars() { INSTALLER_CONF="$(p "$CONF_DIR/installer.conf")"; }
apply_home() {
  HOME_DIR="${1%/}"; LAYOUT=home
  [ "$BIN_EXPLICIT" = 1 ] || BIN_DIR="$HOME_DIR/bin"
  CONF_DIR="$HOME_DIR/conf"; DATA_DIR="$HOME_DIR/data"; LOG_DIR="$HOME_DIR/logs"
  set_layout_vars
}
# /etc/toutwaf.layout remembers a HOME layout (so that --update / --uninstall find it again even after an uninstall that kept the data)
LAYOUT_FILE="$(p /etc/toutwaf.layout)"
write_layout_file() {
  [ "$LAYOUT" = home ] && [ "$STAGING" = 0 ] && [ "$DRY_RUN" = 0 ] || return 0
  printf '# written by install.sh: installation home of this host (bin/ conf/ data/ logs/)\nHOME=%s\n' "$HOME_DIR" >"$LAYOUT_FILE" && chmod 0644 "$LAYOUT_FILE"
  return 0
}
# EX_*: paths of an installation that already exists (read from its systemd units, else from the usual places)
EX_FOUND=0; EX_BIN=""; EX_CONF=""; EX_DATA=""; EX_LOG=""; EX_HOME=""
detect_existing_layout() {
  EX_FOUND=0; EX_BIN=""; EX_CONF=""; EX_DATA=""; EX_LOG=""
  local u f x
  if [ -r "$LAYOUT_FILE" ]; then
    x="$(sed -n 's/^HOME=//p' "$LAYOUT_FILE" | head -n1)"
    if valid_home "$x" && { [ -d "$(p "$x/conf")" ] || [ -d "$(p "$x/data")" ]; }; then
      EX_FOUND=1; EX_CONF="$x/conf"; EX_DATA="$x/data"; EX_LOG="$x/logs"; EX_BIN="$x/bin"; EX_HOME="$x"; return 0
    fi
  fi
  for u in toutwaf-cp toutwaf-dp; do
    f="$(p /etc/systemd/system/$u.service)"; [ -f "$f" ] || continue
    EX_DATA="$(sed -n 's/^ReadWritePaths=\([^ ]*\)[ ].*/\1/p' "$f" | head -n1)"
    EX_LOG="$(sed -n 's/^ReadWritePaths=[^ ]*[ ]\([^ ]*\).*/\1/p' "$f" | head -n1)"
    EX_CONF="$(sed -n 's/^ReadOnlyPaths=\([^ ]*\).*/\1/p' "$f" | head -n1)"
    x="$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$f" | head -n1)"; EX_BIN="${x%/*}"
    for x in "$EX_DATA" "$EX_LOG" "$EX_CONF" "$EX_BIN"; do valid_home "$x" || { EX_DATA=""; break; }; done
    [ -n "$EX_DATA" ] && { EX_FOUND=1; return 0; }
  done
  # no unit (staging, or units removed): look for configuration / binaries in the usual places
  if [ -f "$(p /etc/toutwaf/toutwaf-cp.yaml)" ] || [ -f "$(p /etc/toutwaf/toutwaf-dp.yaml)" ] || [ -f "$(p /var/lib/toutwaf/toutwaf.db)" ] \
     || [ -x "$(p /usr/local/bin/toutwaf-cp)" ] || [ -x "$(p /usr/local/bin/toutwaf-dp)" ]; then
    EX_FOUND=1; EX_CONF=/etc/toutwaf; EX_DATA=/var/lib/toutwaf; EX_LOG=/var/log/toutwaf; EX_BIN="${TOUTWAF_BIN_DIR:-/usr/local/bin}"; return 0
  fi
  if [ -f "$(p /var/toutwaf/conf/toutwaf-cp.yaml)" ] || [ -f "$(p /var/toutwaf/conf/toutwaf-dp.yaml)" ]; then
    EX_FOUND=1; EX_CONF=/var/toutwaf/conf; EX_DATA=/var/toutwaf/data; EX_LOG=/var/toutwaf/logs; EX_BIN=/var/toutwaf/bin
  fi
  return 0
}
resolve_layout() {
  if [ -n "$HOME_DIR" ] && ! valid_home "$HOME_DIR"; then die "$(t home_bad "$HOME_DIR")"; fi
  detect_existing_layout
  if [ "$HOME_EXPLICIT" = 1 ]; then
    apply_home "$HOME_DIR"
    if [ "$EX_FOUND" = 1 ] && [ "$EX_DATA" != "$DATA_DIR" ]; then LAYOUT_NOTE="$(t home_explicit_legacy "$HOME_DIR" "$EX_DATA")"; else LAYOUT_NOTE="$(t home_fresh "$HOME_DIR")"; fi
  elif [ "$EX_FOUND" = 1 ]; then
    LAYOUT=existing
    [ "$BIN_EXPLICIT" = 1 ] || BIN_DIR="$EX_BIN"
    CONF_DIR="$EX_CONF"; DATA_DIR="$EX_DATA"; LOG_DIR="$EX_LOG"; set_layout_vars
    if [ -n "$EX_HOME" ]; then LAYOUT=home; HOME_DIR="$EX_HOME"; elif [ "$EX_CONF" = /var/toutwaf/conf ]; then LAYOUT=home; HOME_DIR=/var/toutwaf; else LAYOUT_NOTE="$(t home_legacy "$BIN_DIR" "$CONF_DIR" "$DATA_DIR")"; fi
  else
    apply_home /var/toutwaf; LAYOUT_NOTE="$(t home_fresh "$HOME_DIR")"
  fi
  return 0
}
resolve_layout
conf_get() { [ -r "$INSTALLER_CONF" ] && sed -n "s/^$1=//p" "$INSTALLER_CONF" | head -n1 || true; }
# precedence: --channel / TOUTWAF_CHANNEL > a non-stable DEFAULT_CHANNEL baked into this copy > remembered installer.conf > stable
decide_channel() {
  [ -n "$CHANNEL" ] && return 0
  if [ "$DEFAULT_CHANNEL" != stable ]; then CHANNEL="$DEFAULT_CHANNEL"; return 0; fi
  CHANNEL="$(conf_get CHANNEL)"; case "$CHANNEL" in stable|dev) ;; *) CHANNEL=stable;; esac
}
channel_branch() { if [ "$CHANNEL" = dev ]; then echo dev; else echo main; fi; }
repo_base() { printf '%s' "${BASE_URL:-${SRC_ROOT:-$SRC_PRIMARY}/$(channel_branch)}"; }
write_installer_conf() {
  if [ "$STAGING" = 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  [ -d "$(dirname "$INSTALLER_CONF")" ] || return 0
  local _rv _rb; _rv="$(conf_get INSTALLED_VERSION)"; _rb="$(conf_get INSTALLED_BUILD)"
  # CHANNEL: used by --update and by the control plane's "update available" check; BASE_URL only when a mirror was given
  { printf '# written by install.sh: release channel used by --update and by the console "update available" check (stable = branch main, dev = branch dev)\nCHANNEL=%s\n' "$CHANNEL"
    case "$BASE_URL" in http://*|https://*) printf 'BASE_URL=%s\n' "$BASE_URL";; esac
    [ "$SKIP_OS_CHECK" = 0 ] || printf '# the installation was made with --skip-os-check (unsupported system): updates keep skipping the compatibility check\nSKIP_OS_CHECK=1\n'
    # what this installation runs (see record_installed): kept as it was until the new binaries are in service
    [ -z "$_rv" ] || printf '# version and build the installer put in service (read by the console when a binary cannot name its own build)\nINSTALLED_VERSION=%s\nINSTALLED_BUILD=%s\n' "$_rv" "${_rb:-unknown}"; } >"$INSTALLER_CONF" && chmod 0644 "$INSTALLER_CONF"
  return 0
}
# record_installed VERSION BUILD: remember what is now in service, next to CHANNEL in installer.conf. Installations made before builds existed have
# no such lines: their build reads as unknown, which counts as different from any published build.
record_installed() {
  [ "$DRY_RUN" = 0 ] || return 0
  [ -n "${1:-}" ] || return 0
  [ -d "$(dirname "$INSTALLER_CONF")" ] || return 0
  local b; b="$(clean_build "${2:-}")"
  { { [ ! -f "$INSTALLER_CONF" ] || grep -v -e '^INSTALLED_VERSION=' -e '^INSTALLED_BUILD=' -e '^# version and build the installer put in service' "$INSTALLER_CONF" || true; }
    printf '# version and build the installer put in service (read by the console when a binary cannot name its own build)\nINSTALLED_VERSION=%s\nINSTALLED_BUILD=%s\n' "$1" "${b:-unknown}"; } >"$INSTALLER_CONF.new" \
    && chmod 0644 "$INSTALLER_CONF.new" && mv -f "$INSTALLER_CONF.new" "$INSTALLER_CONF"
  return 0
}
# semver_lt A B: true when A < B (pre-release < release; "-dev.N" compared numerically)
semver_lt() {
  local a="${1#v}" b="${2#v}"; a="${a%%+*}"; b="${b%%+*}"
  local ac="${a%%-*}" bc="${b%%-*}" ap="" bp=""
  case "$a" in *-*) ap="${a#*-}";; esac; case "$b" in *-*) bp="${b#*-}";; esac
  if [ "$ac" != "$bc" ]; then [ "$(printf '%s\n%s\n' "$ac" "$bc" | sort -V | head -n1)" = "$ac" ]; return; fi
  [ "$ap" = "$bp" ] && return 1
  [ -z "$bp" ] && return 0
  [ -z "$ap" ] && return 1
  [ "$(printf '%s\n%s\n' "$ap" "$bp" | sort -V | head -n1)" = "$ap" ]
}
# update_state CUR_VERSION CUR_BUILD NEW_VERSION NEW_BUILD  ->  newer | rebuilt | older | same
# THE rule (the same in the data plane, the control plane and the console): an update exists when the published version is newer, OR the versions
# are equal and the published build differs from the installed one. An installed build that is unknown counts as different; a published build the
# channel does not state cannot differ from anything.
update_state() {
  local cb nb; cb="$(clean_build "${2:-}")"; nb="$(clean_build "${4:-}")"
  if semver_lt "$1" "$3"; then echo newer; return 0; fi
  if semver_lt "$3" "$1"; then echo older; return 0; fi
  if [ -n "$nb" ] && [ "$nb" != "$cb" ]; then echo rebuilt; return 0; fi
  echo same
}
# channel.json (flat scalars + one array of flat objects + the "yanked" array); no jq needed
CH_VERSION=""; CH_BUILD=""; CH_MIN=""; CH_JSON=""; CH_EMPTY=0; CH_QUERY=""
ch_flat() { printf '%s' "$CH_JSON" | tr -d '\n\r'; }
# the members of the TOP-LEVEL object only: nested arrays and objects (assets, yanked, a history of "releases" that carry their own "version" and "build") are dropped first
ch_top() { ch_flat | sed -e 's/^[[:space:]]*{//' -e 's/}[[:space:]]*$//' -e ':a' -e 's/\[[^][{}]*\]//g' -e 's/{[^{}]*}//g' -e 't a'; }
ch_str() { ch_top | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | sed 's/^[^:]*:[[:space:]]*"\(.*\)"$/\1/' || true; }   # the string value of a top-level key
fetch_channel() {   # returns 1 when unreachable / not JSON / without a version (CH_EMPTY=1 then: a valid channel.json saying that nothing is published)
  CH_EMPTY=0
  if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 -o "$TMP/channel.json" "$(repo_base)/channel.json$CH_QUERY" 2>>"$LOG"; then
    # the primary source is unreachable: the GitHub copy of the same signed channel (not when a mirror or another repository was chosen)
    [ -z "$BASE_URL" ] && [ -n "$SRC_FALLBACK" ] && [ "$SRC_ROOT" != "$SRC_FALLBACK" ] || return 1
    SRC_ROOT="$SRC_FALLBACK"
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 -o "$TMP/channel.json" "$(repo_base)/channel.json$CH_QUERY" 2>>"$LOG" || return 1
  fi
  CH_JSON="$(cat "$TMP/channel.json")"
  case "$CH_JSON" in *'{'*) ;; *) return 1;; esac
  CH_VERSION="$(ch_str version | tr -d '[:space:]')"
  CH_BUILD="$(clean_build "$(ch_str build)")"
  CH_MIN="$(ch_flat | sed -n 's/.*"min_installer"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9.]*\).*/\1/p' | head -n1)"
  # "version": "" (or no version at all) in a channel.json that names its channel: the channel exists and has nothing published yet (deploy/RELEASE-LAYOUT.md)
  if [ -z "$CH_VERSION" ] && ch_flat | grep -q '"channel"[[:space:]]*:'; then CH_EMPTY=1; fi
  [ -n "$CH_VERSION" ]
}
ch_yanked() { ch_flat | sed -n 's/.*"yanked"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | grep -qF "\"${1#v}\""; }
ch_asset_sha() {   # asset name -> sha256 from channel.json
  ch_flat | grep -o '{[^{}]*}' | grep -F "\"name\"" | grep -F "\"$1\"" | head -n1 | sed -n 's/.*"sha256"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F]*\)".*/\1/p' | tr 'A-F' 'a-f'
}

# ------------------------------------------------------------------------------------------------ addresses + panel data
local_ips() {
  { if have ip; then ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    elif have hostname && hostname -I >/dev/null 2>&1; then hostname -I | tr ' ' '\n'
    else awk '/32 host/ { print f } {f=$2}' /proc/net/fib_trie 2>/dev/null; fi; } | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | sort -u || true
}
PUBLIC_IP=""
detect_public_ip() {
  if [ -n "$PUBLIC_HOST" ]; then PUBLIC_IP="$PUBLIC_HOST"; return 0; fi
  [ "$STAGING" = 1 ] && return 0
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then PUBLIC_IP="$ip"; return 0; fi
  done
  return 0
}

# json_str KEY / json_raw KEY read flat scalars from $JSON
JSON=""
json_str() { printf '%s' "$JSON" | tr -d '\n' | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\(\(\\.\|[^"\\]\)*\)".*/\1/p' | head -n1 | sed 's/\\"/"/g; s/\\\\/\\/g'; }
json_raw() { printf '%s' "$JSON" | tr -d '\n' | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([^,}"[:space:]]*\).*/\1/p' | head -n1; }
BS_PATH=""; BS_USER=""; BS_PASS=""; BS_SETUP_TOKEN=""; BS_SETUP_PATH=""; BS_PORTS=""; BS_LINKS=""; BS_OK=0; BS_CREATED=0
parse_bootstrap() {   # $JSON -> BS_*   (contract: docs/panel-access.md; secrets stay in shell variables, never in the log)
  BS_PATH="$(json_str panel_path)"; BS_USER="$(json_str admin_user)"; BS_PASS="$(json_str admin_password)"
  BS_SETUP_TOKEN="$(json_str setup_token)"; BS_SETUP_PATH="$(json_str setup_path)"
  [ "$(json_raw created)" = true ] && BS_CREATED=1 || BS_CREATED=0
  local lp; lp="$(json_raw listen_port)"; if [[ "$lp" =~ ^[0-9]+$ ]]; then CP_PORT="$lp"; fi
  BS_PORTS="$(printf '%s' "$JSON" | tr -d '\n' | sed -n 's/.*"ports"[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\1/p' | grep -o '{[^{}]*}' | while IFS= read -r o; do
      pt="$(printf '%s' "$o" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\).*/\1/p')"
      pr="$(printf '%s' "$o" | sed -n 's/.*"proto"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
      pu="$(printf '%s' "$o" | sed -n 's/.*"purpose"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [ -n "$pt" ] && printf '%s|%s|%s\n' "$pt" "${pr:-tcp}" "$pu"; done || true)"
  # --print-links: links[] = {kind: local|public, host, url}
  BS_LINKS="$(printf '%s' "$JSON" | tr -d '\n' | sed -n 's/.*"links"[[:space:]]*:[[:space:]]*\[\(.*\)\][^]]*$/\1/p' | grep -o '{[^{}]*}' | while IFS= read -r o; do
      k="$(printf '%s' "$o" | sed -n 's/.*"kind"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p')"
      u="$(printf '%s' "$o" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [ -n "$k" ] && [ -n "$u" ] && printf '%s|%s\n' "$k" "$u"; done || true)"
  BS_PATH="${BS_PATH#/}"; BS_PATH="${BS_PATH%/}"
  if [ -n "$BS_PATH" ]; then BS_OK=1; else BS_OK=0; fi
  return 0
}
# toutwaf-cp offline command (always the real binary unless TOUTWAF_CP_BIN overrides it); never logs stdout (secrets)
cp_offline() {   # args... ; stdout = the command's output, stderr -> installer log
  local exe cfgargs=(); exe="$(cp_exe)"
  [ -f "$(p "$CONF_DIR/toutwaf-cp.yaml")" ] && cfgargs=(--config "$(p "$CONF_DIR/toutwaf-cp.yaml")")
  "$exe" "$1" "${@:2}" --data "$(p "$DATA_DIR")" "${cfgargs[@]}" 2>>"$LOG" </dev/null
}
# Contract (docs/panel-access.md):
#   toutwaf-cp bootstrap --data DIR [--public-host H] [--listen-port N] [--keep-token] --json
#   toutwaf-cp bootstrap --print-links --data DIR [--setup-token T] --json
# $1 = bootstrap | print-links ; sets JSON and BS_* ; returns 1 when the control plane has no usable `bootstrap` command.
cp_bootstrap() {
  local exe out rc=0; exe="$(cp_exe)"; JSON=""; BS_OK=0; BS_PASS=""; BS_SETUP_TOKEN=""; BS_SETUP_PATH=""; BS_CREATED=0
  [ -x "$exe" ] || return 1
  if [ "$1" = print-links ]; then out="$(cp_offline bootstrap --print-links --no-lookup --json)" || rc=$?
  else
    local args=(--listen-port "$CP_PORT" --json)
    [ -n "$PUBLIC_HOST" ] && args+=(--public-host "$PUBLIC_HOST")
    [ "$BS_KEEP_TOKEN" = 1 ] && args+=(--keep-token)
    out="$(cp_offline bootstrap "${args[@]}")" || rc=$?
  fi
  if [ $rc -eq 0 ]; then
    case "$out" in *'{'*) JSON="$out"; parse_bootstrap; [ "$STAGING" = 0 ] && chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR" 2>/dev/null; JSON=""; [ "$BS_OK" = 1 ] && return 0;; esac
  fi
  JSON=""
  return 1
}
BS_KEEP_TOKEN=0
# Is the data directory already bootstrapped (path + owner)? Read-only probe, so a re-run never mints a second account.
cp_is_bootstrapped() { local o; o="$(cp_offline bootstrap --print-links --no-lookup --json)" && case "$o" in *'"panel_path"'*) true;; *) false;; esac; }
# On a re-run / update the account and the path exist: keep a still-valid setup token, and never show a setup link for an
# account that was not created now (the link would reopen the web setup of a configured installation).
prepare_panel_run() {
  PANEL_RAN=1; BS_KEEP_TOKEN=0
  if cp_is_bootstrapped; then BS_KEEP_TOKEN=1; fi
  cp_bootstrap bootstrap || { BS_OK=0; return 0; }
  if [ "$BS_KEEP_TOKEN" = 1 ] && [ -n "$BS_SETUP_TOKEN" ] && [ -z "$BS_PASS" ]; then
    cp_offline setup-link --revoke --json >/dev/null 2>&1 || true
    BS_SETUP_TOKEN=""; BS_SETUP_PATH=""
  fi
  # the control plane's own list of console URLs (every up non-loopback IPv4 + the public host), secrets kept aside
  local sp="$BS_PASS" st="$BS_SETUP_TOKEN" spp="$BS_SETUP_PATH" su="$BS_USER" scr="$BS_CREATED" sports="$BS_PORTS"
  if cp_bootstrap print-links; then :; fi
  BS_PASS="$sp"; BS_SETUP_TOKEN="$st"; BS_SETUP_PATH="$spp"; BS_USER="$su"; BS_CREATED="$scr"; BS_PORTS="$sports"; BS_OK=1
  return 0
}
# --links / re-run without bootstrap: panel path + the real links; the user name comes from the account list
cp_links() {
  cp_bootstrap print-links || { BS_OK=0; return 0; }
  BS_USER="$(cp_offline admin list --json | tr -d '\n' | sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  return 0
}

# ------------------------------------------------------------------------------------------------ all-in-one: link the local data plane
# `all` = control plane + data plane on one machine, so nothing may be left to the administrator. The control plane (offline, on its own
# database) mints a one-time enrolment token and writes THE single `control_plane:` block of toutwaf-dp.yaml: idempotent (an already linked
# node is not touched, a duplicated block is merged, a stale token is replaced), validated by `toutwaf-dp check-config` before the file is
# swapped, previous file kept when the new one is refused. Runs on install AND on update, which repairs installations made before this
# existed (data plane left standalone: policy v1, sites answering HTTP 421). The token is never printed or logged.
DP_LINK=""; DP_CFG_CHANGED=0
link_local_dp() {
  { [ "$COMPONENT" = all ] && [ -z "$CP_URL" ] && [ "$DRY_RUN" = 0 ]; } || return 0
  local exe errf out rc=0 act chg blocks msg cfgargs=()
  exe="$(cp_exe)"
  if [ ! -x "$exe" ]; then DP_LINK=failed; warn "$(t dp_link_fail "$exe")"; warn "$(t dp_link_fail_hint)"; return 0; fi
  [ -f "$(p "$CONF_DIR/toutwaf-cp.yaml")" ] && cfgargs=(--config "$(p "$CONF_DIR/toutwaf-cp.yaml")")
  errf="$(mktemp 2>/dev/null || true)"; [ -n "$errf" ] || errf=/dev/null
  [ "$STAGING" = 0 ] || cfgargs+=(--ca-file "$DATA_DIR/tls/console.crt")     # staged: the configuration keeps the logical (unprefixed) paths
  out="$("$exe" enroll-local --dp-config "$(p "$CONF_DIR/toutwaf-dp.yaml")" --dp-bin "$(p "$BIN_DIR/toutwaf-dp")" --update-hook "$BIN_DIR/toutwaf-upgrade" \
    --data "$(p "$DATA_DIR")" --dp-data-dir "$(p "$DATA_DIR")" ${cfgargs[@]+"${cfgargs[@]}"} --json 2>"$errf" </dev/null)" || rc=$?
  if [ "$STAGING" = 0 ]; then chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR" 2>/dev/null || true; fi   # the offline run may have created database files as root
  if [ "$STAGING" = 0 ] && have restorecon; then restorecon -RF "$CONF_DIR" >/dev/null 2>&1 || true; fi   # the new file gets the context of the directory (SELinux)
  if [ "$errf" != /dev/null ]; then cat "$errf" >>"$LOG" 2>/dev/null; fi
  if [ "$rc" -ne 0 ]; then
    msg="$(tr '\n\t' '  ' <"$errf" 2>/dev/null | cut -c1-500)"; [ "$errf" = /dev/null ] || rm -f "$errf"
    DP_LINK=failed; warn "$(t dp_link_fail "${msg:-toutwaf-cp enroll-local rc=$rc}")"; warn "$(t dp_link_fail_hint)"
    return 0
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  JSON="$out"; act="$(json_str action)"; chg="$(json_raw changed)"; blocks="$(json_raw blocks_before)"; JSON=""
  case "$act" in added|refreshed) DP_LINK=linked;; repaired) DP_LINK=repaired;; remote) DP_LINK=remote;; *) DP_LINK=same;; esac
  if [[ "${blocks:-0}" =~ ^[0-9]+$ ]] && [ "${blocks:-0}" -gt 1 ] && [ "$chg" = true ]; then DP_LINK=repaired; fi   # duplicated blocks merged (whatever else changed)
  [ "$chg" = true ] && DP_CFG_CHANGED=1      # a new control_plane block needs a restart of the data plane, not a reload
  info "data plane link: $act (changed=$chg)"
  return 0
}

# ------------------------------------------------------------------------------------------------ optional firewall module
# "Also let ToutWAF manage this machine's firewall": switches the Firewall module on (setting modules.firewall.enabled) and nothing else. No rule
# is loaded: the first change the administrator makes in the console goes through the trial (countdown, automatic rollback, anti-lockout guard).
# Never blocking: a failure is a warning and the module can be switched on later in Settings > Modules.
FW_MODULE_RESULT=""
enable_firewall_module() {
  [ "$FW_MODULE" = 1 ] || return 0
  want_cp || return 0
  [ "$DRY_RUN" = 0 ] || return 0      # (the step line already says what would be done)
  local exe errf out msg rc=0 cfgargs=()
  exe="$(cp_exe)"
  if [ ! -x "$exe" ]; then FW_MODULE_RESULT=failed; warn "$(t fwmod_fail "$exe")"; return 0; fi
  [ -f "$(p "$CONF_DIR/toutwaf-cp.yaml")" ] && cfgargs=(--config "$(p "$CONF_DIR/toutwaf-cp.yaml")")
  errf="$(mktemp 2>/dev/null || true)"; [ -n "$errf" ] || errf=/dev/null
  out="$("$exe" module enable firewall --data "$(p "$DATA_DIR")" ${cfgargs[@]+"${cfgargs[@]}"} --json 2>"$errf" </dev/null)" || rc=$?
  if [ "$STAGING" = 0 ]; then chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR" 2>/dev/null || true; fi   # the offline run may have created database files as root
  if [ "$errf" != /dev/null ]; then cat "$errf" >>"$LOG" 2>/dev/null; fi
  if [ "$rc" -ne 0 ]; then
    msg="$(tr '\n\t' '  ' <"$errf" 2>/dev/null | cut -c1-300)"; [ "$errf" = /dev/null ] || rm -f "$errf"
    FW_MODULE_RESULT=failed; warn "$(t fwmod_fail "${msg:-toutwaf-cp module rc=$rc}")"
    return 0
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  FW_MODULE_RESULT=on; info "firewall module: enabled ($out)"
  return 0
}

# ------------------------------------------------------------------------------------------------ optional ToutWAF Backup client
# ed25519_check PEM MESSAGE SIGNATURE_B64_FILE: true when the signature (base64 of the raw 64 bytes) is valid for the message under that Ed25519 key.
# openssl when it can verify Ed25519 (>= 3.0), else the embedded pure-Python verifier of the release check; neither: false (fail closed).
ed25519_check() {
  local pem="$1" msg="$2" sigb64="$3" py ok=1
  tr -d '[:space:]' <"$sigb64" | base64 -d >"$TMP/bk-sig.bin" 2>/dev/null || return 1
  if openssl_ed25519_ok; then
    openssl pkeyutl -verify -pubin -inkey "$pem" -rawin -in "$msg" -sigfile "$TMP/bk-sig.bin" >>"$LOG" 2>&1 && ok=0
    return "$ok"
  fi
  py="$(python3_bin)"
  [ -n "$py" ] || return 1
  ed25519_py "$TMP/bk-ed25519.py"
  "$py" "$TMP/bk-ed25519.py" "$(pubkey_raw "$pem")" "$TMP/bk-sig.bin" "$msg" >>"$LOG" 2>&1 && ok=0
  return "$ok"
}
# backup_client_pem: prints the path of the PEM public key to check the ToutWAF Backup release with, nothing when there is none
backup_client_pem() {
  local k="$BACKUP_CLIENT_PUBKEY" raw pem="$TMP/backup-release-pub.pem"
  if [ -z "$k" ] && [ -r "$(p "$CONF_DIR/backup-release.pub")" ]; then k="$(p "$CONF_DIR/backup-release.pub")"; fi
  [ -n "$k" ] || return 0
  if [ -f "$k" ]; then raw="$(cat "$k")"; else raw="$k"; fi
  case "$raw" in
    *"BEGIN PUBLIC KEY"*) printf '%s\n' "$raw" >"$pem";;
    *) printf '%s' "$raw" | tr -d '[:space:]' | grep -Eq '^[A-Za-z0-9+/]{43}=$' || return 0
       { printf -- '-----BEGIN PUBLIC KEY-----\n'; { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s' "$raw" | tr -d '[:space:]' | base64 -d; } | base64 -w64; printf -- '-----END PUBLIC KEY-----\n'; } >"$pem";;
  esac
  [ "$(pubkey_raw "$pem" | base64 -d 2>/dev/null | wc -c)" = 32 ] || return 0
  printf '%s' "$pem"
}
# install_backup_client: never blocking (a warning, and the client can be installed later), never installs anything that did not verify.
install_backup_client() {
  [ "$BACKUP_CLIENT" = 1 ] || return 0
  want_cp || return 0
  [ "$DRY_RUN" = 0 ] || return 0
  local base="${BACKUP_CLIENT_BASE%/}" pem want rel asset got ver cur yanked tag x
  case "$base" in https://*|file://*|http://127.0.0.1*|http://localhost*) ;; *) BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "--backup-client-base-url must be https://")"; return 0;; esac
  case "$ARCH" in amd64|arm64) ;; *) BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "no ToutWAF Backup client for $ARCH")"; return 0;; esac
  pem="$(backup_client_pem)"
  if [ -z "$pem" ]; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_nokey)"; return 0; fi
  mkdir -p "$TMP/bkc" || return 0
  fetch "$base/channel.json" "$TMP/bkc/channel.json" || { BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "cannot download $base/channel.json")"; return 0; }
  ver="$BACKUP_CLIENT_VERSION"
  [ -n "$ver" ] || ver="$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]*)".*/\1/p' "$TMP/bkc/channel.json" | head -n1)"
  if ! printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "no valid version in the channel")"; return 0; fi
  yanked="$(sed -nE 's/^[[:space:]]*"yanked":[[:space:]]*\[(.*)\].*/\1/p' "$TMP/bkc/channel.json" | head -n1)"
  if printf '%s' "$yanked" | grep -q "\"$ver\"" && [ "$FORCE" = 0 ]; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "version $ver was withdrawn")"; return 0; fi
  rel="$base/releases/$ver"; asset="toutwaf-backup-linux-$ARCH.tar.gz"
  fetch "$rel/SHA256SUMS" "$TMP/bkc/SHA256SUMS" && fetch "$rel/SHA256SUMS.sig" "$TMP/bkc/SHA256SUMS.sig" || { BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "cannot download the signed list of $ver")"; return 0; }
  if ! ed25519_check "$pem" "$TMP/bkc/SHA256SUMS" "$TMP/bkc/SHA256SUMS.sig"; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_badsig)"; return 0; fi
  want="$(awk -v a="$asset" '$2==a || $2=="*"a {print $1; exit}' "$TMP/bkc/SHA256SUMS" | tr 'A-F' 'a-f')"
  if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{64}$'; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "$asset is not in the signed list")"; return 0; fi
  fetch "$rel/$asset" "$TMP/bkc/$asset" || { BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "cannot download $asset")"; return 0; }
  got="$(sha256sum "$TMP/bkc/$asset" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "SHA-256 of $asset does not match the signed list")"; return 0; fi
  mkdir -p "$TMP/bkc/x" && tar -xzf "$TMP/bkc/$asset" -C "$TMP/bkc/x" --no-same-owner 2>>"$LOG" || { BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "the archive cannot be read")"; return 0; }
  x="$TMP/bkc/x/toutwaf-backup-linux-$ARCH/toutwaf-backup"
  if [ ! -f "$x" ]; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "the archive holds no toutwaf-backup")"; return 0; fi
  chmod 0755 "$x"
  tag="$("$x" engine describe 2>/dev/null | sed -nE 's/.*"contract":[[:space:]]*"([^"]*)".*/\1/p' | head -n1)"
  if [ "$tag" != "toutwaf-backup-engine/1" ]; then BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "the client speaks '${tag:-nothing}', this ToutWAF drives toutwaf-backup-engine/1")"; return 0; fi
  mkdir -p "$(p "$BIN_DIR")"
  cur="$(p "$BIN_DIR/toutwaf-backup")"
  if [ -f "$cur" ]; then cp -p "$cur" "$cur.prev" 2>/dev/null || true; fi
  install -m 0755 "$x" "$cur.new.$$" && mv -f "$cur.new.$$" "$cur" || { BACKUP_CLIENT_RESULT=failed; warn "$(t bkc_fail "cannot write $cur")"; return 0; }
  BACKUP_CLIENT_RESULT=on; info "ToutWAF Backup client $ver installed in $cur (signature and SHA-256 verified)"
  return 0
}

# ------------------------------------------------------------------------------------------------ summary
SUMMARY_PORTS=""
build_ports() {   # lines: port|proto|purpose   (deduplicated by port/proto)
  SUMMARY_PORTS=""
  if want_cp; then
    if [ -n "$BS_PORTS" ]; then
      # the control plane names its ports; our localized purposes win for the well-known ones. 80/443 are the data plane's: added below
      # from its configured ports when one is installed here (otherwise they belong to the nodes).
      SUMMARY_PORTS="$(printf '%s\n' "$BS_PORTS" | awk -F'|' -v cp="$CP_PORT" -v pc="$(t p_console)" -v pd="$(t p_dpapi)" 'BEGIN{OFS="|"} ($1==80||$1==443){next} $1==cp{$3=pc} $1==9444{$3=pd} {print}')"$'\n'
    else SUMMARY_PORTS="$CP_PORT|tcp|$(t p_console)"$'\n'; fi
    printf '%s' "$SUMMARY_PORTS" | grep -q '^9444|' || SUMMARY_PORTS+="9444|tcp|$(t p_dpapi)"$'\n'
  fi
  if want_dp; then SUMMARY_PORTS+="$HTTP_PORT|tcp|$(t p_http)"$'\n'"$HTTPS_PORT|tcp|$(t p_https)"$'\n'; fi
  SUMMARY_PORTS="$(printf '%s' "$SUMMARY_PORTS" | awk -F'|' 'NF>2 && !seen[$1 "/" $2]++')"$'\n'
  return 0
}
panel_urls() {   # one "label|url" per line: the control plane's links[] when known, else our own address detection
  local h k u path="${BS_PATH:+$BS_PATH/}" seen=" "
  if [ -n "$BS_LINKS" ]; then
    while IFS='|' read -r k u; do
      [ -n "$u" ] || continue
      case "$k" in public) printf '%s|%s\n' "$(t sum_public)" "$u";; *) printf '%s|%s\n' "$(t sum_local)" "$u";; esac
      seen+="$u "
    done <<<"$BS_LINKS"
  else
    while IFS= read -r h; do if [ -n "$h" ]; then printf '%s|https://%s:%s/%s\n' "$(t sum_local)" "$h" "$CP_PORT" "$path"; fi; done < <(local_ips)
  fi
  if [ -n "$PUBLIC_IP" ]; then
    u="https://$PUBLIC_IP:$CP_PORT/$path"
    case "$seen" in *" $u "*) ;; *) printf '%s|%s\n' "$(t sum_public)" "$u";; esac
  fi
  return 0
}
setup_urls() {   # one "label|url" per line: the one-time setup link on every local IPv4 and on the public address
  [ -n "$BS_SETUP_TOKEN" ] || return 0      # no token = setup already completed, the link would be dead
  local h sp="$BS_SETUP_PATH"
  if [ -z "$sp" ]; then sp="/${BS_PATH:+$BS_PATH/}setup"; fi
  case "$sp" in /*) ;; *) sp="/$sp";; esac
  if [[ "$sp" != *"$BS_SETUP_TOKEN"* ]]; then case "$sp" in *\?*) sp="$sp&token=$BS_SETUP_TOKEN";; *) sp="$sp?token=$BS_SETUP_TOKEN";; esac; fi
  while IFS= read -r h; do [ -n "$h" ] && printf '%s|https://%s:%s%s\n' "$(t sum_local)" "$h" "$CP_PORT" "$sp"; done < <(local_ips)
  if [ -n "$PUBLIC_IP" ]; then printf '%s|https://%s:%s%s\n' "$(t sum_public)" "$PUBLIC_IP" "$CP_PORT" "$sp"
  elif [ -z "$(local_ips)" ]; then printf '%s|https://%s:%s%s\n' "$(t sum_local)" "$(fqdn)" "$CP_PORT" "$sp"; fi
  return 0
}
setup_url() { setup_urls | head -n1 | cut -d'|' -f2; }

# render_summary tty|plain
render_summary() {
  local mode="$1" lab url pt pr pu hb="" he=""
  if [ "$mode" = tty ]; then hb="$B"; he="$R"; fi
  hdr() { if [ "$mode" = tty ]; then printf '%s%s%s %s%s%s %s%s\n' "$ACC" "$TL" "$H" "$B" "$1" "$R$ACC" "$(frame_fill "$1")" "$R"; else printf '== %s\n' "$1"; fi; }
  row() { if [ "$mode" = tty ]; then printf '%s%s%s %s\n' "$ACC" "$V" "$R" "$1"; else printf '   %s\n' "$1"; fi; }
  endb() { if [ "$mode" = tty ]; then printf '%s%s%s%s\n' "$ACC" "$BL" "$(rule $((FRAME_W - 1)))" "$R"; fi; echo; }
  echo
  if want_cp; then
    hdr "$(t sum_title) - $(t sum_panel)"
    if [ "$BS_OK" = 0 ]; then row "$(paint "$YLW" "$(t sum_fallback)")"; fi
    while IFS='|' read -r lab url; do if [ -n "$url" ]; then row "$lab: $hb$url$he"; fi; done < <(panel_urls)
    if [ -z "$PUBLIC_IP" ]; then row "$(paint "$YLW" "$(t sum_public_unknown)")"; fi
    row "$D$(t sum_tls_note)$R"
    endb
    if [ "$BS_OK" = 1 ]; then
      hdr "$(t sum_admin)"
      if [ -n "$BS_USER" ]; then row "$(t sum_user): $hb$BS_USER$he"; fi
      if [ -n "$BS_PASS" ]; then row "$(t sum_password): $hb$BS_PASS$he   ($(t sum_pw_once))"
      else row "$(t sum_password): $(t sum_pw_unchanged "${BS_USER:-NAME}")"; fi
      endb
      hdr "$(t sum_setup)"
      local n=0
      while IFS='|' read -r lab url; do if [ -n "$url" ]; then row "$lab: $hb$url$he"; n=1; fi; done < <(setup_urls)
      if [ "$n" = 1 ]; then row "$D$(t sum_setup_note)$R"; else row "$(t sum_setup_none)"; fi
      endb
    fi
  fi
  if [ -n "$COMPAT_LINE" ]; then hdr "$(t sum_compat)"; row "$COMPAT_LINE"; endb; fi
  build_ports
  hdr "$(t sum_ports)"
  while IFS='|' read -r pt pr pu; do if [ -n "$pt" ]; then row "$hb$pt/$pr$he  $pu"; fi; done <<<"$SUMMARY_PORTS"
  row ""
  row "$(t sum_cmds):"
  row "  firewalld: $(printf '%s' "$SUMMARY_PORTS" | awk -F'|' '$1!=9444 && NF>2{printf "firewall-cmd --permanent --add-port=%s/%s && ", $1, $2}')firewall-cmd --reload"
  row "  ufw:       $(printf '%s' "$SUMMARY_PORTS" | awk -F'|' '$1!=9444 && NF>2{printf "ufw allow %s/%s; ", $1, $2}' | sed 's/; $//')"
  if printf '%s' "$SUMMARY_PORTS" | grep -q '^9444|'; then
    row "  $(t p_dpapi_only)"
    row "    firewall-cmd --permanent --add-rich-rule='rule family=\"ipv4\" source address=\"<DP_IP>/32\" port port=\"9444\" protocol=\"tcp\" accept'"
    row "    ufw allow from <DP_IP> to any port 9444 proto tcp"
  fi
  row "$(paint "$YLW" "$(t sum_cloud)")"
  endb
  if want_dp && want_cp && [ -z "$CP_URL" ]; then
    case "$DP_LINK" in
      linked) say "  $(paint "$GRN" "$OKM") $(t dp_link_ok)"; echo;;
      repaired) say "  $(paint "$GRN" "$OKM") $(t dp_link_fixed)"; echo;;
      same) say "  $(paint "$GRN" "$OKM") $(t dp_link_same)"; echo;;
      remote) say "  $(t dp_link_remote)"; echo;;
      failed) say "  $(paint "$YLW" "$WRM") $(t dp_link_fail_hint)"; echo;;
    esac
  fi
  return 0
}

write_summary_file() {
  [ "$STAGING" = 1 ] && return 0
  local f; f="$(p "$CONF_DIR/INSTALL-SUMMARY.txt")"
  [ -d "$(dirname "$f")" ] || return 0
  ( umask 077; { printf 'ToutWAF %s - %s\n' "$(t sum_title)" "$(date -u +%FT%TZ)"; render_summary plain; } >"$f" ) 2>/dev/null || return 0
  chmod 0600 "$f"; chown root:root "$f" 2>/dev/null || true
  say "  $(t sum_file "$f")"
  return 0
}

# ------------------------------------------------------------------------------------------------ status / links
cmd_status() {
  local rc=0 s u pt code
  banner; box_top "$(t st_title)"
  detect_installed; load_existing_ports
  if [ "$INST_DP$INST_CP" = 00 ]; then box_line "$(t state_none)"; box_bottom; return 1; fi
  [ "$INST_DP" = 1 ] && box_line "toutwaf-dp $(installed_label "$(p "$BIN_DIR/toutwaf-dp")")"
  [ "$INST_CP" = 1 ] && box_line "toutwaf-cp $(installed_label "$(p "$BIN_DIR/toutwaf-cp")")"
  box_line "$(t st_channel "$CHANNEL") ($(channel_branch))"
  if [ "$INST_CP" = 1 ]; then
    if ls "$(p "$DATA_DIR")"/agent-dist/toutwaf-agent-windows-*.exe >/dev/null 2>&1 || ls "$(p "$DATA_DIR")"/av-dist/toutwaf-av-* >/dev/null 2>&1; then box_line "$(t st_extras_ok)"
    else box_line "$(paint "$YLW" "$WRM $(t st_extras_none "sudo bash install.sh --extras-only")")"; fi
  fi
  if [ "$DRY_RUN" = 0 ]; then
    local frc=0; fetch_channel 2>/dev/null || frc=$?
    if [ "$frc" = 0 ]; then
      local cbin curv curb; cbin="$(p "$BIN_DIR/toutwaf-$([ "$INST_DP" = 1 ] && echo dp || echo cp)")"
      curv="$(installed_version "$cbin")"; curb="$(inst_build "$cbin" "$curv")"
      case "$([ -n "$curv" ] && update_state "$curv" "$curb" "$CH_VERSION" "$CH_BUILD" || echo same)" in
        newer) box_line "$(paint "$YLW" "$WRM $(t st_latest "$(ver_label "$CH_VERSION" "$CH_BUILD")")  -  $(t st_newer)")";;
        rebuilt) box_line "$(paint "$YLW" "$WRM $(t st_latest "$(ver_label "$CH_VERSION" "$CH_BUILD")")  -  $(t st_newbuild "--update")")";;
        *) box_line "$(t st_latest "$(ver_label "$CH_VERSION" "$CH_BUILD")")";;
      esac
    elif [ "$CH_EMPTY" = 1 ]; then
      box_line "$(t st_nochannel)"
    fi
  fi
  for u in $([ "$INST_DP" = 1 ] && echo toutwaf-dp) $([ "$INST_CP" = 1 ] && echo toutwaf-cp); do
    if [ "$HAS_SYSTEMD" = 1 ]; then
      if systemctl is-active --quiet "$u"; then s="$(paint "$GRN" "$OKM $(t st_active)")"; else s="$(paint "$RED" "$ERM $(t st_inactive)")"; rc=1; fi
      box_line "$u: $s ($(systemctl is-enabled "$u" 2>/dev/null || echo disabled))"
    fi
  done
  if [ "$INST_DP" = 1 ]; then
    for pt in "$HTTP_PORT" "$HTTPS_PORT" 9101; do
      if port_listening "$pt"; then box_line "$pt/tcp: $(paint "$GRN" "$OKM $(t st_listening)")"; else box_line "$pt/tcp: $(paint "$RED" "$ERM $(t st_closed)")"; rc=1; fi
    done
    if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:9101/healthz 2>/dev/null; then box_line "http://127.0.0.1:9101/healthz: $(paint "$GRN" "$OKM $(t st_healthy)")"
    else box_line "http://127.0.0.1:9101/healthz: $(paint "$RED" "$ERM $(t st_unhealthy)")"; rc=1; fi
  fi
  if [ "$INST_CP" = 1 ]; then
    for pt in "$CP_PORT" 9444; do
      if port_listening "$pt"; then box_line "$pt/tcp: $(paint "$GRN" "$OKM $(t st_listening)")"; else box_line "$pt/tcp: $(paint "$RED" "$ERM $(t st_closed)")"; rc=1; fi
    done
    # /healthz is a machine endpoint: it needs no panel path and a probe of "/" would count as a guessing attempt (lockout)
    code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 3 "https://127.0.0.1:$CP_PORT/healthz" 2>/dev/null || true)"
    if [ "$code" = 200 ]; then box_line "https://127.0.0.1:$CP_PORT/healthz (HTTP $code): $(paint "$GRN" "$OKM $(t st_healthy)")"
    else box_line "https://127.0.0.1:$CP_PORT/healthz: $(paint "$RED" "$ERM $(t st_unhealthy)")"; rc=1; fi
  fi
  box_bottom
  return $rc
}

cmd_links() {
  banner; detect_installed; load_existing_ports
  if [ "$INST_CP" = 0 ]; then say "  $(t state_none)"; return 1; fi
  component_from_installed; detect_public_ip
  cp_links
  render_summary tty
  return 0
}

# ------------------------------------------------------------------------------------------------ uninstall
FW_CLOSED=0
cmd_uninstall() {
  local a s b l
  banner; box_top "$(t un_title)"; box_bottom
  if interactive; then
    ask_yn a "$(t q_confirm_un)" 0; [ "$a" = 1 ] || { say "  $(t aborted)"; exit 0; }
    ask_yn PURGE "$(t q_purge)" 0
  elif [ "$PURGE" = 1 ] && [ "$ASSUME_YES" = 0 ] && [ "$ACCEPT_DEFAULTS" = 0 ] && [ -n "$TTY_DEV" ]; then
    ask_yn a "$(t q_purge)" 0; [ "$a" = 1 ] || die "$(t aborted)"
  fi
  detect_installed; load_existing_ports
  # firewall rules added by ToutWAF go first (the helper remembers exactly what it added); then the helper itself
  if [ "$STAGING" = 0 ] && [ -x "$BIN_DIR/toutwaf-blocklist" ]; then run "$BIN_DIR/toutwaf-blocklist" clear >>"$LOG" 2>&1 || true; fi
  if [ "$STAGING" = 0 ] && [ -x "$BIN_DIR/toutwaf-firewall" ]; then run "$BIN_DIR/toutwaf-firewall" close >>"$LOG" 2>&1 || true; FW_CLOSED=1; fi
  for s in toutwaf-upgrade.path toutwaf-upgrade.service toutwaf-upgrade-guard.service toutwaf-firewall.path toutwaf-firewall.service toutwaf-blocklist.path toutwaf-blocklist.service toutwaf-vpn.path toutwaf-vpn.service toutwaf-fw.path toutwaf-fw.service toutwaf-fw-boot.service toutwaf-jobs.path toutwaf-jobs.service toutwaf-cloudlink.service toutwaf-dp.service toutwaf-cp.service; do
    if [ "$HAS_SYSTEMD" = 1 ]; then run systemctl disable --now "$s" >>"$LOG" 2>&1 || true; fi
    run rm -f "$(p /etc/systemd/system/$s)"
  done
  if [ "$HAS_SYSTEMD" = 1 ]; then run systemctl stop toutwaf-upgrade-rollback.timer toutwaf-upgrade-rollback.service >>"$LOG" 2>&1 || true; fi   # transient units of an update in progress
  if [ "$HAS_SYSTEMD" = 1 ]; then run systemctl daemon-reload; fi
  for b in toutwaf-dp toutwaf-cp toutwafctl toutwaf-upgrade toutwaf-firewall toutwaf-blocklist toutwaf-vpn toutwaf-fw toutwaf-jobs toutwaf-cloudlink; do run rm -f "$(p "$BIN_DIR/$b")" "$(p "$BIN_DIR/$b.prev")"; done
  run rm -f "$(p /etc/logrotate.d/toutwaf)" "$(p /etc/sysctl.d/90-toutwaf.conf)" "$(p /usr/lib/sysusers.d/toutwaf.conf)" "$(p /usr/lib/tmpfiles.d/toutwaf.conf)" "$(p /etc/firewalld/services/toutwaf-dp.xml)"
  for b in toutwafctl toutwaf-cp toutwaf-dp toutwaf-upgrade toutwaf-firewall toutwaf-blocklist toutwaf-vpn toutwaf-fw toutwaf-jobs; do
    for d in /usr/local/bin "$(secure_link_dir)"; do
      [ -n "$d" ] || continue
      l="$(p "$d/$b")"; if [ -L "$l" ] && [ "$(readlink "$l")" = "$BIN_DIR/$b" ]; then run rm -f "$l"; fi
    done
  done
  run rm -f "$(p "$CONF_DIR/firewall.conf")" "$(p "$CONF_DIR/firewall.managed")"
  if [ "$STAGING" = 0 ] && [ "${FW_CLOSED:-0}" = 0 ] && firewalld_running; then   # installation without the helper (older versions)
    run firewall-cmd --permanent --remove-service=toutwaf-dp >/dev/null 2>&1 || true
    run firewall-cmd --permanent --remove-port="$CP_PORT/tcp" >/dev/null 2>&1 || true
    run firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  if [ "$PURGE" = 1 ]; then
    run rm -rf "$(p "$CONF_DIR")" "$(p "$DATA_DIR")" "$(p "$LOG_DIR")" "$(p "${DATA_DIR}-upgrade")"   # the last one holds copies of the database kept by the update helper: only --purge removes it
    if [ "$LAYOUT" = home ]; then rmdir "$(p "$BIN_DIR")" "$(p "$HOME_DIR")" 2>/dev/null || true; fi
    run rm -f "$LAYOUT_FILE"   # only when empty: the parent directory and foreign content stay
    if [ "$STAGING" = 0 ] && have userdel; then run userdel "$SVC_USER" >/dev/null 2>&1 || true; fi
    say "  $(paint "$GRN" "$OKM") $(t un_purged)"
  else
    say "  $(paint "$GRN" "$OKM") $(t un_kept "$CONF_DIR" "$DATA_DIR")"
  fi
  say "  $(t "done")"
  return 0
}

# ------------------------------------------------------------------------------------------------ prerequisites
# pkg_install PM pkg...: non-interactive install with the native package manager (never a partial system upgrade)
pkg_install() {
  local pm="$1" out; shift
  case "$pm" in
    dnf) run dnf install -y "$@";;
    yum) run yum install -y "$@";;
    apt)   # another apt / dpkg (unattended-upgrades, cloud-init) may hold the lock for a while: wait for it, and try once more after a failure
      local try=1 rc
      while :; do
        run apt-get -o DPkg::Lock::Timeout=300 update -qq || true   # a repository that is unhappy is not ours to fix: the install tells
        rc=0; DEBIAN_FRONTEND=noninteractive run apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "$@" || rc=$?
        [ "$rc" = 0 ] && return 0
        [ "$try" -ge 2 ] && return "$rc"
        try=$((try + 1)); log "apt-get failed (rc $rc): trying once more"; sleep "${TOUTWAF_PKG_RETRY_DELAY:-15}"
      done;;
    zypper) run zypper --non-interactive install --no-recommends "$@";;
    pacman)
      # never "pacman -Sy <pkg>": a partial upgrade breaks Arch. The package databases must already be synchronised.
      if [ "$DRY_RUN" = 1 ]; then run pacman -S --needed --noconfirm "$@"; return 0; fi
      if out="$(pacman -S --needed --noconfirm "$@" 2>&1 </dev/null)"; then printf '%s\n' "$out"; return 0; fi
      printf '%s\n' "$out"
      case "$out" in
        *[Ll]andlock*|*"restricting filesystem access"*)   # kernel / container without Landlock: pacman 7 cannot sandbox its downloads
          log "pacman sandbox (Landlock) unavailable here: retrying with --disable-sandbox"; pacman -S --needed --noconfirm --disable-sandbox "$@" </dev/null;;
        *"target not found"*|*"failed retrieving file"*|*"could not resolve"*) warn "$(t cp_prereq_arch)"; return 1;;
        *) return 1;;
      esac;;
    *) return 1;;
  esac
}

install_pkgs() {
  [ "$STAGING" = 1 ] && return 0
  local fam="${FAMILY:-${FAMILY_GUESS:-}}" pm="" missing=() optional=() n
  [ -n "$fam" ] || die "cannot install prerequisites automatically: no known package manager (dnf, yum, apt-get, zypper, pacman); install curl, tar, coreutils and libcap tools, then re-run"
  need() { n="$(pf_pkg "$fam" "$1")"; if [ -n "$n" ] && [ "$n" != "-" ]; then missing+=("$n"); fi; return 0; }
  have curl || need curl; have tar || need tar; have gzip || need gzip; have sha256sum || need coreutils; have awk || need awk
  if [ -z "$TARBALL" ]; then have openssl || need openssl; fi   # release signature (Ed25519)
  have setcap || need libcap
  [ -d /etc/ssl/certs ] || [ -d /etc/pki/tls/certs ] || need ca
  # SELinux python utilities (semanage), only when SELinux is on and the family has them
  if [ "$NO_SELINUX" = 0 ] && have getenforce && [ "$(getenforce 2>/dev/null)" != "Disabled" ] && ! have semanage; then need selinux; fi
  # logrotate is optional: without it the log files simply are not rotated
  if ! have logrotate; then n="$(pf_pkg "$fam" logrotate)"; if [ -n "$n" ] && [ "$n" != "-" ]; then optional+=("$n"); fi; fi
  [ ${#missing[@]} -gt 0 ] || [ ${#optional[@]} -gt 0 ] || return 0
  # package manager: the family's, falling back to whatever is installed
  case "$(pf_fam "$fam" 3)" in
    dnf) if have dnf; then pm=dnf; elif have yum; then pm=yum; fi;;
    apt) have apt-get && pm=apt;;
    zypper) have zypper && pm=zypper;;
    pacman) have pacman && pm=pacman;;
  esac
  if [ -z "$pm" ]; then
    if have dnf; then pm=dnf; elif have yum; then pm=yum; elif have apt-get; then pm=apt; elif have zypper; then pm=zypper; elif have pacman; then pm=pacman; fi
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    [ -n "$pm" ] || die "cannot install prerequisites automatically (${missing[*]}); install them and re-run"
    log "Installing prerequisites with $pm: ${missing[*]}"
    pkg_install "$pm" "${missing[@]}" || die "installing the prerequisites failed (${missing[*]}); install them and re-run"
  fi
  if [ ${#optional[@]} -gt 0 ] && [ -n "$pm" ]; then
    log "Installing optional packages with $pm: ${optional[*]}"
    pkg_install "$pm" "${optional[@]}" || warn "optional package(s) not installed (${optional[*]}): log rotation will not run"
  fi
  return 0
}

# ------------------------------------------------------------------------------------------------ fetch
fetch() { curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1"; }

# Release signature trust anchor. It lives HERE (in the installer you run), never in channel.json: the copy of the public key that
# channel.json advertises is informational and must not be trusted. Overridden by TOUTWAF_RELEASE_PUBKEY, then by $CONF_DIR/release.pub.
# RELEASE_PUBKEY_ID = first 16 hex chars of sha256(raw public key), same as publisher/internal/sign Fingerprint (checked by a test).
RELEASE_PUBKEY_DEFAULT='V7tJBQsSrIsDTGIqlFhJZ8q4t/Fc8iNvg/cKkfRDATA='
RELEASE_PUBKEY_ID='ebd2a20ce5a5650f'
SIG_REQUIRED_FROM='0.2.0-dev.7'   # releases before this one were published unsigned

# release_pubkey: prints the path of a PEM public key (Ed25519): TOUTWAF_RELEASE_PUBKEY, else $CONF_DIR/release.pub, else the built-in key
release_pubkey() {
  local k="${TOUTWAF_RELEASE_PUBKEY:-}" raw pem="$TMP/release-pub.pem"
  if [ -z "$k" ] && [ -r "$(p "$CONF_DIR/release.pub")" ]; then k="$(p "$CONF_DIR/release.pub")"; fi
  if [ -z "$k" ]; then k="$RELEASE_PUBKEY_DEFAULT"; fi
  if [ -f "$k" ]; then raw="$(cat "$k")"; else raw="$k"; fi
  case "$raw" in
    *"BEGIN PUBLIC KEY"*) printf '%s\n' "$raw" >"$pem";;
    *) { printf -- '-----BEGIN PUBLIC KEY-----\n'; { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s' "$raw" | tr -d '[:space:]' | base64 -d; } | base64 -w64; printf -- '-----END PUBLIC KEY-----\n'; } >"$pem";;
  esac
  printf '%s' "$pem"
}
# ed25519_py FILE: writes the fallback verifier (pure Python, RFC 8032 section 5.1.7, Python >= 3.6, only hashlib) used when openssl cannot verify
# Ed25519 (OpenSSL 1.1.1 on RHEL / Alma / Rocky / Oracle 8). Usage: python ed25519.py PUBLIC_KEY_BASE64 SIGNATURE_FILE MESSAGE_FILE
# Exit 0 = valid, 1 = invalid (also: wrong lengths, S >= L, point not on the curve), 2 = usage / internal error. deploy/tests/compat-test.sh runs
# this very text against the five RFC 8032 vectors (plus tampered / malformed variants) and a signature made by the Go signer.
ed25519_py() {
  cat >"$1" <<'TW_ED25519_PY'
import sys, hashlib, base64
P = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)

def recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P:
        return None
    return x if (x & 1) == sign else P - x

def add(p, q):
    a = (p[1] - p[0]) * (q[1] - q[0]) % P
    b = (p[1] + p[0]) * (q[1] + q[0]) % P
    c = 2 * p[3] * q[3] * D % P
    d = 2 * p[2] * q[2] % P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % P, g * h % P, f * g % P, e * h % P)

def mul(k, p):
    r = (0, 1, 1, 0)
    while k:
        if k & 1:
            r = add(r, p)
        p = add(p, p)
        k >>= 1
    return r

def decode(b):
    n = int.from_bytes(b, "little")
    y = n & ((1 << 255) - 1)
    x = recover_x(y, n >> 255)
    return None if x is None else (x, y, 1, x * y % P)

BY = 4 * pow(5, P - 2, P) % P
BASE = (recover_x(BY, 0), BY, 1, recover_x(BY, 0) * BY % P)

def verify(pub, sig, msg):
    if len(pub) != 32 or len(sig) != 64:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= L:
        return False
    a, r = decode(pub), decode(sig[:32])
    if a is None or r is None:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + pub + msg).digest(), "little") % L
    lhs, rhs = mul(s, BASE), add(r, mul(h, a))
    return (lhs[0] * rhs[2] - rhs[0] * lhs[2]) % P == 0 and (lhs[1] * rhs[2] - rhs[1] * lhs[2]) % P == 0

try:
    pub = base64.b64decode(sys.argv[1], validate=True)
    sig = open(sys.argv[2], "rb").read()
    msg = open(sys.argv[3], "rb").read()
except Exception:
    sys.exit(2)
sys.exit(0 if verify(pub, sig, msg) else 1)
TW_ED25519_PY
}
# openssl_ed25519_ok: true when this openssl really verifies Ed25519 (probe: RFC 8032 test vector 1, empty message)
openssl_ed25519_ok() {
  have openssl || return 1
  local pk="d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
  local sg="e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
  hx() { printf "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }
  { printf -- '-----BEGIN PUBLIC KEY-----\n'; { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; hx "$pk"; } | base64 -w64; printf -- '-----END PUBLIC KEY-----\n'; } >"$TMP/probe.pem"
  hx "$sg" >"$TMP/probe.sig"; : >"$TMP/probe.msg"
  openssl pkeyutl -verify -pubin -inkey "$TMP/probe.pem" -rawin -in "$TMP/probe.msg" -sigfile "$TMP/probe.sig" >>"$LOG" 2>&1
}
# python3_bin: prints a Python 3 interpreter (python3, el8's platform-python, or python when it is version 3), nothing when there is none
python3_bin() {
  local c
  for c in python3 /usr/libexec/platform-python python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 0
}
# pubkey_raw PEM: raw 32-byte public key, base64 (the last 32 bytes of the SPKI DER)
pubkey_raw() { sed '/-----/d' "$1" | tr -d '[:space:]' | base64 -d 2>/dev/null | tail -c 32 | base64 -w0; }
# pubkey_id PEM: key id (first 16 hex chars of sha256 of the raw 32-byte public key)
pubkey_id() { pubkey_raw "$1" | base64 -d | sha256sum | cut -c1-16; }

# resolve the release to install: sets RESOLVED_VERSION (and CH_* from channel.json when reachable)
resolve_release() {
  local pinned=0; [ "$VERSION" != latest ] && pinned=1
  if ! fetch_channel; then
    if [ "$CH_EMPTY" = 1 ] && [ "$pinned" = 0 ]; then
      # not a network problem: the channel is reachable and says that no version is published on it. Say that, and what to do.
      local other=dev; [ "$CHANNEL" != dev ] || other=stable
      die "$(t e_nover "$CHANNEL" "$other" "$other")"
    fi
    [ "$pinned" = 1 ] || die "cannot read $(repo_base)/channel.json (channel $CHANNEL): check the network, use --base-url, --version or --tarball"
    warn "cannot read channel.json: yanked / minimum-installer checks skipped"
  fi
  if [ -n "$CH_MIN" ] && semver_lt "$INSTALLER_VERSION" "$CH_MIN"; then die "$(t e_installer_old "$CH_MIN")"; fi
  if [ "$pinned" = 1 ]; then RESOLVED_VERSION="${VERSION#v}"; else RESOLVED_VERSION="$CH_VERSION"; fi
  if [ -n "$CH_JSON" ] && ch_yanked "$RESOLVED_VERSION" && [ "$FORCE" = 0 ]; then die "$(t e_yanked "$RESOLVED_VERSION")"; fi
  return 0
}

# verify_signature: SHA256SUMS.sig (base64 of the raw signature over SHA256SUMS) against the trust anchor. Used by the installer and,
# because toutwaf-upgrade downloads and runs this very script with --update, by the in-console update too.
# Policy: a bad signature ALWAYS aborts; a missing one aborts for releases >= $SIG_REQUIRED_FROM and only warns for older (unsigned) ones.
# Engine: openssl when it can verify Ed25519 (>= 3.0), else the embedded pure-Python verifier; neither available: refused (fail closed).
verify_signature() {   # $1 = base URL of the release directory, $2 = its cache-bypass query ("" or "?b=<build>")
  local pem code rc=0 kid mode="" py="" okv=0
  pem="$(release_pubkey)"
  if [ "$DRY_RUN" = 1 ] && [ -n "${TOUTWAF_TEST_NO_OPENSSL_ED25519:-}" ]; then
    printf '[test] TOUTWAF_TEST_NO_OPENSSL_ED25519: the Python fallback verifier is forced\n' >&2
  elif openssl_ed25519_ok; then mode=openssl; fi
  if [ -z "$mode" ]; then
    py="$(python3_bin)"
    [ -n "$py" ] || die "cannot verify the Ed25519 release signature: this system's OpenSSL ($(openssl version 2>/dev/null | awk '{print $2}')) has no Ed25519 verification (OpenSSL >= 3.0 is needed) and no Python 3 was found for the built-in fallback verifier. The installation is refused (fail closed): install OpenSSL 3 or python3, or verify SHA256SUMS(.sig) yourself (see deploy/README.md, Release signature) and install from the archive with --tarball"
    mode=python
  fi
  code="$(curl -fsSL --retry 3 --connect-timeout 15 -o "$TMP/SHA256SUMS.sig" -w '%{http_code}' "$1/SHA256SUMS.sig${2:-}" 2>>"$LOG")" || rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$code" = 404 ] || [ "$rc" = 37 ]; then   # not published (37: file:// mirror without the file)
      if semver_lt "$RESOLVED_VERSION" "$SIG_REQUIRED_FROM"; then warn "$(t w_sigold "$RESOLVED_VERSION")"; return 0; fi
      die "release signature missing ($1/SHA256SUMS.sig): releases >= $SIG_REQUIRED_FROM are signed, installation refused"
    fi
    die "cannot download the release signature ($1/SHA256SUMS.sig)"
  fi
  tr -d '[:space:]' <"$TMP/SHA256SUMS.sig" | base64 -d >"$TMP/sums.sig.bin" 2>/dev/null || die "release signature is not valid base64"
  if [ "$mode" = openssl ]; then
    openssl pkeyutl -verify -pubin -inkey "$pem" -rawin -in "$TMP/SHA256SUMS" -sigfile "$TMP/sums.sig.bin" >>"$LOG" 2>&1 && okv=1
  else
    ed25519_py "$TMP/ed25519.py"
    "$py" "$TMP/ed25519.py" "$(pubkey_raw "$pem")" "$TMP/sums.sig.bin" "$TMP/SHA256SUMS" >>"$LOG" 2>&1 && okv=1
  fi
  [ "$okv" = 1 ] || die "release signature verification FAILED"
  kid="$(pubkey_id "$pem")"
  if [ -z "${TOUTWAF_RELEASE_PUBKEY:-}" ] && [ ! -r "$(p "$CONF_DIR/release.pub")" ] && [ "$kid" != "$RELEASE_PUBKEY_ID" ]; then
    die "internal error: the built-in release public key has id ${kid:-?}, expected $RELEASE_PUBKEY_ID"
  fi
  info "$(t s_sigok "${kid:-?}")"
  SIG_OK_FOR="$RESOLVED_VERSION|$(release_build)"
}

SRC_DIR=""; RESOLVED_VERSION=""
# The public mirror (raw.githubusercontent.com) caches for a few minutes, and a development version is republished under the SAME path: right after a
# publication an installer could read the new channel.json with the old SHA256SUMS. Every file of a release directory is therefore asked for with a
# cache-bypass parameter that belongs to the publication, "?b=<build>" (the build read in channel.json), so that a new build can never be answered with
# the files cached for the previous one. No build announced (older channel.json, a version pinned that is not the channel's): no parameter. A file
# mirror (file://) has no cache: no parameter either.
release_build() { if [ -n "$CH_JSON" ] && [ "$RESOLVED_VERSION" = "$CH_VERSION" ]; then printf '%s' "$CH_BUILD"; fi; }
release_q() {   # BUILD -> "?b=BUILD" for an http(s) mirror, nothing otherwise
  case "$(repo_base)" in http://*|https://*) [ -z "${1:-}" ] || printf '?b=%s' "$1";; esac
}
# One more read of channel.json, with its own cache-bypass parameter "?t=<date>", after the files of a release disagreed with each other.
refresh_channel() {
  case "$(repo_base)" in http://*|https://*) CH_QUERY="?t=$(date +%s)";; esac
  local frc=0; fetch_channel || frc=$?
  CH_QUERY=""
  [ "$frc" = 0 ] || return 1
  if [ "$VERSION" = latest ]; then RESOLVED_VERSION="$CH_VERSION"; fi
  if [ "$RESOLVED_VERSION" = "$CH_VERSION" ]; then NEW_BUILD="$CH_BUILD"; fi
  return 0
}
obtain_binaries() {   # sets SRC_DIR to a directory holding the binaries
  local tb="$TARBALL"
  if [ -z "$tb" ]; then
    local asset="toutwaf-linux-$ARCH.tar.gz" rel q attempt=1 want got chsha which
    while :; do
      rel="$(repo_base)/releases/$RESOLVED_VERSION"; q="$(release_q "$(release_build)")"
      tb="$TMP/$asset"
      fetch "$rel/$asset$q" "$tb"
      fetch "$rel/SHA256SUMS$q" "$TMP/SHA256SUMS"
      chsha=""; which=""
      want="$(grep " $asset\$" "$TMP/SHA256SUMS" | awk '{print $1}' | tr 'A-F' 'a-f')"
      got="$(sha256sum "$tb" | awk '{print $1}')"
      if [ -z "$want" ] || [ "$want" != "$got" ]; then which="SHA256SUMS"
      elif [ -n "$CH_JSON" ] && [ "$RESOLVED_VERSION" = "$CH_VERSION" ]; then
        chsha="$(ch_asset_sha "$asset")"
        [ -z "$chsha" ] || [ "$chsha" = "$got" ] || which="channel.json"
      fi
      [ -n "$which" ] || break
      # the files do not agree with each other. Once: read channel.json again past the cache, then start over; the second time: stop, saying why and what to do
      if [ "$attempt" = 1 ] && refresh_channel; then
        attempt=2; warn "$(t w_mirror "$asset")"; continue
      fi
      die "$(t e_mismatch "$asset" "$which")"
    done
    info "$(t s_sha)"
    verify_signature "$rel" "$q"
  else
    [ -f "$tb" ] || die "tarball not found: $tb"
  fi
  mkdir -p "$TMP/out"; tar -xzf "$tb" -C "$TMP/out"
  # layout: toutwaf-<version>-linux-<arch>/bin/{toutwaf-dp,toutwaf-cp,toutwafctl}; a flat archive is accepted too
  if [ -e "$TMP/out/toutwaf-dp" ] || [ -e "$TMP/out/toutwaf-cp" ]; then SRC_DIR="$TMP/out"
  else
    # no find/xargs: findutils is not part of minimal images (Rocky/Alma 8 container images)
    local d="" f
    for f in "$TMP"/out/*/bin/toutwaf-dp "$TMP"/out/*/bin/toutwaf-cp "$TMP"/out/*/toutwaf-dp "$TMP"/out/*/toutwaf-cp "$TMP"/out/*/*/bin/toutwaf-dp "$TMP"/out/*/*/bin/toutwaf-cp; do
      if [ -f "$f" ]; then d="$(dirname "$f")"; break; fi
    done
    [ -n "$d" ] && SRC_DIR="$d" || die "no binaries in the archive (expected toutwaf-<version>-linux-$ARCH/bin/)"
  fi
  read_archive_identity
}
# the archive says what it holds: VERSION and BUILD next to bin/ (older archives have no BUILD)
ARCHIVE_VERSION=""; ARCHIVE_BUILD=""
read_archive_identity() {
  local top f
  ARCHIVE_VERSION=""; ARCHIVE_BUILD=""
  for top in "$(dirname "$SRC_DIR")" "$SRC_DIR"; do
    if [ -f "$top/VERSION" ] || [ -f "$top/BUILD" ]; then
      f="$top/VERSION"; [ ! -f "$f" ] || ARCHIVE_VERSION="$(head -n1 "$f" | tr -d ' \t\r\n')"
      f="$top/BUILD"; [ ! -f "$f" ] || ARCHIVE_BUILD="$(clean_build "$(head -n1 "$f")")"
      break
    fi
  done
  return 0
}

# ------------------------------------------------------------------------------------------------ extras
# The second asset of a release: toutwaf-extras.tar.gz, or toutwaf-extras-<n>of<m>.tar.gz when it is cut (every part under 90 MiB). It holds
# toutwaf-extras-<version>/{agent-dist/toutwaf-agent-windows-*.exe, av-dist/toutwaf-av-*, LICENSE, VERSION, BUILD}. It is listed in the signed SHA256SUMS
# like the archive, so the one signature check covers it; its SHA-256 is compared with SHA256SUMS (and with channel.json when that is the channel's version).
# An installation without the extras works: it does not offer Windows nor the antivirus, and says what to do. A problem with the extras is NEVER fatal
# here (only a bad signature, which verify_signature handles for the whole release).
extras_names() {   # the extras files SHA256SUMS lists, parts in order; prints nothing when the release carries none
  [ -f "$TMP/SHA256SUMS" ] || return 0
  awk '$2 ~ /^toutwaf-extras(-[0-9]+of[0-9]+)?\.tar\.gz$/ {print $2}' "$TMP/SHA256SUMS" | sort -t- -k3,3n
}
extras_fail() {   # KEY ARGS...: remember that the extras are not installed, say why and what to do
  EXTRAS_RESULT=failed; EXTRAS_DIR=""
  warn "$(t "$@")"
  return 0
}
# extras_wanted PATH: a regular file (not a link) whose place and name are the ones of the contract: agent-dist/toutwaf-agent-windows-{amd64,arm64}.exe, av-dist/toutwaf-av-<system>-<arch>
extras_wanted() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  case "$(basename "$(dirname "$1")")/$(basename "$1")" in
    agent-dist/toutwaf-agent-windows-amd64.exe|agent-dist/toutwaf-agent-windows-arm64.exe) return 0;;
    av-dist/toutwaf-av-linux-amd64|av-dist/toutwaf-av-linux-arm64|av-dist/toutwaf-av-darwin-amd64|av-dist/toutwaf-av-darwin-arm64|av-dist/toutwaf-av-windows-amd64.exe|av-dist/toutwaf-av-windows-arm64.exe) return 0;;
  esac
  return 1
}
# extras_unpack FILE...: unpack the parts into $TMP/extras/out and check that they are the release's; sets EXTRAS_DIR; prints nothing
extras_unpack() {
  local f out="$TMP/extras/out" d top nfiles=0 v b
  rm -rf "$out"; mkdir -p "$out"
  for f in "$@"; do
    if ! tar -xzf "$f" -C "$out" 2>>"$LOG"; then extras_fail w_extras_bad "$(basename "$f")"; return 0; fi
  done
  d=""
  for top in "$out"/toutwaf-extras-*; do [ -d "$top" ] && { d="$top"; break; }; done
  [ -n "$d" ] || { extras_fail w_extras_bad "$(basename "$1")"; return 0; }
  v="$(head -n1 "$d/VERSION" 2>/dev/null | tr -d ' \t\r\n')"; b="$(clean_build "$(head -n1 "$d/BUILD" 2>/dev/null)")"
  # they must belong to the release that was installed (or is being installed): a Windows agent of another version would not match the console
  if [ -n "$ARCHIVE_VERSION" ] && [ -n "$v" ] && [ "$v" != "$ARCHIVE_VERSION" ]; then extras_fail w_extras_ver "$v" "$ARCHIVE_VERSION"; return 0; fi
  if [ -n "$ARCHIVE_BUILD" ] && [ -n "$b" ] && [ "$b" != "$ARCHIVE_BUILD" ]; then extras_fail w_extras_ver "$v ($b)" "$ARCHIVE_VERSION ($ARCHIVE_BUILD)"; return 0; fi
  for f in "$d"/agent-dist/* "$d"/av-dist/*; do extras_wanted "$f" && nfiles=$((nfiles + 1)); done
  if [ "$nfiles" = 0 ]; then extras_fail w_extras_bad "$(basename "$1")"; return 0; fi
  EXTRAS_DIR="$d"; EXTRAS_COUNT="$nfiles"; EXTRAS_VERSION="${v:-$ARCHIVE_VERSION}"; EXTRAS_BUILD="${b:-$ARCHIVE_BUILD}"
  return 0
}
# obtain_extras: sets EXTRAS_DIR (unpacked) or EXTRAS_RESULT (none | failed | skipped); never stops the installation
obtain_extras() {
  EXTRAS_DIR=""; EXTRAS_RESULT=""
  if [ "$NO_EXTRAS" = 1 ]; then EXTRAS_RESULT=skipped; return 0; fi
  want_cp || { EXTRAS_RESULT=skipped; return 0; }
  mkdir -p "$TMP/extras"
  local files=() f want got n ch rel q names parts i total=0 attempt
  # ---- local files (offline)
  if [ -n "$EXTRAS_LOCAL" ] || { [ -n "$TARBALL" ] && ls "$(dirname "$TARBALL")"/toutwaf-extras*.tar.gz >/dev/null 2>&1; }; then
    local oldifs="$IFS" list="$EXTRAS_LOCAL"; IFS=:
    for f in $list; do [ -z "$f" ] || files+=("$f"); done
    IFS="$oldifs"
    if [ ${#files[@]} -eq 0 ]; then for f in "$(dirname "$TARBALL")"/toutwaf-extras*.tar.gz; do files+=("$f"); done; fi   # next to the archive: they belong together
    for f in "${files[@]}"; do [ -f "$f" ] || { extras_fail w_extras_nofile "$f"; return 0; }; done
    # a SHA256SUMS next to a file is used to check it; without one the file is trusted as the archive given with --tarball is
    for f in "${files[@]}"; do
      n="$(basename "$f")"
      if [ -f "$(dirname "$f")/SHA256SUMS" ]; then
        want="$(grep " $n\$" "$(dirname "$f")/SHA256SUMS" | awk '{print $1}' | tr 'A-F' 'a-f' | head -n1)"
        got="$(sha256sum "$f" | awk '{print $1}')"
        if [ -z "$want" ] || [ "$want" != "$got" ]; then extras_fail w_extras_sum "$n"; return 0; fi
      else info "$(t s_extras_unchecked "$n")"; fi
    done
    extras_unpack "${files[@]}"
    return 0
  fi
  [ -z "$TARBALL" ] || { EXTRAS_RESULT=none; return 0; }   # an archive given by hand, no extras given with it
  # ---- download: the signed SHA256SUMS of the release says which files are the extras
  rel="$(repo_base)/releases/$RESOLVED_VERSION"; q="$(release_q "$(release_build)")"
  if [ ! -f "$TMP/SHA256SUMS" ] || [ "$SIG_OK_FOR" != "$RESOLVED_VERSION|$(release_build)" ]; then
    if ! fetch "$rel/SHA256SUMS$q" "$TMP/SHA256SUMS" 2>>"$LOG"; then extras_fail w_extras_dl "SHA256SUMS"; return 0; fi
    verify_signature "$rel" "$q"      # a bad signature aborts, as for the archive
  fi
  names="$(extras_names)"
  if [ -z "$names" ]; then EXTRAS_RESULT=none; return 0; fi    # a release from before the extras: nothing to install
  parts=0; for f in $names; do parts=$((parts + 1)); done
  case "$names" in *of[0-9]*) i="$(printf '%s\n' "$names" | head -n1 | sed -n 's/.*-[0-9]*of\([0-9]*\)\.tar\.gz/\1/p')"; if [ "$i" != "$parts" ]; then extras_fail w_extras_inc "$parts" "$i"; return 0; fi;; esac
  files=()
  for n in $names; do
    f="$TMP/extras/$n"
    for attempt in 1 2; do
      if fetch "$rel/$n$q" "$f" 2>>"$LOG"; then break; fi
      rm -f "$f"
    done
    [ -f "$f" ] || { extras_fail w_extras_dl "$n"; return 0; }
    want="$(grep " $n\$" "$TMP/SHA256SUMS" | awk '{print $1}' | tr 'A-F' 'a-f' | head -n1)"
    got="$(sha256sum "$f" | awk '{print $1}')"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then extras_fail w_extras_sum "$n"; return 0; fi
    if [ -n "$CH_JSON" ] && [ "$RESOLVED_VERSION" = "$CH_VERSION" ]; then
      ch="$(ch_asset_sha "$n")"; if [ -n "$ch" ] && [ "$ch" != "$got" ]; then extras_fail w_extras_sum "$n"; return 0; fi
    fi
    total=$((total + $(wc -c <"$f")))
    files+=("$f")
  done
  info "$(t s_extras_sha "$parts" "$((total / 1048576))")"
  extras_unpack "${files[@]}"
  return 0
}
# install_extras: put the unpacked extras next to the data of the control plane and record which release they are of
install_extras() {
  [ -n "$EXTRAS_DIR" ] || return 0
  local f dst own grp n=0 recorded="" sub
  own="$([ "$STAGING" = 1 ] && id -un || echo "$SVC_USER")"; grp="$([ "$STAGING" = 1 ] && id -gn || echo "$SVC_USER")"
  for sub in agent-dist av-dist; do
    run install -d -m 0750 -o "$own" -g "$grp" "$(p "$DATA_DIR/$sub")" || return 0
  done
  for f in "$EXTRAS_DIR"/agent-dist/* "$EXTRAS_DIR"/av-dist/*; do
    extras_wanted "$f" || continue
    dst="$(p "$DATA_DIR/$(basename "$(dirname "$f")")/$(basename "$f")")"
    # a copy next to the final name, moved over it: a program being downloaded by a machine is never half replaced
    if run install -m 0640 -o "$own" -g "$grp" "$f" "$dst.new" && run mv -f "$dst.new" "$dst"; then n=$((n + 1)); recorded="$recorded\"$(basename "$f")\","; else warn "could not install $(basename "$f")"; run rm -f "$dst.new"; fi
  done
  if [ "$n" -gt 0 ] && [ "$DRY_RUN" = 0 ]; then
    local ej; ej="$(p "$DATA_DIR/extras.json")"
    printf '{"version":"%s","build":"%s","installed_at":"%s","files":[%s]}\n' "$EXTRAS_VERSION" "${EXTRAS_BUILD:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${recorded%,}" >"$ej.new" || true
    chown "$own:$grp" "$ej.new" 2>/dev/null || true; chmod 0644 "$ej.new" 2>/dev/null || true
    mv -f "$ej.new" "$ej" || warn "could not record the extras in $ej"
  fi
  EXTRAS_RESULT=ok; EXTRAS_COUNT="$n"
  info "$(t s_extras_ok "$n" "$DATA_DIR")"
  return 0
}
# the extras are installed for THIS release: extras.json says the version and the build, and every program it listed is still there
extras_current() {
  local j v b
  j="$(p "$DATA_DIR/extras.json")"
  [ -f "$j" ] || return 1
  v="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$j" | head -n1)"; b="$(sed -n 's/.*"build":"\([^"]*\)".*/\1/p' "$j" | head -n1)"
  [ -n "$v" ] && [ "$v" = "${1:-}" ] || return 1
  [ -z "${2:-}" ] || [ "$b" = "$2" ] || return 1
  # every program extras.json lists is still there
  local f d
  for f in $(grep -o '"toutwaf-[^"]*"' "$j" | tr -d '"'); do
    case "$f" in toutwaf-agent-*) d=agent-dist;; *) d=av-dist;; esac
    [ -s "$(p "$DATA_DIR/$d/$f")" ] || return 1
  done
  return 0
}
extras_step() { obtain_extras; install_extras; return 0; }
# an update that finds nothing new for the programs still brings the extras when they are missing or of another build (a first install made without network, an older installer)
extras_maintain() {
  want_cp && [ "$NO_EXTRAS" = 0 ] || return 0
  [ "$DRY_RUN" = 0 ] || return 0
  if extras_current "$1" "${2:-}"; then return 0; fi
  ARCHIVE_VERSION="$1"; ARCHIVE_BUILD="$(clean_build "${2:-}")"
  step "$(t s_extras)" extras_step
  extras_report
  return 0
}
# the summary line for the extras (the warning with the cause is already there)
extras_report() {
  case "$EXTRAS_RESULT" in
    ok) say "  $BUL $(t s_extras_ok "$EXTRAS_COUNT" "$DATA_DIR")";;
    none) say "  $BUL $(t w_extras_none)";;
    failed) say "  $BUL $(t w_extras_todo "sudo bash install.sh --extras-only")";;
  esac
  return 0
}
# --extras-only: the extras of the installed release, nothing else is touched
cmd_extras() {
  banner; detect_installed
  [ "$INST_CP" = 1 ] || { say "  $(t extras_needs_cp)"; return 1; }
  component_from_installed; load_existing_ports
  local cbin curv curb; cbin="$(p "$BIN_DIR/toutwaf-cp")"; curv="$(installed_version "$cbin")"; curb="$(inst_build "$cbin" "$curv")"
  SRC_DIR=""; ARCHIVE_VERSION="$curv"; ARCHIVE_BUILD="$(clean_build "$curb")"
  if [ -z "$EXTRAS_LOCAL" ]; then
    resolve_release
    if [ "$RESOLVED_VERSION" != "$curv" ] || { [ -n "$CH_BUILD" ] && [ -n "$ARCHIVE_BUILD" ] && [ "$CH_BUILD" != "$ARCHIVE_BUILD" ]; }; then
      say "  $(paint "$YLW" "$WRM $(t extras_other_release "$(ver_short "$RESOLVED_VERSION" "$CH_BUILD")" "$(ver_short "$curv" "$curb")")")"; return 1
    fi
  else RESOLVED_VERSION=local; fi
  NO_EXTRAS=0
  step "$(t s_extras)" extras_step
  extras_report
  [ "$EXTRAS_RESULT" = ok ]
}

# ------------------------------------------------------------------------------------------------ system setup
create_user() {
  [ "$STAGING" = 1 ] && return 0
  local NOLOGIN; NOLOGIN="$(command -v nologin 2>/dev/null || true)"
  [ -x "$NOLOGIN" ] || { for NOLOGIN in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/false; do [ -x "$NOLOGIN" ] && break; done; }
  # The system group is also what lets `toutwafctl` sign in locally without a password: its members (added by the administrator with
  # `usermod -aG toutwaf USER`, never by this installer) may open <data>/ctl.sock. Each machine has its own group.
  getent group "$SVC_USER" >/dev/null || run groupadd --system "$SVC_USER"
  id "$SVC_USER" >/dev/null 2>&1 || run useradd --system --gid "$SVC_USER" --home-dir "$DATA_DIR" --no-create-home --shell "$NOLOGIN" --comment "ToutWAF service account" "$SVC_USER"
}

make_dirs() {
  local d par
  if [ "$LAYOUT" = home ]; then
    # the parent of the home (/var by default, or whatever --home names) is created only when absent and never modified when it exists
    par="${HOME_DIR%/*}"; [ -n "$par" ] || par=/
    [ -d "$(p "$par")" ] || run install -d -m 0755 "$(p "$par")"
    if [ ! -d "$(p "$HOME_DIR")" ]; then run install -d -m 0755 "$(p "$HOME_DIR")"; fi
    run install -d -m 0755 "$(p "$BIN_DIR")"
    check_noexec "$(p "$BIN_DIR")"
    write_layout_file
  fi
  run install -d -m 0750 -o "$([ "$STAGING" = 1 ] && id -un || echo root)" -g "$([ "$STAGING" = 1 ] && id -gn || echo "$SVC_USER")" "$(p "$CONF_DIR")" "$(p "$CONF_DIR/certs")"
  for d in "$DATA_DIR" "$LOG_DIR" "$DATA_DIR/certs" "$DATA_DIR/spool" "$DATA_DIR/backup"; do
    run install -d -m 0750 -o "$([ "$STAGING" = 1 ] && id -un || echo "$SVC_USER")" -g "$([ "$STAGING" = 1 ] && id -gn || echo "$SVC_USER")" "$(p "$d")"
  done
}

# refuse a directory on a noexec mount: the binaries could not start from there
check_noexec() {
  [ "$STAGING" = 1 ] && return 0
  have findmnt || return 0
  findmnt -no OPTIONS -T "$1" 2>/dev/null | tr ',' '\n' | grep -qx noexec && die "$(t home_noexec "$1")"
  return 0
}
# sudo's secure_path, as the sudoers files set it ("" when none is set: sudo then keeps the PATH of the caller). RHEL, AlmaLinux and Rocky
# replace PATH by /sbin:/bin:/usr/sbin:/usr/bin, which does not hold /usr/local/bin: `sudo toutwafctl` then fails with "command not found".
sudo_secure_path() {
  local f v sp=""
  for f in "$(p /etc/sudoers)" "$(p /etc/sudoers.d)"/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    v="$(sed -n 's/^[[:space:]]*Defaults[^#]*secure_path[[:space:]]*=[[:space:]]*"\{0,1\}\([^"#[:space:]]*\).*/\1/p' "$f" 2>/dev/null | tail -n 1)"
    [ -z "$v" ] || sp="$v"
  done
  printf '%s' "$sp"
}
# the directory of that secure_path the CLIs are linked into: /usr/local/bin when it is listed, else /usr/bin ("" when sudo has none)
secure_link_dir() {
  local sp d; sp="$(sudo_secure_path)"; [ -n "$sp" ] || return 0
  for d in /usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
    case ":$sp:" in *":$d:"*) if [ "$d" = /usr/local/bin ] || [ -d "$(p "$d")" ]; then printf '%s' "$d"; return 0; fi;; esac
  done
  return 0
}
# the CLIs stay on PATH when the binaries live under HOME, and on the PATH sudo uses (secure_path): the commands work with `sudo`
link_cli() {
  local b l d dirs="" sd; sd="$(secure_link_dir)"
  [ "$BIN_DIR" = /usr/local/bin ] || dirs=/usr/local/bin
  if [ -n "$sd" ] && [ "$sd" != "$BIN_DIR" ] && [ "$sd" != /usr/local/bin ]; then dirs="$dirs $sd"; fi
  for d in $dirs; do
    run install -d -m 0755 "$(p "$d")"
    for b in toutwafctl toutwaf-cp toutwaf-dp toutwaf-upgrade toutwaf-firewall toutwaf-blocklist toutwaf-vpn toutwaf-fw toutwaf-jobs; do
      [ -e "$(p "$BIN_DIR/$b")" ] || continue
      l="$(p "$d/$b")"
      if [ -L "$l" ] || [ ! -e "$l" ]; then run ln -sfn "$BIN_DIR/$b" "$l"; fi
    done
  done
  return 0
}
install_binary() {    # name ; returns 1 when already up to date
  local name="$1" src="$SRC_DIR/$1" dst; dst="$(p "$BIN_DIR/$name")"
  [ -e "$src" ] || { [ "$DRY_RUN" = 1 ] && return 0; die "$name missing from the release"; }
  if [ -x "$dst" ] && [ "$FORCE" = 0 ] && same_file "$src" "$dst"; then info "$name already up to date"; return 1; fi
  run install -d -m 0755 "$(p "$BIN_DIR")" || die "cannot create $BIN_DIR"
  if [ -x "$dst" ]; then run cp -p "$dst" "$dst.prev"; fi            # rollback copy
  { run install -m 0755 "$src" "$dst.new" && run mv -f "$dst.new" "$dst"; } || die "cannot install $dst"   # atomic replace
  info "installed $dst"
  return 0
}

write_if_absent() {   # dest mode owner:group  (content on stdin)
  local dest="$1" mode="$2" own="$3"
  if [ -e "$dest" ]; then cat >"$dest.dist"; chmod "$mode" "$dest.dist"; if [ "$STAGING" = 0 ]; then chown "$own" "$dest.dist"; fi; info "keeping existing $dest (new defaults in $(basename "$dest").dist)"; return 0; fi
  cat >"$dest"; chmod "$mode" "$dest"; if [ "$STAGING" = 0 ]; then chown "$own" "$dest"; fi
  return 0
}

dp_config() {
  local dest fresh=0; dest="$(p "$CONF_DIR/toutwaf-dp.yaml")"
  [ "$DRY_RUN" = 1 ] && return 0
  [ -e "$dest" ] || fresh=1
  {
    cat <<EOF
# ToutWAF data plane - node configuration (full reference: toutwaf-dp print-config)
group: ${NODE_GROUP:-default}
data_dir: $DATA_DIR
certs_dir: $DATA_DIR/certs
listen:
  http: ["0.0.0.0:$HTTP_PORT"]
  https: ["0.0.0.0:$HTTPS_PORT"]
  # proxy_protocol: optional      # when behind a TCP load balancer sending PROXY protocol
admin:
  listen: 127.0.0.1:9101          # /healthz /metrics /status /debug/inspect (loopback only)
tls:
  profile: intermediate           # modern = TLS 1.3 only
events:
  spool_dir: $DATA_DIR/spool
logging:
  level: info
  json: true
security:
  no_new_privs: true
EOF
    if [ -n "$CP_URL" ]; then
      echo "control_plane:"; echo "  url: $CP_URL"
      [ -n "$NODE_TOKEN" ] && echo "  token: $NODE_TOKEN"
      [ -n "$ENROLL_TOKEN" ] && echo "  enroll_token: $ENROLL_TOKEN"
      if [ -n "$CP_CA" ]; then echo "  ca_file: $CONF_DIR/certs/cp-ca.pem"
      elif [[ "$CP_URL" =~ ^https://(127\.0\.0\.1|localhost|\[::1\])[:/] ]]; then echo "  ca_file: $DATA_DIR/tls/console.crt   # the local control plane's own certificate"; fi
      echo "  update_hook: [\"$BIN_DIR/toutwaf-upgrade\"]"
    else
      echo "# Standalone mode: serve the applications described in a local policy file (hot reloaded)."
      echo "policy_file: $CONF_DIR/policy.yaml"
    fi
  } | write_if_absent "$dest" 0640 "root:$SVC_USER"
  if [ -n "$CP_CA" ] && [ -n "$CP_URL" ]; then
    case "$CP_CA" in http://*|https://*) fetch "$CP_CA" "$(p "$CONF_DIR/certs/cp-ca.pem")";; *) [ -f "$CP_CA" ] || die "--cp-ca: file not found: $CP_CA"; cp "$CP_CA" "$(p "$CONF_DIR/certs/cp-ca.pem")";; esac
    chmod 0640 "$(p "$CONF_DIR/certs/cp-ca.pem")"; if [ "$STAGING" = 0 ]; then chown "root:$SVC_USER" "$(p "$CONF_DIR/certs/cp-ca.pem")"; fi
  fi
  if [ "$fresh" = 1 ] && [ -z "$CP_URL" ] && [ ! -e "$(p "$CONF_DIR/policy.yaml")" ]; then
    cat <<'EOF' | write_if_absent "$(p "$CONF_DIR/policy.yaml")" 0640 "root:$SVC_USER"
# Local policy (standalone mode). Edit and save: the data plane reloads it within 2 seconds, no restart.
version: 1
node_group: default
apps:
  - id: example
    name: Example application
    hostnames: [example.com, www.example.com]
    origins:
      - url: http://127.0.0.1:8080
    mode: detect              # detect first, then block once the false positives are reviewed
    settings:
      # No TLS certificate is installed yet (place one under certs_dir or configure ACME / the control plane), so do not
      # redirect plain HTTP to an HTTPS listener that cannot complete a handshake. Remove these once HTTPS works.
      REDIRECT_HTTP_TO_HTTPS: false
      HSTS: false
EOF
  fi
  return 0
}

cp_config() {
  [ "$DRY_RUN" = 1 ] && return 0
  local pubhost="${PUBLIC_HOST:-$(fqdn)}"
  cat <<EOF | write_if_absent "$(p "$CONF_DIR/toutwaf-cp.yaml")" 0640 "root:$SVC_USER"
# ToutWAF control plane
data_dir: $DATA_DIR
public_url: https://$pubhost:$CP_PORT
listen:
  console: ":$CP_PORT"
  dp: ":9444"
# TLS: without tls.cert / tls.key the control plane generates (and renews) a self-signed certificate in
# $DATA_DIR/tls. To use your own certificate, copy it to $CONF_DIR/certs and uncomment:
# tls:
#   cert: $CONF_DIR/certs/console.crt
#   key: $CONF_DIR/certs/console.key
$(db_yaml)
dataplane:
  inspect_url: http://127.0.0.1:9101/debug/inspect
  # public ports of the data plane on this machine: what the Docteur ToutWAF and the configuration assistant check
  http_port: $HTTP_PORT
  https_port: $HTTPS_PORT
# Telemetry to the publisher space (app.toutwaf.com): the attacks ToutWAF blocked and aggregate figures, never the content of requests nor
# legitimate visitors. ON by default; "enabled: false" starts with zero telemetry. Once an administrator saved the choice in the console
# (Settings > Privacy and telemetry), the console wins over this file. Details: docs/confidentialite-telemetrie.md
telemetry:
  enabled: $([ "$NO_TELEMETRY" = 1 ] && echo false || echo true)
EOF
  cat <<EOF | write_if_absent "$(p "$CONF_DIR/cp.env")" 0640 "root:$SVC_USER"
# Extra command-line arguments and environment for toutwaf-cp (see https://github.com/$REPO)
TOUTWAF_CP_ARGS=--config $CONF_DIR/toutwaf-cp.yaml
EOF
  return 0
}

# systemd ignores (with a warning) directives it does not know; older releases (RHEL 8 / Rocky 8 / Alma 8: 239) lack the newer
# sandboxing options. sd_opt MINVER LINE prints the line only when the running systemd is at least MINVER (or its version is unknown).
SD_VER=""
sd_opt() {
  if [ -z "$SD_VER" ]; then SD_VER="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}')"; [[ "$SD_VER" =~ ^[0-9]+$ ]] || SD_VER=999; fi
  if [ "$SD_VER" -ge "$1" ]; then printf '%s\n' "$2"; else printf '# %s (needs systemd >= %s, running %s)\n' "$2" "$1" "$SD_VER"; fi
}
# StateDirectory= / LogsDirectory= make systemd create /var/lib/toutwaf and /var/log/toutwaf: only wanted for the legacy locations
state_dir_lines() {
  if [ "$DATA_DIR" = /var/lib/toutwaf ]; then printf 'StateDirectory=toutwaf\nStateDirectoryMode=0750\n'; fi
  if [ "$LOG_DIR" = /var/log/toutwaf ]; then printf 'LogsDirectory=toutwaf\nLogsDirectoryMode=0750\n'; fi
}
write_units() {
  [ "$DRY_RUN" = 1 ] && return 0
  local sd; sd="$(p /etc/systemd/system)"; mkdir -p "$sd"
  if want_dp; then
    cat >"$sd/toutwaf-dp.service" <<EOF
[Unit]
Description=ToutWAF data plane (reverse proxy / WAAP)
Documentation=https://github.com/$REPO
After=network-online.target$(if want_cp || [ "${INST_CP:-0}" = 1 ]; then printf ' toutwaf-cp.service'; fi)
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=main
User=$SVC_USER
Group=$SVC_USER
ExecStartPre=$BIN_DIR/toutwaf-dp --config $CONF_DIR/toutwaf-dp.yaml check-config
ExecStart=$BIN_DIR/toutwaf-dp --config $CONF_DIR/toutwaf-dp.yaml run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=1s
TimeoutStopSec=40s
WatchdogSec=60s
LimitNOFILE=1048576
TasksMax=infinity
Environment=RUST_BACKTRACE=1
# --- sandboxing -----------------------------------------------------------------------------
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
$(sd_opt 244 ProtectKernelLogs=yes)
ProtectControlGroups=yes
$(sd_opt 245 ProtectClock=yes)
$(sd_opt 242 ProtectHostname=yes)
$(sd_opt 247 ProtectProc=invisible)
$(sd_opt 247 ProcSubset=pid)
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
RemoveIPC=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @swap @reboot @raw-io @obsolete @debug @cpu-emulation @clock
UMask=0027
ReadWritePaths=$DATA_DIR $LOG_DIR
ReadOnlyPaths=$CONF_DIR
$(state_dir_lines)

[Install]
WantedBy=multi-user.target
EOF
  fi
  if want_cp; then
    cat >"$sd/toutwaf-cp.service" <<EOF
[Unit]
Description=ToutWAF control plane (API, console, policy distribution)
Documentation=https://github.com/$REPO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=-$CONF_DIR/cp.env
ExecStart=$BIN_DIR/toutwaf-cp \$TOUTWAF_CP_ARGS
Restart=always
RestartSec=2s
TimeoutStopSec=180s
LimitNOFILE=262144
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
$(sd_opt 244 ProtectKernelLogs=yes)
ProtectControlGroups=yes
$(sd_opt 245 ProtectClock=yes)
$(sd_opt 242 ProtectHostname=yes)
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
# AF_NETLINK: Go lists the network interfaces through netlink. Without it the console cannot list the addresses of this machine (only the
# public link is shown), the Doctor cannot tell which addresses are this machine's, and the certificate of the console misses its IP address.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @swap @reboot @raw-io @obsolete @debug @cpu-emulation @clock
UMask=0027
ReadWritePaths=$DATA_DIR $LOG_DIR
ReadOnlyPaths=$CONF_DIR
$(state_dir_lines)

[Install]
WantedBy=multi-user.target
EOF
  fi
  mkdir -p "$(p /usr/lib/sysusers.d)" "$(p /usr/lib/tmpfiles.d)" "$(p /etc/logrotate.d)"
  printf 'u toutwaf - "ToutWAF service account" %s /usr/sbin/nologin\n' "$DATA_DIR" >"$(p /usr/lib/sysusers.d/toutwaf.conf)"
  printf 'd %s 0750 toutwaf toutwaf -\nd %s 0750 toutwaf toutwaf -\n' "$DATA_DIR" "$LOG_DIR" >"$(p /usr/lib/tmpfiles.d/toutwaf.conf)"
  cat >"$(p /etc/logrotate.d/toutwaf)" <<EOF
$LOG_DIR/*.log $LOG_DIR/*.ndjson {
    daily
    rotate 14
    maxsize 500M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su $SVC_USER $SVC_USER
    create 0640 $SVC_USER $SVC_USER
}
EOF
  if want_dp || want_cp; then write_helpers "$sd"; fi
  return 0
}

# ------------------------------------------------------------------------------------------------ root helpers
# toutwaf-cp and toutwaf-dp run as the unprivileged `toutwaf` user in a read-only sandbox, so they cannot upgrade anything or touch
# the firewall. Each action goes through a small root helper that is started by a systemd path unit when the service account drops
# a request file into $DATA_DIR, validates every value again, does the work and writes a status file the control plane reads back:
#   toutwaf-upgrade   download + verify + install a release, health check, automatic rollback  (console: Updates; DP: update_engine)
#   toutwaf-firewall  open the ports ToutWAF needs in firewalld / ufw                            (console: Settings > Firewall; this installer)
#   toutwaf-blocklist put the large blocklists into the kernel (nftables, one table of its own)  (console: Lists > Kernel blocking)
#   toutwaf-vpn       put the files of the VPN module on the machine, start / stop the tunnels, read their state (console: VPN)
#   toutwaf-fw        load the nftables rules of the Firewall module with a root rollback timer, read them back (console: Firewall)
#   toutwaf-jobs      run the privileged jobs of the scheduled tasks: a FIXED list (log rotation, journal vacuum; the power menu and self-repair verbs), no command from the request (console: Scheduled tasks, power menu)
# The scripts carry a "toutwaf-<name>-proto: N" marker that the control plane checks before offering the button.
emit_helper() {   # NAME  (template on stdin)
  local dst tmp; dst="$(p "$BIN_DIR/$1")"; tmp="$dst.new"
  sed -e "s#@DATA_DIR@#$DATA_DIR#g" -e "s#@CONF_DIR@#$CONF_DIR#g" -e "s#@BIN_DIR@#$BIN_DIR#g" -e "s#@REPO@#$REPO#g" -e "s#@SVC_USER@#$SVC_USER#g" >"$tmp"
  chmod 0755 "$tmp"; mv -f "$tmp" "$dst"   # new inode: a helper that is running right now (it is updating us) keeps reading its old copy
}
write_helpers() {
  local sd="$1"
  emit_helper toutwaf-upgrade <<'TW_UPGRADE_TPL'
#!/usr/bin/env bash
# toutwaf-upgrade-proto: 2
#
# toutwaf-upgrade request   (called by toutwaf-dp with TW_DESIRED_ENGINE_VERSION) record a data-plane upgrade request
# toutwaf-upgrade apply     (root; called by toutwaf-upgrade.service) perform the pending request
# toutwaf-upgrade recover   (root; called by toutwaf-upgrade-guard.service at boot) finish or undo an update that was interrupted
#
# The control plane (user toutwaf, read-only sandbox) and the data plane cannot upgrade anything themselves: they only write
# @DATA_DIR@/upgrade-request (KEY=VALUE). toutwaf-upgrade.path notices it and starts toutwaf-upgrade.service, which runs
# this script as root. Everything in the request file is untrusted input here and is validated again, key by key.
# Progress and the outcome are written to @DATA_DIR@/upgrade-status (STATE=queued|running|succeeded|failed|rolled_back)
# and @DATA_DIR@/upgrade.log, which the control plane reads back (also after its own restart).
#
# `apply` hands the update to `toutwafctl upgrade-host apply` (docs/design/update-resilience.md): that program copies itself to a
# root-only versioned directory and runs from the copy, downloads and verifies everything (Ed25519 signature, SHA-256, disk space,
# compatibility, the new programs start, the database migration works on a copy) BEFORE it stops or replaces anything, saves the
# current version, arms a transient systemd timer that rolls back by itself, runs the installer, watches the health for a
# configurable window (5 minutes) and rolls back when it fails. This script is only the entry point and, for an installation whose
# toutwafctl predates `upgrade-host` (the first update after the feature arrives), the fallback below: the former behaviour, but with
# bounded steps, a heartbeat, the sources of install.sh (GitLab first, GitHub next, the direct address of upgrade.conf last) and a
# status that can never be left at "running".
set -uo pipefail
# `set -u` makes an unbound variable fatal, and a helper that dies of it, silently, leaves the console waiting for an update that never
# runs (the incident that led to this block). So: every variable this script reads is given a value right here, before anything else; the
# exit trap (on_exit) turns ANY exit that comes without an outcome into a "failed" status with the reason, and jlog writes one line to the
# journal for every failure. deploy/tests/upgrade-helper-test.sh runs the fallback with a fake environment and with a variable made unbound.
exec 3>&2   # the journal: the standard error the service was started with, kept apart from the one captured below
DATA_DIR='@DATA_DIR@'; CONF_DIR='@CONF_DIR@'; BIN_DIR='@BIN_DIR@'; REPO='@REPO@'; SVC_USER='@SVC_USER@'
comp=""; chan=""; ver=""; xonly=""; dg=0; job=""; trc=0; rc=0; got=0; base=""; direct=""; br=main; tmp=""; v=""; url=""; l=""; msg=""
urls=(); args=(); to=()
errf=""; TOOK=0; LAST_ERR=""
STATE_DIR="${DATA_DIR}-upgrade"
REQ="$DATA_DIR/upgrade-request"; STATUS="$DATA_DIR/upgrade-status"; LOGF="$DATA_DIR/upgrade.log"; INSTLOG="$DATA_DIR/upgrade-installer.log"
CTL="$BIN_DIR/toutwafctl"
# the download sources, as in install.sh
SRC_PRIMARY="${TOUTWAF_SRC_PRIMARY:-https://repo.qu3ntin.com/toutwaf/toutwaf/-/raw}"; SRC_FALLBACK="https://raw.githubusercontent.com/$REPO"
if [ -n "${TOUTWAF_REPO:-}" ]; then SRC_PRIMARY="$SRC_FALLBACK"; SRC_FALLBACK=""; fi
# the service account owns $DATA_DIR and can swap any name in it at any moment: root reads its request and writes its answers only through these
# >>> hostio: how root touches the files of the service account (deploy/helpers/hostio.sh; deploy/tests/hostio-test.sh checks the copies) >>>
# The account owns the data directory and can change any name in it at any moment: a link to a file of root, a FIFO that holds
# root in open(2) for ever, a file with a second name. Nothing it wrote is opened without O_NOFOLLOW | O_NONBLOCK or judged by a
# path that is opened later; nothing of root's is written through a path it could have swapped (no chown/chmod by path).
_dd_nofollow() {   # 0 when dd can open with iflag=nofollow,nonblock (GNU dd; not busybox)
  [ -n "${_DD_NF:-}" ] || { dd iflag=nofollow,nonblock if=/dev/null of=/dev/null count=0 2>/dev/null && _DD_NF=1 || _DD_NF=0; }
  [ "$_DD_NF" = 1 ]
}
_bounded() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }
# copy_safe SRC DST MAX   0: DST holds a copy of SRC; 1: SRC does not exist; 2: refused. SRC must be a regular file (no link, no FIFO,
# no device) with one name, owned by the owner of its directory, that nobody else can write, of at most MAX bytes, and unchanged
# while it was read. DST is a file of root's.
copy_safe() {
  local src="$1" dst="$2" max="$3" dir m1 m2 type uid nlink mode size
  [ -e "$src" ] || [ -L "$src" ] || return 1
  dir="$(dirname -- "$src")"
  m1="$(stat -c '%F|%u|%h|%a|%s|%i|%Y' -- "$src" 2>/dev/null)" || return 2
  IFS='|' read -r type uid nlink mode size _ <<<"$m1"
  case "$type" in "regular file"|"regular empty file") ;; *) return 2;; esac
  [ "$uid" = "$(stat -c %u -- "$dir" 2>/dev/null)" ] && [ "$nlink" = 1 ] || return 2
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$max" ] && [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 2
  if _dd_nofollow; then
    _bounded 10 dd if="$src" of="$dst" iflag=nofollow,nonblock bs=65536 count=$(( max / 65536 + 2 )) 2>/dev/null || { rm -f -- "$dst"; return 2; }
  else
    _bounded 10 cat -- "$src" >"$dst" 2>/dev/null || { rm -f -- "$dst"; return 2; }
  fi
  m2="$(stat -c '%F|%u|%h|%a|%s|%i|%Y' -- "$src" 2>/dev/null)"
  if [ "$m1" != "$m2" ] || [ ! -f "$dst" ] || [ -L "$dst" ] || [ "$(stat -c %s -- "$dst" 2>/dev/null || echo 999999999999)" -gt "$max" ]; then rm -f -- "$dst"; return 2; fi
  return 0
}
# take_request SRC DST MAX: copy_safe, then SRC is removed whatever the answer (a request left in place would start the helper again
# and again). 0: DST holds the request; 1: there was none; 2: refused.
take_request() {
  local rc
  copy_safe "$1" "$2" "$3"; rc=$?
  [ "$rc" -eq 1 ] || rm -f -- "$1"
  return "$rc"
}
# put_file DEST: stdin becomes DEST, mode 0644, owned by root: a new file under a random name (noclobber: O_EXCL), renamed over
# DEST. A link at DEST is replaced, never written through. The account only reads these files.
put_file() {
  local dest="$1" tmp
  tmp="$(mktemp -u -- "$dest.XXXXXX")" || return 1
  ( umask 022; set -C; cat >"$tmp" ) 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -fT -- "$tmp" "$dest" 2>/dev/null || { [ -L "$dest" ] && rm -f -- "$dest"; mv -f -- "$tmp" "$dest"; } || { rm -f -- "$tmp"; return 1; }
}
# <<< hostio <<<

valid_version() { [[ "${1:-}" == latest ]] || [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]{0,40})?$ ]]; }
valid_channel() { [[ "${1:-}" == stable || "${1:-}" == dev ]]; }
valid_comp()    { [[ "${1:-}" == all || "${1:-}" == cp || "${1:-}" == dp ]]; }
valid_job()     { [[ -z "${1:-}" || "${1:-}" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
req_get() { sed -n "s/^${1:-}=//p" "${priv:-/dev/null}" 2>/dev/null | tail -n1 | tr -d '\r'; }
conf_get() { sed -n "s/^${1:-}=//p" "$CONF_DIR/installer.conf" 2>/dev/null | head -n1 | tr -d '\r"'"'"; }
uconf_get() { sed -n "s/^${1:-}=//p" "$CONF_DIR/upgrade.conf" 2>/dev/null | head -n1 | tr -d '\r"'"'"; }
# jlog MESSAGE: one line in the journal for every failure (the service's standard error goes there; a run by hand gets syslog)
jlog() {
  printf 'toutwaf-upgrade: %s\n' "$*" >&3 2>/dev/null || printf 'toutwaf-upgrade: %s\n' "$*"
  if [ -z "${JOURNAL_STREAM:-}" ] && command -v logger >/dev/null 2>&1; then logger -t toutwaf-upgrade -p daemon.err -- "$*" 2>/dev/null || true; fi
}
# the resilient implementation is there when the installed toutwafctl answers its self-test
have_host() { [ -x "$CTL" ] && "$CTL" upgrade-host selftest 2>/dev/null | grep -qx 'toutwaf-upgrade-host 1'; }

S_STATE=""; S_PHASE=""; S_CHANNEL=""; S_FROM=""; S_TO=""; S_FROM_BUILD=""; S_TO_BUILD=""; S_JOB=""; S_MSG=""; S_STARTED=""; S_FINISHED=""
FINAL=0; BEAT_PID=""; inst=""; out=""; priv=""; plogf=""; pinst=""
# the status is a new file of root's renamed over the old name (put_file): a link left there by the service account is replaced, never followed
write_status() {
  { printf 'STATE=%s\nPHASE=%s\nCHANNEL=%s\nFROM=%s\nTO=%s\nFROM_BUILD=%s\nTO_BUILD=%s\nJOB=%s\nSTARTED=%s\nFINISHED=%s\nHEARTBEAT=%s\n' "$S_STATE" "$S_PHASE" "$S_CHANNEL" "$S_FROM" "$S_TO" "$S_FROM_BUILD" "$S_TO_BUILD" "$S_JOB" "$S_STARTED" "$S_FINISHED" "$(date +%s)"
    printf 'MESSAGE=%s\n' "$(printf '%s' "$S_MSG" | tr -d '\000-\037' | cut -c1-300)"; } | put_file "$STATUS" || true
}
# the log is kept in a private file of root's and published (a new file renamed over $LOGF) after every line: nothing is appended through a name of the account
plog() { [ -n "$plogf" ] || return 0; printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$plogf"; put_file "$LOGF" <"$plogf" 2>/dev/null || true; }
cur_version() {
  local v=""
  if [ -x "$BIN_DIR/toutwaf-cp" ]; then v="$("$BIN_DIR/toutwaf-cp" version 2>/dev/null | awk 'NR==1{print $2}')"; fi
  if [ -z "$v" ] && [ -x "$BIN_DIR/toutwaf-dp" ]; then v="$("$BIN_DIR/toutwaf-dp" --version 2>/dev/null | awk 'NR==1{print $2}')"; fi
  printf '%s' "$v"
}
# the build of what is installed ("unknown" when the binaries name none): the version keeps one name between two publications of the dev channel
cur_build() {
  local b=""
  if [ -x "$BIN_DIR/toutwaf-cp" ]; then b="$("$BIN_DIR/toutwaf-cp" version 2>/dev/null | sed -n 's/.*(build \([^) ]*\)).*/\1/p' | head -n1)"; fi
  if [ -z "$b" ] && [ -x "$BIN_DIR/toutwaf-dp" ]; then b="$("$BIN_DIR/toutwaf-dp" --version 2>/dev/null | sed -n 's/.*(build \([^) ]*\)).*/\1/p' | head -n1)"; fi
  printf '%s' "${b:-unknown}"
}
fail() {   # message
  S_STATE=failed; S_PHASE=Failed; S_MSG="${1:-the update failed}"; S_FINISHED="$(date +%s)"; FINAL=1; write_status; plog "ERROR $S_MSG"; jlog "ERROR $S_MSG"; exit 1
}
# whatever happens, the update never ends without an outcome: once the request is taken, ANY exit that comes before the final status (a signal, an
# unbound variable, a command that failed in a way nobody foresaw) writes "failed" with the reason, in the status the console reads and in the
# journal. A SIGKILL is covered by the heartbeat: the console treats a status that stops beating as dead after a few minutes.
on_exit() {
  local rc=$?
  trap - EXIT
  [ -z "${BEAT_PID:-}" ] || kill "$BEAT_PID" 2>/dev/null
  if [ "$FINAL" = 0 ] && [ "$TOOK" = 1 ]; then
    if [ -n "$errf" ] && [ -s "$errf" ]; then LAST_ERR="$(tail -n 1 "$errf" 2>/dev/null | tr -d '\000-\037' | cut -c1-200)"; fi
    S_STATE=failed; S_PHASE=Failed; S_FINISHED="$(date +%s)"
    [ -n "$S_MSG" ] || S_MSG="the update helper stopped unexpectedly (exit $rc${LAST_ERR:+: $LAST_ERR}): see 'journalctl -u toutwaf-upgrade'"
    write_status; plog "ERROR $S_MSG"; jlog "ERROR $S_MSG"
  fi
  if [ -n "$errf" ]; then   # what the script itself printed to its standard error goes to the journal now
    if [ -s "$errf" ]; then cat "$errf" >&3 2>/dev/null; fi
    rm -f "$errf"
  fi
  [ -z "$inst" ] || rm -f "$inst"
  [ -z "$out" ] || rm -f "$out"
  [ -z "$priv" ] || rm -f "$priv"
  [ -z "$plogf" ] || rm -f "$plogf"
  [ -z "$pinst" ] || rm -f "$pinst"
}
trap on_exit EXIT

case "${1:-request}" in
  request)
    v="${TW_DESIRED_ENGINE_VERSION:-latest}"; [ -n "$v" ] || v=latest
    valid_version "$v" || { jlog "ERROR request refused: invalid version '$v'"; echo "toutwaf-upgrade: invalid version '$v'" >&2; exit 1; }
    tmp="$(mktemp "$REQ.XXXXXX")" || { jlog "ERROR request not recorded: cannot create a file next to $REQ"; exit 1; }
    printf 'PROTO=2\nCOMPONENT=dp\nCHANNEL=%s\nVERSION=%s\nALLOW_DOWNGRADE=0\nJOB=\n' "$(conf_get CHANNEL | grep -x -e stable -e dev || echo stable)" "$v" >"$tmp"
    mv -f "$tmp" "$REQ" || { jlog "ERROR request not recorded: cannot move $tmp to $REQ"; rm -f "$tmp"; exit 1; }
    echo "toutwaf-upgrade: upgrade to $v requested (applied by toutwaf-upgrade.service)";;
  recover)
    [ "$(id -u)" -eq 0 ] || { jlog "ERROR recover refused: must run as root"; echo "toutwaf-upgrade recover must run as root" >&2; exit 1; }
    have_host || exit 0
    exec "$CTL" upgrade-host recover --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" --bin-dir "$BIN_DIR" --state-dir "$STATE_DIR" --svc-user "$SVC_USER";;
  apply)
    [ "$(id -u)" -eq 0 ] || { jlog "ERROR apply refused: must run as root"; echo "toutwaf-upgrade apply must run as root" >&2; exit 1; }
    [ -e "$REQ" ] || [ -L "$REQ" ] || exit 0
    # the resilient path: the request file is read (and consumed) by the Go program, from its staged copy
    if have_host; then
      exec "$CTL" upgrade-host apply --data-dir "$DATA_DIR" --conf-dir "$CONF_DIR" --bin-dir "$BIN_DIR" --state-dir "$STATE_DIR" --svc-user "$SVC_USER"
    fi
    # ---- the fallback: this installation's toutwafctl does not know `upgrade-host` yet
    errf="$(mktemp)" && exec 2>>"$errf"   # from here the shell's own complaints (an unbound variable...) are kept and reach the journal and the status
    priv="$(mktemp)"; plogf="$(mktemp)"; pinst="$(mktemp)"
    if [ -z "$priv" ] || [ -z "$plogf" ] || [ -z "$pinst" ]; then jlog "ERROR cannot create temporary files (disk full?)"; exit 1; fi
    # the request is copied by copy_safe (a regular file of the account, one name, nobody else can write it, at most 4 KiB, no link, no FIFO) and removed
    take_request "$REQ" "$priv" 4096; trc=$?
    [ "$trc" -ne 1 ] || exit 0
    # from here on the console is waiting for an outcome: whatever stops this script, on_exit writes it
    TOOK=1; S_STARTED="$(date +%s)"; S_STATE=running; S_PHASE="Checking the request"
    if [ "$trc" -eq 0 ]; then S_JOB="$(req_get JOB)"; valid_job "$S_JOB" || S_JOB=""; fi
    if [ "$trc" -ne 0 ]; then S_JOB=""; fail "invalid update request"; fi
    # legacy request (protocol 1): one line holding the version
    if grep -q '=' "$priv"; then
      comp="$(req_get COMPONENT)"; chan="$(req_get CHANNEL)"; ver="$(req_get VERSION)"; dg="$(req_get ALLOW_DOWNGRADE)"; job="$(req_get JOB)"
    else
      ver="$(head -n1 "$priv" | tr -d '\r')"; comp=dp; chan="$(conf_get CHANNEL)"; dg=0; job=""
    fi
    : >"$plogf"; : >"$pinst"; put_file "$LOGF" </dev/null; put_file "$INSTLOG" </dev/null
    S_JOB="$job"; S_CHANNEL="$chan"; S_TO="$ver"; S_FROM="$(cur_version)"; S_FROM_BUILD="$(cur_build)"; S_STARTED="$(date +%s)"; S_STATE=running; S_PHASE="Checking the request"
    if ! { valid_comp "$comp" && valid_channel "$chan" && valid_version "$ver" && valid_job "$job"; }; then S_JOB=""; fail "invalid update request"; fi
    [ "$dg" = 1 ] || dg=0
    write_status
    # a heartbeat for as long as this helper lives, whatever the installer is doing
    ( while sleep 10; do touch -h "$STATUS" 2>/dev/null; [ -s "$pinst" ] && put_file "$INSTLOG" <"$pinst" 2>/dev/null; done ) & BEAT_PID=$!
    plog "update requested: component=$comp channel=$chan version=$ver downgrade_allowed=$dg (fallback helper: this toutwafctl has no upgrade-host)"
    br=main; [ "$chan" = dev ] && br=dev
    base="$(conf_get BASE_URL)"; case "$base" in http://*|https://*) ;; *) base="";; esac
    # the installer comes from the first source that answers: a mirror, or GitLab, then GitHub, then the direct address of upgrade.conf
    urls=()
    if [ -n "${TOUTWAF_INSTALLER_URL:-}" ]; then urls+=("$TOUTWAF_INSTALLER_URL")
    elif [ -n "$base" ]; then urls+=("$base/install.sh")
    else
      urls+=("$SRC_PRIMARY/$br/install.sh"); [ -z "$SRC_FALLBACK" ] || urls+=("$SRC_FALLBACK/$br/install.sh")
    fi
    direct="$(uconf_get DIRECT_URL)"; case "$direct" in http://*|https://*) urls+=("${direct%/}/install.sh");; esac
    inst="$(mktemp)"
    S_PHASE="Downloading the installer"; write_status
    got=0
    for url in "${urls[@]+"${urls[@]}"}"; do
      plog "$S_PHASE ($url)"
      if curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 -o "$inst" "$url" 2>>"$plogf" && head -c2 "$inst" | grep -q '^#!'; then got=1; break; fi
      plog "this source does not answer; trying the next one"
    done
    [ "$got" = 1 ] || fail "cannot download the installer from any source (${urls[*]+${urls[*]}}). Nothing was changed; check the network of this server or set DIRECT_URL in $CONF_DIR/upgrade.conf"
    # EXTRAS_ONLY=1: only the extras of the installed release (the Windows agents, the antivirus programs) are installed, nothing is replaced or restarted;
    # the installer downloads them, checks them against the signed SHA256SUMS like the archive, and installs them (install.sh --extras-only)
    xonly="$(req_get EXTRAS_ONLY)"
    if [ "$xonly" = 1 ]; then args=(--extras-only --component "$comp" --channel "$chan" --yes --no-color --quiet)
    else args=(--update --component "$comp" --channel "$chan" --yes --no-color --quiet); fi
    [ "$ver" = latest ] || args+=(--version "$ver")
    [ -z "$base" ] || args+=(--base-url "$base")
    [ "$dg" = 1 ] && args+=(--force)
    S_PHASE="Running the installer"; write_status
    out="$(mktemp)"
    to=(); command -v timeout >/dev/null 2>&1 && to=(timeout 1200)
    TOUTWAF_PROGRESS_FILE="$pinst" "${to[@]+"${to[@]}"}" bash "$inst" "${args[@]}" >"$out" 2>&1 </dev/null; rc=$?
    # the installer's own messages (errors, rollback notices) go to the log too
    sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' "$out" | grep -v '^[[:space:]]*$' | tail -n 40 | while IFS= read -r l; do plog "$l"; printf '%s\n' "$l" >>"$pinst"; done
    put_file "$INSTLOG" <"$pinst" 2>/dev/null || true
    S_TO="$(cur_version)"; [ -n "$S_TO" ] || S_TO="$ver"
    S_TO_BUILD="$(cur_build)"
    S_FINISHED="$(date +%s)"
    FINAL=1
    if [ "$rc" -eq 0 ]; then
      S_STATE=succeeded; S_PHASE="Done"; S_MSG=""; plog "update finished: now running ${S_TO} (build ${S_TO_BUILD})"
    else
      msg="$(sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' "$out" | grep -iE 'error|fail|did not|refus|downgrad|checksum|signature|withdrawn|yanked' | tail -n1 | sed 's/^[^[:alnum:]]*//')"
      [ "$rc" -ne 124 ] || msg="the installer did not finish within 20 minutes"
      S_MSG="${msg:-installer exited with status $rc}"
      if grep -qi 'rolled back to the previous version' "$out" "$plogf" 2>/dev/null; then S_STATE=rolled_back; else S_STATE=failed; fi
      S_PHASE="Failed"; plog "ERROR update failed (rc=$rc): $S_MSG"; jlog "ERROR update failed (rc=$rc): $S_MSG"
    fi
    write_status
    exit "$rc";;
  *) jlog "ERROR unknown command '${1:-}'"; echo "usage: toutwaf-upgrade [request|apply|recover]" >&2; exit 2;;
esac
TW_UPGRADE_TPL
  emit_helper toutwaf-firewall <<'TW_FIREWALL_TPL'
#!/usr/bin/env bash
# toutwaf-firewall-proto: 1
#
# toutwaf-firewall status                       scan the host firewall and write @DATA_DIR@/firewall-status
# toutwaf-firewall open [--dp 80,443] [--console PORT [--console-from CIDR]] [--agent PORT --agent-from CIDR]
#                                               open ports (installer, root)
# toutwaf-firewall apply                        (root; toutwaf-firewall.service) perform @DATA_DIR@/firewall-request
# toutwaf-firewall close                        remove every rule this helper added (uninstall)
# toutwaf-firewall print                        print the exact commands for this host
#
# Drives firewalld and ufw only. nftables-only and iptables-only hosts are never modified: the exact commands are printed and
# reported (RESULT=unmanaged). Only ports recorded by the installer in @CONF_DIR@/firewall.conf (root-owned) can be opened,
# only tcp, and only with a validated source network. The data-plane API port is never opened to everyone.
# Rules added here are remembered in @CONF_DIR@/firewall.managed so that `close` removes exactly those and nothing else.
set -uo pipefail
DATA_DIR='@DATA_DIR@'; CONF_DIR='@CONF_DIR@'; SVC_USER='@SVC_USER@'
REQ="$DATA_DIR/firewall-request"; STATUS="$DATA_DIR/firewall-status"; CONF="$CONF_DIR/firewall.conf"; MANAGED="$CONF_DIR/firewall.managed"
have() { command -v "$1" >/dev/null 2>&1; }
# firewalld_running: true only when the daemon is really up. "firewall-cmd --state" alone is not a safe probe: with firewalld installed but stopped it
# triggers D-Bus activation (starts the daemon as a side effect, or blocks ~50 s when it cannot start, e.g. in a container)
firewalld_running() {
  have firewall-cmd || return 1
  if [ -d /run/systemd/system ] && have systemctl; then systemctl is-active --quiet firewalld 2>/dev/null || return 1
  elif have pgrep; then pgrep -x firewalld >/dev/null 2>&1 || return 1; fi
  if have timeout; then timeout 20 firewall-cmd --state >/dev/null 2>&1; else firewall-cmd --state >/dev/null 2>&1; fi
}

# ---- validation (the request file is writable by the service account: never trust it) ------------------------------------
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_job()  { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
# a source is an IPv4/IPv6 address or CIDR, nothing else (no spaces, quotes, newlines: it ends up in a firewall rule)
valid_src()  {
  [[ "$1" =~ ^[0-9a-fA-F:.]{2,45}(/[0-9]{1,3})?$ ]] || return 1
  case "$1" in */0) return 1;; esac
  if [[ "$1" == *:* ]]; then [[ "$1" =~ ^[0-9a-fA-F:.]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]] && [[ "$1" == *:*:* || "$1" == ::* ]]
  else [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] && ! [[ "$1" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9][0-9])(\.|/|$) ]]; fi
}
fam() { [[ "$1" == *:* ]] && echo ipv6 || echo ipv4; }
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n1 | tr -d '\r"'"'"; }
in_list() { local x="$1"; shift; local i; for i in "$@"; do [ "$i" = "$x" ] && return 0; done; return 1; }
# >>> hostio: how root touches the files of the service account (deploy/helpers/hostio.sh; deploy/tests/hostio-test.sh checks the copies) >>>
# The account owns the data directory and can change any name in it at any moment: a link to a file of root, a FIFO that holds
# root in open(2) for ever, a file with a second name. Nothing it wrote is opened without O_NOFOLLOW | O_NONBLOCK or judged by a
# path that is opened later; nothing of root's is written through a path it could have swapped (no chown/chmod by path).
_dd_nofollow() {   # 0 when dd can open with iflag=nofollow,nonblock (GNU dd; not busybox)
  [ -n "${_DD_NF:-}" ] || { dd iflag=nofollow,nonblock if=/dev/null of=/dev/null count=0 2>/dev/null && _DD_NF=1 || _DD_NF=0; }
  [ "$_DD_NF" = 1 ]
}
_bounded() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }
# copy_safe SRC DST MAX   0: DST holds a copy of SRC; 1: SRC does not exist; 2: refused. SRC must be a regular file (no link, no FIFO,
# no device) with one name, owned by the owner of its directory, that nobody else can write, of at most MAX bytes, and unchanged
# while it was read. DST is a file of root's.
copy_safe() {
  local src="$1" dst="$2" max="$3" dir m1 m2 type uid nlink mode size
  [ -e "$src" ] || [ -L "$src" ] || return 1
  dir="$(dirname -- "$src")"
  m1="$(stat -c '%F|%u|%h|%a|%s|%i|%Y' -- "$src" 2>/dev/null)" || return 2
  IFS='|' read -r type uid nlink mode size _ <<<"$m1"
  case "$type" in "regular file"|"regular empty file") ;; *) return 2;; esac
  [ "$uid" = "$(stat -c %u -- "$dir" 2>/dev/null)" ] && [ "$nlink" = 1 ] || return 2
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$max" ] && [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 2
  if _dd_nofollow; then
    _bounded 10 dd if="$src" of="$dst" iflag=nofollow,nonblock bs=65536 count=$(( max / 65536 + 2 )) 2>/dev/null || { rm -f -- "$dst"; return 2; }
  else
    _bounded 10 cat -- "$src" >"$dst" 2>/dev/null || { rm -f -- "$dst"; return 2; }
  fi
  m2="$(stat -c '%F|%u|%h|%a|%s|%i|%Y' -- "$src" 2>/dev/null)"
  if [ "$m1" != "$m2" ] || [ ! -f "$dst" ] || [ -L "$dst" ] || [ "$(stat -c %s -- "$dst" 2>/dev/null || echo 999999999999)" -gt "$max" ]; then rm -f -- "$dst"; return 2; fi
  return 0
}
# take_request SRC DST MAX: copy_safe, then SRC is removed whatever the answer (a request left in place would start the helper again
# and again). 0: DST holds the request; 1: there was none; 2: refused.
take_request() {
  local rc
  copy_safe "$1" "$2" "$3"; rc=$?
  [ "$rc" -eq 1 ] || rm -f -- "$1"
  return "$rc"
}
# put_file DEST: stdin becomes DEST, mode 0644, owned by root: a new file under a random name (noclobber: O_EXCL), renamed over
# DEST. A link at DEST is replaced, never written through. The account only reads these files.
put_file() {
  local dest="$1" tmp
  tmp="$(mktemp -u -- "$dest.XXXXXX")" || return 1
  ( umask 022; set -C; cat >"$tmp" ) 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -fT -- "$tmp" "$dest" 2>/dev/null || { [ -L "$dest" ] && rm -f -- "$dest"; mv -f -- "$tmp" "$dest"; } || { rm -f -- "$tmp"; return 1; }
}
# <<< hostio <<<

CONF_DP=""; CONF_CONSOLE=""; CONF_AGENT=""
load_conf() {
  CONF_DP="$(conf_get DP_PORTS | tr ',' ' ')"; CONF_CONSOLE="$(conf_get CONSOLE_PORT)"; CONF_AGENT="$(conf_get AGENT_PORT)"
}

# ---- backend detection ------------------------------------------------------------------------------------------------------
BACKEND=none; ACTIVE=0; TOOLS=""
detect() {
  BACKEND=none; ACTIVE=0; TOOLS=""
  have firewall-cmd && TOOLS="$TOOLS,firewall-cmd"; have ufw && TOOLS="$TOOLS,ufw"; have nft && TOOLS="$TOOLS,nft"; have iptables && TOOLS="$TOOLS,iptables"
  TOOLS="${TOOLS#,}"
  if firewalld_running; then BACKEND=firewalld; ACTIVE=1
  elif have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then BACKEND=ufw; ACTIVE=1
  elif have nft && nft list ruleset 2>/dev/null | awk '/hook input/{h=1} h && (/policy drop/ || /(^|[ \t])(drop|reject)($|[ \t])/){f=1} END{exit !f}'; then BACKEND=nftables; ACTIVE=1
  elif have iptables && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|^-A INPUT .*-j (DROP|REJECT)'; then BACKEND=iptables; ACTIVE=1
  fi
}

# ---- what is open (only the ports ToutWAF cares about) -----------------------------------------------------------------------
all_ports() { echo $CONF_DP $CONF_CONSOLE $CONF_AGENT; }
OPEN=""
add_open() { OPEN="${OPEN:+$OPEN,}tcp:$1${2:+@$2}"; }
scan_open() {
  OPEN=""
  local p src ports spec
  case "$BACKEND" in
    firewalld)
      local lp svcs s
      lp=" $(firewall-cmd --list-ports 2>/dev/null | tr '\n' ' ') "
      svcs="$(firewall-cmd --list-services 2>/dev/null)"
      for s in $svcs; do lp="$lp $(firewall-cmd --permanent --service="$s" --get-ports 2>/dev/null | tr '\n' ' ') "; done
      for p in $(all_ports); do case "$lp" in *" $p/tcp "*) add_open "$p";; esac; done
      firewall-cmd --list-rich-rules 2>/dev/null | while IFS= read -r l; do
        src="$(printf '%s' "$l" | sed -n 's/.*source address="\([^"]*\)".*/\1/p')"; p="$(printf '%s' "$l" | sed -n 's/.* port="\([0-9]*\)".*/\1/p')"
        case "$l" in *'protocol="tcp"'*accept*) ;; *) continue;; esac
        [ -n "$src" ] && [ -n "$p" ] && valid_src "$src" && in_list "$p" $(all_ports) && echo "tcp:$p@$src"
      done >"$TMPOPEN"
      while IFS= read -r l; do OPEN="${OPEN:+$OPEN,}$l"; done <"$TMPOPEN";;
    ufw)
      ufw status 2>/dev/null | awk '$1 ~ /^[0-9]+(\/tcp)?$/ && $2 == "ALLOW" {print $1, $3}' >"$TMPOPEN"
      while read -r spec src; do
        p="${spec%/tcp}"; valid_port "$p" || continue; in_list "$p" $(all_ports) || continue
        case "$src" in Anywhere) add_open "$p";; *) valid_src "$src" && add_open "$p" "$src";; esac
      done <"$TMPOPEN";;
  esac
}

JOB=""
write_status() {   # RESULT MESSAGE
  { printf 'BACKEND=%s\nACTIVE=%s\nOPEN=%s\nTOOLS=%s\nCHECKED=%s\nRESULT=%s\nJOB=%s\n' "$BACKEND" "$ACTIVE" "$OPEN" "$TOOLS" "$(date +%s)" "$1" "$JOB"
    printf 'MESSAGE=%s\n' "$(printf '%s' "$2" | tr -d '\000-\037' | cut -c1-300)"; } | put_file "$STATUS"
}

# ---- commands (printed for hosts we do not drive, and by `print`) -----------------------------------------------------------
print_commands() {   # backend  dp-ports  console  console-from  agent  agent-from
  local b="$1" dp="$2" con="$3" cfrom="$4" ag="$5" afrom="$6" p
  for p in $dp; do
    case "$b" in
      firewalld) echo "firewall-cmd --permanent --add-port=$p/tcp";; ufw) echo "ufw allow $p/tcp";;
      nftables) echo "nft add rule inet filter input tcp dport $p accept";; iptables) echo "iptables -I INPUT -p tcp --dport $p -j ACCEPT";;
    esac
  done
  rule_cmd() {   # port from
    local port="$1" from="$2"
    case "$b" in
      firewalld) if [ -n "$from" ]; then echo "firewall-cmd --permanent --add-rich-rule='rule family=\"$(fam "$from")\" source address=\"$from\" port port=\"$port\" protocol=\"tcp\" accept'"; else echo "firewall-cmd --permanent --add-port=$port/tcp"; fi;;
      ufw) if [ -n "$from" ]; then echo "ufw allow proto tcp from $from to any port $port"; else echo "ufw allow $port/tcp"; fi;;
      nftables) if [ -n "$from" ]; then echo "nft add rule inet filter input $([[ "$from" == *:* ]] && echo ip6 || echo ip) saddr $from tcp dport $port accept"; else echo "nft add rule inet filter input tcp dport $port accept"; fi;;
      iptables) if [ -n "$from" ]; then echo "iptables -I INPUT -p tcp -s $from --dport $port -j ACCEPT"; else echo "iptables -I INPUT -p tcp --dport $port -j ACCEPT"; fi;;
    esac
  }
  [ -n "$con" ] && rule_cmd "$con" "$cfrom"
  [ -n "$ag" ] && rule_cmd "$ag" "${afrom:-<DATA_PLANE_IP>}"
  case "$b" in firewalld) echo "firewall-cmd --reload";;
    nftables) echo "# then make it permanent in /etc/nftables.conf";; iptables) echo "# then make it permanent (iptables-save / netfilter-persistent)";; esac
  return 0
}

# ---- managed list ------------------------------------------------------------------------------------------------------------
managed_has() { grep -qxF -- "$1" "$MANAGED" 2>/dev/null; }
managed_add() { managed_has "$1" || printf '%s\n' "$1" >>"$MANAGED"; chmod 0644 "$MANAGED" 2>/dev/null || true; }

# ---- opening ----------------------------------------------------------------------------------------------------------------
fwd_rich() { printf 'rule family="%s" source address="%s" port port="%s" protocol="tcp" accept' "$(fam "$2")" "$2" "$1"; }
open_firewalld() {   # dp-ports console cfrom agent afrom
  local dp="$1" con="$2" cfrom="$3" ag="$4" afrom="$5" p rule
  if [ -n "$dp" ]; then
    local xml=/etc/firewalld/services/toutwaf-dp.xml tmpx
    tmpx="$(mktemp)"; {
      printf '<?xml version="1.0" encoding="utf-8"?>\n<service>\n  <short>ToutWAF data plane</short>\n  <description>ToutWAF reverse proxy: HTTP and HTTPS (HTTP/3 / QUIC is not implemented, so UDP 443 stays closed)</description>\n'
      for p in $dp; do printf '  <port protocol="tcp" port="%s"/>\n' "$p"; done; printf '</service>\n'; } >"$tmpx"
    if [ "$(cat "$xml" 2>/dev/null)" != "$(cat "$tmpx")" ]; then install -m 0644 "$tmpx" "$xml"; firewall-cmd --reload >/dev/null 2>&1 || true; fi
    rm -f "$tmpx"
    if ! firewall-cmd --permanent --query-service=toutwaf-dp >/dev/null 2>&1; then firewall-cmd --permanent --add-service=toutwaf-dp >/dev/null || return 1; fi
    managed_add "firewalld service toutwaf-dp"
  fi
  if [ -n "$con" ]; then
    if [ -n "$cfrom" ]; then rule="$(fwd_rich "$con" "$cfrom")"
      firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1 || firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null || return 1
      managed_add "firewalld rich $rule"
    else
      firewall-cmd --permanent --query-port="$con/tcp" >/dev/null 2>&1 || { firewall-cmd --permanent --add-port="$con/tcp" >/dev/null || return 1; managed_add "firewalld port $con/tcp"; }
    fi
  fi
  if [ -n "$ag" ]; then
    rule="$(fwd_rich "$ag" "$afrom")"
    firewall-cmd --permanent --query-rich-rule="$rule" >/dev/null 2>&1 || firewall-cmd --permanent --add-rich-rule="$rule" >/dev/null || return 1
    managed_add "firewalld rich $rule"
  fi
  firewall-cmd --reload >/dev/null || return 1
}
open_ufw() {
  local dp="$1" con="$2" cfrom="$3" ag="$4" afrom="$5" p out
  ufw_allow() {   # key  args...
    local key="$1"; shift
    out="$(ufw "$@" 2>&1)" || return 1
    case "$out" in *Skipping*) ;; *) managed_add "ufw $key";; esac
  }
  for p in $dp; do ufw_allow "allow $p/tcp" allow "$p/tcp" comment ToutWAF || return 1; done
  if [ -n "$con" ]; then
    if [ -n "$cfrom" ]; then ufw_allow "allow proto tcp from $cfrom to any port $con" allow proto tcp from "$cfrom" to any port "$con" comment ToutWAF || return 1
    else ufw_allow "allow $con/tcp" allow "$con/tcp" comment ToutWAF || return 1; fi
  fi
  if [ -n "$ag" ]; then ufw_allow "allow proto tcp from $afrom to any port $ag" allow proto tcp from "$afrom" to any port "$ag" comment ToutWAF || return 1; fi
  return 0
}

do_open() {   # dp-ports console cfrom agent afrom   (already syntactically valid)
  local dp="$1" con="$2" cfrom="$3" ag="$4" afrom="$5" p
  load_conf
  # only what the installer recorded for this host
  for p in $dp; do in_list "$p" $CONF_DP || { write_status error "port $p is not a data-plane port recorded in firewall.conf"; return 1; }; done
  if [ -n "$con" ] && [ "$con" != "$CONF_CONSOLE" ]; then write_status error "port $con is not the console port recorded in firewall.conf"; return 1; fi
  if [ -n "$ag" ]; then
    [ "$ag" = "$CONF_AGENT" ] || { write_status error "port $ag is not the data-plane API port recorded in firewall.conf"; return 1; }
    [ -n "$afrom" ] || { write_status error "the data-plane API port is never opened to everyone: a source network is required"; return 1; }
  fi
  detect
  case "$BACKEND" in
    firewalld) open_firewalld "$dp" "$con" "$cfrom" "$ag" "$afrom" || { scan_open; write_status error "firewalld refused the rules (see: journalctl -u toutwaf-firewall)"; return 1; };;
    ufw) open_ufw "$dp" "$con" "$cfrom" "$ag" "$afrom" || { scan_open; write_status error "ufw refused the rules (see: journalctl -u toutwaf-firewall)"; return 1; };;
    nftables|iptables)
      scan_open
      echo "toutwaf-firewall: $BACKEND is not managed automatically. Run these commands yourself:" >&2
      print_commands "$BACKEND" "$dp" "$con" "$cfrom" "$ag" "$afrom" >&2
      write_status unmanaged "$BACKEND is not managed by ToutWAF: run the commands shown in the console (Settings > Firewall) or in the installer output"; return 2;;
    *)
      scan_open
      write_status ok "no active host firewall (firewalld / ufw / nftables / iptables) was found: nothing filters the traffic, nothing to open"; return 0;;
  esac
  scan_open
  write_status ok "ports opened"
  return 0
}

do_status() { detect; scan_open; write_status ok "${1:-scan}"; }

parse_open_args() {   # sets A_DP A_CON A_CFROM A_AG A_AFROM from "$@"; returns 1 on invalid input
  A_DP=""; A_CON=""; A_CFROM=""; A_AG=""; A_AFROM=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dp) A_DP="$(printf '%s' "$2" | tr ',' ' ')"; shift 2;;
      --console) A_CON="$2"; shift 2;;
      --console-from) A_CFROM="$2"; shift 2;;
      --agent) A_AG="$2"; shift 2;;
      --agent-from) A_AFROM="$2"; shift 2;;
      *) echo "toutwaf-firewall: unknown option $1" >&2; return 1;;
    esac
  done
  local p n=0
  for p in $A_DP; do valid_port "$p" || return 1; n=$((n + 1)); done; [ "$n" -le 8 ] || return 1
  [ -z "$A_CON" ] || valid_port "$A_CON" || return 1
  [ -z "$A_AG" ] || valid_port "$A_AG" || return 1
  [ -z "$A_CFROM" ] || valid_src "$A_CFROM" || return 1
  [ -z "$A_AFROM" ] || valid_src "$A_AFROM" || return 1
  [ -n "$A_DP$A_CON$A_AG" ] || return 1
  return 0
}

TMPOPEN="$(mktemp)"; trap 'rm -f "$TMPOPEN"' EXIT
case "${1:-}" in
  status) [ "$(id -u)" -eq 0 ] || { echo "toutwaf-firewall must run as root" >&2; exit 1; }; load_conf; do_status; cat "$STATUS" 2>/dev/null | sed -n '1,3p';;
  open)
    [ "$(id -u)" -eq 0 ] || { echo "toutwaf-firewall must run as root" >&2; exit 1; }
    shift; parse_open_args "$@" || { echo "toutwaf-firewall: invalid arguments" >&2; exit 2; }
    do_open "$A_DP" "$A_CON" "$A_CFROM" "$A_AG" "$A_AFROM"; exit $?;;
  apply)
    [ "$(id -u)" -eq 0 ] || { echo "toutwaf-firewall must run as root" >&2; exit 1; }
    # a private copy first (the service account can rewrite the file while we read it, or put a link or a FIFO in its place)
    trap 'rm -f "$TMPOPEN" "$TMPOPEN.req"' EXIT
    take_request "$REQ" "$TMPOPEN.req" 4096; rc=$?
    [ "$rc" -ne 1 ] || exit 0
    [ "$rc" -eq 0 ] || { detect; scan_open; write_status error "the request file is not a regular file of the service account"; exit 1; }
    rq() { sed -n "s/^$1=//p" "$TMPOPEN.req" | tail -n1 | tr -d '\r'; }
    JOB="$(rq JOB)"; valid_job "$JOB" || JOB=""
    load_conf; detect
    act="$(rq ACTION)"
    case "$act" in
      status) do_status "scan requested from the console"; exit 0;;
      open)
        dp="$(rq DP_PORTS | tr ',' ' ')"; con="$(rq CONSOLE_PORT)"; cf="$(rq CONSOLE_FROM)"; ag="$(rq AGENT_PORT)"; af="$(rq AGENT_FROM)"
        args=(); [ -z "$dp" ] || args+=(--dp "$(printf '%s' "$dp" | tr ' ' ',')"); [ -z "$con" ] || args+=(--console "$con"); [ -z "$cf" ] || args+=(--console-from "$cf")
        [ -z "$ag" ] || args+=(--agent "$ag"); [ -z "$af" ] || args+=(--agent-from "$af")
        if ! parse_open_args "${args[@]}"; then detect; scan_open; write_status error "invalid firewall request"; exit 1; fi
        do_open "$A_DP" "$A_CON" "$A_CFROM" "$A_AG" "$A_AFROM"; rc=$?; [ "$rc" -eq 2 ] && rc=0; exit "$rc";;
      *) detect; scan_open; write_status error "unknown action"; exit 1;;
    esac;;
  close)
    [ "$(id -u)" -eq 0 ] || { echo "toutwaf-firewall must run as root" >&2; exit 1; }
    detect; load_conf
    if [ -f "$MANAGED" ]; then
      while IFS= read -r l; do
        case "$l" in
          "firewalld service toutwaf-dp") [ "$BACKEND" = firewalld ] && firewall-cmd --permanent --remove-service=toutwaf-dp >/dev/null 2>&1;;
          "firewalld port "*) pt="${l#firewalld port }"; [[ "$pt" =~ ^[0-9]{1,5}/tcp$ ]] && [ "$BACKEND" = firewalld ] && firewall-cmd --permanent --remove-port="$pt" >/dev/null 2>&1;;
          "firewalld rich "*) r="${l#firewalld rich }"
            [[ "$r" =~ ^rule\ family=\"ipv[46]\"\ source\ address=\"[0-9a-fA-F:./]+\"\ port\ port=\"[0-9]{1,5}\"\ protocol=\"tcp\"\ accept$ ]] && [ "$BACKEND" = firewalld ] && firewall-cmd --permanent --remove-rich-rule="$r" >/dev/null 2>&1;;
          "ufw allow "*)
            r="${l#ufw }"
            if [[ "$r" =~ ^allow\ [0-9]{1,5}/tcp$ ]]; then [ "$BACKEND" = ufw ] && ufw --force delete $r >/dev/null 2>&1
            elif [[ "$r" =~ ^allow\ proto\ tcp\ from\ [0-9a-fA-F:./]+\ to\ any\ port\ [0-9]{1,5}$ ]]; then [ "$BACKEND" = ufw ] && ufw --force delete $r >/dev/null 2>&1; fi;;
        esac
      done <"$MANAGED"
      [ "$BACKEND" = firewalld ] && firewall-cmd --reload >/dev/null 2>&1
      rm -f "$MANAGED"
    elif [ "$BACKEND" = firewalld ]; then
      # installation made before rules were tracked: it only ever added the toutwaf-dp service (and the console port)
      firewall-cmd --permanent --remove-service=toutwaf-dp >/dev/null 2>&1
      [ -n "$CONF_CONSOLE" ] && firewall-cmd --permanent --remove-port="$CONF_CONSOLE/tcp" >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
    fi
    rm -f /etc/firewalld/services/toutwaf-dp.xml "$STATUS"
    exit 0;;
  print)
    load_conf; detect
    b="$BACKEND"; [ "$b" != none ] || b=firewalld
    print_commands "$b" "$CONF_DP" "$CONF_CONSOLE" "" "$CONF_AGENT" ""; exit 0;;
  *) echo "usage: toutwaf-firewall status|open ...|apply|close|print" >&2; exit 2;;
esac
TW_FIREWALL_TPL
  emit_helper toutwaf-blocklist <<'TW_BLOCKLIST_TPL'
#!/usr/bin/env bash
# toutwaf-blocklist-proto: 1
#
# toutwaf-blocklist apply     (root; toutwaf-blocklist.service) perform @DATA_DIR@/blocklist-request
# toutwaf-blocklist status    write @DATA_DIR@/blocklist-status (is the table in the kernel, how many entries, how many packets dropped)
# toutwaf-blocklist clear     remove the table (uninstall, or the console switch turned off)
#
# Puts the large blocklists of ToutWAF into the kernel (nftables) so that the packets of a listed address are dropped before the
# proxy ever sees them. The request file and the lists are written by the control plane (the unprivileged service account), so
# for root they are untrusted input:
#   * the request carries nothing but ACTION and JOB; the lists are read from two fixed files and copied first (a symbolic link or
#     anything but a regular file is refused);
#   * every line is checked as an address or a network of the public Internet (IPv4: a.b.c.d[/8..32], not private, loopback,
#     link-local, shared, documentation or multicast space; IPv6: inside 2000::/3, /16..128, not the documentation prefix); a line
#     that is not exactly that is dropped and counted, so nothing can reach the nftables file but addresses (no space, brace, comma,
#     semicolon or newline can survive the check);
#   * only ONE table is ever touched, "inet toutwaf_block" (replaced atomically in one transaction), only the TCP ports of the data
#     plane recorded by the installer in @CONF_DIR@/firewall.conf are filtered, and an "allow" set (the addresses the owner trusts)
#     is accepted before anything is dropped;
#   * no shell is started from the data: the only programs run are nft, awk, sed, sha256sum, dd, cat, stat, mktemp and mv; the files of the
#     service account are opened without following a link or waiting for a writer, and the answers are new files renamed in place (hostio).
# The table lives in the kernel only: it is gone after a reboot, and the control plane asks for it again when it starts. The
# data plane enforces the same lists itself, so a missing table loses speed, never protection.
set -uo pipefail
DATA_DIR='@DATA_DIR@'; CONF_DIR='@CONF_DIR@'; SVC_USER='@SVC_USER@'
REQ="$DATA_DIR/blocklist-request"; STATUS="$DATA_DIR/blocklist-status"; LISTDIR="$DATA_DIR/kernel-blocklist"; CONF="$CONF_DIR/firewall.conf"
RUNDIR=/run/toutwaf-blocklist; STATE="$RUNDIR/state"
TABLE=toutwaf_block; MAX_BLOCK=3000000; MAX_ALLOW=4096; MAX_BYTES=134217728
have() { command -v "$1" >/dev/null 2>&1; }
valid_job() { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
# >>> hostio: how root touches the files of the service account (deploy/helpers/hostio.sh; deploy/tests/hostio-test.sh checks the copies) >>>
# The account owns the data directory and can change any name in it at any moment: a link to a file of root, a FIFO that holds
# root in open(2) for ever, a file with a second name. Nothing it wrote is opened without O_NOFOLLOW | O_NONBLOCK or judged by a
# path that is opened later; nothing of root's is written through a path it could have swapped (no chown/chmod by path).
_dd_nofollow() {   # 0 when dd can open with iflag=nofollow,nonblock (GNU dd; not busybox)
  [ -n "${_DD_NF:-}" ] || { dd iflag=nofollow,nonblock if=/dev/null of=/dev/null count=0 2>/dev/null && _DD_NF=1 || _DD_NF=0; }
  [ "$_DD_NF" = 1 ]
}
_bounded() { local s="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"; else "$@"; fi; }
# copy_safe SRC DST MAX   0: DST holds a copy of SRC; 1: SRC does not exist; 2: refused. SRC must be a regular file (no link, no FIFO,
# no device) with one name, owned by the owner of its directory, that nobody else can write, of at most MAX bytes, and unchanged
# while it was read. DST is a file of root's.
copy_safe() {
  local src="$1" dst="$2" max="$3" dir m1 m2 type uid nlink mode size
  [ -e "$src" ] || [ -L "$src" ] || return 1
  dir="$(dirname -- "$src")"
  m1="$(stat -c '%F|%u|%h|%a|%s|%i|%Y' -- "$src" 2>/dev/null)" || return 2
  IFS='|' read -r type uid nlink mode size _ <<<"$m1"
  case "$type" in "regular file"|"regular empty file") ;; *) return 2;; esac
  [ "$uid" = "$(stat -c %u -- "$dir" 2>/dev/null)" ] && [ "$nlink" = 1 ] || return 2
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -le "$max" ] && [ $(( 8#$mode & 8#022 )) -eq 0 ] || return 2
  if _dd_nofollow; then
    _bounded 10 dd if="$src" of="$dst" iflag=nofollow,nonblock bs=65536 count=$(( max / 65536 + 2 )) 2>/dev/null || { rm -f -- "$dst"; return 2; }
  else
    _bounded 10 cat -- "$src" >"$dst" 2>/dev/null || { rm -f -- "$dst"; return 2; }
  fi
  m2="$(stat -c '%F|%u|%h|%a|%s|%i|%Y' -- "$src" 2>/dev/null)"
  if [ "$m1" != "$m2" ] || [ ! -f "$dst" ] || [ -L "$dst" ] || [ "$(stat -c %s -- "$dst" 2>/dev/null || echo 999999999999)" -gt "$max" ]; then rm -f -- "$dst"; return 2; fi
  return 0
}
# take_request SRC DST MAX: copy_safe, then SRC is removed whatever the answer (a request left in place would start the helper again
# and again). 0: DST holds the request; 1: there was none; 2: refused.
take_request() {
  local rc
  copy_safe "$1" "$2" "$3"; rc=$?
  [ "$rc" -eq 1 ] || rm -f -- "$1"
  return "$rc"
}
# put_file DEST: stdin becomes DEST, mode 0644, owned by root: a new file under a random name (noclobber: O_EXCL), renamed over
# DEST. A link at DEST is replaced, never written through. The account only reads these files.
put_file() {
  local dest="$1" tmp
  tmp="$(mktemp -u -- "$dest.XXXXXX")" || return 1
  ( umask 022; set -C; cat >"$tmp" ) 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -fT -- "$tmp" "$dest" 2>/dev/null || { [ -L "$dest" ] && rm -f -- "$dest"; mv -f -- "$tmp" "$dest"; } || { rm -f -- "$tmp"; return 1; }
}
# <<< hostio <<<
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n1 | tr -d '\r"'"'"; }

JOB=""; TMP=""
cleanup() { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

# state of the table as the last successful apply left it (a file in /run: it disappears with the table, at reboot)
S_APPLIED=0; S_B4=0; S_B6=0; S_A4=0; S_A6=0; S_REJ=0; S_PORTS=""; S_SRC=""
load_state() {
  S_APPLIED=0; S_B4=0; S_B6=0; S_A4=0; S_A6=0; S_REJ=0; S_PORTS=""; S_SRC=""
  [ -f "$STATE" ] && [ ! -L "$STATE" ] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      B4) [[ "$v" =~ ^[0-9]{1,9}$ ]] && S_B4="$v";; B6) [[ "$v" =~ ^[0-9]{1,9}$ ]] && S_B6="$v";;
      A4) [[ "$v" =~ ^[0-9]{1,9}$ ]] && S_A4="$v";; A6) [[ "$v" =~ ^[0-9]{1,9}$ ]] && S_A6="$v";;
      REJ) [[ "$v" =~ ^[0-9]{1,9}$ ]] && S_REJ="$v";; PORTS) [[ "$v" =~ ^[0-9,]{1,64}$ ]] && S_PORTS="$v";;
      SRC) [[ "$v" =~ ^[0-9a-f]{64}$ ]] && S_SRC="$v";;
    esac
  done <"$STATE"
}
# the chain, not the table: listing a table prints every element of its sets (many seconds for a million networks)
CHAIN=""
table_present() { CHAIN="$(nft list chain inet "$TABLE" prerouting 2>/dev/null)"; [ -n "$CHAIN" ]; }
# packets dropped so far by the rules of the table (sum of the two counters; after table_present)
dropped() { printf '%s\n' "$CHAIN" | sed -n 's/.*counter packets \([0-9][0-9]*\) bytes [0-9]* drop.*/\1/p' | awk '{s += $1} END {print s + 0}'; }

write_status() {   # RESULT MESSAGE
  local present=0 pk=0 res="$1"
  if have nft && table_present; then present=1; pk="$(dropped)"; load_state; else S_B4=0; S_B6=0; S_A4=0; S_A6=0; S_REJ=0; S_PORTS=""; S_SRC=""; fi
  { printf 'BACKEND=nftables\nAPPLIED=%s\nBLOCK4=%s\nBLOCK6=%s\nALLOW4=%s\nALLOW6=%s\nREJECTED=%s\nPORTS=%s\nSRC=%s\nDROPPED=%s\nCHECKED=%s\nRESULT=%s\nJOB=%s\n' \
      "$present" "$S_B4" "$S_B6" "$S_A4" "$S_A6" "$S_REJ" "$S_PORTS" "$S_SRC" "$pk" "$(date +%s)" "$res" "$JOB"
    printf 'MESSAGE=%s\n' "$(printf '%s' "$2" | tr -d '\000-\037' | cut -c1-300)"; } | put_file "$STATUS"
}

# ---- the check of every line -----------------------------------------------------------------------------------------------------
# prints the accepted networks to OUT4 / OUT6 and "ok4 ok6 bad reserved" on stdout. Reserved space is the same list as the control plane's.
FILTER='
function hexval(s,   i, c, v) { v = 0; for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)); if (c == 0) return -1; v = v * 16 + c - 1 } return v }
function dotted(x) { return int(x / 16777216) "." int((x % 16777216) / 65536) "." int((x % 65536) / 256) "." (x % 256) }
BEGIN {
  n = split("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3", R, " ")
  for (i = 1; i <= n; i++) { split(R[i], p, "/"); split(p[1], o, "."); lo[i] = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]; hi[i] = lo[i] + 2 ^ (32 - p[2]) - 1 }
  nres = n; ok4 = 0; ok6 = 0; bad = 0; res = 0
}
{
  line = tolower($0); gsub(/[ \t\r]/, "", line)
  if (line == "" || substr(line, 1, 1) == "#") next
  if (ok4 + ok6 >= max) { bad++; next }
  if (line !~ /^[0-9a-f:.\/]+$/) { bad++; next }
  ip = line; len = -1
  if (index(line, "/") > 0) { if (split(line, q, "/") != 2 || q[2] !~ /^[0-9][0-9]?[0-9]?$/) { bad++; next } ip = q[1]; len = q[2] + 0 }
  if (index(ip, ":") == 0) {
    if (len < 0) len = 32
    if (ip !~ /^(0|[1-9][0-9]?[0-9]?)\.(0|[1-9][0-9]?[0-9]?)\.(0|[1-9][0-9]?[0-9]?)\.(0|[1-9][0-9]?[0-9]?)$/) { bad++; next }
    split(ip, o, ".")
    if (o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255 || len < 8 || len > 32) { bad++; next }
    v = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]; size = 2 ^ (32 - len); base = v - (v % size); top = base + size - 1
    r = 0; for (i = 1; i <= nres; i++) if (base <= hi[i] && top >= lo[i]) { r = 1; break }
    if (r) { res++; next }
    print dotted(base) "/" len > out4; ok4++
  } else {
    if (len < 0) len = 128
    if (ip !~ /^[0-9a-f:]+$/ || len < 16 || len > 128) { bad++; next }
    c = split(ip, g, ":"); dbl = 0; t = ip; while ((k = index(t, "::")) > 0) { dbl++; t = substr(t, k + 2) }
    if (dbl > 1 || ip ~ /:::/ || ip == "" || substr(ip, 1, 1) == ":" ) { bad++; next }
    if ((dbl == 0 && c != 8) || (dbl == 1 && c > 8)) { bad++; next }
    okg = 1; for (i = 1; i <= c; i++) if (length(g[i]) > 4 || (dbl == 0 && g[i] == "")) okg = 0
    if (!okg) { bad++; next }
    f = hexval(g[1])
    if (f < 8192 || f > 16383) { res++; next }
    if (g[1] == "2001" && g[2] == "db8") { res++; next }
    print ip "/" len > out6; ok6++
  }
}
END { printf "%d %d %d %d\n", ok4, ok6, bad, res }
'

# copy_list SRC DST: a regular file of a reasonable size, copied as it is now (the service account can rewrite it any time, or put a
# link or a FIFO in its place); no list is an empty list
copy_list() {
  local src="$1" dst="$2" rc
  [ -d "$LISTDIR" ] && [ ! -L "$LISTDIR" ] || return 1
  copy_safe "$src" "$dst" "$MAX_BYTES"; rc=$?
  case "$rc" in 0) return 0;; 1) : >"$dst"; return 0;; *) return 1;; esac
}

emit_set() {   # NAME TYPE FILE
  printf '\tset %s {\n\t\ttype %s\n\t\tflags interval\n\t\tauto-merge\n' "$1" "$2"
  if [ -s "$3" ]; then
    printf '\t\telements = {\n'
    sed -e '$!s/$/,/' -e 's/^/\t\t\t/' "$3"
    printf '\t\t}\n'
  fi
  printf '\t}\n'
}

do_apply() {
  have nft || { write_status unavailable "the nft command (package nftables) is not installed on this host: ToutWAF keeps blocking in the data plane only"; return 1; }
  local ports="" p n=0
  for p in $(conf_get DP_PORTS | tr ',' ' '); do
    [[ "$p" =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || continue
    ports="${ports:+$ports, }$p"; n=$((n + 1)); [ "$n" -le 8 ] || break
  done
  if [ -z "$ports" ]; then write_status unavailable "no data-plane port is recorded in $CONF on this host (the data plane runs elsewhere, or run the installer once more): nothing to filter here"; return 1; fi
  local rc
  copy_list "$LISTDIR/block.txt" "$TMP/block.in"; rc=$?
  [ "$rc" -eq 0 ] || { write_status error "the block list is not a regular file of a reasonable size (at most $((MAX_BYTES / 1048576)) MB)"; return 1; }
  copy_list "$LISTDIR/allow.txt" "$TMP/allow.in"; rc=$?
  [ "$rc" -eq 0 ] || { write_status error "the allow list is not a regular file of a reasonable size"; return 1; }
  local src stats b4 b6 a4 a6 bad1 bad2 res1 res2
  src="$(cat "$TMP/block.in" "$TMP/allow.in" | sha256sum | cut -d' ' -f1)"
  stats="$(awk -v max="$MAX_BLOCK" -v out4="$TMP/block4" -v out6="$TMP/block6" "$FILTER" "$TMP/block.in")" || { write_status error "the block list could not be read"; return 1; }
  read -r b4 b6 bad1 res1 <<<"$stats"
  stats="$(awk -v max="$MAX_ALLOW" -v out4="$TMP/allow4" -v out6="$TMP/allow6" "$FILTER" "$TMP/allow.in")" || { write_status error "the allow list could not be read"; return 1; }
  read -r a4 a6 bad2 res2 <<<"$stats"
  local rej=$((bad1 + res1 + bad2 + res2))
  for f in block4 block6 allow4 allow6; do [ -e "$TMP/$f" ] || : >"$TMP/$f"; done
  if [ "$((b4 + b6))" -eq 0 ]; then
    # an empty list is not a table full of nothing: remove ours so that no rule stays behind
    nft delete table inet "$TABLE" >/dev/null 2>&1 || true
    rm -f "$STATE"; write_status cleared "the block list is empty: no kernel rule"; return 0
  fi
  {
    printf 'add table inet %s\ndelete table inet %s\ntable inet %s {\n' "$TABLE" "$TABLE" "$TABLE"
    emit_set block4 ipv4_addr "$TMP/block4"; emit_set block6 ipv6_addr "$TMP/block6"
    emit_set allow4 ipv4_addr "$TMP/allow4"; emit_set allow6 ipv6_addr "$TMP/allow6"
    printf '\tchain prerouting {\n\t\ttype filter hook prerouting priority -300; policy accept;\n'
    printf '\t\tip saddr @allow4 accept\n\t\tip6 saddr @allow6 accept\n'
    printf '\t\ttcp dport { %s } ip saddr @block4 counter drop\n\t\ttcp dport { %s } ip6 saddr @block6 counter drop\n\t}\n}\n' "$ports" "$ports"
  } >"$TMP/rules.nft"
  local out
  if ! out="$(nft -f "$TMP/rules.nft" 2>&1)"; then
    # one transaction: the table that was in place (if any) is untouched
    write_status error "nftables refused the list: $(printf '%s' "$out" | head -n1)"; return 1
  fi
  mkdir -p "$RUNDIR" && chmod 0755 "$RUNDIR"
  printf 'B4=%s\nB6=%s\nA4=%s\nA6=%s\nREJ=%s\nPORTS=%s\nSRC=%s\n' "$b4" "$b6" "$a4" "$a6" "$rej" "$(printf '%s' "$ports" | tr -d ' ')" "$src" >"$STATE"
  write_status ok "$((b4 + b6)) networks are dropped by the kernel on port(s) $ports before the data plane sees them"
  return 0
}

do_clear() {
  if have nft; then nft delete table inet "$TABLE" >/dev/null 2>&1 || true; fi
  rm -f "$STATE"
  write_status cleared "the kernel rules of ToutWAF were removed"
}

[ "$(id -u)" -eq 0 ] || { echo "toutwaf-blocklist must run as root" >&2; exit 1; }
TMP="$(mktemp -d)" || { echo "toutwaf-blocklist: no temporary directory" >&2; exit 1; }
chmod 0700 "$TMP"
case "${1:-}" in
  status) write_status ok "scan";;
  clear) do_clear;;
  apply)
    # a private copy first (in a directory only root can write): the service account can rewrite the file while we read it, or put a
    # link or a FIFO in its place
    take_request "$REQ" "$TMP/request" 4096; rc=$?
    [ "$rc" -ne 1 ] || exit 0
    [ "$rc" -eq 0 ] || exit 1
    [ -f "$TMP/request" ] && [ ! -L "$TMP/request" ] && [ "$(stat -c %s "$TMP/request")" -le 4096 ] || exit 1
    rq() { sed -n "s/^$1=//p" "$TMP/request" | tail -n1 | tr -d '\r'; }
    JOB="$(rq JOB)"; valid_job "$JOB" || JOB=""
    act="$(rq ACTION)"
    case "$act" in
      apply) do_apply; exit $?;;
      clear) do_clear;;
      status) write_status ok "scan requested from the console";;
      *) write_status error "unknown action"; exit 1;;
    esac;;
  *) echo "usage: toutwaf-blocklist status|apply|clear" >&2; exit 2;;
esac
TW_BLOCKLIST_TPL
  emit_helper toutwaf-vpn <<'TW_VPN_TPL'
#!/usr/bin/env bash
# toutwaf-vpn-proto: 1
#
# toutwaf-vpn apply              (root; toutwaf-vpn.service) perform the pending @DATA_DIR@/vpn-request
# toutwaf-vpn rollback RECORD    put back a change whose trial ran out (a transient systemd timer started by "apply" runs it)
#
# The VPN module of the console generates WireGuard / OpenVPN / strongSwan files; this helper puts them on the machine
# (/etc/wireguard, /etc/openvpn, /etc/swanctl/conf.d), enables or disables the systemd unit and reads the state of the tunnels
# (@DATA_DIR@/vpn-status.json, without any key). The request and the files in it are written by the unprivileged service account,
# so for root they are untrusted input. All the work is done by `toutwafctl vpn-host`, which checks them again:
#   * the destinations are fixed and derived from the validated record id and interface name, never taken from the request;
#   * every configuration file is read against an allow list of directives: nothing that runs a program (PostUp, up, plugin,
#     script-security above 1, updown...) or reads another file can get through; a symbolic link is refused;
#   * a file that ToutWAF did not write is renamed (*.toutwaf-save) before it is replaced, nothing is ever deleted;
#   * the route to the address of the administrator is checked before and after the start and the change is undone at once when
#     it moved; a change of the default route stays on trial and a timer undoes it unless the console confirms it.
set -uo pipefail
DATA_DIR='@DATA_DIR@'; BIN_DIR='@BIN_DIR@'
[ "$(id -u)" -eq 0 ] || { echo "toutwaf-vpn must run as root" >&2; exit 1; }
CTL="$BIN_DIR/toutwafctl"
[ -x "$CTL" ] || { echo "toutwaf-vpn: $CTL is missing" >&2; exit 1; }
case "${1:-}" in
  apply) exec "$CTL" vpn-host apply --data-dir "$DATA_DIR";;
  rollback)
    [[ "${2:-}" =~ ^vp[su]_[0-9a-f]{16}$ ]] || { echo "toutwaf-vpn: invalid record" >&2; exit 2; }
    exec "$CTL" vpn-host rollback --id "$2";;
  *) echo "usage: toutwaf-vpn apply|rollback RECORD" >&2; exit 2;;
esac
TW_VPN_TPL
  emit_helper toutwaf-fw <<'TW_FW_TPL'
#!/usr/bin/env bash
# toutwaf-fw-proto: 1
#
# toutwaf-fw apply              (root; toutwaf-fw.service) perform the pending @DATA_DIR@/fw-request
# toutwaf-fw rollback TRIAL     put back the rules of a trial that was not confirmed (a transient systemd timer started by "apply" runs it)
# toutwaf-fw boot               (root; toutwaf-fw-boot.service) load the rules the console confirmed, at boot
#
# The Firewall module of the console builds an nftables ruleset in ONE table of its own (inet toutwaf_fw); the control plane runs
# without any privilege, so this helper loads it. The request and the files in it are written by the unprivileged service
# account, so for root they are untrusted input. All the work is done by `toutwafctl fw-host`, which checks them again:
#   * the request carries a configuration, never a script: root renders the ruleset itself (validation, strict template, lint) and
#     refuses anything that is not exactly what the renderer writes; only our table can be touched, no other nft command exists;
#   * the lock-out guard runs again on the root side (SSH 22, console 443/9443, agent 9444, the peers and the address of the
#     administrator who asked): a change that would cut access is refused before anything is loaded;
#   * `nft -c` first; then the new rules stay on trial and a transient systemd timer owned by root puts the previous ones back
#     unless the console confirms in time, whether or not the control plane is still alive;
#   * the rules put back are the ones root saved itself, never a copy from the request.
set -uo pipefail
DATA_DIR='@DATA_DIR@'; BIN_DIR='@BIN_DIR@'
[ "$(id -u)" -eq 0 ] || { echo "toutwaf-fw must run as root" >&2; exit 1; }
CTL="$BIN_DIR/toutwafctl"
[ -x "$CTL" ] || { echo "toutwaf-fw: $CTL is missing" >&2; exit 1; }
case "${1:-}" in
  apply) exec "$CTL" fw-host apply --data-dir "$DATA_DIR";;
  rollback)
    [[ "${2:-}" =~ ^[0-9a-f]{32}$ ]] || { echo "toutwaf-fw: invalid trial" >&2; exit 2; }
    exec "$CTL" fw-host rollback --id "$2";;
  boot) exec "$CTL" fw-host boot --data-dir "$DATA_DIR";;
  *) echo "usage: toutwaf-fw apply|rollback TRIAL|boot" >&2; exit 2;;
esac
TW_FW_TPL
  emit_helper toutwaf-jobs <<'TW_JOBS_TPL'
#!/usr/bin/env bash
# toutwaf-jobs-proto: 1
#
# toutwaf-jobs apply            (root; toutwaf-jobs.service) run the pending @DATA_DIR@/jobs-request
#
# The scheduled tasks of the console can ask for a privileged job. The control plane runs without any privilege, so it leaves a small
# request file (JOB, VERB, DAYS) and this helper runs it. The request is written by the unprivileged service account, so for root it
# is untrusted input. All the work is done by `toutwafctl jobs-host`, which checks it again:
#   * the verb must be one of a FIXED list written in the program (logrotate, journal_vacuum, and the power_* verbs of the console's power menu
#     and of the self-repair: restart the data plane, restart ToutWAF, stop the control plane, restart the machine); the command line of each
#     verb is written there too: a request cannot name a program, a path, an option, a unit or a shell;
#   * the only numbers (days of the journal to keep; seconds to wait before a power verb, at most 120) are checked against their bounds;
#   * the answer (exit code, clipped output) goes back in @DATA_DIR@/jobs/<job>.res.json.
set -uo pipefail
DATA_DIR='@DATA_DIR@'; BIN_DIR='@BIN_DIR@'
[ "$(id -u)" -eq 0 ] || { echo "toutwaf-jobs must run as root" >&2; exit 1; }
CTL="$BIN_DIR/toutwafctl"
[ -x "$CTL" ] || { echo "toutwaf-jobs: $CTL is missing" >&2; exit 1; }
case "${1:-}" in
  apply) exec "$CTL" jobs-host apply --data-dir "$DATA_DIR";;
  *) echo "usage: toutwaf-jobs apply" >&2; exit 2;;
esac
TW_JOBS_TPL
  cat >"$sd/toutwaf-upgrade.path" <<EOF
[Unit]
Description=ToutWAF upgrade requests (data plane update_engine, console Updates page)

[Path]
PathExists=$DATA_DIR/upgrade-request
Unit=toutwaf-upgrade.service

[Install]
WantedBy=multi-user.target
EOF
  cat >"$sd/toutwaf-upgrade.service" <<EOF
[Unit]
Description=ToutWAF upgrade (requested by the control plane or the data plane)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$CONF_DIR/upgrade.env
ExecStart=$BIN_DIR/toutwaf-upgrade apply
# longest honest run: download and checks (10 min) + the installer (15 min) + the health window (up to 30 min); the transient rollback timer settles
# the update anyway if systemd cuts the helper short (docs/design/update-resilience.md)
TimeoutStartSec=60min
EOF
  # finishes or undoes an update that a power loss, a killed helper or a reboot interrupted (no-op when the journal of the update helper is closed)
  cat >"$sd/toutwaf-upgrade-guard.service" <<EOF
[Unit]
Description=ToutWAF: finish or undo an interrupted update
After=local-fs.target network-online.target toutwaf-cp.service toutwaf-dp.service
Wants=network-online.target
ConditionPathExists=${DATA_DIR}-upgrade/journal.json

[Service]
Type=oneshot
# a failed repair never stops the machine from booting
ExecStart=-$BIN_DIR/toutwaf-upgrade recover
TimeoutStartSec=10min

[Install]
WantedBy=multi-user.target
EOF
  if want_cp; then
    cat >"$sd/toutwaf-firewall.path" <<EOF
[Unit]
Description=ToutWAF firewall requests (console Settings > Firewall)

[Path]
PathExists=$DATA_DIR/firewall-request
Unit=toutwaf-firewall.service

[Install]
WantedBy=multi-user.target
EOF
    cat >"$sd/toutwaf-firewall.service" <<EOF
[Unit]
Description=ToutWAF firewall helper (requested by the control plane)

[Service]
Type=oneshot
ExecStart=$BIN_DIR/toutwaf-firewall apply
TimeoutStartSec=2min
PrivateTmp=yes
ProtectHome=yes
EOF
    cat >"$sd/toutwaf-blocklist.path" <<EOF
[Unit]
Description=ToutWAF kernel blocklist requests (console Lists > Kernel blocking)

[Path]
PathExists=$DATA_DIR/blocklist-request
Unit=toutwaf-blocklist.service

[Install]
WantedBy=multi-user.target
EOF
    # the helper needs the netfilter netlink socket and to write the status file for the service account, nothing else
    cat >"$sd/toutwaf-blocklist.service" <<EOF
[Unit]
Description=ToutWAF kernel blocklist helper (requested by the control plane)

[Service]
Type=oneshot
ExecStart=$BIN_DIR/toutwaf-blocklist apply
TimeoutStartSec=5min
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$DATA_DIR
RuntimeDirectory=toutwaf-blocklist
RuntimeDirectoryPreserve=yes
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_CHOWN CAP_DAC_OVERRIDE CAP_FOWNER
RestrictAddressFamilies=AF_UNIX AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
LockPersonality=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
UMask=0022
EOF
    cat >"$sd/toutwaf-vpn.path" <<EOF
[Unit]
Description=ToutWAF VPN requests (console VPN)

[Path]
PathExists=$DATA_DIR/vpn-request
Unit=toutwaf-vpn.service

[Install]
WantedBy=multi-user.target
EOF
    # the helper starts and stops the tunnels (systemctl) and reads their state; the tunnels themselves run in their own units
    cat >"$sd/toutwaf-vpn.service" <<EOF
[Unit]
Description=ToutWAF VPN helper (requested by the control plane)

[Service]
Type=oneshot
ExecStart=$BIN_DIR/toutwaf-vpn apply
TimeoutStartSec=5min
PrivateTmp=yes
ProtectHome=yes
EOF
    cat >"$sd/toutwaf-fw.path" <<EOF
[Unit]
Description=ToutWAF firewall rules requests (console Firewall)

[Path]
PathExists=$DATA_DIR/fw-request
Unit=toutwaf-fw.service

[Install]
WantedBy=multi-user.target
EOF
    # the helper loads nftables rules (netlink) and starts the transient rollback timer (systemctl): it is not sandboxed further
    cat >"$sd/toutwaf-fw.service" <<EOF
[Unit]
Description=ToutWAF firewall rules helper (requested by the control plane)
StartLimitIntervalSec=60
StartLimitBurst=30

[Service]
Type=oneshot
ExecStart=$BIN_DIR/toutwaf-fw apply
TimeoutStartSec=2min
PrivateTmp=yes
ProtectHome=yes
EOF
    # loads the confirmed rules at boot, before the control plane runs; installed, NOT enabled (the control plane also compares the
    # loaded rules with the confirmed ones at start-up and every 5 minutes): systemctl enable toutwaf-fw-boot.service
    cat >"$sd/toutwaf-fw-boot.service" <<EOF
[Unit]
Description=ToutWAF firewall: load the confirmed rules at boot
ConditionPathExists=$DATA_DIR/firewall/toutwaf-fw.nft
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no
After=local-fs.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
# a failed load never stops the machine from booting or the control plane from starting
ExecStart=-$BIN_DIR/toutwaf-fw boot
TimeoutStartSec=1min

[Install]
WantedBy=multi-user.target
EOF
    cat >"$sd/toutwaf-jobs.path" <<EOF
[Unit]
Description=ToutWAF privileged job requests (console Scheduled tasks)

[Path]
PathExists=$DATA_DIR/jobs-request
Unit=toutwaf-jobs.service

[Install]
WantedBy=multi-user.target
EOF
    cat >"$sd/toutwaf-jobs.service" <<EOF
[Unit]
Description=ToutWAF privileged jobs helper (requested by the control plane)
StartLimitIntervalSec=60
StartLimitBurst=30

[Service]
Type=oneshot
ExecStart=$BIN_DIR/toutwaf-jobs apply
TimeoutStartSec=6min
PrivateTmp=yes
ProtectHome=yes
NoNewPrivileges=yes
EOF
  fi
  return 0
}

tune_sysctl() {
  if [ "$NO_SYSCTL" = 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  mkdir -p "$(p /etc/sysctl.d)"
  cat >"$(p /etc/sysctl.d/90-toutwaf.conf)" <<'EOF'
# ToutWAF data plane: connection-heavy reverse proxy tuning
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
fs.file-max = 2097152
EOF
  if [ "$STAGING" = 0 ]; then sysctl -q -p "$(p /etc/sysctl.d/90-toutwaf.conf)" >/dev/null 2>&1 || true; fi
  return 0
}

setup_selinux() {
  if [ "$STAGING" = 1 ] || [ "$NO_SELINUX" = 1 ]; then return 0; fi
  # AppArmor (Debian / Ubuntu / SUSE): ToutWAF ships no profile, so nothing is confined by it; the systemd sandbox of the units applies
  if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true)" = Y ]; then info "AppArmor is active: ToutWAF ships no AppArmor profile, the services are confined by their systemd sandbox only"; fi
  have getenforce || return 0
  [ "$(getenforce 2>/dev/null)" = "Disabled" ] && return 0
  have semanage || { warn "SELinux is enabled but semanage is missing; skipping file contexts. By hand, once the SELinux policy utilities are installed: semanage fcontext -a -t var_lib_t '$DATA_DIR(/.*)?' && semanage fcontext -a -t var_log_t '$LOG_DIR(/.*)?' && restorecon -RF '$DATA_DIR' '$LOG_DIR'"; return 0; }
  log "Configuring SELinux contexts ($(getenforce))"
  semanage fcontext -a -t etc_t "$CONF_DIR(/.*)?" 2>/dev/null || semanage fcontext -m -t etc_t "$CONF_DIR(/.*)?" || true
  semanage fcontext -a -t var_lib_t "$DATA_DIR(/.*)?" 2>/dev/null || semanage fcontext -m -t var_lib_t "$DATA_DIR(/.*)?" || true
  semanage fcontext -a -t var_log_t "$LOG_DIR(/.*)?" 2>/dev/null || semanage fcontext -m -t var_log_t "$LOG_DIR(/.*)?" || true
  semanage fcontext -a -t bin_t "$BIN_DIR/toutwaf-(dp|cp|upgrade|firewall)" 2>/dev/null || semanage fcontext -m -t bin_t "$BIN_DIR/toutwaf-(dp|cp|upgrade|firewall)" || true
  semanage fcontext -a -t bin_t "$BIN_DIR/toutwafctl" 2>/dev/null || true
  if [ "$LAYOUT" = home ]; then   # the HOME directory itself (bin/ conf/ data/ logs/ get their own types above)
    semanage fcontext -a -t usr_t "$HOME_DIR" 2>/dev/null || semanage fcontext -m -t usr_t "$HOME_DIR" || true
    restorecon -F "$HOME_DIR" 2>/dev/null || true
  fi
  restorecon -RF "$CONF_DIR" "$DATA_DIR" "$LOG_DIR" "$BIN_DIR"/toutwaf* 2>/dev/null || true
  # the console/DP-facing ports are labelled http_port_t so that confined admin tooling can reach them
  if want_cp; then for port in "$CP_PORT" 9444; do semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || true; done; fi
  # allow the proxy to connect to arbitrary origin ports when running confined by an httpd-like domain
  setsebool -P httpd_can_network_connect on 2>/dev/null || true
  return 0
}

# firewall.conf (root-owned): the ports of this host that toutwaf-firewall may open. Written at every install / update (so that a
# console "Open the required ports" works after a port change); only an install opens ports, an update never re-opens what an
# administrator closed.
write_firewall_conf() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ -d "$(p "$CONF_DIR")" ] || return 0
  detect_installed
  { printf '# written by install.sh: the ports of this host that toutwaf-firewall (root helper) is allowed to open; edit with care\n'
    [ "$INST_DP" = 1 ] && printf 'DP_PORTS="%s %s"\n' "$HTTP_PORT" "$HTTPS_PORT"
    [ "$INST_CP" = 1 ] && printf 'CONSOLE_PORT=%s\nAGENT_PORT=9444\n' "$CP_PORT"; } >"$(p "$CONF_DIR/firewall.conf")"
  chmod 0644 "$(p "$CONF_DIR/firewall.conf")"
  return 0
}

setup_firewall() {
  write_firewall_conf
  if [ "$STAGING" = 1 ] || [ "$OPEN_FW" = 0 ] || [ "$ACTION" = update ]; then return 0; fi
  local fwh="$BIN_DIR/toutwaf-firewall" args=() out rc=0 backend
  [ -x "$fwh" ] || { warn "toutwaf-firewall helper missing: firewall not configured"; return 0; }
  detect_installed
  [ "$INST_DP" = 1 ] && args+=(--dp "$HTTP_PORT,$HTTPS_PORT")
  if [ "$INST_CP" = 1 ] && [ "$OPEN_CP_PORT" = 1 ]; then args+=(--console "$CP_PORT"); [ -z "$CONSOLE_FROM" ] || args+=(--console-from "$CONSOLE_FROM"); fi
  [ "${#args[@]}" -gt 0 ] || return 0
  out="$("$fwh" open "${args[@]}" 2>&1)" || rc=$?
  log "toutwaf-firewall open ${args[*]} -> rc=$rc: $out"
  backend="$("$fwh" status 2>/dev/null | sed -n 's/^BACKEND=//p' | head -n1 || true)"
  case "$rc:$backend" in
    0:firewalld|0:ufw) info "firewall ($backend): ports opened";
      if [ "$INST_CP" = 1 ] && [ "$OPEN_CP_PORT" = 1 ]; then
        if [ -n "$CONSOLE_FROM" ]; then info "$(t fw_console_from "$CP_PORT" "$CONSOLE_FROM")"; else warn "$(t fw_console_open "$CP_PORT")"; fi
      fi;;
    0:*) info "$(t fw_none)";;
    2:*) warn "$(t fw_manual "${backend:-?}")"; printf '%s\n' "$out" | sed -n '/^[a-z#]/{/^toutwaf-firewall/!p}' | while IFS= read -r l; do warn "    $l"; done;;
    *) warn "$(t fw_failed "$out")";;
  esac
  if [ "$INST_CP" = 1 ]; then warn "$(t p_dpapi_warn) (--console-from / Settings > Firewall)"; fi
  return 0
}

set_caps() {
  [ "$STAGING" = 1 ] && return 0
  if want_dp && have setcap && [ -e "$BIN_DIR/toutwaf-dp" ]; then
    # also lets a manually started toutwaf-dp bind 80/443 as the toutwaf user (systemd uses AmbientCapabilities)
    run setcap 'cap_net_bind_service=+ep' "$BIN_DIR/toutwaf-dp" || warn "setcap failed (the systemd unit still grants the capability)"
  fi
  return 0
}

# ------------------------------------------------------------------------------------------------ health + rollback
wait_healthy() {
  local url="http://127.0.0.1:9101/healthz" _
  for _ in $(seq 1 30); do curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null && return 0; sleep 1; done
  return 1
}
wait_cp_healthy() {
  local code _
  for _ in $(seq 1 30); do
    code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 2 "https://127.0.0.1:$CP_PORT/healthz" 2>/dev/null || true)"
    if [ "$code" = 200 ]; then return 0; fi
    sleep 1
  done
  return 1
}

rollback_dp() {
  warn "$(t w_rollback)"
  if [ -x "$BIN_DIR/toutwaf-dp.prev" ]; then
    mv -f "$BIN_DIR/toutwaf-dp.prev" "$BIN_DIR/toutwaf-dp"
    systemctl restart toutwaf-dp || true
    wait_healthy && warn "rolled back to the previous version" || warn "rollback copy also unhealthy: check 'journalctl -u toutwaf-dp'"
  else
    warn "no previous binary to roll back to; check 'journalctl -u toutwaf-dp'"
  fi
  die "toutwaf-dp did not become healthy ($(t w_rollback))"
}
DB_BACKUP_DIR=""
rollback_cp() {
  warn "$(t w_rollback)"
  systemctl stop toutwaf-cp 2>/dev/null || true
  if [ -x "$BIN_DIR/toutwaf-cp.prev" ]; then
    mv -f "$BIN_DIR/toutwaf-cp.prev" "$BIN_DIR/toutwaf-cp"
    if [ -n "$DB_BACKUP_DIR" ] && [ -d "$DB_BACKUP_DIR" ]; then cp -a "$DB_BACKUP_DIR"/. "$DATA_DIR"/ 2>/dev/null && chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR" 2>/dev/null || true; fi
    systemctl restart toutwaf-cp || true
    wait_cp_healthy && warn "rolled back to the previous version" || warn "rollback copy also unhealthy: check 'journalctl -u toutwaf-cp'"
  else
    warn "no previous binary to roll back to; check 'journalctl -u toutwaf-cp'"
  fi
  die "toutwaf-cp did not become healthy ($(t w_rollback))"
}

# BEGIN update-db-backup (extracted by tests/update-db-backup-test.sh: keep the markers)
# SQLite, run by hand (no update program around): what the copy really costs. The write-ahead log is merged into the database first (by the
# installed control plane, as the service account); if the new control plane has no migration to apply, the previous version reads the same
# file after a rollback and no copy is made; otherwise the disk is checked BEFORE the service is stopped, the copy is checked, and a copy
# that cannot be made stops the update (it used to go on without one).
db_size_bytes() { local f s t=0; for f in "$@"; do [ -f "$f" ] || continue; s="$(stat -c %s "$f" 2>/dev/null || echo 0)"; t=$((t + s)); done; printf '%s' "$t"; }
backup_sqlite_before_update() {
  local dir="$1" db="$DATA_DIR/toutwaf.db" newcp="${SRC_DIR:-}/toutwaf-cp" st applied known need free fmb sz wal
  [ -f "$db" ] || return 0
  if [ -x "$(cp_exe)" ] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$SVC_USER" -- "$(cp_exe)" db-snapshot --db "$db" --checkpoint-only >>"$LOG" 2>&1 || log "the write-ahead log could not be merged first (the installed control plane predates it)"
  fi
  if [ -x "$newcp" ]; then
    st="$("$newcp" schema-status --db "$db" 2>>"$LOG" | tail -n1 || true)"
    applied="$(printf '%s' "$st" | sed -n 's/.*"applied":\([0-9][0-9]*\).*/\1/p')"; known="$(printf '%s' "$st" | sed -n 's/.*"known":\([0-9][0-9]*\).*/\1/p')"
    if [ -n "$applied" ] && [ -n "$known" ] && [ "$applied" -ge "$known" ]; then
      info "no database migration is pending (schema $applied): the previous version reads the same database after a rollback, so no copy of it is made"
      return 0
    fi
  fi
  sz="$(db_size_bytes "$db")"; wal="$(db_size_bytes "$db-wal")"
  # MB: the database, what of the log can still hold pages the file does not have (the service's clean stop merges the rest; at most a tenth
  # of the database), and a tenth more for the way the copy lands
  local sz_mb=$((sz / 1024 / 1024)) wal_mb=$((wal / 1024 / 1024)) allow
  allow=$((sz_mb / 10 + 64)); [ "$wal_mb" -ge "$allow" ] || allow="$wal_mb"
  need=$(( (sz_mb + allow) * 11 / 10 + 64 ))
  fmb="$(df -Pm "$DATA_DIR/backup" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  case "$fmb" in ""|*[!0-9]*) fmb="";; esac
  if [ -n "$fmb" ] && [ "$fmb" -lt "$need" ]; then
    die "not enough free disk space on the disk of $DATA_DIR/backup: $fmb MB free, about $need MB needed for the copy of the database before the migration (toutwaf.db $sz_mb MB, toutwaf.db-wal $wal_mb MB). Nothing was changed. Free that space, move the data directory to a larger disk, reduce the retention of events, or delete the older copies in $DATA_DIR/backup/pre-update-*/db, then try again"
  fi
  if svc_active toutwaf-cp; then systemctl stop toutwaf-cp; fi      # consistent copy of the SQLite files (restarted below)
  if ! cp -a "$DATA_DIR"/toutwaf.db* "$DATA_DIR"/master.key "$dir/db/" 2>>"$LOG"; then
    rm -rf "$dir/db"
    if [ "$HAS_SYSTEMD" = 1 ]; then systemctl start toutwaf-cp 2>/dev/null || true; fi
    die "the copy of the database before the update could not be completed (is the disk full? see $LOG). Nothing was replaced and the service was started again"
  fi
  DB_BACKUP_DIR="$dir/db"
}

# update: snapshot configuration, unit files and (for the control plane) the database before replacing anything
backup_before_update() {
  [ "$STAGING" = 1 ] && return 0
  local ts dir; ts="$(date -u +%Y%m%dT%H%M%SZ)"; dir="$DATA_DIR/backup/pre-update-$ts"
  mkdir -p "$dir"; chmod 0700 "$dir"
  tar -czf "$dir/etc-toutwaf.tar.gz" -C / "${CONF_DIR#/}" etc/systemd/system 2>/dev/null || true
  if [ "$INST_CP" = 1 ] && want_cp; then
    mkdir -p "$dir/db"
    if [ "$(db_existing_engine)" = postgres ]; then
      # a database server: a verified pg_dump before the migrations of the new version run (the service keeps running, MVCC gives a consistent dump)
      cp -a "$DATA_DIR"/master.key "$dir/db/" 2>/dev/null || true
      if runuser -u "$SVC_USER" -- "$(cp_exe)" db backup --config "$CONF_DIR/toutwaf-cp.yaml" --dir "$dir/db" --keep 1 >>"$LOG" 2>&1; then DB_BACKUP_DIR="$dir/db"; else warn "the database could not be dumped before the update (see the log): the migrations of the new version will run without this safety copy"; fi
    elif [ "${TOUTWAF_UPDATE_DB_HANDLED:-0}" = 1 ]; then
      # started by toutwafctl upgrade-host: it has saved the database itself (a consistent copy in its private directory) or found that
      # nothing is to be migrated; a second copy of a database of many gigabytes here would only fill the disk
      info "the database is looked after by the update program: no second copy here"
    else
      backup_sqlite_before_update "$dir"
    fi
  fi
  chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR/backup" 2>/dev/null || true
  # keep the five most recent pre-update snapshots (configuration), and the copy of the database in the two newest only
  ls -1d "$DATA_DIR"/backup/pre-update-* 2>/dev/null | sort | head -n -5 | while IFS= read -r old; do rm -rf "$old"; done || true
  ls -1d "$DATA_DIR"/backup/pre-update-* 2>/dev/null | sort | head -n -2 | while IFS= read -r old; do [ ! -d "$old/db" ] || rm -rf "$old/db"; done || true
  info "backup written to $dir"
  return 0
}
# END update-db-backup

# ------------------------------------------------------------------------------------------------ database
# BEGIN db-setup
# The control plane stores its data in a database: PostgreSQL (recommended; the only engine for several control planes) or SQLite (one file,
# small installations on one server). This block does EVERYTHING itself, with no SQL to type:
#   local     installs the PostgreSQL server package of the distribution if missing, initialises the cluster, starts and enables the service,
#             creates the database and a dedicated user (no superuser, random password, scram-sha-256), listens on the loopback only, sizes
#             the server for this machine, schedules a daily verified pg_dump, then applies the schema and checks it
#   existing  with an administrator connection (given once, kept in memory) creates the user and the database; with only the application
#             connection creates or upgrades the schema; when the rights are not enough, prints the exact GRANT statements
# Every step can be run again; a failed run undoes what it created. Passwords are never printed, never put on a command line, never logged:
# they travel through files of mode 0600 and standard input.
db_log() { log "db: $*"; }
db_die() { db_undo; die "$@"; }
db_secret_file() { printf '%s' "$(p "$CONF_DIR/db.dsn")"; }
# the engine of an existing installation, read from its configuration (empty when it has none)
db_existing_engine() {
  local f; f="$(p "$CONF_DIR/toutwaf-cp.yaml")"
  [ -r "$f" ] || return 0
  sed -n 's/^[[:space:]]*driver:[[:space:]]*\([a-z]*\).*/\1/p' "$f" | head -n1
}

# the machine's memory in MB (from /proc/meminfo, or TOUTWAF_TEST_MEM_MB in tests)
db_mem_mb() {
  if [ -n "${TOUTWAF_TEST_MEM_MB:-}" ]; then printf '%s' "$TOUTWAF_TEST_MEM_MB"; return 0; fi
  awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || printf '2048'
}

# conservative server settings for this machine: the control plane may share it with the data plane
db_tuning() {
  local mem sb ec wm mw; mem="$(db_mem_mb)"; [ -n "$mem" ] || mem=2048
  sb=$((mem * 15 / 100)); [ "$sb" -ge 128 ] || sb=128; [ "$sb" -le 1024 ] || sb=1024
  ec=$((mem * 40 / 100)); [ "$ec" -ge 256 ] || ec=256
  wm=4; [ "$mem" -lt 3072 ] || wm=8; [ "$mem" -lt 16384 ] || wm=16
  mw=64; [ "$mem" -lt 3072 ] || mw=128; [ "$mem" -lt 16384 ] || mw=256
  cat <<EOT
# written by the ToutWAF installer; edit freely, it is not overwritten (delete the file to have it generated again)
listen_addresses = '127.0.0.1'
password_encryption = 'scram-sha-256'
max_connections = 100
shared_buffers = ${sb}MB
effective_cache_size = ${ec}MB
work_mem = ${wm}MB
maintenance_work_mem = ${mw}MB
log_min_duration_statement = 1000
log_lock_waits = on
idle_in_transaction_session_timeout = '10min'
EOT
}

# packages of the server and of the client tools (pg_dump) per distribution family
db_packages() {   # db_packages server|client -> package names
  case "${FAMILY:-${FAMILY_GUESS:-}}:$1" in
    debian:server) echo "postgresql";;
    debian:client) echo "postgresql-client";;
    rhel:server) echo "postgresql-server postgresql";;
    rhel:client) echo "postgresql";;
    amazon:server) echo "postgresql15-server postgresql15";;
    amazon:client) echo "postgresql15";;
    suse:server) echo "postgresql-server postgresql";;
    suse:client) echo "postgresql";;
    arch:*) echo "postgresql";;
    *) return 1;;
  esac
}

db_pkg_manager() {
  case "$(pf_fam "${FAMILY:-${FAMILY_GUESS:-}}" 3)" in
    dnf) if have dnf; then echo dnf; elif have yum; then echo yum; fi;;
    apt) have apt-get && echo apt;;
    zypper) have zypper && echo zypper;;
    pacman) have pacman && echo pacman;;
  esac
}

# run a command as the PostgreSQL system user
db_as_pg() { if [ "$(id -u)" = 0 ]; then runuser -u postgres -- "$@"; else "$@"; fi; }
# shellcheck disable=SC2120  # forwards the optional arguments of psql; the callers send the SQL on the standard input
db_psql() { db_as_pg psql -X -q -v ON_ERROR_STOP=1 -At -d postgres "$@"; }   # SQL on the standard input, never on the command line

DB_PG_GLOBS="${TOUTWAF_TEST_PG_GLOBS:-/usr/lib/postgresql/*/bin/postgres /usr/pgsql-*/bin/postgres}"   # (the variable is a test hook)
db_server_installed() { local g; have postgres && return 0; for g in $DB_PG_GLOBS; do [ -x "$g" ] && return 0; done; return 1; }

db_pg_major() {   # major version of the installed server
  local v; v="$( { postgres --version || ls -d /usr/lib/postgresql/*/ /usr/pgsql-*/ 2>/dev/null | tail -n1; } 2>/dev/null | grep -o '[0-9][0-9]*' | head -n1)"
  case "$v" in ""|*[!0-9]*) v="";; esac
  printf '%s' "$v"
}

db_install_server() {
  if db_server_installed && have psql; then db_log "PostgreSQL is already installed"; return 0; fi
  local fam="${FAMILY:-${FAMILY_GUESS:-}}" pm pk
  pk="$(db_packages server)" || db_die "$(t db_no_pkg)"
  pm="$(db_pkg_manager)"; [ -n "$pm" ] || db_die "$(t db_no_pkg)"
  # Red Hat 8: the default stream is too old
  if [ "$pm" = dnf ] && [ "$fam" = rhel ] && [ "${OS_VER%%.*}" = 8 ]; then run dnf -y module enable postgresql:15 || true; fi
  db_log "installing $pk with $pm"
  # shellcheck disable=SC2086
  pkg_install "$pm" $pk || db_die "$(t db_install_failed)"
  # shellcheck disable=SC2034  # set when this run installed the database server package; no step reads it yet
  DB_UNDO_PKG=1
  return 0
}

# find the files of the running server (works on every distribution because the server tells where they are)
db_cluster_init() {
  local fam="${FAMILY:-${FAMILY_GUESS:-}}"
  local rh="${TOUTWAF_TEST_PGDATA:-/var/lib/pgsql/data}" ar="${TOUTWAF_TEST_PGDATA:-/var/lib/postgres/data}"   # (the variable is a test hook)
  case "$fam" in
    rhel|amazon)
      if [ ! -f "$rh/PG_VERSION" ]; then
        db_log "initialising the cluster"
        if have postgresql-setup; then postgresql-setup --initdb >>"$LOG" 2>&1 || db_die "$(t db_init_failed)"; else db_as_pg initdb -D "$rh" -A scram-sha-256 >>"$LOG" 2>&1 || db_die "$(t db_init_failed)"; fi
      fi;;
    arch)
      if [ ! -f "$ar/PG_VERSION" ]; then
        db_log "initialising the cluster"
        db_as_pg initdb -D "$ar" --locale=C.UTF-8 -E UTF8 >>"$LOG" 2>&1 || db_die "$(t db_init_failed)"
      fi;;
    debian)
      if have pg_lsclusters && [ -z "$(pg_lsclusters -h 2>/dev/null)" ] && have pg_createcluster; then
        local v; v="$(ls /usr/lib/postgresql 2>/dev/null | sort -V | tail -n1)"
        db_log "creating the cluster $v/main"
        pg_createcluster "$v" main >>"$LOG" 2>&1 || db_die "$(t db_init_failed)"
      fi;;
  esac
  return 0
}

db_service() { printf 'postgresql'; }

db_start_server() {
  if [ "$HAS_SYSTEMD" = 1 ]; then
    systemctl enable "$(db_service)" >>"$LOG" 2>&1 || true
    systemctl start "$(db_service)" >>"$LOG" 2>&1 || db_die "$(t db_start_failed)"
  fi
  local i=0
  while [ "$i" -lt 30 ]; do
    if db_as_pg pg_isready -q 2>/dev/null; then return 0; fi
    sleep 1; i=$((i + 1))
  done
  db_die "$(t db_start_failed)"
}

DB_SOCKDIR=""; DB_CONF=""; DB_HBA=""
db_discover() {
  DB_SOCKDIR="$(printf 'SHOW unix_socket_directories;\n' | db_psql | cut -d, -f1 | tr -d ' ')"
  DB_CONF="$(printf 'SHOW config_file;\n' | db_psql)"
  DB_HBA="$(printf 'SHOW hba_file;\n' | db_psql)"
  [ -n "$DB_SOCKDIR" ] && [ -n "$DB_CONF" ] && [ -n "$DB_HBA" ] || db_die "$(t db_start_failed)"
}

# a self-signed certificate for the loopback listener (TLS on, so that the day a replica or a tool connects it is encrypted)
db_tls_files() {
  have openssl || return 1
  local d; d="$(p "$CONF_DIR/pg")"
  if [ ! -s "$d/server.crt" ]; then
    install -d -m 0750 -o postgres -g postgres "$d" 2>/dev/null || install -d -m 0750 "$d"
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
      -keyout "$d/server.key" -out "$d/server.crt" >>"$LOG" 2>&1 || return 1
    chown postgres:postgres "$d/server.key" "$d/server.crt" 2>/dev/null || true
    chmod 0600 "$d/server.key"; chmod 0644 "$d/server.crt"
  fi
  printf '%s' "$d"
}

db_configure_server() {
  local cdir conf d inc
  cdir="$(dirname "$DB_CONF")"
  if [ -d "$cdir/conf.d" ]; then conf="$cdir/conf.d/toutwaf.conf"; inc=""; else conf="$cdir/toutwaf.conf"; inc="include_if_exists = 'toutwaf.conf'"; fi
  if [ ! -s "$conf" ]; then
    db_tuning >"$conf"
    if d="$(db_tls_files)"; then printf "ssl = on\nssl_cert_file = '%s/server.crt'\nssl_key_file = '%s/server.key'\n" "$d" "$d" >>"$conf"; fi
    chown postgres "$conf" 2>/dev/null || true; chmod 0644 "$conf"
    DB_NEEDS_RESTART=1
  fi
  if [ -n "$inc" ] && ! grep -qF "$inc" "$DB_CONF" 2>/dev/null; then printf '\n# ToutWAF\n%s\n' "$inc" >>"$DB_CONF"; DB_NEEDS_RESTART=1; fi
  # pg_hba.conf: the user of the control plane authenticates with scram-sha-256 on the socket and on the loopback, ahead of any other rule
  if ! grep -q '^# BEGIN toutwaf' "$DB_HBA" 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    {
      printf '# BEGIN toutwaf (managed by the ToutWAF installer)\n'
      printf 'local   %s   %s   scram-sha-256\n' "$DB_NAME" "$DB_USER"
      printf 'host    %s   %s   127.0.0.1/32   scram-sha-256\n' "$DB_NAME" "$DB_USER"
      printf 'host    %s   %s   ::1/128        scram-sha-256\n' "$DB_NAME" "$DB_USER"
      printf '# END toutwaf\n'
      cat "$DB_HBA"
    } >"$tmp"
    cat "$tmp" >"$DB_HBA"; rm -f "$tmp"
    DB_NEEDS_RELOAD=1
  fi
  if [ "${DB_NEEDS_RESTART:-0}" = 1 ] && [ "$HAS_SYSTEMD" = 1 ]; then
    systemctl restart "$(db_service)" >>"$LOG" 2>&1 || db_die "$(t db_start_failed)"
    local i=0; while [ "$i" -lt 30 ]; do db_as_pg pg_isready -q 2>/dev/null && break; sleep 1; i=$((i + 1)); done
  elif [ "${DB_NEEDS_RELOAD:-0}" = 1 ]; then
    printf 'SELECT pg_reload_conf();\n' | db_psql >/dev/null
  fi
  return 0
}

db_random_password() {
  local pw; pw="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom 2>/dev/null | head -c 32 || true)"
  [ "${#pw}" -ge 24 ] || pw="$(openssl rand -hex 24)"
  printf '%s' "$pw"
}

# DSN of the application user for a unix socket / host
db_make_dsn() {   # host port user password database tls ca
  local host="$1" port="$2" user="$3" pw="$4" name="$5" tls="$6" ca="$7" enc q=""
  enc="$(printf '%s' "$pw" | od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g')"
  [ -z "$tls" ] || q="sslmode=$tls"
  [ -z "$ca" ] || q="${q:+$q&}sslrootcert=$ca"
  case "$host" in
    /*) printf 'postgres://%s:%s@/%s?host=%s%s%s' "$user" "$enc" "$name" "$host" "${port:+&port=$port}" "${q:+&$q}";;
    *) printf 'postgres://%s:%s@%s%s/%s%s' "$user" "$enc" "$host" "${port:+:$port}" "$name" "${q:+?$q}";;
  esac
}

# write the DSN secret file: mode 0600, owned by the service user, atomically
db_write_secret() {
  local f; f="$(db_secret_file)"
  ( umask 077; printf '%s\n' "$1" >"$f.new" ) || db_die "cannot write $f"
  chmod 0600 "$f.new"
  if [ "$STAGING" = 0 ]; then chown "$SVC_USER:$SVC_USER" "$f.new" 2>/dev/null || true; fi
  mv -f "$f.new" "$f"
  DB_SECRET_WRITTEN=1
}

# local installation: package, cluster, service, configuration, user and database (psql as the postgres user), secret file
db_setup_local() {
  local f pw exists_role exists_db
  f="$(db_secret_file)"
  db_install_server
  db_cluster_init
  db_start_server
  local major; major="$(db_pg_major)"
  if [ -n "$major" ] && [ "$major" -lt 13 ]; then db_die "$(t db_too_old "$major")"; fi
  db_discover
  db_configure_server
  exists_role="$(printf "SELECT 1 FROM pg_roles WHERE rolname='%s';\n" "$DB_USER" | db_psql)"
  exists_db="$(printf "SELECT 1 FROM pg_database WHERE datname='%s';\n" "$DB_NAME" | db_psql)"
  if [ -s "$f" ] && [ -n "$exists_role" ] && [ -n "$exists_db" ]; then
    db_log "the user and the database already exist and the secret file is in place: nothing to create"
    DB_RESULT="kept"; DB_SERVER_LOCAL=1
    return 0
  fi
  if [ -n "$exists_role" ] || [ -n "$exists_db" ]; then
    # something of the same name that we do not own (no secret file): never take it over, never reset a password we did not set
    db_die "$(t db_exists "$DB_USER" "$DB_NAME")"
  fi
  pw="$(db_random_password)"
  # the password goes to psql on the standard input only
  if ! printf "CREATE ROLE \"%s\" LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;\n" "$DB_USER" "$pw" | db_psql >/dev/null; then db_die "$(t db_create_failed)"; fi
  DB_UNDO_ROLE=1
  if ! printf 'CREATE DATABASE "%s" OWNER "%s" ENCODING '"'UTF8'"' TEMPLATE template0;\nREVOKE ALL ON DATABASE "%s" FROM PUBLIC;\nGRANT CONNECT, TEMPORARY ON DATABASE "%s" TO "%s";\nGRANT pg_monitor TO "%s";\n' \
        "$DB_NAME" "$DB_USER" "$DB_NAME" "$DB_NAME" "$DB_USER" "$DB_USER" | db_psql >/dev/null; then db_die "$(t db_create_failed)"; fi
  DB_UNDO_DB=1
  db_write_secret "$(db_make_dsn "$DB_SOCKDIR" "" "$DB_USER" "$pw" "$DB_NAME" "" "")"
  pw=""
  DB_RESULT="created"
  DB_SERVER_LOCAL=1
  return 0
}

# an existing server: an administrator connection creates the user and the database; the application connection alone creates the schema
db_setup_existing() {
  local cp; cp="$(cp_exe)"; local f; f="$(db_secret_file)"
  if [ -n "$DB_DSN_FILE" ]; then
    ( umask 077; cp "$DB_DSN_FILE" "$f.new" ) 2>/dev/null || db_die "cannot read $DB_DSN_FILE"; [ -s "$f.new" ] || db_die "empty DSN file"
    chmod 0600 "$f.new"; [ "$STAGING" = 1 ] || chown "$SVC_USER:$SVC_USER" "$f.new" 2>/dev/null || true; mv -f "$f.new" "$f"; DB_SECRET_WRITTEN=1
  elif [ -n "$DB_DSN" ]; then
    db_write_secret "$DB_DSN"
  fi
  if [ -s "$f" ] && [ -z "$DB_DSN$DB_DSN_FILE" ] && [ "$DB_SECRET_WRITTEN" = 0 ]; then
    # a previous run left the connection of the application user: the user and the database exist, nothing to create and no administrator
    # connection needed; the schema is brought up to date below
    db_log "the connection file is already in place: nothing to create"
    DB_RESULT="kept"; return 0
  fi
  if [ -n "$DB_ADMIN_DSN_FILE" ] || [ -n "${TOUTWAF_DB_ADMIN_DSN:-}" ]; then
    local pwargs=()
    [ -z "$DB_PASSWORD_FILE" ] || pwargs=(--app-password-file "$DB_PASSWORD_FILE")
    local args=(db provision --database "$DB_NAME" --user "$DB_USER" --dsn-out -)
    [ -z "$DB_HOST" ] || args+=(--app-host "$DB_HOST"); [ -z "$DB_PORT" ] || args+=(--app-port "$DB_PORT")
    [ -z "$DB_TLS_MODE" ] || args+=(--tls-mode "$DB_TLS_MODE"); [ -z "$DB_CA" ] || args+=(--ca-file "$DB_CA")
    local out rc
    if [ -n "$DB_ADMIN_DSN_FILE" ]; then
      out="$("$cp" "${args[@]}" "${pwargs[@]}" --admin-dsn-file "$DB_ADMIN_DSN_FILE" 2>>"$LOG")" && rc=0 || rc=$?
    else
      out="$(printf '%s\n' "$TOUTWAF_DB_ADMIN_DSN" | "$cp" "${args[@]}" "${pwargs[@]}" --admin-dsn-stdin 2>>"$LOG")" && rc=0 || rc=$?
    fi
    unset TOUTWAF_DB_ADMIN_DSN
    if [ "$rc" = 3 ]; then db_print_grants; db_die "$(t db_rights)"; fi
    [ "$rc" = 0 ] || db_die "$(t db_create_failed)"
    if [ -n "$out" ]; then db_write_secret "$out"; DB_RESULT="created"; else DB_RESULT="kept"; fi
  else
    # only the application connection: the database and the user must exist
    if [ -z "$DB_DSN$DB_DSN_FILE" ]; then
      if [ -n "$DB_HOST" ] && [ -n "$DB_PASSWORD_FILE" ]; then
        db_write_secret "$(db_make_dsn "$DB_HOST" "${DB_PORT:-5432}" "$DB_USER" "$(tr -d '\r\n' <"$DB_PASSWORD_FILE")" "$DB_NAME" "${DB_TLS_MODE:-prefer}" "$DB_CA")"
      elif [ ! -s "$f" ]; then db_die "$(t db_need_conn)"; fi
    fi
    DB_RESULT="schema"
  fi
  return 0
}

db_say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&3 2>/dev/null || true; }   # to the terminal even from inside a step (whose output goes to the log)
db_print_grants() {
  db_say ""
  "$(cp_exe)" db grants --database "$DB_NAME" --user "$DB_USER" 2>/dev/null | while IFS= read -r l; do db_say "    $l"; done
  db_say ""
}

# the schema, the check and the summary
db_apply_schema() {
  local cp rc out; cp="$(cp_exe)"
  [ -x "$cp" ] || { warn "toutwaf-cp is not installed yet: the schema is applied at the first start"; return 0; }
  # run as the service user: this is exactly how the service will connect
  if [ "$STAGING" = 0 ] && [ "$(id -u)" = 0 ]; then
    out="$(runuser -u "$SVC_USER" -- "$cp" db init --dsn-file "$(db_secret_file)" ${DB_TLS_MODE:+--tls-mode "$DB_TLS_MODE"} ${DB_CA:+--ca-file "$DB_CA"} 2>&1)" && rc=0 || rc=$?
  else
    out="$("$cp" db init --dsn-file "$(db_secret_file)" ${DB_TLS_MODE:+--tls-mode "$DB_TLS_MODE"} ${DB_CA:+--ca-file "$DB_CA"} 2>&1)" && rc=0 || rc=$?
  fi
  printf '%s\n' "$out" >>"$LOG"
  if [ "$rc" = 3 ]; then printf '%s\n' "$out" | sed 's/^/    /' >&3 2>/dev/null || true; db_die "$(t db_rights)"; fi
  [ "$rc" = 0 ] || db_die "$(t db_schema_failed)"
  DB_SCHEMA_LINE="$(printf '%s\n' "$out" | tail -n1)"
  return 0
}

# the daily dump: a systemd timer that runs `toutwaf-cp db backup` as the service user (verified, rotated, status for the console)
db_backup_units() {
  [ "$DB_BACKUP_TIMER" = 1 ] && [ "$HAS_SYSTEMD" = 1 ] || return 0
  local sd; sd="$(p /etc/systemd/system)"; mkdir -p "$sd"
  local pk; pk="$(db_packages client 2>/dev/null || true)"
  if ! have pg_dump && ! ls /usr/lib/postgresql/*/bin/pg_dump >/dev/null 2>&1 && [ -n "$pk" ]; then
    local pm; pm="$(db_pkg_manager)"; # shellcheck disable=SC2086
    [ -z "$pm" ] || pkg_install "$pm" $pk >>"$LOG" 2>&1 || warn "$(t db_no_pgdump)"
  fi
  cat >"$sd/toutwaf-db-backup.service" <<EOT
[Unit]
Description=ToutWAF database backup (pg_dump, verified, rotated)
After=postgresql.service network-online.target

[Service]
Type=oneshot
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=-$CONF_DIR/cp.env
ExecStart=$BIN_DIR/toutwaf-cp db backup --config $CONF_DIR/toutwaf-cp.yaml --dir $DATA_DIR/db-backups --keep 7
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$DATA_DIR
ReadOnlyPaths=$CONF_DIR
UMask=0077
EOT
  cat >"$sd/toutwaf-db-backup.timer" <<EOT
[Unit]
Description=Daily ToutWAF database backup

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=20min
Persistent=true

[Install]
WantedBy=timers.target
EOT
  if [ "$DRY_RUN" = 0 ]; then
    systemctl daemon-reload >>"$LOG" 2>&1 || true
    systemctl enable --now toutwaf-db-backup.timer >>"$LOG" 2>&1 || warn "the backup timer could not be enabled"
  fi
  DB_BACKUP_SCHEDULED=1
}

# the control plane starts after a local PostgreSQL (a drop-in: the unit file itself is left alone)
db_unit_dropin() {
  [ "$HAS_SYSTEMD" = 1 ] || return 0
  [ "$DB_SERVER_LOCAL" = 1 ] || return 0
  local d; d="$(p /etc/systemd/system/toutwaf-cp.service.d)"; mkdir -p "$d"
  printf '[Unit]\nAfter=postgresql.service\nWants=postgresql.service\n' >"$d/database.conf"
}

# undo what this run created, when a later step fails
db_undo() {
  [ "${DB_UNDO_DB:-0}" = 1 ] && printf 'DROP DATABASE IF EXISTS "%s";\n' "$DB_NAME" | db_psql >/dev/null 2>&1
  [ "${DB_UNDO_ROLE:-0}" = 1 ] && printf 'DROP ROLE IF EXISTS "%s";\n' "$DB_USER" | db_psql >/dev/null 2>&1
  if [ "${DB_SECRET_WRITTEN:-0}" = 1 ]; then rm -f "$(db_secret_file)"; fi
  return 0
}

# the whole database phase of an installation
phase_database() {
  [ "$DRY_RUN" = 1 ] && return 0
  local existing; existing="$(db_existing_engine)"
  if [ -n "$existing" ]; then
    # an installation that already has a configuration keeps its database exactly as it is
    DB_ENGINE="$existing"; DB_RESULT="unchanged"
    if [ "$existing" = postgres ] && [ -s "$(db_secret_file)" ]; then DB_SERVER_LOCAL="$(db_unit_dropin_present && echo 1 || echo 0)"; fi
    return 0
  fi
  if [ -z "$DB_ENGINE" ]; then DB_ENGINE=sqlite; DB_RESULT="default"; return 0; fi
  if [ "$DB_ENGINE" = sqlite ]; then DB_RESULT="sqlite"; return 0; fi
  if [ "$DB_LOCAL" = 1 ]; then db_setup_local; else db_setup_existing; fi
  db_apply_schema
  db_backup_units
  db_unit_dropin
  db_log "done: $DB_RESULT"
  return 0
}
db_unit_dropin_present() { [ -f "$(p /etc/systemd/system/toutwaf-cp.service.d/database.conf)" ]; }

# the database section of toutwaf-cp.yaml
db_yaml() {
  if [ "$DB_ENGINE" = postgres ]; then
    printf 'database:\n  driver: postgres\n  dsn_file: %s\n' "$CONF_DIR/db.dsn"
    [ -z "$DB_TLS_MODE" ] || printf '  tls_mode: %s\n' "$DB_TLS_MODE"
    [ -z "$DB_CA" ] || printf '  ca_file: %s\n' "$DB_CA"
  else
    printf 'database:\n  driver: sqlite\n'
  fi
}

# the plain summary, shown at the end of the database step (no secret in it)
db_summary() {
  case "$DB_ENGINE:$DB_RESULT" in
    *:unchanged|*:"") ;;
    sqlite:default) say "  $BUL $(t db_hint)";;
    postgres:*)
      say "  $BUL $(t db_sum_engine "PostgreSQL")"
      if [ "$DB_SERVER_LOCAL" = 1 ]; then say "  $BUL $(t db_sum_local "$DB_NAME" "$DB_USER")"; else say "  $BUL $(t db_sum_remote "$DB_NAME" "$DB_USER")"; fi
      [ -z "${DB_SCHEMA_LINE:-}" ] || say "  $BUL $(t db_sum_schema "$DB_SCHEMA_LINE")"
      say "  $BUL $(t db_sum_secret "$CONF_DIR/db.dsn")"
      if [ "${DB_BACKUP_SCHEDULED:-0}" = 1 ]; then say "  $BUL $(t db_sum_backup)"; else say "  $BUL $(t db_sum_nobackup)"; fi;;
    sqlite:*) say "  $BUL $(t db_sum_sqlite)";;
  esac
}

# the questions of the interactive mode
db_ask() {
  local c sub ok an ap enc
  # shellcheck disable=SC2034  # set when the person was asked; no step reads it yet
  DB_ASKED=1
  say ""; say "  $(paint "$B" "$(t db_choose)")"
  say "    1) $(t db_opt_pg)"
  say "    2) $(t db_opt_sqlite)"
  ask c "$(t choice)" 1
  if [ "$c" = 2 ]; then DB_ENGINE=sqlite; say "  $D$(t db_sqlite_note)$R"; return 0; fi
  DB_ENGINE=postgres
  say "    1) $(t db_opt_pg_local)"
  say "    2) $(t db_opt_pg_remote)"
  ask sub "$(t choice)" 1
  if [ "$sub" != 2 ]; then DB_LOCAL=1; return 0; fi
  ask DB_HOST "$(t db_q_host)" "${DB_HOST:-127.0.0.1}"
  ask DB_PORT "$(t db_q_port)" "${DB_PORT:-5432}"
  ask DB_NAME "$(t db_q_name)" "$DB_NAME"
  ask DB_USER "$(t db_q_user)" "$DB_USER"
  ask DB_TLS_MODE "$(t db_q_tls)" "${DB_TLS_MODE:-prefer}"
  case "$DB_TLS_MODE" in verify-ca|verify-full) ask DB_CA "$(t db_q_ca)" "$DB_CA";; esac
  ask an "$(t db_q_admin)" ""
  if [ -n "$an" ]; then
    ask ap "$(t db_q_adminpw)" "" secret
    enc="$(printf '%s' "$ap" | od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g')"
    DB_ADMIN_DSN_FILE="$TMP/db-admin.dsn"
    ( umask 077; printf 'postgres://%s:%s@%s:%s/postgres?sslmode=%s%s\n' "$an" "$enc" "$DB_HOST" "$DB_PORT" "$DB_TLS_MODE" "${DB_CA:+&sslrootcert=$DB_CA}" >"$DB_ADMIN_DSN_FILE" )
    ap=""; enc=""
  fi
  ask ap "$(t db_q_pw)" "" secret
  if [ -n "$ap" ]; then DB_PASSWORD_FILE="$TMP/db-app.pw"; ( umask 077; printf '%s' "$ap" >"$DB_PASSWORD_FILE" ); fi
  ap=""
  return 0
}
# END db-setup

# ------------------------------------------------------------------------------------------------ install / update flow
CHANGED=0; OLD_DP=""; UPDATE_NOOP=0; PANEL_RAN=0
phase_account() { create_user; make_dirs; }
# The control plane serves the host agent builds to the servers of the cluster: the Linux ones ship in every archive (agent-dist/) and are kept next to the control
# plane data, replaced at every update. The ones for Windows, and the antivirus programs, come with the extras of the release (install_extras).
install_agent_dist() {
  local d="" src f own grp
  for src in "$(dirname "$SRC_DIR")/agent-dist" "$SRC_DIR/agent-dist"; do
    if [ -d "$src" ]; then d="$src"; break; fi
  done
  [ -n "$d" ] || { info "this release carries no host agent builds (the Cluster page cannot enrol servers until you update)"; return 0; }
  own="$([ "$STAGING" = 1 ] && id -un || echo "$SVC_USER")"; grp="$([ "$STAGING" = 1 ] && id -gn || echo "$SVC_USER")"
  run install -d -m 0750 -o "$own" -g "$grp" "$(p "$DATA_DIR/agent-dist")" || return 0
  for f in "$d"/toutwaf-agent-*; do
    [ -f "$f" ] || continue
    run install -m 0640 -o "$own" -g "$grp" "$f" "$(p "$DATA_DIR/agent-dist/$(basename "$f")")" || warn "could not install $(basename "$f")"
  done
  info "host agent builds installed in $DATA_DIR/agent-dist"
}
# ---- ToutWAF Cloud (--cloud-url): the node connects OUTBOUND to the hosted control plane through toutwaf-cloudlink --------------------------
# The link enrols the node (its key pair is made here, only the public key leaves), keeps one HTTPS connection to the account, and gives the data plane a
# control-plane address on the loopback interface (http://127.0.0.1:$CLOUDLINK_PORT). The data plane keeps filtering with its last policy if the cloud is
# unreachable. Nothing listens for the platform.
cloud_prepare() {
  case "$CLOUD_URL" in https://*) ;; *) die "$(t cloud_https)";; esac
  CLOUD_URL="${CLOUD_URL%/}"
  if [ "$COMPONENT" = all ]; then COMPONENT=dp; fi
  [ "$COMPONENT" = dp ] || die "$(t cloud_dp_only)"
  if [ -z "$ENROLL_TOKEN" ] && [ ! -f "$(p "$DATA_DIR/cloudlink/link.json")" ]; then
    if interactive; then ask ENROLL_TOKEN "$(t q_token)" "" secret; fi
    [ -n "$ENROLL_TOKEN" ] || die "$(t cloud_need_token)"
  fi
  if [ -n "$CLOUD_CA" ]; then
    case "$CLOUD_CA" in http://*|https://*) die "$(t cloud_ca_local)";; *) [ -f "$CLOUD_CA" ] || die "--cloud-ca: file not found: $CLOUD_CA";; esac
  fi
  # the data plane talks to the link, not to the internet: the enrolment token is consumed by the link, never written in the data plane's file
  CP_URL="http://127.0.0.1:$CLOUDLINK_PORT"
  CLOUD_ENROL_TOKEN="$ENROLL_TOKEN"; ENROLL_TOKEN=""
}
cloud_link_args() {
  local IFS=$' \t\n'; local a="" pin
  for pin in $CLOUD_PINS; do a="$a --pin $pin"; done
  [ -z "$CLOUD_CA" ] || a="$a --ca $CONF_DIR/certs/cloud-ca.pem"
  printf '%s' "$a"
}
# enrol the node with the account (once; a link that is already enrolled is left alone) and hand its local secret to the data plane
cloud_link_enrol() {
  local IFS=$' \t\n'   # the pins are split on blanks whatever the IFS of the caller
  [ -n "$CLOUD_URL" ] || return 0
  [ "$DRY_RUN" = 1 ] && return 0
  local dir; dir="$(p "$DATA_DIR/cloudlink")"
  run install -d -m 0700 "$dir"
  if [ -n "$CLOUD_CA" ]; then
    run install -d -m 0755 "$(p "$CONF_DIR/certs")"
    run cp "$CLOUD_CA" "$(p "$CONF_DIR/certs/cloud-ca.pem")"; run chmod 0644 "$(p "$CONF_DIR/certs/cloud-ca.pem")"
  fi
  if [ -f "$dir/link.json" ] && [ -f "$dir/node.key" ]; then info "the node is already enrolled with this account"
  else
    [ -n "$CLOUD_ENROL_TOKEN" ] || die "$(t cloud_need_token)"
    log "Enrolling this node with $CLOUD_URL"
    local -a eargs=(); local pin
    for pin in $CLOUD_PINS; do eargs+=(--pin "$pin"); done
    [ -z "$CLOUD_CA" ] || eargs+=(--ca "$(p "$CONF_DIR/certs/cloud-ca.pem")")
    if ! TOUTWAF_ENROL_TOKEN="$CLOUD_ENROL_TOKEN" "$(p "$BIN_DIR/toutwaf-cloudlink")" enrol --dir "$dir" --cloud-url "$CLOUD_URL" ${eargs[@]+"${eargs[@]}"} --name "$(hostname 2>/dev/null || echo node)" >>"$LOG" 2>&1; then
      tail -n 5 "$LOG" >&2
      die "$(t cloud_enrol_failed)"
    fi
  fi
  if [ "$STAGING" = 0 ]; then chown -R "$SVC_USER:$SVC_USER" "$dir"; fi
  NODE_TOKEN="$(cat "$dir/local.token" 2>/dev/null || true)"
  [ -n "$NODE_TOKEN" ] || die "$(t cloud_enrol_failed)"
  CLOUD_ENROL_TOKEN=""
}
cloud_link_unit() {
  [ -n "$CLOUD_URL" ] || [ -f "$(p "$DATA_DIR/cloudlink/link.json")" ] || return 0
  [ "$DRY_RUN" = 1 ] && return 0
  local sd envf; sd="$(p /etc/systemd/system)"; mkdir -p "$sd"
  envf="$(p "$CONF_DIR/cloudlink.env")"
  # the proxy of the machine is the one of the link: the values present at installation are kept in a file the administrator can edit
  if [ ! -e "$envf" ]; then
    { echo "# environment of toutwaf-cloudlink (systemctl restart toutwaf-cloudlink after a change)"
      echo "# HTTPS_PROXY=http://proxy.example.com:3128"
      echo "# NO_PROXY=localhost,127.0.0.1"
      [ -z "${HTTPS_PROXY:-}" ] || echo "HTTPS_PROXY=$HTTPS_PROXY"
      [ -z "${https_proxy:-}" ] || echo "https_proxy=$https_proxy"
      [ -z "${NO_PROXY:-}" ] || echo "NO_PROXY=$NO_PROXY"
    } >"$envf"; chmod 0640 "$envf"; if [ "$STAGING" = 0 ]; then chown "root:$SVC_USER" "$envf"; fi
  fi
  cat >"$sd/toutwaf-cloudlink.service" <<EOF
[Unit]
Description=ToutWAF Cloud link (outbound connection of this node to its hosted account)
Documentation=https://github.com/$REPO
After=network-online.target
Wants=network-online.target
Before=toutwaf-dp.service

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=-$CONF_DIR/cloudlink.env
ExecStart=$BIN_DIR/toutwaf-cloudlink run --dir $DATA_DIR/cloudlink --listen 127.0.0.1:$CLOUDLINK_PORT$(cloud_link_args)
Restart=always
RestartSec=2s
LimitNOFILE=65536
# --- sandboxing: it needs the network (outbound only) and its own directory, nothing else -----------------------------------
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources @mount @swap @reboot @raw-io @obsolete @debug @cpu-emulation @clock
UMask=0077
ReadWritePaths=$DATA_DIR/cloudlink
ReadOnlyPaths=$CONF_DIR

[Install]
WantedBy=multi-user.target
EOF
  # the data plane starts after the link (it asks it for its policy)
  if [ -e "$sd/toutwaf-dp.service" ] && ! grep -q 'toutwaf-cloudlink' "$sd/toutwaf-dp.service"; then
    sed -i 's/^After=network-online.target/After=network-online.target toutwaf-cloudlink.service/' "$sd/toutwaf-dp.service"
  fi
}
phase_binaries() {
  if want_dp; then
    OLD_DP="$(installed_label "$(p "$BIN_DIR/toutwaf-dp")")"; [ "$OLD_DP" != "?" ] || OLD_DP=""
    if install_binary toutwaf-dp; then CHANGED=1; fi
    if [ -n "$CLOUD_URL" ] || [ -x "$(p "$BIN_DIR/toutwaf-cloudlink")" ]; then
      if [ ! -e "$SRC_DIR/toutwaf-cloudlink" ] && [ "$DRY_RUN" = 0 ]; then die "$(t cloud_nolink)"; fi
      if install_binary toutwaf-cloudlink; then CHANGED=1; fi
    fi
  fi
  if want_cp; then
    if install_binary toutwaf-cp; then CHANGED=1; fi
    if install_binary toutwafctl; then CHANGED=1; fi
    install_agent_dist
    install_extras         # the Windows agents and the antivirus programs (obtain_extras unpacked them; nothing when there are none)
  fi
  link_cli
  return 0
}
phase_config() { if want_dp; then cloud_link_enrol; dp_config; fi; if want_cp; then cp_config; fi; return 0; }
phase_units() { write_units; cloud_link_unit; tune_sysctl; set_caps; return 0; }
prepare_panel() { prepare_panel_run; }

start_services() {
  # the update helper serves the console Updates page (cp) and update_engine (dp); the firewall helper serves Settings > Firewall (cp)
  if want_dp || want_cp; then systemctl enable --now toutwaf-upgrade.path >/dev/null 2>&1 || warn "could not enable toutwaf-upgrade.path"; fi
  # enabled, never started now: this installer may be running under the update helper, whose journal is still open
  if want_dp || want_cp; then systemctl enable toutwaf-upgrade-guard.service >/dev/null 2>&1 || warn "could not enable toutwaf-upgrade-guard.service"; fi
  if want_cp; then systemctl enable --now toutwaf-firewall.path >/dev/null 2>&1 || warn "could not enable toutwaf-firewall.path"; fi
  if want_cp; then systemctl enable --now toutwaf-blocklist.path >/dev/null 2>&1 || warn "could not enable toutwaf-blocklist.path"; fi
  if want_cp; then systemctl enable --now toutwaf-vpn.path >/dev/null 2>&1 || warn "could not enable toutwaf-vpn.path"; fi
  if want_cp; then systemctl enable --now toutwaf-fw.path >/dev/null 2>&1 || warn "could not enable toutwaf-fw.path"; fi
  if want_cp; then systemctl enable --now toutwaf-jobs.path >/dev/null 2>&1 || warn "could not enable toutwaf-jobs.path"; fi
  if want_cp; then
    systemctl enable toutwaf-cp >/dev/null 2>&1 || true
    if svc_active toutwaf-cp && [ "$CHANGED" = 0 ]; then :; else
      log "(Re)starting toutwaf-cp"
      systemctl restart toutwaf-cp >>"$LOG" 2>&1 || true
      if ! wait_cp_healthy; then
        if [ "$ACTION" = update ]; then rollback_cp; fi
        warn "toutwaf-cp does not answer on :$CP_PORT yet (journalctl -u toutwaf-cp)"
      fi
    fi
  fi
  if want_dp && [ -e "$(p /etc/systemd/system/toutwaf-cloudlink.service)" ]; then
    systemctl enable toutwaf-cloudlink >/dev/null 2>&1 || true
    if svc_active toutwaf-cloudlink && [ "$CHANGED" = 0 ]; then :; else log "(Re)starting toutwaf-cloudlink"; systemctl restart toutwaf-cloudlink >>"$LOG" 2>&1 || warn "toutwaf-cloudlink did not start (journalctl -u toutwaf-cloudlink)"; fi
  fi
  if want_dp; then
    systemctl enable toutwaf-dp >/dev/null 2>&1 || true
    if svc_active toutwaf-dp && [ "$CHANGED" = 0 ] && [ "$DP_CFG_CHANGED" = 0 ]; then log "data plane unchanged; reloading configuration"; systemctl reload toutwaf-dp || true
    else
      log "(Re)starting toutwaf-dp"
      systemctl restart toutwaf-dp >>"$LOG" 2>&1 || rollback_dp
      wait_healthy || rollback_dp
    fi
  fi
  return 0
}

# update_verdict VERSION BUILD: the rule applied to every installed component that this run touches; "same" only when each one is
update_verdict() {
  local b v bb st res=same
  for b in toutwaf-dp toutwaf-cp; do
    case "$b" in toutwaf-dp) { want_dp && [ "$INST_DP" = 1 ]; } || continue;; *) { want_cp && [ "$INST_CP" = 1 ]; } || continue;; esac
    v="$(installed_version "$(p "$BIN_DIR/$b")")"; [ -n "$v" ] || continue
    bb="$(inst_build "$(p "$BIN_DIR/$b")" "$v")"
    st="$(update_state "$v" "$bb" "$1" "${2:-}")"
    case "$st" in newer) res=newer;; rebuilt) [ "$res" = newer ] || res=rebuilt;; older) [ "$res" != same ] || res=older;; esac
  done
  printf '%s' "$res"
}
# what is installed, as one label (the data plane when there is one, else the control plane)
installed_identity_label() {
  if [ "$INST_DP" = 1 ] && want_dp; then installed_label "$(p "$BIN_DIR/toutwaf-dp")"; else installed_label "$(p "$BIN_DIR/toutwaf-cp")"; fi
}

do_install_flow() {
  step "$(t s_prereq)" install_pkgs
  if [ "$DRY_RUN" = 1 ]; then   # the prerequisites were only listed, not installed: what needs them cannot be shown
    local _tool
    for _tool in curl tar gzip awk sha256sum; do
      if ! have "$_tool"; then say "  $BUL (dry-run) $_tool is not installed yet: download, verification and the steps after it are skipped"; return 0; fi
    done
  fi
  SRC_DIR=""
  RESOLVED_VERSION="${TARBALL:+local}"
  NEW_BUILD=""
  if [ "$VIA_REPO" = 1 ] && [ -z "$TARBALL" ] && [ -z "$BASE_URL" ]; then via_repo_try || true; fi   # sets BASE_URL to the staged package on success
  if [ -z "$TARBALL" ]; then resolve_release; fi
  if [ -n "$CH_JSON" ] && [ "$RESOLVED_VERSION" = "$CH_VERSION" ]; then NEW_BUILD="$CH_BUILD"; fi
  if [ "$ACTION" = update ] && [ -z "$TARBALL" ] && [ "$FORCE" = 0 ]; then
    # THE rule, before anything is downloaded: same version AND same build as the channel's = nothing to do. (A channel that does not state its
    # build cannot tell: the archive is downloaded and its files are compared, as before.)
    local ust; ust="$(update_verdict "$RESOLVED_VERSION" "$NEW_BUILD")"
    case "$ust" in
      same) if [ -n "$NEW_BUILD" ]; then say "  $(paint "$GRN" "$OKM") $(t up_to_date "$(ver_short "$RESOLVED_VERSION" "$NEW_BUILD")")"; UPDATE_NOOP=1; extras_maintain "$RESOLVED_VERSION" "$NEW_BUILD"; return 0; fi;;
      rebuilt) say "  $BUL $(t up_rebuilt "$(installed_identity_label)" "$(ver_label "$RESOLVED_VERSION" "$NEW_BUILD")")";;
    esac
  fi
  step "$(t s_fetch "${RESOLVED_VERSION:-?}" "$ARCH")" obtain_binaries
  [ -z "$ARCHIVE_BUILD" ] || NEW_BUILD="$ARCHIVE_BUILD"
  if want_cp && [ "$NO_EXTRAS" = 0 ]; then step "$(t s_extras)" obtain_extras; fi   # downloaded and checked now, installed with the programs (never fatal)
  if [ "$ACTION" = update ]; then
    local cur="" curb="" same=1 b
    if want_dp && [ "$INST_DP" = 1 ]; then cur="$(installed_version "$(p "$BIN_DIR/toutwaf-dp")")"; curb="$(inst_build "$(p "$BIN_DIR/toutwaf-dp")" "$cur")"; fi
    if [ -z "$cur" ] && want_cp && [ "$INST_CP" = 1 ]; then cur="$(installed_version "$(p "$BIN_DIR/toutwaf-cp")")"; curb="$(inst_build "$(p "$BIN_DIR/toutwaf-cp")" "$cur")"; fi
    for b in toutwaf-dp toutwaf-cp toutwafctl; do
      case "$b" in toutwaf-dp) want_dp || continue;; *) want_cp || continue;; esac
      same_file "$SRC_DIR/$b" "$(p "$BIN_DIR/$b")" || same=0
    done
    if [ -n "$cur" ] && [ "$RESOLVED_VERSION" != local ] && [ "$RESOLVED_VERSION" != source ] && semver_lt "$RESOLVED_VERSION" "$cur" && [ "$FORCE" = 0 ]; then die "$(t e_downgrade "$RESOLVED_VERSION" "$CHANNEL" "$cur")"; fi
    if [ "$same" = 1 ] && [ "$FORCE" = 0 ]; then
      say "  $(paint "$GRN" "$OKM") $(t up_to_date "$(ver_short "${cur:-${ARCHIVE_VERSION:-$RESOLVED_VERSION}}" "${curb:-$NEW_BUILD}")")"; UPDATE_NOOP=1
      # the files are the archive's: whatever the binaries cannot say of themselves, the archive does
      record_installed "${cur:-${ARCHIVE_VERSION:-$RESOLVED_VERSION}}" "${curb:-$NEW_BUILD}"
      if [ -n "$EXTRAS_DIR" ]; then install_extras; extras_report; else extras_maintain "${ARCHIVE_VERSION:-$RESOLVED_VERSION}" "${ARCHIVE_BUILD:-$NEW_BUILD}"; fi   # same programs: the extras alone may be missing
      return 0
    fi
    step "$(t s_backup)" backup_before_update
  fi
  step "$(t s_user)" phase_account
  write_installer_conf
  step "$(t s_bin)" phase_binaries
  if want_cp && [ "$ACTION" = install ]; then step "$(t s_db)" phase_database; db_summary; fi
  step "$(t s_cfg)" phase_config
  load_existing_ports
  step "$(t s_units)" phase_units
  if [ "$STAGING" = 0 ]; then step "$(t s_selinux)" setup_selinux; fi
  if [ "$STAGING" = 0 ]; then step "$(t s_fw)" setup_firewall; fi
  if want_cp && [ "$DRY_RUN" = 0 ]; then step "$(t s_boot)" prepare_panel; fi
  if want_dp && want_cp && [ "$DRY_RUN" = 0 ]; then step "$(t s_link)" link_local_dp; fi
  if want_cp && [ "$FW_MODULE" = 1 ]; then step "$(t s_fwmod)" enable_firewall_module; fi
  if want_cp && [ "$BACKUP_CLIENT" = 1 ]; then step "$(t s_bkclient)" install_backup_client; fi
  if [ "$HAS_SYSTEMD" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    run systemctl daemon-reload
    if [ "$NO_START" = 0 ]; then
      step "$(t s_start)" start_services
    else
      say "  $BUL services installed but not started (--no-start)"
    fi
    if [ "$NO_ENABLE" = 1 ]; then
      for u in toutwaf-cp toutwaf-dp toutwaf-upgrade.path toutwaf-upgrade-guard.service toutwaf-firewall.path toutwaf-blocklist.path toutwaf-vpn.path toutwaf-fw.path toutwaf-jobs.path; do systemctl disable "$u" >/dev/null 2>&1 || true; done
    fi
  fi
  record_installed_now
  return 0
}
# the new binaries are in service: remember their version and build (the binary's own when it names one, else what the archive / channel says)
record_installed_now() {
  local bin="" v b
  if want_cp && [ -x "$(p "$BIN_DIR/toutwaf-cp")" ]; then bin="$(p "$BIN_DIR/toutwaf-cp")"; elif want_dp && [ -x "$(p "$BIN_DIR/toutwaf-dp")" ]; then bin="$(p "$BIN_DIR/toutwaf-dp")"; fi
  [ -n "$bin" ] || return 0
  v="$(installed_version "$bin")"; b="$(installed_build "$bin")"
  [ -n "$v" ] || { case "$RESOLVED_VERSION" in local|source|"") v="$ARCHIVE_VERSION";; *) v="$RESOLVED_VERSION";; esac; }
  [ -n "$b" ] || b="$NEW_BUILD"
  record_installed "$v" "$b"
  return 0
}

# ------------------------------------------------------------------------------------------------ interactive configuration
configure_interactively() {
  local fw fwm boot go su
  box_top "$(t cfg_title)"; box_bottom
  if [ "$COMPONENT" = dp ] && [ -z "$CP_URL" ]; then ask CP_URL "$(t q_cp_url)" ""; fi
  if [ -n "$CP_URL" ] && [ -z "$NODE_TOKEN$ENROLL_TOKEN" ]; then ask ENROLL_TOKEN "$(t q_token)" "" secret; fi
  if [ -n "$CP_URL" ] && [[ "$CP_URL" =~ ^https:// ]] && [ -z "$CP_CA" ]; then ask CP_CA "$(t q_cp_ca)" ""; fi
  if want_cp; then ask CP_PORT "$(t q_cp_port)" "$CP_PORT"; ask PUBLIC_HOST "$(t q_public_host)" "$PUBLIC_HOST"; fi
  if want_dp; then ask HTTP_PORT "$(t q_http_port)" "$HTTP_PORT"; ask HTTPS_PORT "$(t q_https_port)" "$HTTPS_PORT"; fi
  if want_cp && [ "$ACTION" = install ] && [ -z "$DB_ENGINE" ] && [ -z "$(db_existing_engine)" ]; then db_ask; fi
  ask_yn fw "$(t q_firewall)" 1; if [ "$fw" = 1 ]; then OPEN_FW=1; OPEN_CP_PORT=1; else OPEN_FW=0; fi
  if want_cp && [ "$OPEN_FW" = 1 ]; then
    say "  $D$(t fw_console_note "$CP_PORT")$R"
    ask CONSOLE_FROM "$(t q_console_from)" "$CONSOLE_FROM"
    if [ -n "$CONSOLE_FROM" ] && { ! [[ "$CONSOLE_FROM" =~ ^[0-9a-fA-F:.]{2,45}(/[0-9]{1,3})?$ ]] || [[ "$CONSOLE_FROM" == */0 ]]; }; then say "  $(paint "$RED" "$(t q_console_from_bad)")"; CONSOLE_FROM=""; fi
  fi
  if want_cp && [ -z "$FW_MODULE" ] && [ "$ACTION" = install ]; then
    echo >&3
    say "  $D$(t fwmod_n1)$R"; say "  $D$(t fwmod_n2)$R"; say "  $D$(t fwmod_n3)$R"
    ask_yn fwm "$(t q_fwmodule)" 0; FW_MODULE="$fwm"
  fi
  ask_yn boot "$(t q_boot)" 1; if [ "$boot" != 1 ]; then NO_ENABLE=1; fi
  if [ "$SKIP_SYSUPDATE" != 1 ]; then ask_yn su "$(t q_sysupdate)" 1; if [ "$su" != 1 ]; then SKIP_SYSUPDATE=1; fi; fi
  if [ -z "$TARBALL" ]; then ask CHANNEL "$(t q_channel)" "$CHANNEL"; fi
  if [ "$LAYOUT" = home ] && [ "$BIN_EXPLICIT" = 0 ]; then
    local h="$HOME_DIR"; ask h "$(t q_bindir)" "$HOME_DIR"
    if valid_home "$h"; then apply_home "$h"; else say "  $(paint "$RED" "$(t home_bad "$h")")"; fi
  else ask BIN_DIR "$(t q_bindir)" "$BIN_DIR"; fi
  check_ports
  case "$CHANNEL" in beta) CHANNEL=dev;; stable|dev) ;; *) CHANNEL=stable;; esac
  ask_yn go "$(t q_confirm)" 1; [ "$go" = 1 ] || { say "  $(t aborted)"; exit 0; }
  return 0
}

menu() {
  local choice st lab d i=1 k
  banner
  st="$(state_line)"
  if [ -n "$st" ]; then say "  $(t state_installed "$st")"; else say "  $(t state_none)"; fi
  echo
  box_top "$(t menu_title)"
  for k in install cp dp update uninstall status links; do
    case "$k" in install) lab="$(t opt_install)"; d="$(t opt_install_d)";; cp) lab="$(t opt_cp)"; d="$(t opt_cp_d)";; dp) lab="$(t opt_dp)"; d="$(t opt_dp_d)";;
      update) lab="$(t opt_update)"; d="$(t opt_update_d)";; uninstall) lab="$(t opt_uninstall)"; d="$(t opt_uninstall_d)";;
      status) lab="$(t opt_status)"; d="$(t opt_status_d)";; links) lab="$(t opt_links)"; d="$(t opt_links_d)";; esac
    box_line "${B}${VIO}[$i]${R} ${B}${lab}${R}"
    box_line "    $D$d$R"
    i=$((i + 1))
  done
  box_line "${B}${VIO}[q]${R} $(t opt_quit)"
  box_bottom
  while :; do
    ask choice "$(t choice)" ""
    case "$choice" in
      1) ACTION=install; COMPONENT=all; return 0;;
      2) ACTION=install; COMPONENT="cp"; return 0;;
      3) ACTION=install; COMPONENT="dp"; return 0;;
      4) ACTION=update; return 0;;
      5) ACTION=uninstall; return 0;;
      6) ACTION=status; return 0;;
      7) ACTION=links; return 0;;
      q|Q) exit 0;;
      *) say "  $(paint "$RED" "$(t invalid_choice)")";;
    esac
  done
}

# One clear paragraph about telemetry: what is shared by default, what never is, and how to switch it off. Printed once, at the start of an installation.
telemetry_notice() {
  [ "$QUIET" = 0 ] || return 0
  if [ "$NO_TELEMETRY" = 1 ]; then say "  $BUL $(t tele_off)"; else say "  $BUL $(t tele_on)"; fi
  return 0
}

# ------------------------------------------------------------------------------------------------ main
decide_channel
if [ -z "$ACTION" ]; then
  if [ "$NARGS" -eq 0 ] && interactive; then menu; else ACTION=install; fi
fi

case "$ACTION" in
  checkenv) detect_installed; if [ "$INST_CP" = 1 ] || [ "$INST_DP" = 1 ]; then load_existing_ports; fi; rc=0; env_run_check || rc=$?; exit "$rc";;
  checkprereq) rc=0; prereq_run_check || rc=$?; exit "$rc";;
  status) persist_log; rc=0; cmd_status || rc=$?; exit "$rc";;      # (a plain call would fire the ERR trap on a non-zero status)
  links) persist_log; rc=0; cmd_links || rc=$?; exit "$rc";;
  extras) persist_log; rc=0; cmd_extras || rc=$?; exit "$rc";;
  uninstall) persist_log; cmd_uninstall; exit 0;;
esac
compat_gate          # unsupported system: stops here (exit 3) before anything is changed
persist_log

detect_installed
if [ "$ACTION" = update ]; then
  [ "$INST_DP$INST_CP" != 00 ] || die "$(t not_installed)"
  component_from_installed          # an update refreshes what is installed, nothing else
  load_existing_ports
  if interactive && [ "$NARGS" -eq 0 ]; then ask CHANNEL "$(t q_channel)" "$CHANNEL"; case "$CHANNEL" in beta) CHANNEL=dev;; stable|dev) ;; *) CHANNEL=stable;; esac; fi
else
  if [ "$INST_CP" = 1 ]; then load_existing_ports; fi
  banner
  if interactive && [ "$STAGING" = 0 ]; then configure_interactively; fi
fi
if [ -n "$CLOUD_URL" ]; then cloud_prepare; fi
if [ -n "$ENROLL_TOKEN$NODE_TOKEN" ] && [ -z "$CP_URL" ]; then die "$(t need_cp)"; fi
banner
say "  ${D}os=$OS_ID $OS_VER family=${FAMILY:-${FAMILY_GUESS:-?}} arch=$ARCH component=$COMPONENT channel=$CHANNEL${DESTDIR:+ staging=$DESTDIR}$R"
[ -z "$LAYOUT_NOTE" ] || say "  ${D}$LAYOUT_NOTE$R"
if [ "$COMPAT_OK" = 1 ]; then
  say "  $(paint "$GRN" "$OKM") $COMPAT_LINE"
  for _n in ${CP_NOTES[@]+"${CP_NOTES[@]}"}; do warn "$_n"; done
fi
if want_cp && [ "$ACTION" = install ]; then telemetry_notice; fi   # what is shared with the publisher space, said before anything is installed
if [ "$ACTION" = install ]; then env_gate; fi   # what is in the way is said now, before anything is changed (exit 4)
prereq_gate          # disk space, DNS and clock, with the fix of each problem (only a full disk refuses, exit 4)
sysupdate_run        # then the system packages (an installation only; TOUTWAF_SKIP_SYSUPDATE=1 skips it; a failure is a warning)
if want_cp && [ "$STAGING" = 0 ] && [ "$DRY_RUN" = 0 ]; then detect_public_ip; fi
do_install_flow

new_dp="$(installed_label "$(p "$BIN_DIR/toutwaf-dp")" 2>/dev/null || true)"; [ "$new_dp" != "?" ] || new_dp=""
echo
if [ "$DRY_RUN" = 1 ]; then say "  $(t dry_done)"; exit 0; fi
if [ "$UPDATE_NOOP" = 1 ]; then exit 0; fi
say "  $(paint "$GRN" "$OKM") $(t "done")${new_dp:+  toutwaf-dp $new_dp${OLD_DP:+ (was $OLD_DP)}}"
if [ "${#WARNINGS[@]}" -gt 0 ] && [ "$QUIET" = 0 ] && [ "$UI_COLOR" = 1 ]; then local_w=""; for local_w in "${WARNINGS[@]}"; do printf '  %s%s%s %s\n' "$YLW" "$WRM" "$R" "$local_w"; done; fi
if want_cp && [ "$PANEL_RAN" = 0 ] && [ "$STAGING" = 0 ]; then cp_links; fi
render_summary tty
extras_report
if [ "$FW_MODULE_RESULT" = on ]; then say "  $BUL $(t fwmod_done)"; fi
if [ "$BACKUP_CLIENT_RESULT" = on ]; then say "  $BUL $(t bkc_done)"; fi
if want_dp; then
  say "  ${D}data plane: systemctl status toutwaf-dp   config: $CONF_DIR/toutwaf-dp.yaml   health: curl http://127.0.0.1:9101/healthz$R"
  if [ -z "$CP_URL" ] && { [ "$COMPONENT" != all ] || [ "$DP_LINK" = failed ]; }; then say "  ${D}policy: edit $CONF_DIR/policy.yaml (hot reloaded) - apps start in detect mode$R"; fi
fi
write_summary_file
exit 0
