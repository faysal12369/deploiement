<?php
declare(strict_types=1);

/**
 * deploy-agent.php — the agent of "Déploiement" (source: assets/agent/ of the app).
 *
 * One self-contained file for ANY PHP + MySQL/MariaDB project. The app places it in the project's root folder on a
 * target (shared hosting such as Hostinger, a VPS, an office server) under a random name. It obeys only the app: every
 * request carries the token whose SHA-256 is written below. All the work happens on the target itself, so the target's
 * database never has to accept outside connections.
 *
 * WEB MODE  (POST ?a=<action>, JSON body, header X-Deploy-Token)
 *   status          PHP, extensions, database (and where its settings come from), last release, limits
 *   configure       store the database connection in the agent's private folder (otherwise: auto-detected from
 *                   .env, wp-config.php or define('DB_…') in config/*.php)
 *   upload          one chunk of a file (raw body; ?name=…&offset=…) ; upload_done checks its SHA-256
 *   plan            what a release would change: new / changed / removed files, pending migrations
 *   backup          database (.sql.gz) and files (.zip) backup, step by step
 *   migrate         run pending migrations (recorded in the `_deploy_migrations` table)
 *   apply_files     write the release's files (only those that differ), remove files dropped from the project
 *   sync            upsert the rows of the tables whose data is sent (never deletes), step by step — dry_run: true = simulation
 *   counts          exact number of rows of every table
 *   verify          tables and columns of the developer's database still missing on the target
 *   tables          the structure of chosen tables made like the developer's: table created, columns and indexes
 *                   added, columns changed - never a column, an index or a row removed. dry_run: true = simulation
 *   import_db       load a full database copy (.sql / .sql.gz) step by step ; replace: true drops the tables first
 *   mark_migrations record every migration of a release as applied (after importing an up-to-date copy)
 *   restore_files   put back the files of a files backup
 *   summary         tables and row counts of the target database
 *   list, download, delete   files of the private folder (packages, backups)
 *   schema_sql      the structure as SQL (CREATE TABLE / VIEW), for the Delta Schéma tool
 *   inventory       rows of each table recognised by a natural key (never the id), to compare two databases
 *
 * CLI MODE  (on the developer's PC, run by the app):  php deploy-agent.php cli <action> <config.json> <output>
 *   schema, sync_export, tables_ddl, dump, summary, structure, schema_sql, inventory, import — same database code, local database
 *   given in config.json.
 *
 * Files never touched by a release: the "keep" patterns of the project (.env, uploads/…), the private folder, the
 * agent itself, .git/.
 */

const TOKEN_SHA256  = '{{TOKEN_SHA256}}';   // written by the app when it places the agent
const PRIVATE_DIR   = '{{PRIVATE_DIR}}';    // relative to this folder: ".deploy", "../.deploy-myshop"…
const AGENT_VERSION = 8;
const WORK_SECONDS  = 15.0;                 // work per request; long tasks resume where they stopped
/** Columns that name a row when two databases are compared, the first present wins (after the key). */
const DP_LABELS = ['numero', 'code', 'raison_sociale', 'nom', 'name', 'title', 'titre', 'intitule', 'libelle', 'label',
                   'full_name', 'username', 'email', 'objet', 'setting_key', 'designation', 'slug', 'sku'];

define('DP_ROOT', str_replace('\\', '/', __DIR__));
define('DP_START', microtime(true));

@ini_set('display_errors', '0');
error_reporting(E_ALL);
$GLOBALS['dp_warnings'] = [];
set_error_handler(static function (int $no, string $msg, string $f = '', int $l = 0): bool {
    if (error_reporting() & $no) {
        $GLOBALS['dp_warnings'][] = $msg . ' (' . basename($f) . ':' . $l . ')';
    }
    return true;
});

if (PHP_SAPI === 'cli') {
    exit(dpCli($argv ?? []));
}

@set_time_limit(300);
@ignore_user_abort(true);
ob_start();

if (strlen(TOKEN_SHA256) !== 64 || !ctype_xdigit(TOKEN_SHA256)) {
    dpRespond(['ok' => false, 'code' => 'not_configured', 'message' => 'Agent not configured.'], 503);
}
$token = (string)($_SERVER['HTTP_X_DEPLOY_TOKEN'] ?? '');
if ($token === '' || !hash_equals(TOKEN_SHA256, hash('sha256', $token))) {
    usleep(800000);
    dpRespond(['ok' => false, 'code' => 'denied', 'message' => 'Access denied.'], 403);
}
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    dpRespond(['ok' => false, 'message' => 'POST expected.'], 405);
}

$A = (string)($_GET['a'] ?? '');
$P = $A === 'upload' ? $_GET : (json_decode((string)file_get_contents('php://input'), true) ?: []);

try {
    dpPrepare();
    if (!str_ends_with(basename(__FILE__), '-next.php') && $A !== 'update_agent' && is_file(DP_ROOT . '/' . dpNextName())) {
        @unlink(DP_ROOT . '/' . dpNextName());   // what is left of an update
    }
    dpRespond(match ($A) {
        'status'          => aStatus(),
        'configure'       => aConfigure($P),
        'upload'          => aUpload($P),
        'upload_done'     => aUploadDone($P),
        'plan'            => aPlan($P),
        'backup'          => aBackup($P),
        'migrate'         => aMigrate($P),
        'apply_files'     => aApplyFiles($P),
        'sync'            => aSync($P),
        'verify'          => aVerify($P),
        'tables'          => aTables($P),
        'import_db'       => aImportDb($P),
        'mark_migrations' => aMarkMigrations($P),
        'restore_files'   => aRestoreFiles($P),
        'summary'         => dpSummary(dpPdo()),
        'counts'          => ['ok' => true, 'tables' => (object)dpCounts(dpPdo())],
        'list'            => aList(),
        'download'        => aDownload($P),
        'delete'          => aDelete($P),
        'file'            => aFile($P),
        'compare'         => aCompare($P),
        'update_agent'    => aUpdateAgent($P),
        'take_over'       => aTakeOver(),
        'table'           => aTable($P),
        'structure'       => ['ok' => true, 'tables' => dpStructureAll(dpPdo())],
        'schema_sql'      => ['ok' => true, 'sql' => dpSchemaSql(dpPdo())],
        'inventory'       => aInventory($P),
        'sql'             => aSql($P),
        default           => ['ok' => false, 'message' => 'Unknown action: ' . $A],
    });
} catch (\Throwable $e) {
    dpRespond(['ok' => false, 'message' => $e->getMessage(), 'where' => basename($e->getFile()) . ':' . $e->getLine()], 500);
}

// =====================================================================================================================
//  Tools
// =====================================================================================================================

function dpRespond(array $d, int $code = 200): never
{
    $out = '';
    while (ob_get_level() > 0) {
        $out = (string)ob_get_clean() . $out;
    }
    if (!headers_sent()) {
        http_response_code($code);
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-store');
        header('X-Robots-Tag: noindex, nofollow');
    }
    if (trim($out) !== '') {
        $d['output'] = mb_substr($out, 0, 20000);
    }
    if ($GLOBALS['dp_warnings'] !== []) {
        $d['warnings'] = array_slice(array_values(array_unique($GLOBALS['dp_warnings'])), 0, 30);
    }
    echo json_encode($d, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR);
    exit;
}

function dpTimeLeft(): float
{
    return WORK_SECONDS - (microtime(true) - DP_START);
}

function dpSafeName(mixed $n): string
{
    $n = (string)$n;
    if (preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]{0,150}$/', $n) !== 1 || str_contains($n, '..')) {
        throw new RuntimeException('File name refused: ' . $n);
    }
    return $n;
}

/** The private folder: packages, backups, last manifest, database settings. Never served to a browser. */
function dpPrivate(string $sub = ''): string
{
    $base = DP_ROOT . '/' . trim(str_replace('\\', '/', PRIVATE_DIR), '/');
    $d = $sub === '' ? $base : $base . '/' . $sub;
    if (!is_dir($d) && !@mkdir($d, 0775, true) && !is_dir($d)) {
        throw new RuntimeException('Cannot create ' . $d);
    }
    return $d;
}

function dpPrepare(): void
{
    $p = dpPrivate();
    foreach (['packages', 'backups', 'tmp'] as $s) {
        dpPrivate($s);
    }
    if (!is_file($p . '/.htaccess')) {
        @file_put_contents($p . '/.htaccess', "<IfModule mod_authz_core.c>\n    Require all denied\n</IfModule>\n<IfModule !mod_authz_core.c>\n    Order allow,deny\n    Deny from all\n</IfModule>\n");
        @file_put_contents($p . '/web.config', "<?xml version=\"1.0\"?>\n<configuration><system.webServer><authorization><deny users=\"*\" /></authorization></system.webServer></configuration>\n");
        @file_put_contents($p . '/index.html', '');
    }
}

/** The private folder relative to the project root ('' when it lives outside the project). */
function dpPrivateRel(): string
{
    $rel = trim(str_replace('\\', '/', PRIVATE_DIR), '/');
    return str_starts_with($rel, '..') ? '' : $rel . '/';
}

/** gitignore-like pattern → regex: "storage/", "*.log", "config/app.local.php", "/public/uploads/", "**\/cache/". */
function dpGlob(string $g): string
{
    $g = trim(str_replace('\\', '/', $g));
    $anchored = str_starts_with($g, '/');
    $g = ltrim($g, '/');
    $dir = str_ends_with($g, '/');
    $g = rtrim($g, '/');
    $re = '';
    for ($i = 0, $n = strlen($g); $i < $n; $i++) {
        $c = $g[$i];
        if ($c === '*' && ($g[$i + 1] ?? '') === '*') {
            $re .= '.*';
            $i++;
            if (($g[$i + 1] ?? '') === '/') {
                $i++;
            }
        } elseif ($c === '*') {
            $re .= '[^/]*';
        } elseif ($c === '?') {
            $re .= '[^/]';
        } else {
            $re .= preg_quote($c, '#');
        }
    }
    $start = ($anchored || str_contains($g, '/')) ? '^' : '(^|/)';
    return '#' . $start . $re . ($dir ? '/' : '(/|$)') . '#i';
}

/** Files a release never writes nor deletes: keep patterns, private folder, agents, .git. */
function dpKept(string $rel, array $keep): bool
{
    $rel = ltrim(str_replace('\\', '/', $rel), '/');
    if (preg_match('#^deploy-agent[A-Za-z0-9_-]*\.php$#', $rel) === 1 || str_starts_with($rel, '.git/')) {
        return true;
    }
    $priv = dpPrivateRel();
    if ($priv !== '' && str_starts_with($rel, $priv)) {
        return true;
    }
    foreach ($keep as $k) {
        if (trim((string)$k) !== '' && preg_match(dpGlob((string)$k), $rel) === 1) {
            return true;
        }
    }
    return false;
}

/** A relative path from a package: no "..", no absolute path. */
function dpSafePath(string $rel): ?string
{
    $rel = str_replace('\\', '/', $rel);
    if ($rel === '' || str_starts_with($rel, '/') || preg_match('#(^|/)\.\.(/|$)#', $rel) === 1 || preg_match('#^[A-Za-z]:#', $rel) === 1) {
        return null;
    }
    return $rel;
}

function dpWrite(string $path, string $content): void
{
    $dir = dirname($path);
    if (!is_dir($dir) && !@mkdir($dir, 0775, true) && !is_dir($dir)) {
        throw new RuntimeException('Cannot create folder ' . $dir);
    }
    $tmp = $path . '.dp-tmp';
    if (file_put_contents($tmp, $content) === false) {
        throw new RuntimeException('Cannot write ' . $path);
    }
    if (!@rename($tmp, $path)) {
        @unlink($path);
        if (!@rename($tmp, $path)) {
            @unlink($tmp);
            throw new RuntimeException('Cannot replace ' . $path);
        }
    }
    if (function_exists('opcache_invalidate')) {
        @opcache_invalidate($path, true);
    }
}

function dpLastManifest(): ?array
{
    $f = dpPrivate() . '/manifest.json';
    $m = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    return is_array($m) ? $m : null;
}

/** An uploaded package: [ZipArchive, manifest]. */
function dpPackage(mixed $name): array
{
    $f = dpPrivate('packages') . '/' . dpSafeName($name);
    if (!is_file($f)) {
        throw new RuntimeException('Package not found on the target: ' . $name);
    }
    $zip = new ZipArchive();
    if ($zip->open($f) !== true) {
        throw new RuntimeException('Unreadable package: ' . $name);
    }
    $m = json_decode((string)$zip->getFromName('__deploy/manifest.json'), true);
    if (!is_array($m) || !is_array($m['files'] ?? null)) {
        throw new RuntimeException('This package has no manifest.');
    }
    return [$zip, $m];
}

// =====================================================================================================================
//  Database
// =====================================================================================================================

/** The target's database settings: the agent's own config, else .env, wp-config.php, define('DB_…') in config/*.php. */
function dpDbConfig(): array
{
    static $c = null;
    if ($c !== null) {
        return $c;
    }
    $f = dpPrivate() . '/config.php';
    if (is_file($f)) {
        $x = include $f;
        if (is_array($x) && !empty($x['db']['name'])) {
            return $c = $x['db'] + ['source' => 'agent settings'];
        }
    }
    $d = dpDetectDb();
    if ($d === null) {
        throw new RuntimeException('No database settings: enter them in the target settings, or provide a .env / wp-config.php the agent can read.');
    }
    return $c = $d;
}

