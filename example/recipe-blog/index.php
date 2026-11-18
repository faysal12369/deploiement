<?php
declare(strict_types=1);
require __DIR__ . '/config.php';

$rows = db()->query(
    'SELECT r.title, r.prep_minutes, r.servings, c.name AS category
       FROM recipes r
       LEFT JOIN categories c ON c.id = r.category_id
      ORDER BY c.position, r.title'
)->fetchAll();
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Recipe Blog</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 720px; margin: 40px auto; padding: 0 16px; color: #1e293b; }
        h1 { margin-bottom: 4px; }
        .meta { color: #64748b; margin-bottom: 28px; }
        .recipe { border: 1px solid #e2e8f0; border-radius: 10px; padding: 14px 18px; margin-bottom: 10px; }
        .tag { display: inline-block; background: #eff6ff; color: #1d63ed; border-radius: 99px; padding: 2px 10px; font-size: 13px; }
        .small { color: #64748b; font-size: 14px; }
    </style>
</head>
<body>
    <h1>Recipe Blog</h1>
    <div class="meta"><?= count($rows) ?> recipes — a made-up site to try Déploiement</div>
    <?php foreach ($rows as $r): ?>
        <div class="recipe">
            <span class="tag"><?= e($r['category'] ?? 'Other') ?></span>
            <h3><?= e($r['title']) ?></h3>
            <div class="small"><?= (int)$r['prep_minutes'] ?> min · <?= (int)$r['servings'] ?> servings</div>
        </div>
    <?php endforeach; ?>
</body>
</html>
