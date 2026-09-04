# Michel Mails

Application macOS de recherche intelligente pour Apple Mail.

Michel Mails permet de formuler des recherches en langage naturel, en français ou en anglais, avec tolérance aux fautes et aux variantes de noms. Les résultats peuvent être ouverts dans Mail. L'application peut aussi effectuer des actions explicites et confirmées, comme copier les images trouvées dans un dossier.

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
- un schéma de sortie strict pour convertir le prompt en filtres fiables ;
- un mode local de secours ;
- la correction approximative des noms grâce aux Contacts et à la similarité orthographique ;
- la recherche dans l’index natif de Mail, puis la sélection des vrais messages dans Mail ;
- la détection des images jointes en excluant les petits logos et éléments de signature ;
- une confirmation avant de copier des images dans un dossier ;
- le stockage de la clé API dans le trousseau macOS.

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

Pour lancer les tests :

```bash
swift test
```

## Première ouverture

1. Ouvrir `Michel Mails.app`.
2. Ajouter une clé API OpenAI dans les réglages de l’application.
3. Autoriser Michel Mails dans **Réglages Système → Confidentialité et sécurité → Accessibilité**.
4. Accepter l’autorisation d’automatiser Mail lorsqu’elle est demandée.

L’autorisation d’accessibilité sert uniquement à placer la requête interprétée dans le champ de recherche natif de Mail. AppleScript est ensuite utilisé pour vérifier les dates et les pièces jointes, sélectionner les messages, et copier les images après confirmation.

## Exemples

```text
Trouve les derniers emails de Raffi qui ont une photo
Show me the five latest emails from Sarah about the trip
Copie toutes les images des emails de Raffi dans un dossier toto
```

L’API est appelée avec `store: false` et des sorties structurées. Voir la [documentation officielle de l’API Responses](https://developers.openai.com/api/reference/cli/resources/responses/methods/create).
