# Security

Déploiement places a PHP agent on your servers. That agent can write files and run SQL there, so its safety matters.

## How the agent is protected

- It has a random file name, and answers only requests that carry its secret key (only the SHA-256 of the key is in
  the file). A wrong key is refused after a short delay.
- The key is stored encrypted on your PC (Windows DPAPI, tied to your Windows account). Project files you export
  (`.deploy.json`) never contain passwords nor keys.
- Its private folder (packages, backups) is protected by an `.htaccess` file; put it outside the web root when your
  host allows it (target settings › Agent private folder, e.g. `../.deploy-app`).
- Use HTTPS for your targets, so the key never travels in clear.
- Remove an agent you no longer use, or make a new key (target settings › Agent › New key).

## Reporting a vulnerability

Please do not open a public issue. Use **Security › Report a vulnerability** on this repository (a private report),
with the steps to reproduce. You will get an answer as soon as possible, and credit in the fix if you wish.