function dpDetectDb(): ?array
{
    $env = DP_ROOT . '/.env';
    if (is_file($env)) {
        $v = [];
        foreach (file($env, FILE_IGNORE_NEW_LINES) ?: [] as $l) {
            if (preg_match('/^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*?)\s*$/', $l, $m) === 1 && !str_starts_with(trim($l), '#')) {
                $v[$m[1]] = trim(preg_replace('/\s+#.*$/', '', $m[2]) ?? '', "\"'");
            }
        }
        $name = $v['DB_DATABASE'] ?? $v['DB_NAME'] ?? '';
        if ($name !== '') {
            return ['host' => $v['DB_HOST'] ?? 'localhost', 'port' => $v['DB_PORT'] ?? '3306', 'name' => $name,
                'user' => $v['DB_USERNAME'] ?? $v['DB_USER'] ?? '', 'pass' => $v['DB_PASSWORD'] ?? $v['DB_PASS'] ?? '', 'source' => '.env'];
        }
    }
    $candidates = [DP_ROOT . '/wp-config.php'];
    foreach (['/config/*.local.php', '/config/*.php', '/*.local.php'] as $g) {
        foreach (glob(DP_ROOT . $g) ?: [] as $f) {
            $candidates[] = $f;
        }
    }
    $found = [];
    $from = [];
    foreach (array_unique($candidates) as $f) {
        if (!is_file($f) || filesize($f) > 300000) {
            continue;
        }
        $txt = (string)file_get_contents($f);
        if (preg_match_all('/define\(\s*[\'"](DB_(?:HOST|PORT|NAME|USER|PASSWORD|PASS))[\'"]\s*,\s*[\'"]((?:[^\'"\\\\]|\\\\.)*)[\'"]\s*\)/', $txt, $mm, PREG_SET_ORDER) > 0) {
            foreach ($mm as $m) {
                $k = $m[1] === 'DB_PASSWORD' ? 'DB_PASS' : $m[1];
                if (!isset($found[$k])) {
                    $found[$k] = stripcslashes($m[2]);
                    $from[] = basename($f);
                }
            }
        }
    }
    if (empty($found['DB_NAME'])) {
        return null;
    }
    $host = $found['DB_HOST'] ?? 'localhost';
    $port = $found['DB_PORT'] ?? '3306';
    if (preg_match('/^(.*):(\d+)$/', $host, $m) === 1) {   // wp-config: "localhost:3307"
        [$host, $port] = [$m[1], $m[2]];
    }
    return ['host' => $host, 'port' => $port, 'name' => $found['DB_NAME'], 'user' => $found['DB_USER'] ?? '',
        'pass' => $found['DB_PASS'] ?? '', 'source' => implode(', ', array_unique($from))];
}

function dpConnect(array $c): PDO
{
    $pdo = new PDO(sprintf('mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4', $c['host'] ?? 'localhost', ($c['port'] ?? '') !== '' ? $c['port'] : '3306', $c['name'] ?? ''),
        (string)($c['user'] ?? ''), (string)($c['pass'] ?? ''), [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false, PDO::ATTR_STRINGIFY_FETCHES => false,
        ]);
    $pdo->exec("SET SESSION sql_mode = 'NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO'");
    $pdo->exec('SET FOREIGN_KEY_CHECKS = 0');
    return $pdo;
}

function dpPdo(): PDO
{
    static $pdo = null;
    return $pdo ??= dpConnect(dpDbConfig());
}

function dpQ(string $ident): string
{
    return '`' . str_replace('`', '``', $ident) . '`';
}

function dpTables(PDO $pdo, string $type = 'BASE TABLE'): array
{
    $st = $pdo->prepare('SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = ? ORDER BY TABLE_NAME');
    $st->execute([$type]);
    return array_map('strval', $st->fetchAll(PDO::FETCH_COLUMN));
}

