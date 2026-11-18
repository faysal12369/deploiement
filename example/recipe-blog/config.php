<?php
// Recipe Blog — a tiny made-up PHP + MySQL site to try Déploiement with.
// The database settings come from .env (each copy of the site has its own: this PC, the test server…).
declare(strict_types=1);

function env_values(string $file): array
{
    $out = [];
    foreach (is_file($file) ? file($file, FILE_IGNORE_NEW_LINES) : [] as $line) {
        if (preg_match('/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/', $line, $m) === 1) {
            $out[$m[1]] = trim($m[2], "\"'");
        }
    }
    return $out;
}

function db(): PDO
{
    static $pdo = null;
    if ($pdo === null) {
        $e = env_values(__DIR__ . '/.env');
        $pdo = new PDO(
            sprintf('mysql:host=%s;port=%s;dbname=%s;charset=utf8mb4', $e['DB_HOST'] ?? '127.0.0.1', $e['DB_PORT'] ?? '3306', $e['DB_DATABASE'] ?? 'recipe_blog'),
            $e['DB_USERNAME'] ?? 'root',
            $e['DB_PASSWORD'] ?? '',
            [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]
        );
    }
    return $pdo;
}

function e(?string $s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
}
