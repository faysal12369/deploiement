# Changelog

## 1.0.1 — 2026-11-19

- "Save the agent to a file" asks where to save it (the project folder of the server, a USB key…), keeps the name
  the app calls it by, and says where it is. It never fails silently any more: on a PC where the program sits in a
  folder Windows protects (Program Files, a protected Desktop), the working folder moves to
  `%LOCALAPPDATA%\Deploiement\work`.
- Tables: one control per table, Nothing / Structure / Structure + data, and "All tables:" in the Deploy window.
- A server whose database was deleted: Test says so, Deploy refuses, More › Install… creates the database and copies
  one into it.
- GitHub: the address of a page of the repository (…/branches, …/tree/…) is turned into the repository address; a
  410 or 404 is explained as a wrong address, not as "GitHub cannot be reached".

## 1.0.0 — 2026-11-18

First public version.

- Projects and targets: shared hosting, VPS or office server, by FTP, FTPES, FTPS, SFTP, a Windows folder or network
  share, or an agent placed by hand. Projects saved by themselves, exported and imported as `.deploy.json` (without
  passwords nor keys).
- Simulation: files that differ (with the lines that change), migrations to run, structure and data of the chosen
  tables, both databases side by side; saved as a web page.
- Deployment: files, structure (SQL migrations, or table by table: created, columns and indexes added, columns
  changed, nothing removed), data (rows added or updated, never deleted, matched by key, links translated by key),
  chosen at each deployment, table by table. A backup of the server before every change; restore in one click.
- Big tables sent step by step; a cut connection resumes where it stopped; FTP in binary mode, retried when the
  transfer port does not answer.
- Compare the databases of this PC and a server, SQL console on a server, clone a server to this PC, install a
  project on an empty server, GitHub branch after a deployment, e-mail alerts when a server stops answering.
- English and French, light and dark theme.