/** Columns (=> nullable), primary key, auto-increment of a table; null when absent. */
function dpStructure(PDO $pdo, string $t): ?array
{
    $st = $pdo->prepare('SELECT COLUMN_NAME c, IS_NULLABLE n, COLUMN_KEY k, EXTRA e FROM information_schema.COLUMNS
                          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION');
    $st->execute([$t]);
    $rows = $st->fetchAll();
    if ($rows === []) {
        return null;
    }
    $s = ['columns' => [], 'pk' => [], 'auto' => false];
    foreach ($rows as $r) {
        $s['columns'][(string)$r['c']] = $r['n'] === 'YES';
        if ($r['k'] === 'PRI') {
            $s['pk'][] = (string)$r['c'];
            $s['auto'] = $s['auto'] || str_contains((string)$r['e'], 'auto_increment');
        }
    }
    return $s;
}

function dpSchema(PDO $pdo): array
{
    $out = [];
    foreach ($pdo->query('SELECT TABLE_NAME t, COLUMN_NAME c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION') as $r) {
        $out[(string)$r['t']][] = (string)$r['c'];
    }
    unset($out['_deploy_migrations']);
    return $out;
}

function dpSummary(PDO $pdo): array
{
    $rows = $pdo->query("SELECT TABLE_NAME t, COALESCE(TABLE_ROWS, 0) r FROM information_schema.TABLES
                          WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE' AND TABLE_NAME <> '_deploy_migrations'
                          ORDER BY TABLE_ROWS DESC")->fetchAll();
    $top = [];
    foreach (array_slice($rows, 0, 12) as $r) {
        $top[] = ['table' => (string)$r['t'], 'rows' => (int)$pdo->query('SELECT COUNT(*) FROM ' . dpQ((string)$r['t']))->fetchColumn()];
    }
    usort($top, static fn (array $a, array $b): int => $b['rows'] <=> $a['rows']);
    return ['ok' => true, 'tables' => count($rows), 'rows_estimate' => array_sum(array_map(static fn (array $r): int => (int)$r['r'], $rows)),
        'top' => $top, 'version' => (string)$pdo->query('SELECT VERSION()')->fetchColumn()];
}

// =====================================================================================================================
//  SQL files: statement by statement (quotes, comments, DELIMITER), resumable at a byte offset
// =====================================================================================================================

final class SqlReader
{
    /** @var resource */
    private $fh;
    private int $pos;
    private string $delim = ';';

    public function __construct(string $file, int $pos = 0)
    {
        $fh = fopen($file, 'rb');
        if ($fh === false) {
            throw new RuntimeException('Cannot read ' . $file);
        }
        $this->fh = $fh;
        $this->pos = $pos;
        fseek($this->fh, $pos);
    }

    public function position(): int
    {
        return $this->pos;
    }

    public function next(): ?string
    {
        $buf = '';
        $state = null;   // null | ' | " | ` | /*
        while (($line = fgets($this->fh)) !== false) {
            $len = strlen($line);
            if ($state === null && trim(self::lead($buf)) === '' && preg_match('/^\s*DELIMITER\s+(\S+)\s*$/i', $line, $m) === 1) {
                $this->delim = $m[1];
                $this->pos += $len;
                $buf = '';
                continue;
            }
            $dl = strlen($this->delim);
            $i = 0;
            while ($i < $len) {
                if ($state === null) {
                    $i += strcspn($line, "'\"`#/-" . $this->delim[0], $i);
                    if ($i >= $len) {
                        break;
                    }
                    $c = $line[$i];
                    if ($c === "'" || $c === '"' || $c === '`') {
                        $state = $c;
                        $i++;
                    } elseif ($c === '#' || ($c === '-' && ($line[$i + 1] ?? '') === '-' && ($i + 2 >= $len || ctype_space($line[$i + 2])))) {
                        break;
                    } elseif ($c === '/' && ($line[$i + 1] ?? '') === '*') {
                        $state = '/*';
                        $i += 2;
                    } elseif (substr($line, $i, $dl) === $this->delim) {
                        $buf .= substr($line, 0, $i);
                        $this->pos += $i + $dl;
                        fseek($this->fh, $this->pos);
                        $s = trim(self::lead($buf));
                        if ($s === '') {
                            $buf = '';
                            continue 2;
                        }
                        return $s;
                    } else {
                        $i++;
                    }
                } elseif ($state === '/*') {
                    $p = strpos($line, '*/', $i);
                    if ($p === false) {
                        $i = $len;
                        break;
                    }
                    $i = $p + 2;
                    $state = null;
                } else {
                    $i += strcspn($line, $state . '\\', $i);
                    if ($i >= $len) {
                        break;
                    }
                    if ($line[$i] === '\\' && $state !== '`') {
                        $i += 2;
                    } elseif (($line[$i + 1] ?? '') === $state) {
                        $i += 2;
                    } else {
                        $state = null;
                        $i++;
                    }
                }
            }
            $buf .= $line;
            $this->pos += $len;
        }
        $s = trim(self::lead($buf));
        return $s === '' ? null : $s;
    }

    /** Drops LEADING comments (not the /*! … *\/ ones MySQL executes). */
    private static function lead(string $s): string
    {
        while (true) {
            $s = ltrim($s);
            if (str_starts_with($s, '--') || str_starts_with($s, '#')) {
                $p = strpos($s, "\n");
                $s = $p === false ? '' : substr($s, $p + 1);
            } elseif (str_starts_with($s, '/*') && !str_starts_with($s, '/*!')) {
                $p = strpos($s, '*/');
                $s = $p === false ? '' : substr($s, $p + 2);
            } else {
                return $s;
            }
        }
    }
}

/** Statements tied to the session of a mysqldump export (@OLD_… variables, locks): irrelevant here. */
function dpSkip(string $s): bool
{
    return preg_match('/^\/\*!\d+\s+SET\s+(@\w+\s*:?=|[\w@]+\s*=\s*@)/i', $s) === 1
        || preg_match('/^(\/\*!\d+\s+)?(LOCK|UNLOCK)\s+TABLES/i', $s) === 1;
}

/**
 * SQL typed in the app ("SQL…"): each statement run in turn. One that reads (SELECT, SHOW, DESCRIBE, EXPLAIN, WITH)
 * gives its columns and up to [max] rows; the others say how many rows they changed. Stops at the first error: what
 * ran before stays (MySQL cannot undo ALTER, CREATE, DROP) — the app backs the database up first.
 */
function dpSqlRun(PDO $pdo, string $sql, int $max = 500): array
{
    $tmp = (string)tempnam(sys_get_temp_dir(), 'dpsql');
    file_put_contents($tmp, $sql);
    $out = [];
    try {
        $r = new SqlReader($tmp);
        while (($s = $r->next()) !== null) {
            $t0 = microtime(true);
            $one = ['sql' => mb_substr(trim(preg_replace('/\s+/', ' ', $s) ?? ''), 0, 400)];
            try {
                if (preg_match('/^\(?\s*(SELECT|SHOW|DESCRIBE|DESC|EXPLAIN|WITH)\b/i', $s) === 1) {
                    $st = $pdo->query($s);
                    $cols = [];
                    for ($i = 0; $i < $st->columnCount(); $i++) {
                        $m = $st->getColumnMeta($i);
                        $cols[] = (string)($m['name'] ?? ('col' . $i));
                    }
                    $rows = [];
                    $n = 0;
                    while (($row = $st->fetch(PDO::FETCH_NUM)) !== false) {
                        if (++$n <= $max) {
                            $rows[] = array_map(static fn($v) => $v === null ? null : (string)$v, $row);
                        }
                    }
                    $st->closeCursor();
                    $one += ['columns' => $cols, 'rows' => $rows, 'count' => $n];
                } else {
                    $one['affected'] = (int)$pdo->exec($s);
                }
            } catch (\PDOException $e) {
                $one['error'] = (string)($e->errorInfo[2] ?? $e->getMessage());
                $one['ms'] = (int)round((microtime(true) - $t0) * 1000);
                $out[] = $one;
                return ['ok' => true, 'results' => $out, 'stopped' => true];
            }
            $one['ms'] = (int)round((microtime(true) - $t0) * 1000);
            $out[] = $one;
        }
    } finally {
        @unlink($tmp);
    }
    return ['ok' => true, 'results' => $out, 'stopped' => false];
}

function aSql(array $p): array
{
    @set_time_limit(600);
    return dpSqlRun(dpPdo(), (string)($p['sql'] ?? ''));
}

function dpRunSql(PDO $pdo, string $sql, string $label): int
{
    $tmp = dpPrivate('tmp') . '/sql-' . bin2hex(random_bytes(6)) . '.sql';
    file_put_contents($tmp, $sql);
    try {
        $r = new SqlReader($tmp);
        $n = 0;
        while (($s = $r->next()) !== null) {
            if (dpSkip($s)) {
                continue;
            }
            try {
                $st = $pdo->query($s);
                if ($st !== false) {
                    do {
                        try {
                            $st->fetchAll();
                        } catch (\Throwable) {
                        }
                    } while ($st->nextRowset());
                    $st->closeCursor();
                }
            } catch (\PDOException $e) {
                throw new RuntimeException($label . ': ' . ($e->errorInfo[2] ?? $e->getMessage()) . ' — in: ' . mb_substr(preg_replace('/\s+/', ' ', $s) ?? '', 0, 300));
            }
            $n++;
        }
        return $n;
    } finally {
        @unlink($tmp);
    }
}

// =====================================================================================================================
//  Dump (backup on the target, copy of the local database in CLI mode)
// =====================================================================================================================

/** One step of a dump into a .sql.gz: tables in order, 2 000 rows per read, INSERTs of at most 256 KB. */
function dpDumpStep(PDO $pdo, string $file, array &$s, float $until): void
{
    $gz = gzopen($file, $s['i'] === 0 && $s['offset'] === 0 && !is_file($file) ? 'wb6' : 'ab6');
    if ($s['i'] === 0 && $s['offset'] === 0 && empty($s['head'])) {
        gzwrite($gz, '-- Déploiement: database ' . $s['db'] . ', ' . date('Y-m-d H:i:s') . "\nSET NAMES utf8mb4;\nSET FOREIGN_KEY_CHECKS = 0;\nSET SQL_MODE = 'NO_AUTO_VALUE_ON_ZERO';\n\n");
        $s['head'] = true;
    }
    while ($s['i'] < count($s['tables']) && microtime(true) < $until) {
        $t = (string)$s['tables'][$s['i']];
        if ($s['offset'] === 0) {
            $create = $pdo->query('SHOW CREATE TABLE ' . dpQ($t))->fetch(PDO::FETCH_NUM);
            gzwrite($gz, 'DROP TABLE IF EXISTS ' . dpQ($t) . ";\n" . preg_replace('/ AUTO_INCREMENT=\d+/', '', (string)$create[1]) . ";\n");
        }
        $pk = array_column($pdo->query('SHOW KEYS FROM ' . dpQ($t) . " WHERE Key_name = 'PRIMARY'")->fetchAll(), 'Column_name');
        $order = $pk !== [] ? ' ORDER BY ' . implode(', ', array_map('dpQ', $pk)) : '';
        $rows = $pdo->query('SELECT * FROM ' . dpQ($t) . $order . ' LIMIT 2000 OFFSET ' . (int)$s['offset'])->fetchAll();
        $head = $rows !== [] ? 'INSERT INTO ' . dpQ($t) . ' (' . implode(', ', array_map('dpQ', array_keys($rows[0]))) . ") VALUES\n" : '';
        $vals = [];
        $size = 0;
        foreach ($rows as $r) {
            $v = '(' . implode(', ', array_map(static fn (mixed $x): string => match (true) {
                $x === null => 'NULL',
                is_int($x), is_float($x) => (string)$x,
                is_bool($x) => $x ? '1' : '0',
                default => $pdo->quote((string)$x),
            }, array_values($r))) . ')';
            if ($vals !== [] && $size + strlen($v) > 262144) {
                gzwrite($gz, $head . implode(",\n", $vals) . ";\n");
                $vals = [];
                $size = 0;
            }
            $vals[] = $v;
            $size += strlen($v) + 2;
        }
        if ($vals !== []) {
            gzwrite($gz, $head . implode(",\n", $vals) . ";\n");
        }
        if (count($rows) < 2000) {
            $s['i']++;
            $s['offset'] = 0;
            gzwrite($gz, "\n");
        } else {
            $s['offset'] += 2000;
        }
    }
    if ($s['i'] >= count($s['tables'])) {
        gzwrite($gz, "SET FOREIGN_KEY_CHECKS = 1;\n");
        $s['done'] = true;
    }
    gzclose($gz);
}

function dpDumpState(PDO $pdo, string $db): array
{
    return ['tables' => dpTables($pdo), 'i' => 0, 'offset' => 0, 'db' => $db, 'done' => false];
}

// =====================================================================================================================
//  Table sync (export on the PC, apply on the target)
// =====================================================================================================================

/** The unique indexes of every table but the primary key (table => list of column lists), fewest columns first. */
function dpUniqueKeys(PDO $pdo): array
{
    $u = [];
    foreach ($pdo->query("SELECT TABLE_NAME t, INDEX_NAME i, COLUMN_NAME c FROM information_schema.STATISTICS
                           WHERE TABLE_SCHEMA = DATABASE() AND NON_UNIQUE = 0 AND INDEX_NAME <> 'PRIMARY' ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX") as $r) {
        $u[(string)$r['t']][(string)$r['i']][] = (string)$r['c'];
    }
    foreach ($u as $t => $l) {
        $l = array_values($l);
        usort($l, static fn (array $a, array $b): int => count($a) <=> count($b));
        $u[$t] = $l;
    }
    return $u;
}

/**
 * Local export of the tables whose data is sent, as lines (NDJSON, so the target reads them step by step): a first
 * line says how each table's rows are recognised from one database to the other — its KEY (the given columns, else a
 * unique index, else a non-auto primary key; never an auto-increment id) — and what its columns point at: LINKS (a
 * table sent too: id → key → id), REFS (a table not sent: the row pointed at is found on the target by its own key —
 * hf_ref, code, username… — given in "refkeys"), LOCAL (never written: ignored columns, a row of the same table, a
 * table without any key). Then one line per row, tables parents first.
 */
function dpSyncExport(PDO $pdo, array $wanted, string $out): array
{
    $names = array_map(static fn (array $w): string => (string)$w['table'], $wanted);
    $fks = [];
    foreach ($pdo->query('SELECT TABLE_NAME t, COLUMN_NAME c, REFERENCED_TABLE_NAME r FROM information_schema.KEY_COLUMN_USAGE
                           WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL') as $r) {
        $fks[(string)$r['t']][(string)$r['c']] = (string)$r['r'];
    }
    $uniques = dpUniqueKeys($pdo);
    $keyable = static function (string $ref) use ($pdo, $uniques): bool {
        $s = dpStructure($pdo, $ref);
        return $s !== null && count($s['pk']) === 1 && (($uniques[$ref] ?? []) !== [] || !$s['auto']);
    };
    $meta = [];
    $data = [];
    $refIds = [];
    foreach ($wanted as $w) {
        $t = (string)$w['table'];
        $s = dpStructure($pdo, $t);
        if ($s === null) {
            throw new RuntimeException('Table not found in the local database: ' . $t);
        }
        $key = array_values(array_filter((array)($w['key'] ?? []), 'strlen'));
        if ($key === []) {
            $key = $uniques[$t][0] ?? (!$s['auto'] ? $s['pk'] : []);
        }
        if ($key === []) {   // its rows cannot be recognised on the target: left out, with the reason (the others still go)
            $meta[$t] = ['table' => $t, 'columns' => [], 'pk' => $s['pk'], 'auto' => $s['auto'], 'key' => [], 'links' => [], 'refs' => [], 'local' => [],
                'count' => 0, 'nokey' => (int)$pdo->query('SELECT COUNT(*) FROM ' . dpQ($t))->fetchColumn()];
            $data[$t] = [];
            continue;
        }
        $ignore = array_values(array_filter((array)($w['ignore'] ?? []), 'strlen'));
        $links = [];
        $refs = [];
        $local = $ignore;
        foreach ($fks[$t] ?? [] as $col => $ref) {
            if (in_array($col, $ignore, true)) {
                continue;
            }
            if ($ref !== $t && in_array($ref, $names, true)) {
                $links[$col] = $ref;
            } elseif ($ref !== $t && $keyable($ref)) {
                $refs[$col] = $ref;
            } else {
                $local[] = $col;
            }
        }
        foreach ((array)($w['links'] ?? []) as $col => $ref) {
            $links[(string)$col] = (string)$ref;
            unset($refs[(string)$col]);
            $local = array_values(array_diff($local, [(string)$col]));
        }
        $cols = array_keys($s['columns']);
        $where = trim((string)($w['where'] ?? ''));
        $rows = $pdo->query('SELECT * FROM ' . dpQ($t) . ($where !== '' ? ' WHERE ' . $where : '') . ($s['pk'] !== [] ? ' ORDER BY ' . implode(', ', array_map('dpQ', $s['pk'])) : ''))
            ->fetchAll(PDO::FETCH_NUM);
        foreach ($refs as $col => $ref) {
            $ci = array_search($col, $cols, true);
            foreach ($rows as $r) {
                if ($r[$ci] !== null) {
                    $refIds[$ref][(string)$r[$ci]] = true;
                }
            }
        }
        $meta[$t] = ['table' => $t, 'columns' => $cols, 'pk' => $s['pk'], 'auto' => $s['auto'], 'key' => $key,
            'links' => $links, 'refs' => $refs, 'local' => array_values(array_unique($local)), 'count' => count($rows)];
        $data[$t] = $rows;
    }
    // the key of each row pointed at in a table not sent: its first unique index with no empty value
    $refkeys = [];
    foreach ($refIds as $ref => $ids) {
        $s = dpStructure($pdo, $ref);
        $pk = $s['pk'][0];
        $cands = $uniques[$ref] ?? [];
        if ($cands === []) {   // a primary key that is not a counter (a code): it is its own key
            foreach (array_keys($ids) as $id) {
                $refkeys[$ref][(string)$id] = [[$pk], [(string)$id]];
            }
            continue;
        }
        $all = array_values(array_unique(array_merge(...$cands)));
        foreach (array_chunk(array_keys($ids), 1000) as $chunk) {
            $st = $pdo->prepare('SELECT ' . dpQ($pk) . ', ' . implode(', ', array_map('dpQ', $all)) . ' FROM ' . dpQ($ref)
                . ' WHERE ' . dpQ($pk) . ' IN (' . implode(',', array_fill(0, count($chunk), '?')) . ')');
            $st->execute(array_map('strval', $chunk));
            foreach ($st->fetchAll() as $r) {
                foreach ($cands as $k) {
                    $vals = array_map(static fn (string $c): ?string => $r[$c] === null ? null : (string)$r[$c], $k);
                    if (!in_array(null, $vals, true) && !in_array('', $vals, true)) {
                        $refkeys[$ref][(string)$r[$pk]] = [$k, $vals];
                        break;
                    }
                }
            }
        }
    }
    // parents first (a table after the tables it links to)
    $sorted = [];
    $visit = static function (string $t, array $seen) use (&$visit, &$sorted, $meta): void {
        if (isset($sorted[$t]) || isset($seen[$t])) {
            return;
        }
        $seen[$t] = true;
        foreach ($meta[$t]['links'] as $ref) {
            if (isset($meta[$ref])) {
                $visit($ref, $seen);
            }
        }
        $sorted[$t] = $meta[$t];
    };
    foreach (array_keys($meta) as $t) {
        $visit($t, []);
    }
    $flags = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PRESERVE_ZERO_FRACTION | JSON_THROW_ON_ERROR;
    $h = fopen($out, 'wb');
    if ($h === false) {
        throw new RuntimeException('Cannot write ' . $out);
    }
    fwrite($h, json_encode(['format' => 3, 'tables' => array_values($sorted), 'refkeys' => (object)$refkeys], $flags) . "\n");
    foreach (array_keys($sorted) as $t) {
        foreach ($data[$t] as $row) {
            fwrite($h, json_encode($row, $flags) . "\n");
        }
    }
    fclose($h);
    return ['tables' => count($sorted), 'rows' => array_sum(array_map('count', $data))];
}

/** Columns computed by the database (GENERATED): never written. */
function dpGenerated(PDO $pdo, string $t): array
{
    $st = $pdo->prepare("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND EXTRA LIKE '%GENERATED%'");
    $st->execute([$t]);
    return array_map('strval', $st->fetchAll(PDO::FETCH_COLUMN));
}

/**
 * Applies the rows of a sync export to the target, step by step (each request works WORK_SECONDS, then says where it
 * stopped). Never deletes a row. A row is found by its key: same → nothing, different → updated, absent → added
 * (with its id of the PC when that id is free). A link is translated: to a row sent before (its new id), to a row of
 * a table not sent (found by that row's key); not found on the target: the link is left empty when the column allows
 * it, otherwise the row is not written. Simulation ($dryRun): nothing is written — rows are only compared and counted
 * (18/11/2026: 178 000 rows of stock took 3.5 min to simulate when each was written then rolled back).
 */
function dpSyncStep(PDO $pdo, array $head, $h, array &$st, bool $dryRun): void
{
    $tables = $head['tables'];
    $refkeys = (array)($head['refkeys'] ?? []);
    $parents = [];
    foreach ($tables as $T) {
        foreach ((array)$T['links'] as $ref) {
            $parents[$ref] = true;
        }
    }
    $refCache = [];
    $refPk = [];
    $ctx = null;
    $pdo->beginTransaction();
    try {
        while ($st['ti'] < count($tables) && dpTimeLeft() > 2) {
            $ti = $st['ti'];
            $T = $tables[$ti];
            $t = (string)$T['table'];
            if (!isset($st['res'][$ti])) {
                $st['res'][$ti] = ['table' => $t, 'added' => 0, 'updated' => 0, 'same' => 0, 'skipped' => 0, 'unlinked' => 0, 'details' => [],
                    'missing_columns' => [], 'columns' => [], 'rows' => []];
            }
            $r = &$st['res'][$ti];
            if (isset($T['nokey'])) {
                $r['skipped'] = (int)$T['nokey'];
                $r['nokey'] = true;
                // 18/11/2026: "but it has a primary key" — say that this key is a counter, numbered apart on each database
                $pkCols = (array)($T['pk'] ?? []);
                $why = $pkCols !== [] && !empty($T['auto'])
                    ? 'its primary key ' . implode(', ', $pkCols) . ' is only a counter, numbered apart on each database (the same number can be another row on the target), and it has no other unique index'
                    : 'no primary key and no unique index';
                $r['details'] = [['skip', $why . ': its rows cannot be recognised on the target. Set its key columns in the project settings.']];
                $st['ti']++;
                $st['ri'] = 0;
                unset($r);
                continue;
            }
            if ($ctx === null || $ctx['ti'] !== $ti) {
                $s = dpStructure($pdo, $t);
                $colsPc = array_map('strval', (array)$T['columns']);
                $ctx = ['ti' => $ti, 's' => $s, 'colsPc' => $colsPc];
                if ($s !== null) {
                    $cols = array_values(array_intersect($colsPc, array_keys($s['columns'])));
                    $r['missing_columns'] = array_values(array_diff($colsPc, $cols));
                    $r['columns'] = $cols;
                    $ctx['cols'] = $cols;
                    $ctx['local'] = array_merge((array)$T['local'], ['updated_at'], dpGenerated($pdo, $t));   // never written
                }
            }
            if ($st['ri'] >= (int)$T['count']) {
                $st['ti']++;
                $st['ri'] = 0;
                unset($r);
                continue;
            }
            $line = fgets($h);
            $st['ri']++;
            if ($line === false) {
                throw new RuntimeException('The rows of ' . $t . ' end too early in the package.');
            }
            $s = $ctx['s'];
            if ($s === null) {   // not there yet (created at deployment by a migration or "Structure"): its rows come then
                $r['table_missing'] = true;
                $r['pending'] = (int)$T['count'];
                unset($r);
                continue;
            }
            $vals = json_decode($line, true);
            $colsPc = $ctx['colsPc'];
            if (!is_array($vals) || count($vals) !== count($colsPc)) {
                unset($r);
                continue;
            }
            $note = static function (string $kind, string $text) use (&$r): void {
                $r[match ($kind) { 'add' => 'added', 'update' => 'updated', 'unlink' => 'unlinked', default => 'skipped' }]++;
                if (count(array_filter($r['details'], static fn (array $d): bool => $d[0] === $kind)) < 10) {
                    $r['details'][] = [$kind, $text];
                }
            };
            $cols = $ctx['cols'];
            $grid = static function (string $kind, string $label, array $row, array $old = []) use (&$r, $cols): void {
                if (count($r['rows']) < 200) {
                    $r['rows'][] = ['k' => $kind, 'key' => $label, 'values' => array_map(static fn (string $c): ?string => dpCell($row[$c] ?? null), $cols),
                        'old' => array_map(static fn (mixed $v): ?string => dpCell($v), $old)];
                }
            };
            $row = array_combine($colsPc, $vals);
            $key = (array)$T['key'];
            $links = (array)$T['links'];
            $local = $ctx['local'];
            $pkPc = (array)$T['pk'];
            $pkOne = count($pkPc) === 1 ? $pkPc[0] : null;
            $pk = $s['pk'];
            $auto = $s['auto'];
            $idPc = $pkOne !== null && isset($row[$pkOne]) ? (string)$row[$pkOne] : null;
            $label = implode(' / ', array_map(static fn (string $c): string => isset($links[$c]) && $row[$c] !== null
                ? ($st['labels'][$links[$c]][(string)$row[$c]] ?? '#' . $row[$c]) : (string)$row[$c], $key));
            if ($idPc !== null && isset($parents[$t])) {
                $st['labels'][$t][$idPc] = $label;
            }
            foreach ($links as $col => $ref) {
                if (!array_key_exists($col, $row) || $row[$col] === null) {
                    continue;
                }
                $id = $st['ids'][$ref][(string)$row[$col]] ?? null;
                if ($id === null) {
                    $note('skip', $label . ': ' . $col . ' points at a row of ' . $ref . ' that was not synced');
                    unset($r);
                    continue 2;
                }
                $row[$col] = $id;
            }
            foreach ((array)$T['refs'] as $col => $ref) {
                if (!array_key_exists($col, $row) || $row[$col] === null || !array_key_exists($col, $s['columns'])) {
                    continue;
                }
                $rk = $refkeys[$ref][(string)$row[$col]] ?? null;
                $found = null;
                if ($rk !== null) {
                    $ck = $ref . "\0" . implode("\0", (array)$rk[1]);
                    if (!array_key_exists($ck, $refCache)) {
                        if (!isset($refPk[$ref])) {
                            $refPk[$ref] = dpStructure($pdo, $ref)['pk'][0] ?? null;
                        }
                        $refCache[$ck] = null;
                        if ($refPk[$ref] !== null) {
                            $q = $pdo->prepare('SELECT ' . dpQ($refPk[$ref]) . ' FROM ' . dpQ($ref) . ' WHERE '
                                . implode(' AND ', array_map(static fn (string $c): string => dpQ($c) . ' = ?', (array)$rk[0])) . ' LIMIT 1');
                            $q->execute((array)$rk[1]);
                            $v = $q->fetchColumn();
                            $refCache[$ck] = $v === false ? null : $v;
                        }
                    }
                    $found = $refCache[$ck];
                }
                if ($found !== null) {
                    $row[$col] = $found;
                    continue;
                }
                $what = $ref . ' ' . ($rk !== null ? implode(' / ', (array)$rk[1]) : '#' . $row[$col]);
                if ($s['columns'][$col]) {   // may be empty: the row comes, without this link
                    $row[$col] = null;
                    $note('unlink', $label . ': ' . $col . ' → ' . $what . ' not on the target, left empty');
                } else {
                    $note('skip', $label . ': ' . $col . ' → ' . $what . ' not on the target');
                    unset($r);
                    continue 2;
                }
            }
            $where = [];
            $par = [];
            foreach ($key as $c) {
                if (!array_key_exists($c, $row) || $row[$c] === null || $row[$c] === '') {
                    $note('skip', $label . ': empty ' . $c);
                    unset($r);
                    continue 2;
                }
                $where[] = dpQ($c) . ' = ?';
                $par[] = $row[$c];
            }
            $q = $pdo->prepare('SELECT * FROM ' . dpQ($t) . ' WHERE ' . implode(' AND ', $where) . ' LIMIT 1');
            $q->execute($par);
            $cur = $q->fetch() ?: null;
            if ($cur !== null) {
                if ($idPc !== null && count($pk) === 1 && isset($parents[$t])) {
                    $st['ids'][$t][$idPc] = $cur[$pk[0]];
                }
                $changed = [];
                foreach ($cols as $c) {
                    // who created or last changed a row stays the target's own (18/11/2026: settings "updated" only for that)
                    if (in_array($c, $pk, true) || in_array($c, $key, true) || in_array($c, $local, true) || $c === 'created_at'
                        || preg_match('/^(created|updated|modified)_by(_id)?$/', $c) === 1) {
                        continue;
                    }
                    $a = $row[$c];
                    $b = $cur[$c] ?? null;
                    if (($a === null) !== ($b === null) || ($a !== null && (string)$a !== (string)$b)) {
                        $changed[] = $c;
                    }
                }
                if ($changed === []) {
                    $r['same']++;
                    unset($r);
                    continue;
                }
                if ($dryRun) {
                    $note('update', $label . ': ' . implode(', ', array_map(static fn (string $c): string =>
                        $c . ' ' . dpShow($cur[$c] ?? null) . ' → ' . dpShow($row[$c]), $changed)));
                    $grid('update', $label, $row, array_combine($changed, array_map(static fn (string $c): mixed => $cur[$c] ?? null, $changed)));
                    unset($r);
                    continue;
                }
                try {
                    $pdo->prepare('UPDATE ' . dpQ($t) . ' SET ' . implode(', ', array_map(static fn (string $c): string => dpQ($c) . ' = ?', $changed))
                        . ' WHERE ' . implode(' AND ', array_map(static fn (string $c): string => dpQ($c) . ' = ?', $pk)))
                        ->execute(array_merge(array_map(static fn (string $c): mixed => $row[$c], $changed), array_map(static fn (string $c): mixed => $cur[$c], $pk)));
                    $note('update', $label . ': ' . implode(', ', array_map(static fn (string $c): string =>
                        $c . ' ' . dpShow($cur[$c] ?? null) . ' → ' . dpShow($row[$c]), $changed)));
                    $grid('update', $label, $row, array_combine($changed, array_map(static fn (string $c): mixed => $cur[$c] ?? null, $changed)));
                } catch (\PDOException $e) {
                    $note('skip', $label . ': ' . ($e->errorInfo[2] ?? $e->getMessage()));
                }
                unset($r);
                continue;
            }
            if ($dryRun) {   // would be added: the rows pointing at it get its id of this PC, for the count
                if ($idPc !== null && isset($parents[$t])) {
                    $st['ids'][$t][$idPc] = $idPc;
                }
                $note('add', $label);
                $grid('add', $label, $row);
                unset($r);
                continue;
            }
            $ins = array_values(array_filter($cols, static fn (string $c): bool => !in_array($c, $local, true) && !($auto && count($pk) === 1 && $c === $pk[0])));
            $withId = false;
            if ($auto && count($pk) === 1 && $idPc !== null) {
                $chk = $pdo->prepare('SELECT COUNT(*) FROM ' . dpQ($t) . ' WHERE ' . dpQ($pk[0]) . ' = ?');
                $chk->execute([$idPc]);
                if ((int)$chk->fetchColumn() === 0) {
                    $ins[] = $pk[0];
                    $withId = true;
                }
            }
            try {
                $pdo->prepare('INSERT INTO ' . dpQ($t) . ' (' . implode(', ', array_map('dpQ', $ins)) . ') VALUES (' . implode(', ', array_fill(0, count($ins), '?')) . ')')
                    ->execute(array_map(static fn (string $c): mixed => $row[$c], $ins));
                if ($idPc !== null && isset($parents[$t])) {
                    $st['ids'][$t][$idPc] = ($auto && !$withId) ? (int)$pdo->lastInsertId() : ($row[$pk[0] ?? $pkOne] ?? $idPc);
                }
                $note('add', $label);
                $grid('add', $label, $row);
            } catch (\PDOException $e) {
                $note('skip', $label . ': ' . ($e->errorInfo[2] ?? $e->getMessage()));
            }
            unset($r);
        }
        $dryRun ? $pdo->rollBack() : $pdo->commit();
    } catch (\Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }
}

/** The tables whose rows cannot be recognised from one database to the other: no unique index, a counter as key. */
function dpNoKey(PDO $pdo): array
{
    $u = dpUniqueKeys($pdo);
    $out = [];
    foreach (dpTables($pdo) as $t) {
        $s = dpStructure($pdo, $t);
        if ($t !== '_deploy_migrations' && $s !== null && ($u[$t] ?? []) === [] && ($s['auto'] || $s['pk'] === [])) {
            $out[] = $t;
        }
    }
    return $out;
}

/** Exact number of rows of every table. */
function dpCounts(PDO $pdo): array
{
    $out = [];
    foreach (dpTables($pdo) as $t) {
        if ($t !== '_deploy_migrations') {
            $out[$t] = (int)$pdo->query('SELECT COUNT(*) FROM ' . dpQ($t))->fetchColumn();
        }
    }
    return $out;
}

// =====================================================================================================================
//  Migrations (table `_deploy_migrations`)
// =====================================================================================================================

function dpMigrationsTable(PDO $pdo): void
{
    $pdo->exec('CREATE TABLE IF NOT EXISTS `_deploy_migrations` (`name` VARCHAR(255) NOT NULL PRIMARY KEY, `checksum` CHAR(40) NOT NULL,
                `applied_at` DATETIME NOT NULL) DEFAULT CHARSET=utf8mb4');
}

/** name => checksum of the applied migrations; null when the table does not exist yet (never deployed by the app). */
function dpApplied(PDO $pdo): ?array
{
    if (!in_array('_deploy_migrations', dpTables($pdo), true)) {
        return null;
    }
    $out = [];
    foreach ($pdo->query('SELECT name, checksum FROM `_deploy_migrations`') as $r) {
        $out[(string)$r['name']] = (string)$r['checksum'];
    }
    return $out;
}

/**
 * Pending migrations of a release. Already recorded: skipped (re-run if its file changed and "rerun_changed").
 * Never recorded (first deployment by the app): a migration whose file is already in the project folder on the target
 * is considered applied (baseline) — the target was deployed by other means up to that file.
 */
function dpPendingMigrations(PDO $pdo, array $m): array
{
    $mig = (array)($m['migrations']['files'] ?? []);
    $rerun = (bool)($m['migrations']['rerun_changed'] ?? false);
    $applied = dpApplied($pdo);
    // An empty database has applied nothing, whatever files are already there (e.g. after a files-only install).
    $empty = array_diff(dpTables($pdo), ['_deploy_migrations']) === [];
    $run = $baseline = [];
    foreach ($mig as $f) {
        $p = dpSafePath((string)($f['path'] ?? ''));
        if ($p === null) {
            continue;
        }
        $name = basename($p);
        $sha = (string)($f['sha1'] ?? '');
        if ($applied !== null && isset($applied[$name])) {
            if ($rerun && $applied[$name] !== $sha) {
                $run[] = ['path' => $p, 'reason' => 'changed'];
            }
            continue;
        }
        if ($applied === null && !$empty && is_file(DP_ROOT . '/' . $p)) {
            if ($rerun && sha1_file(DP_ROOT . '/' . $p) !== $sha) {
                $run[] = ['path' => $p, 'reason' => 'changed'];
            } else {
                $baseline[] = $p;
            }
            continue;
        }
        $run[] = ['path' => $p, 'reason' => 'new'];
    }
    return ['run' => $run, 'baseline' => $baseline, 'tracked' => $applied !== null];
}

// =====================================================================================================================
//  Web actions
// =====================================================================================================================

function aStatus(): array
{
    $ext = [];
    foreach (['pdo_mysql', 'zip', 'zlib', 'mbstring', 'json', 'openssl', 'curl', 'gd', 'intl', 'fileinfo'] as $x) {
        $ext[$x] = extension_loaded($x);
    }
    $m = dpLastManifest();
    $e = [
        'ok' => true, 'agent' => AGENT_VERSION, 'agent_sha1' => (string)sha1_file(__FILE__),
        'features' => ['file', 'compare', 'update_agent', 'row_values', 'row_grid', 'table', 'structure', 'clone', 'schema_sql', 'inventory', 'sql', 'tables', 'sync_steps', 'counts'], 'php' => PHP_VERSION, 'os' => PHP_OS_FAMILY,
        'server' => (string)($_SERVER['SERVER_SOFTWARE'] ?? ''), 'extensions' => $ext,
        'root' => DP_ROOT, 'writable' => is_writable(DP_ROOT), 'private' => str_replace('\\', '/', dpPrivate()),
        'files' => count(array_diff(scandir(DP_ROOT) ?: [], ['.', '..'])),
        'release' => $m !== null ? ['label' => $m['label'] ?? '', 'date' => $m['date'] ?? '', 'source' => $m['source'] ?? '', 'project' => $m['project'] ?? ''] : null,
        'limits' => ['memory_limit' => ini_get('memory_limit'), 'max_execution_time' => ini_get('max_execution_time'),
            'upload_max_filesize' => ini_get('upload_max_filesize'), 'post_max_size' => ini_get('post_max_size')],
        'disk_free_mb' => ($f = @disk_free_space(DP_ROOT)) !== false ? (int)($f / 1048576) : null,
    ];
    try {
        $c = dpDbConfig();
        $pdo = dpPdo();
        $e['db'] = ['ok' => true, 'name' => $c['name'], 'host' => $c['host'], 'source' => $c['source'],
            'version' => (string)$pdo->query('SELECT VERSION()')->fetchColumn(), 'tables' => count(dpTables($pdo)),
            'tracked' => dpApplied($pdo) !== null];
    } catch (\Throwable $t) {
        $e['db'] = ['ok' => false, 'error' => $t->getMessage()];
    }
    return $e;
}

function aConfigure(array $p): array
{
    $f = dpPrivate() . '/config.php';
    $db = (array)($p['db'] ?? []);
    if (trim((string)($db['name'] ?? '')) === '') {
        @unlink($f);   // back to auto-detection
        return ['ok' => true, 'auto' => true];
    }
    $c = ['host' => (string)($db['host'] ?? 'localhost'), 'port' => (string)($db['port'] ?? '3306'), 'name' => (string)$db['name'],
        'user' => (string)($db['user'] ?? ''), 'pass' => (string)($db['pass'] ?? '')];
    $pdo = dpConnect($c);
    dpWrite($f, "<?php\n// Written by the Déploiement agent on " . date('Y-m-d H:i') . ".\nreturn " . var_export(['db' => $c], true) . ";\n");
    return ['ok' => true, 'version' => (string)$pdo->query('SELECT VERSION()')->fetchColumn(), 'tables' => count(dpTables($pdo))];
}

function aUpload(array $p): array
{
    $name = dpSafeName($p['name'] ?? '');
    $off = (int)($p['offset'] ?? 0);
    $f = dpPrivate('packages') . '/' . $name . '.part';
    clearstatcache();
    $size = is_file($f) ? (int)filesize($f) : 0;
    if ($off === 0 && $size > 0) {
        @unlink($f);
        $size = 0;
    }
    if ($off !== $size) {
        return ['ok' => false, 'message' => 'Chunk expected at ' . $size . ', received at ' . $off . '.', 'size' => $size];
    }
    $in = fopen('php://input', 'rb');
    $out = fopen($f, 'ab');
    if ($in === false || $out === false) {
        throw new RuntimeException('Cannot write ' . $f);
    }
    $n = stream_copy_to_stream($in, $out);
    fclose($in);
    fclose($out);
    return ['ok' => true, 'size' => $size + (int)$n];
}

/** End of a transfer (HTTP chunks, FTP, SFTP, folder): "<name>.part" checked (SHA-256), then renamed "<name>". */
function aUploadDone(array $p): array
{
    $name = dpSafeName($p['name'] ?? '');
    $part = dpPrivate('packages') . '/' . $name . '.part';
    $final = dpPrivate('packages') . '/' . $name;
    $want = strtolower((string)($p['sha256'] ?? ''));
    if (!is_file($part)) {
        if (is_file($final) && hash_file('sha256', $final) === $want) {
            return ['ok' => true, 'size' => filesize($final)];
        }
        throw new RuntimeException('Received file not found: ' . $name . '.part');
    }
    if (!hash_equals($want, (string)hash_file('sha256', $part))) {
        @unlink($part);
        throw new RuntimeException('The file ' . $name . ' arrived damaged (checksum differs): send it again.');
    }
    @unlink($final);
    if (!rename($part, $final)) {
        throw new RuntimeException('Cannot rename ' . $name);
    }
    return ['ok' => true, 'size' => filesize($final)];
}

function aPlan(array $p): array
{
    [$zip, $m] = dpPackage($p['package'] ?? '');
    $zip->close();
    $keep = (array)($m['keep'] ?? []);
    $force = array_flip((array)($m['force'] ?? []));   // the target's own files (".env.production" sent as ".env")
    $last = dpLastManifest();
    $new = $changed = $removed = [];
    foreach ($m['files'] as $rel => $sha1) {
        $rel = dpSafePath((string)$rel);
        if ($rel === null || (dpKept($rel, $keep) && !isset($force[$rel]))) {
            continue;
        }
        $f = DP_ROOT . '/' . $rel;
        if (!is_file($f)) {
            $new[] = $rel;
        } elseif (sha1_file($f) !== $sha1) {
            $changed[] = $rel;
        }
    }
    if ($last !== null) {
        foreach (array_keys($last['files'] ?? []) as $rel) {
            $rel = dpSafePath((string)$rel);
            if ($rel !== null && !isset($m['files'][$rel]) && !dpKept($rel, $keep) && is_file(DP_ROOT . '/' . $rel)) {
                $removed[] = $rel;
            }
        }
    }
    [$zip2] = dpPackage($p['package'] ?? '');
    $stale = dpStale($zip2, $m, array_merge($new, $changed));
    $zip2->close();
    $out = ['ok' => true, 'label' => $m['label'] ?? '', 'date' => $m['date'] ?? '', 'source' => $m['source'] ?? '',
        'total' => count($m['files']), 'new' => $new, 'changed' => $changed, 'removed' => $removed, 'stale' => $stale,
        'first_release' => $last === null, 'migrations' => ['run' => [], 'baseline' => [], 'tracked' => false], 'db_ok' => false];
    try {
        $pdo = dpPdo();
        $out['db_ok'] = true;
        $out['migrations'] = dpPendingMigrations($pdo, $m);
    } catch (\Throwable $e) {
        $out['db_error'] = $e->getMessage();
    }
    return $out;
}

function aBackup(array $p): array
{
    $s = $p['state'] ?? null;
    $withDb = (bool)($p['db'] ?? true);
    $withFiles = (bool)($p['files'] ?? true);
    $keep = (array)($p['keep'] ?? (dpLastManifest()['keep'] ?? []));
    $all = (bool)($p['all'] ?? false);   // a copy of the whole site (clone): kept files (uploads, .env…) included
    if (!is_array($s)) {
        $id = date('Ymd-His') . '-' . bin2hex(random_bytes(3));
        $s = ['id' => $id, 'db_done' => !$withDb, 'files' => $withFiles];
        if ($withDb) {
            $s['dump'] = dpDumpState(dpPdo(), (string)dpDbConfig()['name']);
        }
    }
    $id = dpSafeName($s['id']);
    if (!$s['db_done']) {
        dpDumpStep(dpPdo(), dpPrivate('backups') . '/db-' . $id . '.sql.gz', $s['dump'], DP_START + WORK_SECONDS - 2);
        $s['db_done'] = $s['dump']['done'];
        if (!$s['db_done']) {
            return ['ok' => true, 'done' => false, 'state' => $s,
                'progress' => 'database: table ' . ($s['dump']['i'] + 1) . ' / ' . count($s['dump']['tables'])];
        }
    }
    $files = [];
    if (!empty($s['dump'])) {
        $files[] = 'db-' . $id . '.sql.gz';
    }
    $s['all'] = $s['all'] ?? $all;
    $all = (bool)$s['all'];
    if ($s['files']) {
        if (dpTimeLeft() < 8) {
            return ['ok' => true, 'done' => false, 'state' => $s, 'progress' => 'files'];
        }
        $zip = new ZipArchive();
        $zf = dpPrivate('backups') . '/files-' . $id . '.zip';
        if ($zip->open($zf, ZipArchive::CREATE | ZipArchive::OVERWRITE) !== true) {
            throw new RuntimeException('Cannot create ' . $zf);
        }
        $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator(DP_ROOT, FilesystemIterator::SKIP_DOTS));
        foreach ($it as $f) {
            if (!$f->isFile()) {
                continue;
            }
            $rel = ltrim(str_replace('\\', '/', substr($f->getPathname(), strlen(DP_ROOT))), '/');
            if ($all ? !dpKept($rel, []) : !dpKept($rel, $keep)) {   // kept files are never touched by a release: not backed up
                $zip->addFile($f->getPathname(), $rel);
            }
        }
        $zip->close();
        $files[] = 'files-' . $id . '.zip';
    }
    foreach (['db-*.sql.gz', 'files-*.zip'] as $g) {   // the 6 latest of each kind are kept
        $all = glob(dpPrivate('backups') . '/' . $g) ?: [];
        rsort($all);
        foreach (array_slice($all, 6) as $old) {
            @unlink($old);
        }
    }
    return ['ok' => true, 'done' => true, 'files' => $files,
        'sizes' => array_map(static fn (string $n): int => (int)@filesize(dpPrivate('backups') . '/' . $n), $files)];
}

function aMigrate(array $p): array
{
    [$zip, $m] = dpPackage($p['package'] ?? '');
    $pdo = dpPdo();
    dpMigrationsTable($pdo);
    $sha = [];
    foreach ((array)($m['migrations']['files'] ?? []) as $f) {
        $sha[(string)$f['path']] = (string)$f['sha1'];
    }
    $rec = $pdo->prepare('REPLACE INTO `_deploy_migrations` (name, checksum, applied_at) VALUES (?, ?, NOW())');
    foreach ((array)($p['baseline'] ?? []) as $path) {
        $rec->execute([basename((string)$path), $sha[(string)$path] ?? '']);
    }
    $done = [];
    foreach ((array)($p['run'] ?? []) as $path) {
        $path = dpSafePath((string)$path);
        if ($path === null) {
            continue;
        }
        $sql = $zip->getFromName($path);
        if ($sql === false) {
            $zip->close();
            return ['ok' => false, 'message' => 'Not in the package: ' . $path, 'done' => $done];
        }
        try {
            $n = dpRunSql($pdo, $sql, basename($path));
        } catch (\Throwable $e) {
            $zip->close();
            return ['ok' => false, 'message' => $e->getMessage(), 'done' => $done, 'failed' => $path];
        }
        $rec->execute([basename($path), $sha[$path] ?? sha1($sql)]);
        $done[] = ['path' => $path, 'statements' => $n];
    }
    $zip->close();
    return ['ok' => true, 'done' => $done];
}

function aMarkMigrations(array $p): array
{
    [$zip, $m] = dpPackage($p['package'] ?? '');
    $zip->close();
    $pdo = dpPdo();
    dpMigrationsTable($pdo);
    $rec = $pdo->prepare('REPLACE INTO `_deploy_migrations` (name, checksum, applied_at) VALUES (?, ?, NOW())');
    $n = 0;
    foreach ((array)($m['migrations']['files'] ?? []) as $f) {
        $rec->execute([basename((string)$f['path']), (string)$f['sha1']]);
        $n++;
    }
    return ['ok' => true, 'marked' => $n];
}

function aApplyFiles(array $p): array
{
    [$zip, $m] = dpPackage($p['package'] ?? '');
    $keep = (array)($m['keep'] ?? []);
    $force = array_flip((array)($m['force'] ?? []));
    $last = dpLastManifest();
    $written = $same = 0;
    $bad = [];
    $differ = [];
    foreach ($m['files'] as $rel => $sha1) {
        $rel = dpSafePath((string)$rel);
        if ($rel !== null && !(dpKept($rel, $keep) && !isset($force[$rel])) && (!is_file(DP_ROOT . '/' . $rel) || sha1_file(DP_ROOT . '/' . $rel) !== $sha1)) {
            $differ[] = $rel;
        }
    }
    $stale = dpStale($zip, $m, $differ);
    if ($stale !== []) {   // a package with only some files, and the target changed since: nothing is written
        $zip->close();
        return ['ok' => false, 'code' => 'stale', 'stale' => array_slice($stale, 0, 20),
            'message' => 'The target changed since the simulation (' . count($stale) . ' file(s), e.g. ' . $stale[0] . '): simulate again.'];
    }
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $rel = $zip->getNameIndex($i);
        if ($rel === false || str_ends_with($rel, '/') || str_starts_with($rel, '__deploy/')) {
            continue;
        }
        $rel = dpSafePath($rel);
        if ($rel === null || (dpKept($rel, $keep) && !isset($force[$rel]))) {
            continue;
        }
        $f = DP_ROOT . '/' . $rel;
        $sha = $m['files'][$rel] ?? null;
        if ($sha !== null && is_file($f) && sha1_file($f) === $sha) {
            $same++;
            continue;
        }
        $c = $zip->getFromIndex($i);
        if ($c === false) {
            $bad[] = $rel;
            continue;
        }
        dpWrite($f, $c);
        $written++;
    }
    $zip->close();
    $removed = 0;
    if ($last !== null) {
        foreach (array_keys($last['files'] ?? []) as $rel) {
            $rel = dpSafePath((string)$rel);
            if ($rel !== null && !isset($m['files'][$rel]) && !dpKept($rel, $keep) && is_file(DP_ROOT . '/' . $rel) && @unlink(DP_ROOT . '/' . $rel)) {
                $removed++;
            }
        }
    }
    file_put_contents(dpPrivate() . '/manifest.json', json_encode($m, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    if (function_exists('opcache_reset')) {
        @opcache_reset();
    }
    return ['ok' => $bad === [], 'written' => $written, 'same' => $same, 'removed' => $removed, 'unreadable' => $bad,
        'message' => $bad === [] ? null : count($bad) . ' unreadable file(s) in the package.'];
}

function aSync(array $p): array
{
    $dry = (bool)($p['dry_run'] ?? true);
    $work = dpPrivate('work');
    $st = $p['state'] ?? null;
    if (!is_array($st)) {
        [$zip] = dpPackage($p['package'] ?? '');
        $in = $zip->getStream('__deploy/sync.ndjson');
        if ($in === false) {
            $zip->close();
            return ['ok' => true, 'done' => true, 'tables' => [], 'none' => true, 'dry_run' => $dry];
        }
        foreach (glob($work . '/sync-*') ?: [] as $old) {   // what an interrupted sync left
            if (filemtime($old) < time() - 86400) {
                @unlink($old);
            }
        }
        $id = bin2hex(random_bytes(6));
        $o = fopen($work . '/sync-' . $id . '.ndjson', 'wb');
        stream_copy_to_stream($in, $o);
        fclose($o);
        fclose($in);
        $zip->close();
        $h = fopen($work . '/sync-' . $id . '.ndjson', 'rb');
        fgets($h);
        $state = ['offset' => ftell($h), 'ti' => 0, 'ri' => 0, 'ids' => [], 'labels' => [], 'res' => []];
        fclose($h);
        file_put_contents($work . '/sync-' . $id . '.state', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE));
        $st = ['id' => $id];
    }
    $id = dpSafeName($st['id'] ?? '');
    $file = $work . '/sync-' . $id . '.ndjson';
    $sf = $work . '/sync-' . $id . '.state';
    if (!is_file($file) || !is_file($sf)) {
        throw new RuntimeException('The rows of this synchronisation are gone from the target: simulate again.');
    }
    $lock = fopen($sf . '.lock', 'c');
    if ($lock !== false) {
        flock($lock, LOCK_EX);   // a step asked again while the cut one still runs: it waits, then goes on from there
    }
    $state = json_decode((string)file_get_contents($sf), true);
    $h = fopen($file, 'rb');
    $head = json_decode((string)fgets($h), true);
    if (!is_array($head['tables'] ?? null) || !is_array($state)) {
        throw new RuntimeException('Unreadable sync data in the package.');
    }
    fseek($h, (int)$state['offset']);
    dpSyncStep(dpPdo(), $head, $h, $state, $dry);
    $state['offset'] = ftell($h);
    fclose($h);
    if ($state['ti'] >= count($head['tables'])) {
        @unlink($file);
        @unlink($sf);
        if ($lock !== false) {
            fclose($lock);
            @unlink($sf . '.lock');
        }
        return ['ok' => true, 'done' => true, 'tables' => array_values($state['res']), 'dry_run' => $dry];
    }
    file_put_contents($sf . '.tmp', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE));
    rename($sf . '.tmp', $sf);   // never half written
    if ($lock !== false) {
        fclose($lock);
    }
    $T = $head['tables'][$state['ti']];
    $done = array_sum(array_map(static fn (array $x): int => (int)$x['count'], array_slice($head['tables'], 0, $state['ti']))) + $state['ri'];
    $all = array_sum(array_map(static fn (array $x): int => (int)$x['count'], $head['tables']));
    return ['ok' => true, 'done' => false, 'state' => ['id' => $id],
        'progress' => $T['table'] . ': ' . $state['ri'] . ' / ' . $T['count'] . '  (' . ($all > 0 ? (int)(100 * $done / $all) : 100) . ' %)'];
}

function aVerify(array $p): array
{
    [$zip] = dpPackage($p['package'] ?? '');
    $ref = json_decode((string)$zip->getFromName('__deploy/schema.json'), true);
    $zip->close();
    if (!is_array($ref['tables'] ?? null)) {
        return ['ok' => true, 'missing' => [], 'none' => true];
    }
    $have = dpSchema(dpPdo());
    $missing = [];
    foreach ($ref['tables'] as $t => $cols) {
        if (!isset($have[$t])) {
            $missing[] = ['table' => $t, 'column' => null];
            continue;
        }
        foreach (array_diff((array)$cols, $have[$t]) as $c) {
            $missing[] = ['table' => $t, 'column' => $c];
        }
    }
    return ['ok' => true, 'missing' => $missing, 'tables' => count($ref['tables'])];
}

// =====================================================================================================================
//  Structure of chosen tables (asked 17/11/2026: "some tables with their data, some only their structure")
// =====================================================================================================================

/** CREATE TABLE of each wanted table that exists (its counter removed: not a difference of structure). */
function dpTablesDdl(PDO $pdo, array $wanted): array
{
    $have = dpTables($pdo);
    $out = [];
    foreach ($wanted as $t) {
        $t = (string)$t;
        if (!in_array($t, $have, true)) {
            continue;
        }
        $row = $pdo->query('SHOW CREATE TABLE ' . dpQ($t))->fetch(PDO::FETCH_NUM);
        $out[$t] = preg_replace('/ AUTO_INCREMENT=\d+/', '', (string)$row[1]);
    }
    return $out;
}

/**
 * The parts of a CREATE TABLE: columns (name => definition, in order) and indexes (name => definition; PRIMARY for
 * the primary key). Constraints (foreign keys, checks) are left out: never added nor compared.
 * @return array{columns: array<string,string>, keys: array<string,string>}
 */
function dpDdlParts(string $ddl): array
{
    $cols = [];
    $keys = [];
    foreach (preg_split('/\R/', $ddl) ?: [] as $line) {
        $l = rtrim(trim($line), ',');
        if (preg_match('/^`((?:[^`]|``)+)`\s+(.+)$/s', $l, $m) === 1) {
            $cols[str_replace('``', '`', $m[1])] = $l;
        } elseif (str_starts_with($l, 'PRIMARY KEY')) {
            $keys['PRIMARY'] = $l;
        } elseif (preg_match('/^(?:UNIQUE |FULLTEXT |SPATIAL )?(?:KEY|INDEX) `((?:[^`]|``)+)`/', $l, $m) === 1) {
            $keys[str_replace('``', '`', $m[1])] = $l;
        }
    }
    return ['columns' => $cols, 'keys' => $keys];
}

/** A column definition written the same way by two servers: no display width, no character set, same defaults. */
function dpColumnNorm(string $def): string
{
    $d = strtolower($def);
    $d = (string)preg_replace('/\b(tinyint|smallint|mediumint|int|bigint)\(\d+\)/', '$1', $d);
    $d = (string)preg_replace('/ (character set|charset) [a-z0-9_]+| collate [a-z0-9_]+/', '', $d);
    $d = str_replace(['current_timestamp()', 'now()'], 'current_timestamp', $d);
    $d = (string)preg_replace("/default '(-?\\d+(?:\\.\\d+)?)'/", 'default $1', $d);
    $d = (string)preg_replace('/ default null\b/', '', $d);   // a column that may be null has null by default
    return trim((string)preg_replace('/\s+/', ' ', $d));
}

/**
 * What makes the target's tables like the developer's ($ddl: table => CREATE TABLE of this PC): the table when it is
 * missing, the columns missing (at the same place), the columns that differ, the indexes missing. Nothing is removed:
 * a column or an index only on the target stays. Not dry: run in order, stops at the first error.
 */
function dpTablesApply(PDO $pdo, array $ddl, bool $dryRun): array
{
    $have = dpTables($pdo);
    $out = [];
    foreach ($ddl as $t => $create) {
        $t = (string)$t;
        $missing = !in_array($t, $have, true);
        $todo = [];
        $kept = [];
        if ($missing) {
            $todo[] = ['what' => 'create', 'name' => $t, 'sql' => (string)preg_replace('/^CREATE TABLE /', 'CREATE TABLE IF NOT EXISTS ', (string)$create, 1)];
        } else {
            $row = $pdo->query('SHOW CREATE TABLE ' . dpQ($t))->fetch(PDO::FETCH_NUM);
            $mine = dpDdlParts((string)$create);
            $there = dpDdlParts((string)$row[1]);
            $prev = null;
            foreach ($mine['columns'] as $c => $def) {
                if (!isset($there['columns'][$c])) {
                    $todo[] = ['what' => 'add_column', 'name' => $c,
                        'sql' => 'ALTER TABLE ' . dpQ($t) . ' ADD COLUMN ' . $def . ($prev === null ? ' FIRST' : ' AFTER ' . dpQ($prev))];
                } elseif (dpColumnNorm($def) !== dpColumnNorm($there['columns'][$c])) {
                    $todo[] = ['what' => 'change_column', 'name' => $c, 'sql' => 'ALTER TABLE ' . dpQ($t) . ' MODIFY COLUMN ' . $def,
                        'before' => $there['columns'][$c], 'after' => $def];
                }
                $prev = $c;
            }
            foreach ($mine['keys'] as $k => $def) {
                if (!isset($there['keys'][$k])) {
                    $todo[] = ['what' => 'add_key', 'name' => $k, 'sql' => 'ALTER TABLE ' . dpQ($t) . ' ADD ' . $def];
                }
            }
            $kept = array_values(array_diff(array_keys($there['columns']), array_keys($mine['columns'])));
        }
        $r = ['table' => $t, 'create' => $missing, 'changes' => $todo, 'kept_columns' => $kept, 'done' => 0];
        if (!$dryRun && $todo !== []) {
            $pdo->exec('SET FOREIGN_KEY_CHECKS = 0');
            try {
                foreach ($todo as $x) {
                    $pdo->exec($x['sql']);
                    $r['done']++;
                }
            } catch (\Throwable $e) {
                $r['error'] = $e->getMessage();
                $out[] = $r;
                $pdo->exec('SET FOREIGN_KEY_CHECKS = 1');
                return ['tables' => $out, 'stopped' => true];
            }
            $pdo->exec('SET FOREIGN_KEY_CHECKS = 1');
        }
        $out[] = $r;
    }
    return ['tables' => $out, 'stopped' => false];
}

function aTables(array $p): array
{
    [$zip] = dpPackage($p['package'] ?? '');
    $json = $zip->getFromName('__deploy/tables.json');
    $zip->close();
    if ($json === false) {
        return ['ok' => true, 'tables' => [], 'none' => true];
    }
    $d = json_decode($json, true);
    if (!is_array($d['tables'] ?? null)) {
        throw new RuntimeException('Unreadable table structures in the package.');
    }
    $dry = (bool)($p['dry_run'] ?? true);
    $r = dpTablesApply(dpPdo(), $d['tables'], $dry);
    $last = end($r['tables']);
    return ['ok' => !$r['stopped'], 'tables' => $r['tables'], 'dry_run' => $dry]
        + ($r['stopped'] ? ['message' => 'Table ' . $last['table'] . ': ' . ($last['error'] ?? '')] : []);
}

/** Loads a .sql / .sql.gz from packages/ or backups/, step by step. replace: drops every table and view first. */
function aImportDb(array $p): array
{
    $s = $p['state'] ?? null;
    $pdo = dpPdo();
    if (!is_array($s)) {
        $folder = ($p['folder'] ?? 'packages') === 'backups' ? 'backups' : 'packages';
        $src = dpPrivate($folder) . '/' . dpSafeName($p['file'] ?? '');
        if (!is_file($src)) {
            throw new RuntimeException('File not found on the target: ' . ($p['file'] ?? ''));
        }
        $tables = dpTables($pdo);
        if ($tables !== [] && !($p['replace'] ?? false)) {
            return ['ok' => false, 'code' => 'db_not_empty', 'message' => 'The target database is not empty (' . count($tables) . ' tables).'];
        }
        foreach (dpTables($pdo, 'VIEW') as $v) {
            $pdo->exec('DROP VIEW IF EXISTS ' . dpQ($v));
        }
        foreach ($tables as $t) {
            $pdo->exec('DROP TABLE IF EXISTS ' . dpQ($t));
        }
        $sql = dpPrivate('tmp') . '/import-' . date('Ymd-His') . '-' . bin2hex(random_bytes(3)) . '.sql';
        if (str_ends_with($src, '.gz')) {
            $in = gzopen($src, 'rb');
            $out = fopen($sql, 'wb');
            while (!gzeof($in)) {
                fwrite($out, (string)gzread($in, 1048576));
            }
            gzclose($in);
            fclose($out);
        } else {
            copy($src, $sql);
        }
        $s = ['sql' => basename($sql), 'offset' => 0, 'statements' => 0, 'size' => filesize($sql)];
    }
    $f = dpPrivate('tmp') . '/' . dpSafeName($s['sql']);
    $r = new SqlReader($f, (int)$s['offset']);
    while (dpTimeLeft() > 1.5) {
        $q = $r->next();
        if ($q === null) {
            $pdo->exec('SET FOREIGN_KEY_CHECKS = 1');
            @unlink($f);
            return ['ok' => true, 'done' => true, 'statements' => $s['statements'], 'tables' => count(dpTables($pdo))];
        }
        if (dpSkip($q)) {
            continue;
        }
        try {
            $pdo->exec($q);
        } catch (\PDOException $e) {
            return ['ok' => false, 'message' => 'Import stopped: ' . ($e->errorInfo[2] ?? $e->getMessage()) . ' — in: '
                . mb_substr(preg_replace('/\s+/', ' ', $q) ?? '', 0, 300), 'state' => $s];
        }
        $s['statements']++;
        $s['offset'] = $r->position();
    }
    return ['ok' => true, 'done' => false, 'state' => $s, 'progress' => (int)round(100 * $s['offset'] / max(1, (int)$s['size'])) . ' %'];
}

function aRestoreFiles(array $p): array
{
    $f = dpPrivate('backups') . '/' . dpSafeName($p['file'] ?? '');
    $zip = new ZipArchive();
    if (!is_file($f) || $zip->open($f) !== true) {
        throw new RuntimeException('Unreadable files backup: ' . ($p['file'] ?? ''));
    }
    $keep = (array)(dpLastManifest()['keep'] ?? []);
    $n = 0;
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $rel = $zip->getNameIndex($i);
        if ($rel === false || str_ends_with($rel, '/') || ($rel = dpSafePath($rel)) === null || dpKept($rel, $keep)) {
            continue;
        }
        dpWrite(DP_ROOT . '/' . $rel, (string)$zip->getFromIndex($i));
        $n++;
    }
    $zip->close();
    @unlink(dpPrivate() . '/manifest.json');   // the release on the target is no longer known: the next one compares every file
    return ['ok' => true, 'files' => $n];
}

function aList(): array
{
    $out = [];
    foreach (['backups', 'packages'] as $d) {
        foreach (glob(dpPrivate($d) . '/*') ?: [] as $f) {
            if (is_file($f)) {
                $out[] = ['folder' => $d, 'name' => basename($f), 'size' => filesize($f), 'date' => date('Y-m-d H:i:s', (int)filemtime($f))];
            }
        }
    }
    usort($out, static fn (array $a, array $b): int => strcmp($b['date'], $a['date']));
    return ['ok' => true, 'files' => $out];
}

function aDownload(array $p): array
{
    $folder = ($p['folder'] ?? 'backups') === 'packages' ? 'packages' : 'backups';
    $f = dpPrivate($folder) . '/' . dpSafeName($p['file'] ?? '');
    if (!is_file($f)) {
        throw new RuntimeException('File not found: ' . ($p['file'] ?? ''));
    }
    $total = (int)filesize($f);
    $off = max(0, (int)($p['offset'] ?? 0));
    $len = max(1, min((int)($p['length'] ?? 4194304), 8388608));
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    $left = min($len, max(0, $total - $off));
    header('Content-Type: application/octet-stream');
    header('X-Deploy-Total: ' . $total);
    header('Content-Length: ' . $left);
    header('Cache-Control: no-store');
    $fh = fopen($f, 'rb');
    fseek($fh, $off);
    while ($left > 0 && !feof($fh)) {
        $b = (string)fread($fh, min(65536, $left));
        echo $b;
        $left -= strlen($b);
    }
    fclose($fh);
    exit;
}

function aDelete(array $p): array
{
    $folder = ($p['folder'] ?? 'packages') === 'backups' ? 'backups' : 'packages';
    $f = dpPrivate($folder) . '/' . dpSafeName($p['file'] ?? '');
    return ['ok' => !is_file($f) || @unlink($f)];
}

// =====================================================================================================================
//  CLI mode (the developer's PC)
// =====================================================================================================================

/** A value in a report: NULL, a number, or a short quoted text. */
function dpShow(mixed $v): string
{
    if ($v === null) {
        return 'NULL';
    }
    $s = (string)$v;
    if (strlen($s) > 60) {
        $s = (function_exists('mb_substr') ? mb_substr($s, 0, 40) : substr($s, 0, 40)) . '…';
    }
    return is_numeric($s) ? $s : '"' . str_replace(["\r", "\n"], ' ', $s) . '"';
}

/** Files a deployment must write ([$differ]) that a package does not carry: it was built for an older state. */
function dpStale(ZipArchive $zip, array $m, array $differ): array
{
    $in = [];
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $n = $zip->getNameIndex($i);
        if ($n !== false) {
            $in[$n] = true;
        }
    }
    return array_values(array_filter($differ, static fn (string $rel): bool => isset($m['files'][$rel]) && !isset($in[$rel])));
}

