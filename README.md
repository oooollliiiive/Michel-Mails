# Michel Mails

Application macOS de recherche intelligente pour Apple Mail.

Michel Mails permet de formuler des recherches en langage naturel, en français ou en anglais, avec tolérance aux fautes et aux variantes de noms. Les résultats sont affichés dans Michel Mails et chaque message peut être ouvert individuellement dans Mail. L'application peut aussi effectuer des actions explicites et confirmées, comme copier les images trouvées dans un dossier.

## Principes du produit

- Interface minimale sous forme de barre flottante et déplaçable.
- Position de la fenêtre mémorisée.
- Compréhension conversationnelle bilingue français–anglais.
- Recherche sémantique et résolution approximative des correspondants.
- Résultats fondés uniquement sur les messages réellement présents dans Mail.
- Confirmation avant toute action sur des fichiers.
- Traitement local privilégié pour protéger les données personnelles.

## Prototype actuel

Le MVP comprend :

- une barre flottante SwiftUI, déplaçable, dont la position est mémorisée ;
- une vraie présence dans le Dock, avec une icône dédiée et réouverture de la barre au clic ;
- une interprétation bilingue français–anglais via l’API OpenAI Responses ;
- un schéma de sortie strict pour convertir le sens du prompt en filtres et en ordre de tri fiables, sans coder chaque formulation en dur ;
- un mode local de secours ;
- la correction approximative des noms grâce aux Contacts et à la similarité orthographique ;
- un index SQLite local et progressif du texte intégral, des correspondants, des dates, des tailles exactes et des pièces jointes ;
- des recherches exécutées dans cet index sans afficher ni piloter l’interface de Mail ;
- une recherche utilisable pendant l’indexation, accompagnée de l’avertissement `Email scan not finished — results may be incomplete` ;
- un scan résilient qui ignore un email illisible et poursuit immédiatement le travail ;
- un compteur persistant du type `2,345 / 32,463 emails scanned` et une surveillance des nouveaux emails tant que l’application reste ouverte ;
- un interrupteur `Force Scan`, remis sur `OFF` à chaque lancement, qui utilise de gros lots, des délais très courts et ignore rapidement les emails trop lents lorsqu’il est activé ;
- une liste compacte de résultats affichée directement dans Michel Mails, avec ouverture individuelle dans Mail ;
- la détection des images jointes en excluant les petits logos, les bannières et les éléments de signature ;
- une grille universelle inspirée de Michel OS pour les images, PDF, documents, tableurs, présentations, archives, fichiers audio et vidéo ;
- des vignettes Quick Look — notamment la première page des PDF — avec le nom et la date du fichier ;
- le glisser-déposer des fichiers vers le Finder ou une autre application ;
- le copier-coller, l’enregistrement d’un ou plusieurs fichiers et l’ouverture de leur email d’origine ;
- une confirmation avant de copier des images dans un dossier ;
- le stockage local de la clé API dans un fichier privé accessible uniquement à l’utilisateur ;
- la migration automatique de l’ancienne entrée du trousseau afin d’éviter une demande de mot de passe après chaque compilation locale.

Le prompt et la date courante peuvent être envoyés à OpenAI pour être interprétés. Le contenu des emails et les pièces jointes restent sur le Mac.

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
2. Ajouter une clé API OpenAI dans les réglages de l’application.
3. Accepter l’autorisation d’automatiser Mail lorsqu’elle est demandée.

Michel Mails n’a pas besoin de l’autorisation Accessibilité. AppleScript lit et extrait les données en arrière-plan sans activer Mail ni ouvrir de fenêtre. Mail ne devient visible que lorsque l’utilisateur choisit explicitement `Open in Mail`.

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
