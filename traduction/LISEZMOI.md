# Traduction Bintuk

Chaque page a maintenant un fichier `traduction/<page>.json` qui contient
tous les segments de texte traduisibles de cette page, extraits automatiquement.

## Comment traduire

Ouvre un fichier, par exemple `traduction/index.json` :

```json
{
  "t001": "République d'Étalie — Site officiel du gouvernement",
  "t002": "Notre Roîe",
  "t007": "Accueil",
  ...
}
```

Remplace simplement chaque valeur (à droite du `:`) par sa traduction en
Bintuk. Ne touche pas aux clés (`t001`, `t002`...) — elles font le lien
avec le bon endroit dans le HTML. Le français reste toujours visible tant
qu'une clé n'a pas encore de traduction (le site retombe automatiquement
sur le texte original si la clé est absente ou vide).

Ordre suggéré, du plus visible au moins visible : `index.json` en premier
(page d'accueil), puis les pages que tes visiteurs consultent le plus.

## Comment ça marche sur le site

- Le bouton "Bintuk" (en haut à gauche de chaque page) appelle
  `basculerLangue()`, défini dans `assets/i18n.js`.
- Un clic charge le fichier `traduction/<page>.json` correspondant à la
  page affichée et remplace le texte des éléments marqués `data-i18n`.
- Le choix de langue est mémorisé (`localStorage`) et s'applique aux
  pages suivantes visitées, jusqu'à ce que tu recliques sur le bouton
  pour revenir au français.
- Rien d'autre n'a été modifié : le HTML, le CSS, les scripts Supabase
  du portail citoyen fonctionnent exactement comme avant.

## Limite connue

Le tableau de bord du portail citoyen (après connexion) est généré par
JavaScript une fois la personne connectée — ce contenu-là n'est pas
couvert par ce système et resterait en français même en mode Bintuk.
Si tu veux que je m'attaque à cette partie-là aussi (c'est plus long,
il faut traduire les chaînes directement dans le script), dis-le-moi.