/** A file of the project as it is on the target, to show what a deployment would change in it. */
function aFile(array $p): array
{
    $rel = dpSafePath((string)($p['path'] ?? ''));
    $priv = dpPrivateRel();
    if ($rel === null || ($priv !== '' && str_starts_with($rel, $priv)) || preg_match('#^deploy-agent[A-Za-z0-9_-]*\.php$#', $rel) === 1) {
        throw new RuntimeException('Path refused: ' . (string)($p['path'] ?? ''));
    }
    $f = DP_ROOT . '/' . $rel;
    if (!is_file($f)) {
        return ['ok' => true, 'exists' => false];
    }
    $size = (int)filesize($f);
    if ($size > 2 * 1048576) {
        return ['ok' => true, 'exists' => true, 'size' => $size, 'sha1' => (string)sha1_file($f), 'too_big' => true];
    }
    $c = (string)file_get_contents($f);
    return ['ok' => true, 'exists' => true, 'size' => $size, 'sha1' => sha1($c), 'base64' => base64_encode($c)];
}

/** Which files of the project ({path: sha1} sent by the app) are missing or different here: only they are sent. */
function aCompare(array $p): array
{
    $keep = (array)($p['keep'] ?? []);
    $force = array_flip((array)($p['force'] ?? []));
    $differ = [];
    $same = 0;
    foreach ((array)($p['files'] ?? []) as $rel => $sha1) {
        $rel = dpSafePath((string)$rel);
        if ($rel === null || (dpKept($rel, $keep) && !isset($force[$rel]))) {
            continue;
        }
        $f = DP_ROOT . '/' . $rel;
        if (is_file($f) && sha1_file($f) === (string)$sha1) {
            $same++;
        } else {
            $differ[] = $rel;
        }
    }
    return ['ok' => true, 'differ' => $differ, 'same' => $same];
}

