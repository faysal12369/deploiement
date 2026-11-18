# Example: a made-up recipe blog

A tiny PHP + MySQL site to try Déploiement on your own PC, without any hosting: the "server" is a second folder of
your local XAMPP.

```
recipe-blog/
  index.php, config.php        the site (reads its database settings from .env)
  .env.example                 copy to .env — never sent: it is a "kept" file
  database/migrations/         001 categories, 002 recipes, 003 a new column — run once on each target
  database/seed.sql            the data of this PC (not sent: in "never sent")
  uploads/                     kept on each target
recipe-blog.deploy.json        the project for Déploiement (no password, no key)
```

## Try it

1. Copy `recipe-blog` to `C:\xampp\htdocs\recipe-blog`, and `.env.example` to `.env` next to it.
2. Create the database of "this PC" and fill it — in phpMyAdmin or the MySQL console:
   `CREATE DATABASE recipe_blog CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;` then run the three files of
   `database/migrations` and `database/seed.sql` in it. <http://localhost/recipe-blog> shows four recipes.
3. Create the "server": an empty folder `C:\xampp\htdocs\recipe-blog-test`, an empty database `recipe_blog_test`,
   and a `.env` in that folder with `DB_DATABASE=recipe_blog_test`.
4. In Déploiement: **Import a project…** › `recipe-blog.deploy.json`. If your XAMPP is elsewhere, change the folders
   in the project and in its target "Local test".
5. Target **Local test**: **Place the agent**, **Install…** (the empty server gets the files and the database of this
   PC), then change something — a recipe title in `index.php`, a category in the database, a new migration — and
   **Simulate**, then **Deploy**.

The table `categories` is in the project's list with **Data** ticked: its rows go to the target, matched by `code`.
The recipes are written on each site by its own users: only their structure goes, by the migrations.
