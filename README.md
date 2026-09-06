# Michel Mails

Application macOS de recherche intelligente pour Apple Mail.

Michel Mails permet de formuler des recherches en langage naturel, en français ou en anglais, avec tolérance aux fautes et aux variantes de noms. Les résultats sont affichés dans Michel Mails et chaque message peut être ouvert individuellement dans Mail. L'application peut aussi effectuer des actions explicites et confirmées, comme copier les images trouvées dans un dossier.

## Principes du produit

- Interface minimale sous forme de barre déplaçable.
- Position de la fenêtre mémorisée.
- Compréhension conversationnelle bilingue français–anglais.
- Recherche sémantique et résolution approximative des correspondants.
- Résultats fondés uniquement sur les messages réellement présents dans Mail.
- Confirmation avant toute action sur des fichiers.
- Traitement local privilégié pour protéger les données personnelles.

## Prototype actuel

Le MVP comprend :

- une barre SwiftUI déplaçable, dont la position est mémorisée, sans rester au-dessus des autres applications ;
- une vraie présence dans le Dock, avec une icône dédiée et réouverture de la barre au clic ;
- une interprétation bilingue français–anglais via l’API OpenAI Responses, activable ou désactivable à tout moment ;
- un schéma de sortie strict pour convertir le sens du prompt en filtres et en ordre de tri fiables, sans coder chaque formulation en dur ;
- un mode local rapide qui fonctionne sans API et reste disponible même lorsqu’une clé OpenAI est enregistrée ;
- la correction approximative des noms grâce aux Contacts et à la similarité orthographique ;
- un premier index local rapide des correspondants, objets, dates, tailles et pièces jointes, suivi d’un second scan progressif du contenu intégral déjà téléchargé ;
- des recherches exécutées dans cet index sans afficher ni piloter l’interface de Mail ;
- une recherche utilisable pendant l’indexation, accompagnée de l’avertissement `Email scan not finished — results may be incomplete` ;
- un scan résilient qui ignore un email illisible et poursuit immédiatement le travail ;
- deux compteurs persistants, `Email index` et `Full content scan`, et une surveillance des nouveaux emails tant que l’application reste ouverte ;
- un interrupteur `Force Scan`, remis sur `OFF` à chaque lancement, qui utilise de gros lots, des délais très courts et ignore rapidement les emails trop lents lorsqu’il est activé ;
- une reprise immédiate depuis le dernier curseur enregistré, sans attendre le recomptage complet de toutes les boîtes Mail ;
- un superviseur permanent : base locale indisponible, fichier absent ou email invalide déclenchent respectivement reconnexion ou passage au suivant, sans terminer le scan ;
- une liste compacte de résultats affichée directement dans Michel Mails, avec trombone, grandes vignettes des images jointes et ouverture individuelle dans Mail ;
- la détection des images jointes en excluant les petits logos, les bannières et les éléments de signature ;
- des interrupteurs pour contrôler l’affichage des images parasites et des emails classés Junk ;
- une grille universelle inspirée de Michel OS pour les images, PDF, documents, tableurs, présentations, archives, fichiers audio et vidéo ;
- des vignettes non bloquantes pour les formats d’image reconnus par macOS, la première page des PDF et les vidéos, avec le nom et la date du fichier ;
- le glisser-déposer des fichiers vers le Finder ou une autre application ;
- le copier-coller, l’enregistrement d’un ou plusieurs fichiers et l’ouverture de leur email d’origine ;
- une préparation automatique des vignettes : les fichiers locaux sont traités en parallèle et les pièces jointes manquantes sont demandées à Mail sans clic ;
- des récupérations auprès de Mail exécutées une par une afin de préserver sa réactivité, toujours priorisées du fichier le plus récent au plus ancien ;
- des vignettes persistantes conservées indépendamment des originaux et réutilisées aux lancements suivants ;
- un cache temporaire des originaux conservé pendant 7 jours après leur dernière utilisation, afin de ne pas redemander plusieurs fois le même fichier à Mail ;
- le refus systématique des fichiers vides ou incomplets avant toute copie ;
- une colonne `Downloads` compacte intégrée à droite de la fenêtre principale, ouverte automatiquement, refermable et consultable à la demande, ainsi qu’une destination commune `Desktop/Files from Mails`, directement visible par Michel OS ;
- une grille horizontale qui répond aussi à la molette verticale d’une souris classique ;
- une confirmation avant de copier des images dans un dossier ;
- le stockage local de la clé API dans un fichier privé accessible uniquement à l’utilisateur ;
- la migration automatique de l’ancienne entrée du trousseau afin d’éviter une demande de mot de passe après chaque compilation locale.

Lorsque `AI Interpretation` est activé, le prompt et la date courante peuvent être envoyés à OpenAI pour être interprétés. Lorsque l’interrupteur est désactivé, l’interprétation reste locale. Le contenu des emails et les pièces jointes restent toujours sur le Mac.

## Construire l’application

Le prototype peut être compilé avec les outils Swift en ligne de commande :

```bash
./Scripts/package-app.sh release
```

L’application est créée ici :

```text
.build/app/Michel Mails.app
```

Cette copie est un artefact interne. La copie utilisée par Michel reste toujours
`/Applications/Michel Mails.app` et n’est jamais lancée automatiquement après une
compilation. La signature contient une identité désignée stable afin que macOS
reconnaisse les versions successives comme la même application.

Pour lancer les tests :

```bash
swift test
```

## Première ouverture

1. Ouvrir `Michel Mails.app`.
2. Ajouter facultativement une clé API OpenAI, puis choisir `AI Interpretation` ON ou OFF.
3. Ajouter `/Applications/Michel Mails.app` dans Réglages Système › Confidentialité et sécurité › Accès complet au disque, puis rouvrir l’application.
4. Accepter l’autorisation d’automatiser Mail lors de la première utilisation de `Open in Mail` ou du téléchargement d’une pièce jointe absente du stockage local.

Michel Mails n’a pas besoin de l’autorisation Accessibilité. L’index et les fichiers locaux de Mail sont ouverts uniquement en lecture. Mail ne devient visible que lorsque l’utilisateur choisit explicitement `Open in Mail`; un téléchargement manquant peut solliciter Mail en arrière-plan sans ouvrir sa fenêtre.

## Exemples

```text
Trouve les derniers emails de Raffi qui ont une photo
Show me the five latest emails from Sarah about the trip
Montre-moi les 10 dernières images reçues par email
Montre-moi les derniers PDF reçus par email
10 plus vieux emails de Michel
Copie toutes les images des emails de Raffi dans un dossier toto
```

L’API est appelée avec `store: false` et des sorties structurées. Voir la [documentation officielle de l’API Responses](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).