/** Replaces this agent by a newer one from the app: refused unless it has the same key and the same private folder. */
function aUpdateAgent(array $p): array
{
    $code = (string)($p['code'] ?? '');
    if (!str_starts_with($code, '<?php')
        || !str_contains($code, "const TOKEN_SHA256  = '" . TOKEN_SHA256 . "';")
        || !str_contains($code, "const PRIVATE_DIR   = '" . PRIVATE_DIR . "';")
        || preg_match('/const AGENT_VERSION = (\d+);/', $code, $v) !== 1) {
        throw new RuntimeException('Agent update refused: not an agent for this key and this private folder.');
    }
    if ((int)$v[1] < AGENT_VERSION) {
        throw new RuntimeException('Agent update refused: version ' . $v[1] . ' is older than ' . AGENT_VERSION . '.');
    }
    // A running PHP file cannot be replaced on Windows: the new agent is written next to this one ("…-next.php"),
    // then the app asks it to take over (this file is not running then), and this file deletes it afterwards.
    dpWrite(DP_ROOT . '/' . dpNextName(), $code);
    return ['ok' => true, 'version' => (int)$v[1], 'next' => dpNextName()];
}

function dpNextName(): string
{
    return basename(__FILE__, '.php') . '-next.php';
}

/** Run from "<agent>-next.php": copies itself over the agent, which is not running at that moment. */
function aTakeOver(): array
{
    $me = basename(__FILE__);
    if (!str_ends_with($me, '-next.php')) {
        throw new RuntimeException('Only the next agent takes over.');
    }
    $main = substr($me, 0, -strlen('-next.php')) . '.php';
    @copy(DP_ROOT . '/' . $main, dpPrivate() . '/agent-previous.php');
    dpWrite(DP_ROOT . '/' . $main, (string)file_get_contents(__FILE__));
    return ['ok' => true, 'agent' => $main];
}

