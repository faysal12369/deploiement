-- The local database of this PC: run the three migrations, then this file.
--   CREATE DATABASE recipe_blog CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
INSERT INTO categories (code, name, position) VALUES
    ('BREAKFAST', 'Breakfast', 1),
    ('MAIN', 'Main dishes', 2),
    ('DESSERT', 'Desserts', 3),
    ('DRINK', 'Drinks', 4);

INSERT INTO recipes (slug, title, category_id, prep_minutes, servings) VALUES
    ('banana-pancakes', 'Banana pancakes', (SELECT id FROM categories WHERE code = 'BREAKFAST'), 15, 2),
    ('lemon-chicken', 'Lemon chicken with rice', (SELECT id FROM categories WHERE code = 'MAIN'), 40, 4),
    ('chocolate-mousse', 'Chocolate mousse', (SELECT id FROM categories WHERE code = 'DESSERT'), 20, 6),
    ('mint-tea', 'Fresh mint tea', (SELECT id FROM categories WHERE code = 'DRINK'), 5, 2);
