-- Categories of recipes: reference data, sent to the targets by Déploiement ("Data" box), matched by their code.
CREATE TABLE IF NOT EXISTS categories (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    code VARCHAR(20) NOT NULL,
    name VARCHAR(60) NOT NULL,
    position SMALLINT NOT NULL DEFAULT 0,
    UNIQUE KEY uq_categories_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