/** Loads a .sql / .sql.gz into the database of [$pdo] (this PC): refused when it has tables, unless [$replace]. */
function dpCliImport(PDO $pdo, string $file, bool $replace): int
{
    if (!is_file($file)) {
        throw new RuntimeException('File not found: ' . $file);
    }
    $tables = dpTables($pdo);
    if ($tables !== [] && !$replace) {
        throw new RuntimeException('The database is not empty (' . count($tables) . ' tables).');
    }
    foreach (dpTables($pdo, 'VIEW') as $v) {
        $pdo->exec('DROP VIEW IF EXISTS ' . dpQ($v));
    }
    foreach ($tables as $t) {
        $pdo->exec('DROP TABLE IF EXISTS ' . dpQ($t));
    }
    $sql = $file;
    if (str_ends_with($file, '.gz')) {
        $sql = $file . '.sql';
        $in = gzopen($file, 'rb');
        $out = fopen($sql, 'wb');
        while (!gzeof($in)) {
            fwrite($out, (string)gzread($in, 1048576));
        }
        gzclose($in);
        fclose($out);
    }
    $n = 0;
    $r = new SqlReader($sql, 0);
    try {
        while (($q = $r->next()) !== null) {
            if (dpSkip($q)) {
                continue;
            }
            $pdo->exec($q);
            $n++;
        }
    } finally {
        if ($sql !== $file) {
            @unlink($sql);
        }
    }
    $pdo->exec('SET FOREIGN_KEY_CHECKS = 1');
    return $n;
}

