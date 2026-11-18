-- Recipes: written on each site by its own users, so only their structure is followed by Déploiement.
CREATE TABLE IF NOT EXISTS recipes (
    id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    slug VARCHAR(80) NOT NULL,
    title VARCHAR(120) NOT NULL,
    category_id INT UNSIGNED NULL,
    servings TINYINT UNSIGNED NOT NULL DEFAULT 2,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_recipes_slug (slug),
    CONSTRAINT fk_recipes_category FOREIGN KEY (category_id) REFERENCES categories (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