/** A value for a grid: text cut at 120 characters, binary shown as such, NULL kept. */
function dpCell(mixed $v): ?string
{
    if ($v === null) {
        return null;
    }
    $s = (string)$v;
    if (!mb_check_encoding($s, 'UTF-8')) {
        return '[binary ' . strlen($s) . ' B]';
    }
    return mb_strlen($s) > 120 ? mb_substr($s, 0, 119) . '…' : $s;
}

/** Every base table: its columns with type, null, key, default, extra (in column order). */
function dpStructureAll(PDO $pdo): array
{
    $q = $pdo->query("SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_KEY, c.COLUMN_DEFAULT, c.EXTRA
        FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
        WHERE c.TABLE_SCHEMA = DATABASE() AND t.TABLE_TYPE = 'BASE TABLE' AND c.TABLE_NAME <> '_deploy_migrations'
        ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION");
    $out = [];
    foreach ($q->fetchAll(PDO::FETCH_NUM) as [$t, $c, $type, $null, $key, $def, $extra]) {
        $out[(string)$t][(string)$c] = ['type' => (string)$type, 'null' => $null === 'YES', 'key' => (string)$key, 'default' => $def, 'extra' => (string)$extra];
    }
    return $out;
}

/** One table of the target, read-only: its columns, its row count, a page of rows. Secrets are masked. */
function aTable(array $p): array
{
    $pdo = dpPdo();
    $t = (string)($p['table'] ?? '');
    if (!in_array($t, dpTables($pdo), true)) {
        throw new RuntimeException('Unknown table: ' . $t);
    }
    $limit = max(1, min(200, (int)($p['limit'] ?? 50)));
    $offset = max(0, (int)($p['offset'] ?? 0));
    $cols = [];
    $pk = [];
    foreach ($pdo->query('SHOW FULL COLUMNS FROM ' . dpQ($t))->fetchAll() as $c) {
        $cols[] = ['name' => (string)$c['Field'], 'type' => (string)$c['Type'], 'null' => $c['Null'] === 'YES', 'key' => (string)$c['Key'],
            'default' => $c['Default'], 'extra' => (string)$c['Extra']];
        if ($c['Key'] === 'PRI') {
            $pk[] = dpQ((string)$c['Field']);
        }
    }
    $secret = array_map(static fn (array $c): bool => preg_match('/pass|pwd|secret|token|hash|salt|api_?key/i', $c['name']) === 1, $cols);
    $count = (int)$pdo->query('SELECT COUNT(*) FROM ' . dpQ($t))->fetchColumn();
    $rows = [];
    $sql = 'SELECT * FROM ' . dpQ($t) . ($pk !== [] ? ' ORDER BY ' . implode(', ', $pk) : '') . ' LIMIT ' . $limit . ' OFFSET ' . $offset;
    foreach ($pdo->query($sql)->fetchAll(PDO::FETCH_NUM) as $row) {
        $rows[] = array_map(static fn (mixed $v, bool $hide): ?string => $hide && $v !== null && $v !== '' ? '••••••' : dpCell($v), $row, $secret);
    }
    return ['ok' => true, 'table' => $t, 'columns' => $cols, 'count' => $count, 'offset' => $offset, 'rows' => $rows];
}

// =====================================================================================================================
//  Comparing two databases (this PC and a target): the structure as SQL, and an inventory of the rows
// =====================================================================================================================

/**
 * The structure as a structure-only export: CREATE TABLE of every table, then CREATE VIEW. The first line names the
 * server ("-- Server version: 10.4.32-MariaDB"), which the Delta Schéma tool reads to write a script it accepts.
 */
function dpSchemaSql(PDO $pdo): string
{
    $out = '-- Server version: ' . (string)$pdo->query('SELECT VERSION()')->fetchColumn() . "\n"
        . '-- Database: ' . (string)$pdo->query('SELECT DATABASE()')->fetchColumn() . "\n"
        . '-- Structure exported by Déploiement, ' . date('Y-m-d H:i:s') . "\n\nSET NAMES utf8mb4;\n\n";
    foreach (dpTables($pdo) as $t) {
        if ($t === '_deploy_migrations') {
            continue;
        }
        $row = $pdo->query('SHOW CREATE TABLE ' . dpQ($t))->fetch(PDO::FETCH_NUM);
        // the counter differs on every copy: not a difference of structure
        $out .= '-- Table ' . $t . "\n" . preg_replace('/ AUTO_INCREMENT=\d+/', '', (string)$row[1]) . ";\n\n";
    }
    foreach (dpTables($pdo, 'VIEW') as $t) {
        $row = $pdo->query('SHOW CREATE VIEW ' . dpQ($t))->fetch(PDO::FETCH_NUM);
        $out .= '-- View ' . $t . "\n" . (string)$row[1] . ";\n\n";
    }
    return $out;
}

/**
 * The key that recognises a row from one database to the other — never the id, which differs between copies:
 * hf_ref (a reference imported from another system), else a unique index containing "code", else the first unique
 * index, else a primary key that is not a lone counter. Empty: the table is compared by its number of rows only.
 * @param array<string,list<string>> $uniques  index => columns
 * @param list<array{c:string,auto:bool}> $pk
 */
function dpKeyOf(array $cols, array $uniques, array $pk): array
{
    if (in_array('hf_ref', $cols, true)) {
        return ['hf_ref'];
    }
    foreach ($uniques as $index) {
        if (in_array('code', $index, true)) {
            return $index;
        }
    }
    if ($uniques !== []) {
        return array_values($uniques)[0];
    }
    if ($pk !== [] && !(count($pk) === 1 && $pk[0]['auto'])) {
        return array_column($pk, 'c');
    }
    return [];
}

/** "*_log", "*sessions*"… → does the table match one of them (case ignored)? */
function dpNameMatches(string $name, array $patterns): bool
{
    foreach ($patterns as $g) {
        $g = trim((string)$g);
        if ($g !== '' && preg_match('/^' . str_replace(['\*', '\?'], ['.*', '.'], preg_quote($g, '/')) . '$/i', $name) === 1) {
            return true;
        }
    }
    return false;
}

/**
 * Each table: its rows, its key, and the key of each row with a label ("CODE / Name"). A key column that points to
 * another table (a role, a category…) is replaced by the key of the row it points to, since ids differ between copies.
 * Log-like tables ($countOnly) are counted only. $special: table => key columns, chosen by the developer for a table
 * without a useful unique index. Read only. Rows matched by key, as a hand-written comparison script would.
 */
function dpInventory(PDO $pdo, array $countOnly, int $max = 200000, array $special = []): array
{
    $max = max(1000, $max);
    $cols = [];
    foreach ($pdo->query("SELECT c.TABLE_NAME t, c.COLUMN_NAME c FROM information_schema.COLUMNS c
                          JOIN information_schema.TABLES x ON x.TABLE_SCHEMA = c.TABLE_SCHEMA AND x.TABLE_NAME = c.TABLE_NAME
                          WHERE c.TABLE_SCHEMA = DATABASE() AND x.TABLE_TYPE = 'BASE TABLE' AND c.TABLE_NAME <> '_deploy_migrations'
                          ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION") as $r) {
        $cols[(string)$r['t']][] = (string)$r['c'];
    }
    $uniques = [];
    foreach ($pdo->query("SELECT TABLE_NAME t, INDEX_NAME i, COLUMN_NAME c FROM information_schema.STATISTICS
                          WHERE TABLE_SCHEMA = DATABASE() AND NON_UNIQUE = 0 AND INDEX_NAME <> 'PRIMARY'
                          ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX") as $r) {
        $uniques[(string)$r['t']][(string)$r['i']][] = (string)$r['c'];
    }
    $pks = [];
    foreach ($pdo->query("SELECT TABLE_NAME t, COLUMN_NAME c, EXTRA e FROM information_schema.COLUMNS
                          WHERE TABLE_SCHEMA = DATABASE() AND COLUMN_KEY = 'PRI' ORDER BY TABLE_NAME, ORDINAL_POSITION") as $r) {
        $pks[(string)$r['t']][] = ['c' => (string)$r['c'], 'auto' => str_contains((string)$r['e'], 'auto_increment')];
    }
    $fks = [];   // table => column => [referenced table, referenced column]
    foreach ($pdo->query('SELECT TABLE_NAME t, COLUMN_NAME c, REFERENCED_TABLE_NAME r, REFERENCED_COLUMN_NAME rc FROM information_schema.KEY_COLUMN_USAGE
                          WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL') as $r) {
        $fks[(string)$r['t']][(string)$r['c']] = [(string)$r['r'], (string)$r['rc']];
    }
    $keys = [];
    foreach ($cols as $t => $c) {
        $want = array_values(array_filter(array_map('strval', (array)($special[$t] ?? [])), static fn (string $x): bool => $x !== ''));
        $keys[$t] = $want !== [] && array_diff($want, $c) === [] ? $want : dpKeyOf($c, $uniques[$t] ?? [], $pks[$t] ?? []);
    }
    $label = static fn (string $t, array $key): ?string => array_values(array_diff(array_intersect(DP_LABELS, $cols[$t] ?? []), $key))[0] ?? null;

    // referenced table + column => [value => readable key of that row]
    $maps = [];
    $translate = static function (string $t, string $col) use (&$maps, $keys, $cols, $fks, $pdo, $label): array {
        $id = $t . "\0" . $col;
        if (isset($maps[$id])) {
            return $maps[$id];
        }
        $key = $keys[$t] ?? [];
        // no translation when that key points to other tables itself, or already is the column pointed to
        if ($key === [] || in_array($col, $key, true) || !in_array($col, $cols[$t] ?? [], true)
            || array_intersect($key, array_keys($fks[$t] ?? [])) !== []) {
            return $maps[$id] = [];
        }
        $lib = $label($t, $key);
        $map = [];
        $sql = 'SELECT ' . dpQ($col) . ' AS _ref, ' . implode(', ', array_map('dpQ', $key)) . ($lib !== null ? ', ' . dpQ($lib) . ' AS _lib' : '') . ' FROM ' . dpQ($t);
        foreach ($pdo->query($sql) as $r) {
            $vals = array_map(static fn (string $c): string => trim((string)($r[$c] ?? '')), $key);
            $map[(string)$r['_ref']] = !in_array('', $vals, true) ? implode('/', $vals)
                : (isset($r['_lib']) && (string)$r['_lib'] !== '' ? (string)$r['_lib'] : '#' . $r['_ref']);
        }
        return $maps[$id] = $map;
    };

    $out = [];
    foreach ($cols as $t => $c) {
        $rows = (int)$pdo->query('SELECT COUNT(*) FROM ' . dpQ($t))->fetchColumn();
        $key = $keys[$t];
        $e = ['rows' => $rows, 'key' => $key, 'keyFrom' => (object)[], 'countOnly' => dpNameMatches($t, $countOnly),
              'noKey' => 0, 'values' => [], 'truncated' => false];
        if ($key !== [] && !$e['countOnly'] && $rows > 0) {
            $lib = $label($t, $key);
            $by = [];
            $from = [];
            foreach ($key as $k) {
                [$rt, $rc] = $fks[$t][$k] ?? [null, null];
                if ($rt !== null && $rt !== $t) {
                    $by[$k] = $translate($rt, $rc);
                    if ($by[$k] !== []) {
                        $from[$k] = $rt;
                    }
                }
            }
            $e['keyFrom'] = (object)$from;
            $seen = [];
            $sql = 'SELECT ' . implode(', ', array_map('dpQ', $key)) . ($lib !== null ? ', ' . dpQ($lib) . ' AS _lib' : '') . ' FROM ' . dpQ($t) . ' LIMIT ' . $max;
            foreach ($pdo->query($sql) as $r) {
                $vals = array_map(static function (string $k) use ($r, $by): string {
                    $v = trim((string)($r[$k] ?? ''));
                    return $v !== '' && ($by[$k] ?? []) !== [] ? ($by[$k][$v] ?? '#' . $v) : $v;
                }, $key);
                if (in_array('', $vals, true)) {
                    $e['noKey']++;
                    continue;
                }
                $k = mb_strtolower(implode(' | ', $vals));
                if (isset($seen[$k])) {
                    continue;
                }
                $seen[$k] = true;
                // pairs, not an object: PHP would turn keys "0", "1"… into a list
                $e['values'][] = [$k, mb_substr(implode(' / ', $vals) . (isset($r['_lib']) && (string)$r['_lib'] !== '' ? ' — ' . (string)$r['_lib'] : ''), 0, 160)];
            }
            $e['truncated'] = $rows > $max;
        }
        $out[$t] = $e;
    }
    return ['server' => (string)$pdo->query('SELECT VERSION()')->fetchColumn(), 'database' => (string)$pdo->query('SELECT DATABASE()')->fetchColumn(),
            'host' => (string)gethostname(), 'time' => date('Y-m-d H:i:s'), 'tables' => (object)$out];
}

/** The inventory of the target's database, read only (see dpInventory). */
function aInventory(array $p): array
{
    @ini_set('memory_limit', '512M');
    @set_time_limit(600);
    return ['ok' => true] + dpInventory(dpPdo(), (array)($p['count_only'] ?? []), (int)($p['max'] ?? 100000), (array)($p['keys'] ?? []));
}

function dpCli(array $argv): int
{
    [, $mode, $action, $cfgFile, $out] = array_pad($argv, 5, '');
    if ($mode !== 'cli' || $action === '' || $out === '') {
        fwrite(STDERR, "Usage: php deploy-agent.php cli <schema|sync_export|tables_ddl|counts|dump|summary|structure|schema_sql|inventory|import|sql> <config.json> <output>\n");
        return 2;
    }
    @set_time_limit(0);
    ini_set('memory_limit', '-1');
    try {
        $cfg = json_decode((string)@file_get_contents($cfgFile), true);
        if (!is_array($cfg) || !is_array($cfg['db'] ?? null)) {
            throw new RuntimeException('Unreadable config: ' . $cfgFile);
        }
        if ($action === 'import') {   // the database of the copy is created when missing
            $name = (string)($cfg['db']['name'] ?? '');
            if (preg_match('/^[A-Za-z0-9_$-]{1,64}$/', $name) !== 1) {
                throw new RuntimeException('Invalid database name: ' . $name);
            }
            dpConnect(['name' => ''] + $cfg['db'])->exec('CREATE DATABASE IF NOT EXISTS ' . dpQ($name) . ' CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
        }
        $pdo = dpConnect($cfg['db']);
        $flags = JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE;
        switch ($action) {
            case 'schema':
                file_put_contents($out, json_encode(['tables' => dpSchema($pdo)], $flags));
                break;
            case 'tables_ddl':
                file_put_contents($out, json_encode(['server' => (string)$pdo->query('SELECT VERSION()')->fetchColumn(),
                    'tables' => dpTablesDdl($pdo, (array)($cfg['tables'] ?? []))], $flags | JSON_THROW_ON_ERROR));
                break;
            case 'sync_export':
                dpSyncExport($pdo, (array)($cfg['tables'] ?? []), $out);
                break;
            case 'summary':
                file_put_contents($out, json_encode(dpSummary($pdo), $flags));
                break;
            case 'counts':
                file_put_contents($out, json_encode(['tables' => (object)dpCounts($pdo), 'nokey' => dpNoKey($pdo)], $flags));
                break;
            case 'structure':
                file_put_contents($out, json_encode(['tables' => dpStructureAll($pdo)], $flags));
                break;
            case 'schema_sql':
                file_put_contents($out, dpSchemaSql($pdo));
                break;
            case 'inventory':
                file_put_contents($out, json_encode(dpInventory($pdo, (array)($cfg['count_only'] ?? []), (int)($cfg['max'] ?? 200000), (array)($cfg['keys'] ?? [])), $flags | JSON_THROW_ON_ERROR));
                break;
            case 'sql':
                file_put_contents($out, json_encode(dpSqlRun($pdo, (string)($cfg['sql'] ?? '')), $flags | JSON_PARTIAL_OUTPUT_ON_ERROR));
                break;
            case 'import':
                $n = dpCliImport($pdo, (string)($cfg['file'] ?? ''), (bool)($cfg['replace'] ?? false));
                file_put_contents($out, json_encode(['statements' => $n, 'tables' => count(dpTables($pdo))], $flags));
                break;
            case 'dump':
                @unlink($out);
                $s = dpDumpState($pdo, (string)$cfg['db']['name']);
                while (!$s['done']) {
                    dpDumpStep($pdo, $out, $s, microtime(true) + 3600);
                }
                break;
            default:
                throw new RuntimeException('Unknown CLI action: ' . $action);
        }
        echo json_encode(['ok' => true, 'size' => @filesize($out) ?: 0]), PHP_EOL;
        return 0;
    } catch (\Throwable $e) {
        fwrite(STDERR, $e->getMessage() . PHP_EOL);
        return 1;
    }
}
